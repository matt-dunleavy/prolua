// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Lua State Management
//!
//! This module implements the Lua state structure (lua_State) and global state
//! management. Each Lua state represents a thread of execution with its own
//! stack, while the global state contains shared data like the string table,
//! garbage collector, and registry.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const builtin = @import("builtin");

const value = @import("value.zig");
const gc = @import("gc.zig");
const opcode = @import("opcode.zig");
const proto = @import("proto.zig");
const table = @import("table.zig");
const config = @import("config.zig");
const string_interning = @import("string.zig");
const stack = @import("stack.zig");

/// Lua thread status
pub const ThreadStatus = enum(u8) {
    ok = 0,
    yield = 1,
    errrun = 2,
    errsyntax = 3,
    errmem = 4,
    errerr = 5,
    errfile = 6,

    pub fn isError(self: ThreadStatus) bool {
        return @intFromEnum(self) >= @intFromEnum(ThreadStatus.errrun);
    }
};

/// Hook event types
pub const HookEvent = enum(u8) {
    call = 0,
    ret = 1,
    line = 2,
    count = 3,
    tail_call = 4,
};

/// Hook mask flags
pub const HookMask = packed struct {
    call: bool = false,
    ret: bool = false,
    line: bool = false,
    count: bool = false,
    _padding: u4 = 0,

    pub fn toInt(self: HookMask) u8 {
        return @bitCast(self);
    }

    pub fn fromInt(mask: u8) HookMask {
        return @bitCast(mask & 0xF);
    }

    pub fn any(self: HookMask) bool {
        return self.call or self.ret or self.line or self.count;
    }
};

/// Debug hook function. Native, like every other callback here: it may raise
/// a Lua error by returning one.
pub const HookFn = *const fn (L: *LuaState, ar: *DebugInfo) anyerror!void;

/// Extra stack space for error handling and C calls
pub const EXTRA_STACK = 5;

/// Minimum stack size
pub const BASIC_STACK_SIZE = 2 * config.MINSTACK;

/// Maximum stack size
pub const MAXSTACK = 1000000;

/// Registry index pseudo-indices
pub const REGISTRY_INDEX = -MAXSTACK - 1000;
pub const RIDX_MAINTHREAD = 1;
pub const RIDX_GLOBALS = 2;
pub const RIDX_LAST = RIDX_GLOBALS;

/// Call info flags
pub const CallStatus = packed struct {
    // Call type
    isLua: bool = false, // call is running a Lua function
    isHooked: bool = false, // call is running a debug hook
    isFresh: bool = false, // call is a fresh invocation

    // C function flags
    isYpcall: bool = false, // a protected call that can be yielded across (CIST_YPCALL)
    isTailCall: bool = false, // call was tail called
    isHookYielded: bool = false, // last hook called yielded

    // Finalizer flag
    isFinalizer: bool = false, // call is running a finalizer

    // Transfer flag
    hasTransfer: bool = false, // call has transfer info

    // Reserved bits
    _reserved: u8 = 0,
};

/// Call information for functions
pub const CallInfo = struct {
    func: [*]value.TValue, // function being called
    top: [*]value.TValue, // top for this function
    previous: ?*CallInfo, // previous call info
    next: ?*CallInfo, // next call info

    // Union for different call types
    u: union {
        l: LuaCallInfo, // for Lua functions
        c: CCallInfo, // for C functions
    },

    // Extra values (vararg)
    extra: ?[*]value.TValue,

    // Return information
    nresults: i16, // expected number of results (-1 = multiple)
    callstatus: CallStatus,

    // Transfer information (for coroutines)
    transfer: u16, // number of values transferred
    ftransfer: u16, // number of values transferred on yield

    pub fn init() CallInfo {
        return .{
            .func = undefined,
            .top = undefined,
            .previous = null,
            .next = null,
            .u = .{ .l = LuaCallInfo.init() },
            .extra = null,
            .nresults = 0,
            .callstatus = .{},
            .transfer = 0,
            .ftransfer = 0,
        };
    }
};

/// Lua function call info
pub const LuaCallInfo = struct {
    // The base register of a Lua frame is always `ci.func + 1` (Lua 5.4
    // moves the function above the varargs instead of keeping a base field).
    savedpc: ?[*]const opcode.Instruction, // saved program counter
    nextraargs: u32, // number of extra (vararg) arguments below `func`
    nres: u32, // results of an interrupted RETURN (finishOp needs them back)

    pub fn init() LuaCallInfo {
        return .{
            .savedpc = null,
            .nextraargs = 0,
            .nres = 0,
        };
    }
};

/// C function call info. The extra fields carry what `lua_pcallk` keeps in
/// `CallInfo.u2` so a protected call can be finished after a yield unwound
/// the native frame that started it.
pub const CCallInfo = struct {
    k: ?ContinuationFn, // continuation function
    ctx: usize, // context info for continuation
    old_errfunc: usize, // old error handler
    funcidx: usize, // stack offset of the called function (u2.funcidx)
    errfunc: usize, // stack offset of the message handler, 0 for none
    nyield: u32, // number of values yielded (u2.nyield)
    recst: ThreadStatus, // status to finish an interrupted protected call with

    pub fn init() CCallInfo {
        return .{
            .k = null,
            .ctx = 0,
            .old_errfunc = 0,
            .funcidx = 0,
            .errfunc = 0,
            .nyield = 0,
            .recst = .ok,
        };
    }
};

/// Continuation of a native function interrupted by a yield: called with the
/// status of the interrupted call and the context the function stored
/// (lua_KFunction). Returns the number of results, like the function itself.
pub const ContinuationFn = *const fn (L: *LuaState, status: ThreadStatus, ctx: usize) anyerror!i32;

/// Native function type. This is a Zig-native signature, not a C ABI one: a
/// handler returns the number of results it pushed and reports Lua errors by
/// returning a Zig error (see `LuaState.throw`). Any `fn (*LuaState) !i32`
/// coerces to it, so library functions need no trampoline.
pub const CFunction = *const fn (L: *LuaState) anyerror!i32;

/// Debug information about a function or an activation record (lua_Debug),
/// filled in by `debug.getInfo` according to the options requested
pub const DebugInfo = struct {
    event: HookEvent = .call,
    name: ?[]const u8 = null, // 'n'
    namewhat: []const u8 = "", // 'n': "global", "local", "method", "field", "upvalue", "" ...
    what: []const u8 = "", // 'S': "Lua", "C", "main"
    source: []const u8 = "", // 'S'
    currentline: i32 = -1, // 'l'
    linedefined: i32 = -1, // 'S'
    lastlinedefined: i32 = -1, // 'S'
    nups: u8 = 0, // 'u'
    nparams: u8 = 0, // 'u'
    isvararg: bool = false, // 'u'
    istailcall: bool = false, // 't'
    ftransfer: u16 = 0, // 'r'
    ntransfer: u16 = 0, // 'r'
    short_src_buf: [config.IDSIZE]u8 = undefined, // 'S'
    short_src_len: usize = 0,

    // Private part: the activation record this describes, if any
    i_ci: ?*CallInfo = null,

    pub fn shortSrc(self: *const DebugInfo) []const u8 {
        return self.short_src_buf[0..self.short_src_len];
    }
};

/// Memory allocator function type
pub const AllocFn = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;

/// Panic function type
pub const PanicFn = *const fn (L: *LuaState) callconv(.c) c_int;

/// Warning function type
pub const WarnFn = *const fn (ud: ?*anyopaque, msg: [*c]const u8, tocont: c_int) callconv(.c) void;

/// Global state shared between all threads
pub const GlobalState = struct {
    // Memory management
    frealloc: AllocFn, // memory allocator function
    ud: ?*anyopaque, // userdata for allocator

    // String interning
    string_pool: string_interning.StringPool,
    strcache: [config.STRCACHE_N][config.STRCACHE_M]?*value.String,
    seed: u32, // randomized seed for hashes

    // Garbage collector: the single owner of every GC list, colour and
    // memory-accounting field (there is no duplicate set here).
    gc: gc.GarbageCollector,

    // Thread management
    mainthread: *LuaState,

    // Error handling
    panic: ?PanicFn, // panic function

    // Warnings
    warnf: ?WarnFn, // warning function
    ud_warn: ?*anyopaque, // userdata for warning function
    warn_on: bool, // whether `warn` prints (the "@on"/"@off" control messages)
    warn_cont: bool, // a warning message is in progress (`warnfcont`): no prefix for the next piece

    // Global registry and metatables
    l_registry: value.TValue,
    mt: [NUM_TYPE_TAGS]?*value.Table, // metatables for basic types, indexed by ValueType
    tmname: [value.TMS.count]*value.String, // tag method names

    // Version
    version: ?*const f64,

    /// "not enough memory", interned when the state is created and marked
    /// every cycle (luaC_fix / G(L)->memerrmsg): the one string that must
    /// exist when no string can be made
    memerrmsg: value.TValue,

    // Memory allocator wrapper
    allocator: std.mem.Allocator,

    pub const NUM_TYPE_TAGS = @typeInfo(value.ValueType).@"enum".fields.len;

    pub fn init(allocator: std.mem.Allocator, f: AllocFn, ud: ?*anyopaque) !*GlobalState {
        const g = try allocator.create(GlobalState);
        errdefer allocator.destroy(g);

        g.* = .{
            .frealloc = f,
            .ud = ud,
            .string_pool = undefined, // Will initialize after creating the gc
            .gc = gc.GarbageCollector.init(allocator),
            .strcache = undefined,
            .seed = @truncate(@intFromPtr(g) >> 4), // address-derived seed (luai_makeseed style)
            .mainthread = undefined, // Set later
            .panic = null,
            .warnf = null,
            .ud_warn = null,
            .warn_on = false,
            .warn_cont = false,
            .l_registry = value.TValue.nil(),
            .mt = .{null} ** NUM_TYPE_TAGS,
            .tmname = undefined, // Initialize later
            .version = &config.LUA_VERSION_NUM,
            .memerrmsg = value.TValue.nil(),
            .allocator = allocator,
        };

        // From here on everything the state allocates is accounted by the
        // collector (l_alloc / luaM_*)
        g.gc.attachAccounting();
        g.allocator = g.gc.allocator;

        // The collector needs the pool to unlink dead strings, and the pool
        // needs the collector to own new strings.
        g.string_pool = try string_interning.StringPool.init(g.allocator, &g.gc);
        errdefer g.string_pool.deinit();
        g.gc.strpool = &g.string_pool;
        g.gc.global = g;

        // Initialize string cache
        for (&g.strcache) |*row| {
            for (row) |*entry| {
                entry.* = null;
            }
        }

        g.memerrmsg = value.TValue.string(try g.string_pool.intern("not enough memory"));

        // Initialize tag method names
        inline for (@typeInfo(value.TMS).@"enum".fields, 0..) |field, i| {
            g.tmname[i] = try g.string_pool.intern(field.name);
        }

        return g;
    }

    pub fn deinit(self: *GlobalState) void {
        // Free every collectable object first (strings unlink themselves from
        // the pool while it is still alive), then the pool's own tables.
        const backing = self.gc.backing; // the accounting allocator lives in this block
        self.gc.deinit();
        self.string_pool.deinit();
        backing.destroy(self);
    }
};

/// Error jump buffer (Zig replacement for setjmp/longjmp)
pub const ErrorJmp = struct {
    previous: ?*ErrorJmp,
    status: ThreadStatus,

    // In Zig, we use error returns instead of longjmp
    // This struct is kept for API compatibility
};

/// Lua state (thread)
pub const LuaState = struct {
    // Common header for GC
    header: value.GCObject,

    // Thread status
    status: ThreadStatus,
    allowhook: u8, // whether hooks are allowed

    // Stack
    stack: [*]value.TValue, // stack base
    top: [*]value.TValue, // first free slot in stack
    stack_last: [*]value.TValue, // end of stack space (last free slot)
    stacksize: u32,

    // Call info
    ci: *CallInfo, // current call info
    base_ci: CallInfo, // base call info
    oldpc: u32, // index of the last instruction the line hook saw (luaG_traceexec)

    // Open upvalues
    openupval: ?*value.Upvalue, // list of open upvalues
    twups: ?*LuaState, // next thread with open upvalues (lgc.c `twups`); self when not in the list
    gclist: ?*value.GCObject,

    // To-be-closed variables, as offsets from `stack` (innermost last)
    tbclist: std.ArrayList(u32),

    // Hook information
    hook: ?HookFn,
    basehookcount: i32,
    hookcount: i32,
    hookmask: HookMask,

    // Error handling
    errorJmp: ?*ErrorJmp, // current error recovery point
    errfunc: usize, // current error handling function

    // Thread info
    nci: u32, // number of call infos
    nCcalls: u16, // number of nested C calls
    nny: u16, // number of non-yieldable calls in progress (nCcalls' high half in C)
    l_G: *GlobalState, // global state

    // Allocator for easier memory management
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, L: ?*LuaState) !*LuaState {
        const thread = try allocator.create(LuaState);
        errdefer allocator.destroy(thread);

        // Initialize stack
        const stack_mem = try allocator.alloc(value.TValue, BASIC_STACK_SIZE);
        errdefer allocator.free(stack_mem);

        thread.* = .{
            .header = .{
                .next = null,
                .tt = @intFromEnum(value.ValueType.thread),
                .marked = 0,
            },
            .status = .ok,
            .allowhook = 1,
            .stack = stack_mem.ptr,
            .top = stack_mem.ptr,
            .stack_last = stack_mem.ptr + BASIC_STACK_SIZE - EXTRA_STACK,
            .stacksize = BASIC_STACK_SIZE,
            .ci = &thread.base_ci,
            .base_ci = CallInfo.init(),
            .oldpc = 0,
            .openupval = null,
            .twups = undefined, // set below: the sentinel is the thread itself
            .gclist = null,
            .tbclist = .empty,
            .hook = null,
            .basehookcount = 0,
            .hookcount = 0,
            .hookmask = .{},
            .errorJmp = null,
            .errfunc = 0,
            .nci = 1,
            .nCcalls = 0,
            .nny = if (L == null) 1 else 0, // the main thread can never yield
            .l_G = if (L) |parent| parent.l_G else undefined,
            .allocator = allocator,
        };

        thread.twups = thread; // not in the collector's `twups` list

        // Initialize stack to nil
        for (stack_mem) |*slot| {
            slot.* = value.TValue.nil();
        }

        // Setup base call info: slot 0 holds the (nil) "function" of the
        // base frame, so the frame's first value lives at stack + 1 (lstate.c)
        thread.base_ci.func = thread.stack;
        thread.top = thread.stack + 1;
        thread.base_ci.top = thread.top + config.MINSTACK;
        thread.ci = &thread.base_ci;

        // If this is the main thread, setup globals
        if (L == null) {
            thread.l_G = try GlobalState.init(allocator, defaultAlloc, null);
            errdefer thread.l_G.deinit();
            thread.allocator = thread.l_G.allocator; // accounted from now on
            thread.l_G.mainthread = thread;
            thread.l_G.gc.mainthread = thread;
            // The main thread is not in any GC list but is a root: it must
            // start white so that marking traverses it (re-whitened at sweep end)
            thread.header.marked = thread.l_G.gc.currentwhite;
            thread.l_G.gc.l_registry = &thread.l_G.l_registry;

            // Create registry table
            const reg = try thread.l_G.gc.newTable(0, 0);
            thread.l_G.l_registry = value.TValue.table(reg);

            // Set main thread in registry
            try reg.setInt(RIDX_MAINTHREAD, value.TValue.thread(thread));

            // Create global table
            const globals = try thread.l_G.gc.newTable(0, 0);
            try reg.setInt(RIDX_GLOBALS, value.TValue.table(globals));
        } else {
            thread.header.marked = L.?.l_G.gc.currentwhite;
        }

        return thread;
    }

    pub fn deinit(self: *LuaState) void {
        // Closing the main state runs all pending finalizers first, while
        // this stack can still be used for the calls
        if (self == self.l_G.mainthread) {
            self.l_G.gc.closeFinalizers();
        }

        // Free the CallInfo chain allocated by stack.nextCI
        var ci = self.base_ci.next;
        while (ci) |c| {
            const next = c.next;
            self.allocator.destroy(c);
            ci = next;
        }

        self.tbclist.deinit(self.allocator);

        // Free stack
        self.allocator.free(self.stack[0..self.stacksize]);

        // If main thread, cleanup global state (frees every other object,
        // including the other threads). The accounting allocator lives in
        // the global state, so the main thread itself, which was allocated
        // before it existed, is released through the backing allocator.
        if (self == self.l_G.mainthread) {
            const backing = self.l_G.gc.backing;
            self.l_G.deinit();
            backing.destroy(self);
            return;
        }

        self.allocator.destroy(self);
    }

    // Stack operations

    /// Get current stack top (number of values in the current frame)
    pub fn getTop(self: *const LuaState) i32 {
        return @intCast((@intFromPtr(self.top) - @intFromPtr(self.ci.func + 1)) / @sizeOf(value.TValue));
    }

    /// Set stack top
    pub fn setTop(self: *LuaState, idx: i32) void {
        const func = self.ci.func;
        const newtop = if (idx >= 0)
            func + @as(usize, @intCast(idx)) + 1
        else
            self.top - @as(usize, @intCast(-idx - 1));

        assert(@intFromPtr(newtop) >= @intFromPtr(func + 1));
        assert(@intFromPtr(newtop) <= @intFromPtr(self.stack_last));

        // Set new values to nil
        while (@intFromPtr(self.top) < @intFromPtr(newtop)) : (self.top += 1) {
            self.top[0] = value.TValue.nil();
        }
        self.top = newtop;
    }

    /// Check if stack has space for n elements (may reallocate the stack)
    pub fn checkStack(self: *LuaState, n: i32) !void {
        try stack.checkStack(self, n);
    }

    /// Push a value onto the stack
    pub fn pushValue(self: *LuaState, v: value.TValue) !void {
        try stack.push(self, v);
    }

    /// Pop a value from the stack
    pub fn popValue(self: *LuaState) value.TValue {
        assert(@intFromPtr(self.top) > @intFromPtr(self.ci.func + 1));
        self.top -= 1;
        return self.top[0];
    }

    /// Push nil
    pub fn pushNil(self: *LuaState) !void {
        try self.pushValue(value.TValue.nil());
    }

    /// Push boolean
    pub fn pushBoolean(self: *LuaState, b: bool) !void {
        try self.pushValue(value.TValue.boolean(b));
    }

    /// Push integer
    pub fn pushInteger(self: *LuaState, n: i64) !void {
        try self.pushValue(try value.TValue.integerOrBox(&self.l_G.gc, n));
    }

    /// Push float
    pub fn pushNumber(self: *LuaState, n: f64) !void {
        try self.pushValue(value.TValue.float(n));
    }

    /// Push string
    pub fn pushString(self: *LuaState, s: []const u8) !void {
        const str = try self.l_G.string_pool.create(s); // interns short strings only
        try self.pushValue(value.TValue.string(str));
    }

    /// Push light userdata
    pub fn pushLightUserdata(self: *LuaState, p: *anyopaque) !void {
        try self.pushValue(value.TValue.lightUserdata(p));
    }

    /// Get value at index (see stack.index2Stack for the index rules)
    pub fn index2Value(self: *LuaState, idx: i32) !*value.TValue {
        return stack.index2Stack(self, idx);
    }

    /// Type checking
    pub fn type_(self: *LuaState, idx: i32) !value.ValueType {
        const v = try self.index2Value(idx);
        return v.tag();
    }

    pub fn isNil(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isNil();
    }

    pub fn isBoolean(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isBoolean();
    }

    pub fn isNumber(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isNumber();
    }

    pub fn isString(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isString();
    }

    pub fn isTable(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isTable();
    }

    pub fn isFunction(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isFunction();
    }

    pub fn isThread(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isThread();
    }

    /// Value extraction
    pub fn toBoolean(self: *LuaState, idx: i32) bool {
        const v = self.index2Value(idx) catch return false;
        return v.isTruthy();
    }

    pub fn toInteger(self: *LuaState, idx: i32) !i64 {
        const v = try self.index2Value(idx);
        return v.asInteger() orelse error.NotAnInteger;
    }

    pub fn toNumber(self: *LuaState, idx: i32) !f64 {
        const v = try self.index2Value(idx);
        if (v.asFloat()) |f| return f;
        if (v.asInteger()) |i| return @floatFromInt(i);
        return error.NotANumber;
    }

    pub fn toString(self: *LuaState, idx: i32) ![]const u8 {
        const v = try self.index2Value(idx);
        if (v.asString()) |s| return s.slice();
        return error.NotAString;
    }

    /// Create a new thread (owned by the garbage collector) and push it
    pub fn newThread(self: *LuaState) !*LuaState {
        const thread = try self.l_G.gc.newThread(self);
        try self.pushValue(value.TValue.thread(thread));
        return thread;
    }

    /// Close the state
    pub fn close(self: *LuaState) void {
        self.deinit();
    }

    /// Get/set globals
    pub fn getGlobal(self: *LuaState, name: []const u8) !void {
        const globals = self.l_G.l_registry.asTable().?.getInt(RIDX_GLOBALS);
        const key = try self.l_G.string_pool.intern(name);
        const val = globals.asTable().?.get(value.TValue.string(key));
        try self.pushValue(val);
    }

    pub fn setGlobal(self: *LuaState, name: []const u8) !void {
        const val = self.popValue();
        const globals = self.l_G.l_registry.asTable().?.getInt(RIDX_GLOBALS);
        const key = try self.l_G.string_pool.intern(name);
        const gt = globals.asTable().?;
        try gt.set(value.TValue.string(key), val);
        self.l_G.gc.barrierBackValue(&gt.header, &value.TValue.string(key));
        self.l_G.gc.barrierBackValue(&gt.header, &val);
    }

    /// Create error message
    pub fn error_(self: *LuaState, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);

        try self.pushString(msg);
        return self.throw(.errrun);
    }

    /// Throw an error: the error object is on top of the stack. Errors
    /// propagate as `error.LuaError` up to the nearest protected call (or to
    /// the host, which decides what to do); the panic function, if any, is
    /// consulted only when no protected call is active.
    pub fn throw(self: *LuaState, status: ThreadStatus) error{LuaError}!void {
        self.status = status;
        if (self.errorJmp) |jmp| {
            jmp.status = status;
        } else if (self.l_G.panic) |panic_fn| {
            _ = panic_fn(self);
        }
        return error.LuaError;
    }

    /// Set panic function
    pub fn atPanic(self: *LuaState, panicf: ?PanicFn) ?PanicFn {
        const old = self.l_G.panic;
        self.l_G.panic = panicf;
        return old;
    }

    /// Set warning function
    pub fn atWarning(self: *LuaState, warnf: ?WarnFn, ud: ?*anyopaque) void {
        self.l_G.warnf = warnf;
        self.l_G.ud_warn = ud;
    }

    /// Protected call wrapper
    pub fn pcall(self: *LuaState, func: anytype, args: anytype) ThreadStatus {
        var jmp = ErrorJmp{
            .previous = self.errorJmp,
            .status = .ok,
        };
        self.errorJmp = &jmp;
        defer self.errorJmp = jmp.previous;

        @call(.auto, func, .{self} ++ args) catch |err| {
            _ = err;
            return jmp.status;
        };

        return .ok;
    }
};

/// Allocator backing `defaultAlloc`. The C allocator matches Lua's
/// realloc-based design and is what the interpreter itself uses, but a test
/// root compiled on its own does not link libc, so fall back to a pure-Zig
/// allocator there rather than failing to build.
const default_allocator: std.mem.Allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.smp_allocator;

/// Default allocator function
fn defaultAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const allocator = default_allocator;

    _ = ud;

    if (nsize == 0) {
        // Free
        if (ptr) |p| {
            allocator.free(@as([*]u8, @ptrCast(p))[0..osize]);
        }
        return null;
    } else if (ptr == null) {
        // Allocate
        const allocated_mem = allocator.alloc(u8, nsize) catch return null;
        return allocated_mem.ptr;
    } else {
        // Realloc
        const old_mem = @as([*]u8, @ptrCast(ptr.?))[0..osize];
        const new_mem = allocator.realloc(old_mem, nsize) catch return null;
        return new_mem.ptr;
    }
}

// Tests
test "LuaState creation and destruction" {
    const allocator = std.testing.allocator;

    const L = try LuaState.init(allocator, null);
    defer L.deinit();

    try std.testing.expect(L.status == .ok);
    try std.testing.expect(L.stacksize == BASIC_STACK_SIZE);
    try std.testing.expect(L.nCcalls == 0);
}

test "LuaState stack operations" {
    const allocator = std.testing.allocator;

    const L = try LuaState.init(allocator, null);
    defer L.deinit();

    // Push values
    try L.pushNil();
    try L.pushBoolean(true);
    try L.pushInteger(42);
    try L.pushNumber(3.14);
    try L.pushString("hello");

    try std.testing.expect(L.getTop() == 5);

    // Check types
    try std.testing.expect(L.isNil(1));
    try std.testing.expect(L.isBoolean(2));
    try std.testing.expect(L.isNumber(3));
    try std.testing.expect(L.isNumber(4));
    try std.testing.expect(L.isString(5));

    // Extract values
    try std.testing.expect(L.toBoolean(2) == true);
    try std.testing.expect(try L.toInteger(3) == 42);
    try std.testing.expect(try L.toNumber(4) == 3.14);
    try std.testing.expect(std.mem.eql(u8, try L.toString(5), "hello"));

    // Pop values
    _ = L.popValue();
    _ = L.popValue();
    _ = L.popValue();

    try std.testing.expect(L.getTop() == 2);
}

test "LuaState global variables" {
    const allocator = std.testing.allocator;

    const L = try LuaState.init(allocator, null);
    defer L.deinit();

    // Set global
    try L.pushInteger(100);
    try L.setGlobal("test_var");

    // Get global
    try L.getGlobal("test_var");
    try std.testing.expect(try L.toInteger(-1) == 100);

    _ = L.popValue();
}

test "LuaState thread creation" {
    const allocator = std.testing.allocator;

    const L = try LuaState.init(allocator, null);
    defer L.deinit();

    const thread = try L.newThread();
    try std.testing.expect(thread.status == .ok);
    try std.testing.expect(thread.l_G == L.l_G);
    try std.testing.expect(L.isThread(-1)); // Thread is on stack

    // Thread should have its own stack
    try thread.pushInteger(42);
    try std.testing.expect(thread.getTop() == 1);
    try std.testing.expect(L.getTop() == 1); // Only thread on main stack
}
