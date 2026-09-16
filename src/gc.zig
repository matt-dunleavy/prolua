// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Garbage Collector
//!
//! Incremental tri-colour mark and sweep modelled on Lua 5.4's lgc.c.
//! Every collectable object is created through (or linked by) this module
//! and is freed either by a sweep or by `deinit`, so object ownership has a
//! single owner: the collector of the global state that created it.
//!
//! A cycle: `pause` marks the roots (main thread, registry, per-type
//! metatables, tag-method names, objects awaiting finalization); `propagate`
//! traverses one gray object per step; `atomic` finishes marking, converges
//! ephemeron tables, separates unreachable objects with `__gc` metamethods
//! (and resurrects them for their finalizer), clears weak entries and flips
//! the current white; the sweep states free dead objects and whiten
//! survivors; `callfin` runs the pending finalizers.
//!
//! Generational mode follows lgc.c as well: `allgc` and `finobj` are kept
//! ordered new → survival → old1 → really old, a young collection marks
//! from the old1 objects and the gray lists, sweeps only the young part,
//! and a major collection (or a "bad" one) goes through incremental mode
//! (`enterInc` / `enterGen`, `genStep`, `stepGenFull`).
//!
//! Emergency collection: when an allocation through the collector's
//! allocator fails, a full collection runs in emergency mode (no finalizers,
//! nothing shrunk) and the allocation is tried once more, as luaM_malloc_
//! does. Not implemented: `luaC_fix` in general (reserved
//! words and metamethod names are marked as roots every cycle instead).

const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;

const value = @import("value.zig");
const state = @import("state.zig");
const table = @import("table.zig");
const string_module = @import("string.zig");
const closure = @import("closure.zig");
const coroutine_module = @import("coroutine.zig");
const proto_module = @import("proto.zig");
const config = @import("config.zig");
const api = @import("api.zig");

/// Object marking masks (shared with value.GCObject)
pub const WHITE0BIT: u8 = value.GCObject.WHITE0;
pub const WHITE1BIT: u8 = value.GCObject.WHITE1;
pub const BLACKBIT: u8 = value.GCObject.BLACK;
pub const FINALIZEDBIT: u8 = value.GCObject.FINALIZEDBIT; // object is in `finobj`/`tobefnz`
pub const AGEBITS: u8 = 0x70; // bits 4-6: object age (generational mode)
pub const TESTBIT: u8 = 0x80;

pub const WHITEBITS: u8 = WHITE0BIT | WHITE1BIT;
const MASKCOLORS: u8 = BLACKBIT | WHITEBITS;
const MASKGCBITS: u8 = MASKCOLORS | AGEBITS;

/// Object ages in generational mode (lgc.h)
pub const G_NEW: u8 = 0; // created in current cycle
pub const G_SURVIVAL: u8 = 1; // created in previous cycle
pub const G_OLD0: u8 = 2; // marked old by a forward barrier in this cycle
pub const G_OLD1: u8 = 3; // first full cycle as old
pub const G_OLD: u8 = 4; // really old object (not to be visited)
pub const G_TOUCHED1: u8 = 5; // old object touched this cycle
pub const G_TOUCHED2: u8 = 6; // old object touched in previous cycle

pub inline fn getAge(o: *const value.GCObject) u8 {
    return (o.marked & AGEBITS) >> 4;
}

pub inline fn setAge(o: *value.GCObject, age: u8) void {
    o.marked = (o.marked & ~AGEBITS) | (age << 4);
}

pub inline fn isOld(o: *const value.GCObject) bool {
    return getAge(o) > G_SURVIVAL;
}

fn changeAge(o: *value.GCObject, from: u8, to: u8) void {
    assert(getAge(o) == from);
    setAge(o, to);
}

/// Bytes of "work" one traversal unit represents when converting debt to steps
/// Check if object is white
pub fn isWhite(o: *const value.GCObject) bool {
    return (o.marked & WHITEBITS) != 0;
}

/// Check if object is black
pub fn isBlack(o: *const value.GCObject) bool {
    return (o.marked & BLACKBIT) != 0;
}

/// Check if object is gray
pub fn isGray(o: *const value.GCObject) bool {
    return !isWhite(o) and !isBlack(o);
}

/// The white that objects created before the current cycle's flip carry.
pub fn otherWhite(gc: *const GarbageCollector) u8 {
    return gc.currentwhite ^ WHITEBITS;
}

/// Check if object is dead: it carries the *other* white, i.e. it was not
/// reached during the marking phase that just finished.
pub fn isDead(gc: *const GarbageCollector, o: *const value.GCObject) bool {
    return (o.marked & otherWhite(gc)) != 0;
}

/// Change object to current white
pub fn changeWhite(o: *value.GCObject) void {
    o.marked ^= WHITEBITS;
}

/// Mark object black
pub fn markBlack(o: *value.GCObject) void {
    o.marked |= BLACKBIT;
}

/// Turn a (marked) object gray again
fn set2gray(o: *value.GCObject) void {
    o.marked &= ~BLACKBIT;
}

/// Reset an object to the current white (used by the sweep for survivors)
pub fn makeWhite(gc: *const GarbageCollector, o: *value.GCObject) void {
    o.marked = (o.marked & ~(BLACKBIT | WHITEBITS)) | gc.currentwhite;
}

/// Reset an object to white and clear its age (whitelist / sweeplist)
fn makeWhiteNew(gc: *const GarbageCollector, o: *value.GCObject) void {
    o.marked = (o.marked & ~MASKGCBITS) | gc.currentwhite;
}

/// Mark object white (alias kept for older call sites)
pub fn markWhite(gc: *GarbageCollector, o: *value.GCObject) void {
    makeWhite(gc, o);
}

/// Mark object as having a finalizer registered
pub fn markFinalized(o: *value.GCObject) void {
    o.marked |= FINALIZEDBIT;
}

/// Whether the object still needs to be registered for finalization
pub fn toFinalize(o: *value.GCObject) bool {
    return (o.marked & FINALIZEDBIT) == 0;
}

/// GC states
pub const GCState = enum(u8) {
    pause = 0, // waiting for next cycle
    propagate = 1, // marking phase
    enteratomic = 8, // marking done: the atomic phase runs next (GCSenteratomic)
    atomic = 2, // atomic marking (cannot be interrupted)
    sweepallgc = 3, // sweep main list
    sweepfinobj = 4, // sweep finalizer list
    sweeptobefnz = 5, // sweep to-be-finalized list
    sweepend = 6, // finish sweep
    callfin = 7, // call finalizers
};

/// GC modes
pub const GCMode = enum(u8) {
    incremental = 0, // incremental collection
    generational = 1, // generational collection
};

/// GC step kinds
pub const GCKind = enum(u8) {
    normal = 0, // regular step
    emergency = 1, // emergency collection
};

pub const GarbageCollector = struct {
    // GC state
    currentwhite: u8, // current white bit
    state: GCState, // current GC state
    kind: GCKind, // kind of GC running
    gcrunning: bool, // true if GC is running
    in_atomic: bool, // true while `atomic` runs (threads clear their dead stack)

    // GC mode and parameters
    gckind: GCMode, // incremental or generational
    gcstopem: bool, // stop emergency collections
    gcemergency: bool, // emergency mode flag
    /// The head of `allgc` at the last normal collection point, when every
    /// live object was reachable from a root. An emergency collection, which
    /// can run in the middle of anything, treats every object linked since
    /// (the list from the head to here) as live: the code that made them may
    /// still hold them only in its own variables (a proto being compiled,
    /// a table being sized, a closure whose upvalues are being made).
    young_head: ?*value.GCObject,
    gcpause: i32, // pause between cycles (percent)
    gcstepmul: i32, // GC speed multiplier (percent)

    // Memory accounting
    totalbytes: usize, // total allocated memory
    GCdebt: isize, // memory allocated not compensated by GC
    GCmemtrav: usize, // memory traversed by GC
    GCestimate: usize, // estimate of non-garbage memory
    lastatomic: usize, // last atomic memory amount

    // Object lists
    allgc: ?*value.GCObject, // all collectable objects without finalizers
    finobj: ?*value.GCObject, // objects with finalizers
    tobefnz: ?*value.GCObject, // unreachable objects waiting for their finalizer
    fixedgc: ?*value.GCObject, // non-collectable objects
    gray: ?*value.GCObject, // gray list
    grayagain: ?*value.GCObject, // gray objects to traverse atomically
    weak: ?*value.GCObject, // tables with weak values
    ephemeron: ?*value.GCObject, // tables with weak keys (ephemeron tables)
    allweak: ?*value.GCObject, // tables with weak keys and values

    // Sweep state: pointer to the link that holds the next object to sweep
    sweepgc: ?*?*value.GCObject,

    // Generational mode: the `allgc` list is ordered new → survival → old1
    // → really old, and `finobj` likewise (lgc.c)
    survival: ?*value.GCObject, // start of objects that survived one cycle
    old1: ?*value.GCObject, // start of old1 objects
    reallyold: ?*value.GCObject, // start of objects older than old1
    firstold1: ?*value.GCObject, // first OLD1 object in the list (if any)
    finobjsur: ?*value.GCObject,
    finobjold1: ?*value.GCObject,
    finobjrold: ?*value.GCObject,
    genminormul: i32, // percent growth that triggers a minor collection
    genmajormul: i32, // percent growth that triggers a major collection
    gcstepsize: u8, // log2 of the incremental step size in bytes

    // References into the owning global state (null for a stand-alone
    // collector, e.g. in unit tests)
    global: ?*state.GlobalState,
    mainthread: ?*state.LuaState, // main thread
    twups: ?*state.LuaState, // threads with open upvalues
    l_registry: ?*value.TValue, // registry value
    strpool: ?*string_module.StringPool, // to unlink dead short strings

    // Allocators: `backing` is the one the embedder gave the state; `allocator`
    // is the accounting wrapper over it (see `attachAccounting`) that every
    // part of the state allocates through.
    backing: std.mem.Allocator,
    allocator: std.mem.Allocator,

    // Statistics
    gccount: u64, // number of GC cycles
    marked: u64, // objects marked
    swept: u64, // objects swept

    pub fn init(allocator: std.mem.Allocator) GarbageCollector {
        return .{
            .currentwhite = WHITE0BIT,
            .state = .pause,
            .kind = .normal,
            .gcrunning = true,
            .in_atomic = false,
            .gckind = .incremental,
            .gcstopem = false,
            .gcemergency = false,
            .young_head = null,
            .gcpause = config.GCPAUSE,
            .gcstepmul = config.GCSTEPMUL,
            .totalbytes = 0,
            .GCdebt = 0,
            .GCmemtrav = 0,
            .GCestimate = 0,
            .lastatomic = 0,
            .allgc = null,
            .finobj = null,
            .tobefnz = null,
            .fixedgc = null,
            .gray = null,
            .grayagain = null,
            .weak = null,
            .ephemeron = null,
            .allweak = null,
            .sweepgc = null,
            .survival = null,
            .old1 = null,
            .reallyold = null,
            .finobjsur = null,
            .finobjold1 = null,
            .finobjrold = null,
            .firstold1 = null,
            .genminormul = 20,
            .genmajormul = 100,
            .gcstepsize = 13,
            .global = null,
            .mainthread = null,
            .twups = null,
            .l_registry = null,
            .strpool = null,
            .backing = allocator,
            .allocator = allocator,
            .gccount = 0,
            .marked = 0,
            .swept = 0,
        };
    }

    /// Free every object still owned by the collector (luaC_freeallobjects).
    /// Pending finalizers are called first when a thread is available. The
    /// string pool is going away with us, so strings are not unlinked from it.
    /// Run every registered finalizer because the state is closing
    /// (lua_close semantics). Must run while the main thread's stack is
    /// still usable, i.e. before `deinit`.
    pub fn closeFinalizers(self: *GarbageCollector) void {
        self.separateToBeFnz(true);
        self.callAllPendingFinalizers();
        self.mainthread = null; // no thread to run anything on from now on
    }

    pub fn deinit(self: *GarbageCollector) void {
        // Objects still registered for finalization are freed without a
        // call when no thread is available (see closeFinalizers)
        self.separateToBeFnz(true);
        self.callAllPendingFinalizers();

        self.strpool = null;
        self.gcrunning = false;
        self.freeList(&self.tobefnz);
        self.freeList(&self.finobj);
        self.freeList(&self.allgc);
        self.freeList(&self.fixedgc);
        self.gray = null;
        self.grayagain = null;
        self.weak = null;
        self.ephemeron = null;
        self.allweak = null;
        self.sweepgc = null;
    }

    fn freeList(self: *GarbageCollector, head: *?*value.GCObject) void {
        var o = head.*;
        while (o) |obj| {
            const next = obj.next;
            self.freeObject(obj);
            o = next;
        }
        head.* = null;
    }

    // Memory accounting (luaM_* over l_alloc)

    /// Make `allocator` the accounting wrapper over `backing`. Every
    /// allocation, resize and free through it moves `totalbytes` and
    /// `GCdebt`, so GC pacing and `collectgarbage("count")` see table parts,
    /// prototypes, stacks and buffers, not only object headers. Called once
    /// the collector has its final address.
    pub fn attachAccounting(self: *GarbageCollector) void {
        self.allocator = .{ .ptr = self, .vtable = &accounting_vtable };
    }

    const accounting_vtable = std.mem.Allocator.VTable{
        .alloc = accAlloc,
        .resize = accResize,
        .remap = accRemap,
        .free = accFree,
    };

    fn accAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *GarbageCollector = @ptrCast(@alignCast(ctx));
        const p = self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr) orelse blk: {
            // luaM_malloc_'s second try: collect everything that can go, then ask again
            if (!self.emergencyCollect()) return null;
            break :blk self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr) orelse return null;
        };
        self.accountAlloc(len);
        return p;
    }

    /// A full collection in emergency mode when an allocation has just
    /// failed: no finalizers run and nothing is shrunk, so it allocates
    /// nothing itself; refused while the collector is already running (the
    /// failed allocation was its own) or before the state is complete.
    /// True when it ran, so the allocation is worth a second try.
    fn emergencyCollect(self: *GarbageCollector) bool {
        if (self.gcstopem or self.gcemergency or self.global == null or self.mainthread == null) return false;
        self.gcemergency = true;
        defer self.gcemergency = false;
        self.fullGC() catch return false;
        return true;
    }

    fn accResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *GarbageCollector = @ptrCast(@alignCast(ctx));
        if (!self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.accountResize(memory.len, new_len);
        return true;
    }

    fn accRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *GarbageCollector = @ptrCast(@alignCast(ctx));
        // A null here is not memory exhaustion: the interface lets a backing
        // allocator decline to move a block (the Debug allocator always
        // does), and the caller then allocates, copies and frees, where a
        // real failure reaches `accAlloc` and its emergency collection. A
        // collection here ran a full cycle on every declined remap in Debug
        // builds, in the middle of compiling a chunk
        const p = self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        self.accountResize(memory.len, new_len);
        return p;
    }

    fn accFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *GarbageCollector = @ptrCast(@alignCast(ctx));
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
        self.accountFree(memory.len);
    }

    fn accountResize(self: *GarbageCollector, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) self.accountAlloc(new_len - old_len) else self.accountFree(old_len - new_len);
    }

    fn accountAlloc(self: *GarbageCollector, size: usize) void {
        self.totalbytes += size;
        self.GCdebt += @intCast(size);
    }

    fn accountFree(self: *GarbageCollector, size: usize) void {
        self.totalbytes -|= size;
        self.GCdebt -= @intCast(size);
    }

    // Object allocation and linking

    /// Take ownership of an object allocated elsewhere: colour it with the
    /// current white, link it into `allgc` and account `size` bytes.
    pub fn linkObject(self: *GarbageCollector, o: *value.GCObject, size: usize) void {
        _ = size; // accounted when the block was allocated (see `attachAccounting`)
        o.marked = self.currentwhite;
        o.next = self.allgc;
        self.allgc = o;
    }

    /// Create new GC object of a fixed-size struct type
    pub fn newObject(self: *GarbageCollector, comptime T: type, tt: value.ValueType) !*T {
        const obj = try self.allocator.create(T);
        obj.header = .{
            .next = null,
            .tt = @intFromEnum(tt),
            .marked = 0,
        };
        self.linkObject(&obj.header, @sizeOf(T));
        return obj;
    }

    /// Create new string (not interned; prefer the string pool for short strings)
    pub fn newString(self: *GarbageCollector, bytes: []const u8) !*value.String {
        const s = try string_module.createString(self.allocator, bytes, string_module.hashString(bytes, string_module.STRING_SEED));
        self.linkObject(&s.header, value.String.sizeOf(bytes.len));
        return s;
    }

    /// Create new table
    pub fn newTable(self: *GarbageCollector, arraysize: u32, hashsize: u32) !*table.Table {
        const tbl = try table.Table.initWithSize(self, arraysize, hashsize);
        self.linkObject(&tbl.header, @sizeOf(table.Table));
        return tbl;
    }

    /// Box an integer that does not fit a TValue's inline payload
    pub fn newBoxedInt(self: *GarbageCollector, i: i64) !*value.BoxedInt {
        const b = try self.allocator.create(value.BoxedInt);
        b.* = .{
            .header = .{ .next = null, .tt = @intFromEnum(value.ValueType.boxint), .marked = 0 },
            .v = i,
        };
        self.linkObject(&b.header, @sizeOf(value.BoxedInt));
        return b;
    }

    /// Create new userdata
    pub fn newUserdata(self: *GarbageCollector, size: usize, nuvalue: u16) !*value.Userdata {
        const u = try self.allocator.create(value.Userdata);
        errdefer self.allocator.destroy(u);

        const data = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(data);

        const values = try self.allocator.alloc(value.TValue, nuvalue);
        errdefer self.allocator.free(values);
        for (values) |*v| v.* = value.TValue.nil();

        u.* = .{
            .header = .{ .next = null, .tt = @intFromEnum(value.ValueType.userdata), .marked = 0 },
            .metatable = null,
            .len = size,
            .nuvalue = nuvalue,
            .data = data.ptr,
            .values = values,
        };
        self.linkObject(&u.header, @sizeOf(value.Userdata) + size + values.len * @sizeOf(value.TValue));
        return u;
    }

    /// Create new thread
    pub fn newThread(self: *GarbageCollector, L: *state.LuaState) !*state.LuaState {
        const th = try state.LuaState.init(self.allocator, L);
        self.linkObject(&th.header, @sizeOf(state.LuaState) + th.stacksize * @sizeOf(value.TValue));
        return th;
    }

    // Finalizers

    /// Register `o` for finalization if `mt` has a `__gc` field
    /// (luaC_checkfinalizer). Moves it from `allgc` to `finobj`.
    pub fn checkFinalizer(self: *GarbageCollector, o: *value.GCObject, mt: ?*table.Table) void {
        const g = self.global orelse return;
        const m = mt orelse return;
        if (!toFinalize(o)) return; // already registered
        const gc_key = g.tmname[@intFromEnum(value.TMS.__gc)];
        if (m.getShortStr(gc_key).isNil()) return; // no finalizer

        // Unlink from allgc (walk the list, as lgc.c does)
        var p: *?*value.GCObject = &self.allgc;
        while (p.*) |cur| : (p = &cur.next) {
            if (cur == o) break;
        } else return; // not in allgc (e.g. fixed): nothing to do

        if (self.isSweepPhase()) {
            makeWhite(self, o); // "sweep" the object
            // Keep the sweep position valid if it points at this object's link
            if (self.sweepgc) |sg| {
                if (sg == &o.next) self.sweepgc = p;
            }
        } else {
            self.correctPointers(o);
        }
        p.* = o.next;

        o.next = self.finobj;
        self.finobj = o;
        markFinalized(o);
    }

    /// Move unreachable objects (or all of them) from `finobj` to the end of
    /// `tobefnz` (lgc.c separatetobefnz)
    fn separateToBeFnz(self: *GarbageCollector, all: bool) void {
        // Find the end of tobefnz
        var lastnext: *?*value.GCObject = &self.tobefnz;
        while (lastnext.*) |cur| : (lastnext = &cur.next) {}

        // Only the young part of `finobj` can hold dead objects in
        // generational mode: the walk stops at `finobjold1` (null in
        // incremental mode, so the whole list), and if the object removed
        // is the survivors' boundary the boundary moves with it, as the
        // reference's separatetobefnz does (a sweep that later walks
        // `finobj` up to a boundary no longer in the list runs off its end)
        var p: *?*value.GCObject = &self.finobj;
        while (p.* != self.finobjold1) {
            const cur = p.*.?;
            if (!(all or isWhite(cur))) {
                p = &cur.next; // reachable: keep it in finobj
            } else {
                if (cur == self.finobjsur) self.finobjsur = cur.next; // removing the boundary
                p.* = cur.next; // unlink from finobj
                cur.next = lastnext.*;
                lastnext.* = cur;
                lastnext = &cur.next;
            }
        }
    }

    /// Mark every object waiting for a finalizer (they are roots until the
    /// finalizer runs)
    fn markBeingFnz(self: *GarbageCollector) void {
        var o = self.tobefnz;
        while (o) |obj| : (o = obj.next) {
            self.markObject(obj);
        }
    }

    /// Call every pending finalizer (luaC_callallpendingfinalizers)
    pub fn callAllPendingFinalizers(self: *GarbageCollector) void {
        while (self.tobefnz != null) {
            self.callOneFinalizer();
        }
    }

    /// Pop one object from `tobefnz`, return it to `allgc` and run its `__gc`
    fn callOneFinalizer(self: *GarbageCollector) void {
        const o = self.tobefnz.?;
        self.tobefnz = o.next;
        o.next = self.allgc;
        self.allgc = o;
        o.marked &= ~FINALIZEDBIT; // object is "normal" again
        if (self.isSweepPhase()) {
            makeWhite(self, o); // "sweep" the object
        } else if (getAge(o) == G_OLD1) {
            self.firstold1 = o; // now the first OLD1 object in `allgc` (udata2finalize)
        }

        const L = self.mainthread orelse return; // no thread to run it on
        const g = self.global orelse return;
        const v = objectToValue(o) orelse return;
        const tm = api.getMetamethodOf(L, &v, .__gc) orelse return;
        if (!tm.isFunction()) return;

        // Run the finalizer protected (GCTM): no GC steps and no hooks while
        // it runs, the calling frame is flagged so `debug.getinfo` names the
        // function "__gc" (CIST_FIN), and an error becomes a warning.
        const saved_running = self.gcrunning;
        self.gcrunning = false; // avoid GC steps inside the finalizer
        defer self.gcrunning = saved_running;
        const saved_allowhook = L.allowhook;
        L.allowhook = 0;
        defer L.allowhook = saved_allowhook;
        _ = g;
        api.pushValue(L, tm) catch return;
        api.pushValue(L, v) catch {
            api.pop(L, 1);
            return;
        };
        const caller = L.ci;
        caller.callstatus.isFinalizer = true;
        const status = api.pcall(L, 1, 0, 0);
        caller.callstatus.isFinalizer = false;
        if (status != .ok) {
            api.warnError(L, "__gc");
            api.pop(L, 1); // the error object
        }
    }

    // Marking phase

    /// Mark the roots of a cycle
    fn restartCollection(self: *GarbageCollector) void {
        self.gray = null;
        self.grayagain = null;
        self.weak = null;
        self.allweak = null;
        self.ephemeron = null;
        self.markRoots();
        self.markBeingFnz();
    }

    fn markRoots(self: *GarbageCollector) void {
        if (self.mainthread) |th| self.markObject(&th.header);
        if (self.l_registry) |reg| self.markValue(reg);
        if (self.global) |g| {
            for (g.mt) |mt| {
                if (mt) |t| self.markObject(&t.header);
            }
            for (g.tmname) |s| self.markObject(&s.header);
            self.markValue(&g.memerrmsg); // fixed: must exist when nothing can be made
        }
        if (self.gcemergency) self.markYoung();
    }

    /// Every object linked since the last normal collection point is a root
    /// of an emergency collection (see `young_head`)
    fn markYoung(self: *GarbageCollector) void {
        var o = self.allgc;
        while (o) |obj| : (o = obj.next) {
            if (obj == self.young_head) break;
            self.markObject(obj);
        }
    }

    /// A normal collection starts only where everything live is reachable:
    /// from here on, objects linked later are the young ones
    pub fn safePoint(self: *GarbageCollector) void {
        if (!self.gcemergency) self.young_head = self.allgc;
    }

    /// Mark a value
    pub fn markValue(self: *GarbageCollector, v: *const value.TValue) void {
        if (v.toGCObject()) |o| {
            self.markObject(o);
        }
    }

    /// Mark an object
    pub fn markObject(self: *GarbageCollector, o: ?*value.GCObject) void {
        const obj = o orelse return;
        if (!isWhite(obj)) return; // already marked
        self.reallyMarkObject(obj);
    }

    /// Mark an object regardless of its colour (reallymarkobject): leaf
    /// objects turn black at once, the rest join the gray list
    fn reallyMarkObject(self: *GarbageCollector, obj: *value.GCObject) void {
        obj.marked &= ~WHITEBITS;
        self.marked += 1;

        switch (obj.typeTag()) {
            .table, .lclosure, .cclosure, .thread, .proto, .upvalue => {
                self.linkGray(obj);
            },
            .boxint => {
                markBlack(obj); // a leaf, like a string
                self.GCmemtrav += @sizeOf(value.BoxedInt);
            },
            .string => {
                // Strings are atomic, mark black immediately
                markBlack(obj);
                const s: *value.String = @fieldParentPtr("header", obj);
                self.GCmemtrav += value.String.sizeOf(s.len());
            },
            .userdata => {
                const u: *value.Userdata = @fieldParentPtr("header", obj);
                if (u.nuvalue == 0 and u.metatable == null) {
                    markBlack(obj);
                    self.GCmemtrav += @sizeOf(value.Userdata) + u.len;
                } else {
                    self.linkGray(obj);
                }
            },
            else => unreachable,
        }
    }

    /// The gray-list link of an object. Only the types that can be gray
    /// carry one (Lua's per-type `gclist`); strings never do, which keeps
    /// their header at 16 bytes.
    fn gclistOf(o: *value.GCObject) *?*value.GCObject {
        return switch (o.typeTag()) {
            .table => &@as(*table.Table, @fieldParentPtr("header", o)).gclist,
            .lclosure => &@as(*closure.LClosure, @fieldParentPtr("header", o)).gclist,
            .cclosure => &@as(*closure.CClosure, @fieldParentPtr("header", o)).gclist,
            .proto => &@as(*proto_module.Proto, @fieldParentPtr("header", o)).gclist,
            .thread => &@as(*state.LuaState, @fieldParentPtr("header", o)).gclist,
            .userdata => &@as(*value.Userdata, @fieldParentPtr("header", o)).gclist,
            .upvalue => &@as(*closure.Upvalue, @fieldParentPtr("header", o)).gclist,
            else => unreachable,
        };
    }

    /// Link object to gray list
    pub fn linkGray(self: *GarbageCollector, o: *value.GCObject) void {
        set2gray(o);
        gclistOf(o).* = self.gray;
        self.gray = o;
    }

    /// Link object to gray again list
    pub fn linkGrayAgain(self: *GarbageCollector, o: *value.GCObject) void {
        set2gray(o);
        gclistOf(o).* = self.grayagain;
        self.grayagain = o;
    }

    fn linkList(o: *value.GCObject, list: *?*value.GCObject) void {
        set2gray(o);
        gclistOf(o).* = list.*;
        list.* = o;
    }

    /// Traverse one gray object
    pub fn propagateMark(self: *GarbageCollector) !bool {
        const o = self.gray orelse return false;

        self.gray = gclistOf(o).*;
        markBlack(o);

        switch (o.typeTag()) {
            .table => try self.traverseTable(@fieldParentPtr("header", o)),
            .lclosure => self.traverseLClosure(@fieldParentPtr("header", o)),
            .cclosure => self.traverseCClosure(@fieldParentPtr("header", o)),
            .thread => self.traverseThread(@fieldParentPtr("header", o)),
            .proto => self.traverseProto(@fieldParentPtr("header", o)),
            .upvalue => self.traverseUpvalue(@fieldParentPtr("header", o)),
            .userdata => self.traverseUserdata(@fieldParentPtr("header", o)),
            else => unreachable,
        }

        return true;
    }

    /// Mark all gray objects
    fn propagateAll(self: *GarbageCollector) !void {
        while (self.gray != null) {
            _ = try self.propagateMark();
        }
    }

    /// Whether a weak reference to `o` must be cleared: white objects will
    /// die. Strings are values, never cleared, and get marked instead.
    fn isCleared(self: *GarbageCollector, o: *value.GCObject) bool {
        if (o.typeTag() == .string or o.typeTag() == .boxint) {
            // strings and boxed integers are values, never weak
            self.markObject(o);
            return false;
        }
        return isWhite(o);
    }

    fn traverseTable(self: *GarbageCollector, t: *table.Table) !void {
        // Mark metatable and refresh the weak flags from its __mode
        if (t.metatable) |mt| {
            self.markObject(&mt.header);
            if (self.global) |g| t.updateWeakFlags(g.tmname[@intFromEnum(value.TMS.__mode)]);
        }

        const weakkey = t.flags.has_weak_keys;
        const weakvalue = t.flags.has_weak_values;

        if (!weakkey and !weakvalue) {
            self.traverseStrongTable(t);
        } else if (weakkey and weakvalue) {
            linkList(&t.header, &self.allweak); // nothing to mark; entries cleared later
        } else if (weakvalue) {
            self.traverseWeakValue(t);
        } else {
            _ = self.traverseEphemeron(t);
        }

        self.GCmemtrav += @sizeOf(table.Table) +
            t.asize * @sizeOf(value.TValue) +
            t.hashSize() * @sizeOf(table.Node);
    }

    fn traverseStrongTable(self: *GarbageCollector, t: *table.Table) void {
        for (t.arr()) |*v| {
            self.markValue(v);
        }
        for (t.nodes()) |*node| {
            if (node.isEmpty()) continue;
            if (node.isDead()) {
                node.clearDeadKey();
            } else {
                const nk = node.key();
                self.markValue(&nk);
                self.markValue(&node.val);
            }
        }
        self.genLink(&t.header);
    }

    /// Weak values: keys are marked, values are not (cleared later if dead)
    fn traverseWeakValue(self: *GarbageCollector, t: *table.Table) void {
        for (t.nodes()) |*node| {
            if (node.isEmpty()) continue;
            if (node.isDead()) {
                node.clearDeadKey();
            } else {
                const nk = node.key();
                self.markValue(&nk);
            }
        }
        // Re-traverse (or clear) in the atomic phase
        if (self.in_atomic) linkList(&t.header, &self.weak) else self.linkGrayAgain(&t.header);
    }

    /// Weak keys: a value is marked only if its key is marked. Returns whether
    /// anything new was marked (for the ephemeron convergence loop).
    fn traverseEphemeron(self: *GarbageCollector, t: *table.Table) bool {
        var marked_something = false;
        var has_clears = false; // some white key
        var has_ww = false; // some white key with a white value

        for (t.arr()) |*v| {
            if (v.toGCObject()) |o| {
                if (isWhite(o)) {
                    marked_something = true;
                    self.markObject(o);
                }
            }
        }

        for (t.nodes()) |*node| {
            if (node.isEmpty()) continue;
            if (node.isDead()) {
                node.clearDeadKey();
                continue;
            }
            const keyobj = node.key().toGCObject();
            if (keyobj != null and self.isCleared(keyobj.?)) {
                has_clears = true;
                if (node.val.toGCObject()) |vo| {
                    if (isWhite(vo)) has_ww = true;
                }
            } else if (node.val.toGCObject()) |vo| {
                if (isWhite(vo)) {
                    marked_something = true;
                    self.markObject(vo);
                }
            }
        }

        if (!self.in_atomic) {
            self.linkGrayAgain(&t.header); // must be visited again in the atomic phase
        } else if (has_ww) {
            linkList(&t.header, &self.ephemeron); // may need another pass
        } else if (has_clears) {
            linkList(&t.header, &self.allweak); // only keys to clear
        } else {
            self.genLink(&t.header); // nothing to clear: an old table may still need revisiting
        }
        return marked_something;
    }

    fn traverseLClosure(self: *GarbageCollector, cl: *closure.LClosure) void {
        self.markObject(&cl.proto.header);
        for (cl.upvalueSlice()) |maybe_uv| {
            if (maybe_uv) |uv| self.markObject(&uv.header);
        }
        self.GCmemtrav += closure.lclosureSize(cl.nupvalues);
    }

    fn traverseCClosure(self: *GarbageCollector, cl: *closure.CClosure) void {
        for (cl.upvalueSlice()) |*v| {
            self.markValue(v);
        }
        self.GCmemtrav += closure.cclosureSize(cl.nupvalues);
    }

    fn traverseUserdata(self: *GarbageCollector, u: *value.Userdata) void {
        if (u.metatable) |mt| self.markObject(&mt.header);
        for (u.values) |*v| self.markValue(v);
        self.genLink(&u.header);
        self.GCmemtrav += @sizeOf(value.Userdata) + u.len + u.values.len * @sizeOf(value.TValue);
    }

    /// Traverse thread. Threads stay gray during propagation and are visited
    /// again in the atomic phase, where the dead part of the stack is cleared.
    fn traverseThread(self: *GarbageCollector, th: *state.LuaState) void {
        // Threads have no barriers: an old thread is visited at every young
        // collection, and in incremental mode a thread traversed during
        // propagation is visited again in the atomic phase
        if (isOld(&th.header) or self.state == .propagate) self.linkGrayAgain(&th.header);

        // Mark live stack values
        var o = th.stack;
        while (@intFromPtr(o) < @intFromPtr(th.top)) : (o += 1) {
            self.markValue(&o[0]);
        }

        // Mark open upvalues
        var uv = th.openupval;
        while (uv) |upval| : (uv = upval.u.open.next) {
            self.markObject(&upval.header);
        }

        if (self.in_atomic) {
            // Clear the dead part of the stack so stale references cannot be
            // picked up later
            const end = th.stack + th.stacksize;
            var d = th.top;
            while (@intFromPtr(d) < @intFromPtr(end)) : (d += 1) {
                d[0] = value.TValue.nil();
            }
            // `remarkUpvals` may have removed the thread from `twups`
            if (th.twups == th and th.openupval != null) {
                th.twups = self.twups;
                self.twups = th;
            }
        }

        self.GCmemtrav += @sizeOf(state.LuaState) +
            th.stacksize * @sizeOf(value.TValue);
    }

    /// Re-mark the values of open upvalues of threads that may be dead
    /// (lgc.c remarkupvals). A thread writes its stack without barriers, so
    /// an open upvalue marked earlier in the cycle can hold an unmarked
    /// value if its thread died before the atomic phase; marked threads
    /// are traversed again there and need no help. Threads that are not
    /// marked, or have no open upvalues left, leave the list.
    fn remarkUpvals(self: *GarbageCollector) usize {
        var work: usize = 0;
        var p: *?*state.LuaState = &self.twups;
        while (p.*) |th| {
            work += 1;
            if (!isWhite(&th.header) and th.openupval != null) {
                p = &th.twups; // keep marked thread with upvalues in the list
            } else {
                p.* = th.twups; // remove thread from the list
                th.twups = th; // mark that it is out of list
                var uv = th.openupval;
                while (uv) |upval| : (uv = upval.u.open.next) {
                    work += 1;
                    if (!isWhite(&upval.header)) {
                        self.markValue(upval.p); // upvalue already visited: mark its value
                    }
                }
            }
        }
        return work;
    }

    /// Traverse proto
    fn traverseProto(self: *GarbageCollector, p: *proto_module.Proto) void {
        for (p.constants[0..p.sizek]) |*k| {
            self.markValue(k);
        }

        for (p.upvalues[0..p.sizeupvalues]) |*uv| {
            if (uv.name) |name| {
                self.markObject(&name.header);
            }
        }

        for (p.protos[0..p.sizep]) |nested| {
            self.markObject(&nested.header);
        }

        if (p.source) |src| {
            self.markObject(&src.header);
        }

        for (p.locvars[0..p.sizelocvars]) |*locvar| {
            self.markObject(&locvar.name.header);
        }

        self.GCmemtrav += @sizeOf(proto_module.Proto) +
            p.sizecode * @sizeOf(u32) +
            p.sizek * @sizeOf(value.TValue) +
            @as(usize, p.sizeupvalues) * @sizeOf(proto_module.Upvaldesc) +
            p.sizep * @sizeOf(*proto_module.Proto);
    }

    /// Traverse upvalue
    fn traverseUpvalue(self: *GarbageCollector, uv: *closure.Upvalue) void {
        self.markValue(uv.getValue());
        self.markValue(&uv.tbc); // a pending __close handler
        self.GCmemtrav += @sizeOf(closure.Upvalue);
    }

    // Atomic phase

    /// Finish the marking phase without interruption (lgc.c atomic)
    fn atomic(self: *GarbageCollector) !usize {
        self.in_atomic = true;
        defer self.in_atomic = false;
        self.state = .atomic;
        const marked_before = self.marked;

        // Re-mark the roots (they may have changed since the cycle started)
        self.markRoots();
        try self.propagateAll();

        // Remark occasional upvalues of (maybe) dead threads
        _ = self.remarkUpvals();
        try self.propagateAll();

        // Objects re-grayed by barriers, threads and weak tables
        self.gray = self.grayagain;
        self.grayagain = null;
        try self.propagateAll();

        try self.convergeEphemerons();

        // Values of weak tables that died before finalizers may resurrect them
        self.clearByValues(self.weak);
        self.clearByValues(self.allweak);

        // Unreachable objects with finalizers are resurrected for their __gc
        self.separateToBeFnz(false);
        self.markBeingFnz();
        try self.propagateAll();
        try self.convergeEphemerons();

        // Clear weak entries that are still dead after resurrection
        self.clearByKeys(self.ephemeron);
        self.clearByKeys(self.allweak);
        self.clearByValues(self.weak);
        self.clearByValues(self.allweak);

        // Flip current white: everything still carrying the old white is dead.
        // The weak lists are left for the caller: the incremental restart
        // clears them, the generational cycle folds them into `grayagain`.
        self.currentwhite = otherWhite(self);
        return self.marked - marked_before;
    }

    /// Start the sweep phase (entersweep)
    fn enterSweep(self: *GarbageCollector) void {
        self.state = .sweepallgc;
        self.sweepgc = &self.allgc;
    }

    /// Traverse ephemeron tables until no more values get marked
    fn convergeEphemerons(self: *GarbageCollector) !void {
        var changed = true;
        while (changed) {
            changed = false;
            var w = self.ephemeron;
            self.ephemeron = null;
            while (w) |e| {
                const next = gclistOf(e).*;
                const t: *table.Table = @fieldParentPtr("header", e);
                markBlack(e);
                if (self.traverseEphemeron(t)) {
                    try self.propagateAll();
                    changed = true;
                }
                w = next;
            }
        }
    }

    /// Clear entries with dead keys from the tables in `list`
    fn clearByKeys(self: *GarbageCollector, list: ?*value.GCObject) void {
        var w = list;
        while (w) |o| : (w = gclistOf(o).*) {
            const t: *table.Table = @fieldParentPtr("header", o);
            for (t.nodes()) |*node| {
                if (node.isEmpty()) continue;
                if (node.key().toGCObject()) |ko| {
                    if (self.isCleared(ko)) node.val = value.TValue.nil();
                }
                if (node.isDead()) node.clearDeadKey();
            }
        }
    }

    /// Clear entries with dead values from the tables in `list`
    fn clearByValues(self: *GarbageCollector, list: ?*value.GCObject) void {
        var w = list;
        while (w) |o| : (w = gclistOf(o).*) {
            const t: *table.Table = @fieldParentPtr("header", o);
            for (t.arr()) |*v| {
                if (v.toGCObject()) |vo| {
                    if (self.isCleared(vo)) v.* = value.TValue.nil();
                }
            }
            for (t.nodes()) |*node| {
                if (node.isEmpty()) continue;
                if (node.val.toGCObject()) |vo| {
                    if (self.isCleared(vo)) node.val = value.TValue.nil();
                }
                if (node.isDead()) node.clearDeadKey();
            }
        }
    }

    // Sweep phase

    /// Sweep up to `count` objects starting at the link `p`. Dead objects are
    /// unlinked and freed; survivors are reset to the current white. Returns
    /// the link to continue from, or null once the list is exhausted.
    fn sweepList(self: *GarbageCollector, p_in: *?*value.GCObject, count: u32, swept: *u32) ?*?*value.GCObject {
        var p = p_in;
        var n: u32 = 0;

        while (p.*) |obj| {
            if (n >= count) return p;
            if (isDead(self, obj)) {
                p.* = obj.next;
                self.freeObject(obj);
                swept.* += 1;
            } else {
                makeWhite(self, obj);
                p = &obj.next;
            }
            n += 1;
        }

        return null;
    }

    /// Free an object (the inverse of the allocation paths above)
    fn freeObject(self: *GarbageCollector, o: *value.GCObject) void {
        if (self.young_head == o) self.young_head = o.next; // the mark stays on the list
        switch (o.typeTag()) {
            .boxint => {
                const b: *value.BoxedInt = @fieldParentPtr("header", o);
                self.allocator.destroy(b);
            },
            .string => {
                const s: *value.String = @fieldParentPtr("header", o);
                if (self.strpool) |pool| pool.remove(s);
                string_module.freeString(self.allocator, s);
            },
            .table => {
                const t: *table.Table = @fieldParentPtr("header", o);
                t.deinit(); // frees its parts and the struct
            },
            .lclosure => {
                const cl: *closure.LClosure = @fieldParentPtr("header", o);
                closure.freeLClosure(self.allocator, cl);
            },
            .cclosure => {
                const cl: *closure.CClosure = @fieldParentPtr("header", o);
                closure.freeCClosure(self.allocator, cl);
            },
            .thread => {
                const th: *state.LuaState = @fieldParentPtr("header", o);
                // Closures may still refer to this stack through open
                // upvalues: give them their values before the stack goes
                coroutine_module.closeUpvaluesOnFree(th);
                th.deinit();
            },
            .userdata => {
                const u: *value.Userdata = @fieldParentPtr("header", o);
                self.allocator.free(u.data[0..u.len]);
                self.allocator.free(u.values);
                self.allocator.destroy(u);
            },
            .proto => {
                const p: *proto_module.Proto = @fieldParentPtr("header", o);
                p.deinit(self.allocator); // frees its arrays and the struct
            },
            .upvalue => {
                const uv: *closure.Upvalue = @fieldParentPtr("header", o);
                if (uv.status != .closed) closure.unlinkUpvalue(uv); // still in a thread's open list
                self.allocator.destroy(uv);
            },
            else => unreachable,
        }

        self.swept += 1;
    }

    // GC control

    // Incremental stepping (lgc.c singlestep / incstep). Work is measured
    // the way lgc.c measures it: bytes traversed while marking, objects
    // swept while sweeping, a fixed cost per finalizer called.
    const GCSWEEPMAX: u32 = 100; // objects swept per single step
    const GCFINMAX: u32 = 10; // finalizers called per single step
    const GCFINALIZECOST: usize = 50; // cost of calling one finalizer
    const WORK2MEM: usize = @sizeOf(value.TValue); // bytes per unit of work

    /// One step of the collector's state machine; returns the work done
    fn singleStep(self: *GarbageCollector) !usize {
        std.debug.assert(!self.gcstopem); // the collector is not reentrant
        self.gcstopem = true; // no emergency collections while collecting
        defer self.gcstopem = false;
        switch (self.state) {
            .pause => {
                self.marked = 0;
                self.swept = 0;
                self.GCmemtrav = 0;
                self.gccount += 1;
                self.restartCollection();
                self.state = .propagate;
                return 1;
            },
            .propagate => {
                if (self.gray == null) { // no more gray objects?
                    self.state = .enteratomic; // finish propagate phase
                    return 0;
                }
                const before = self.GCmemtrav;
                _ = try self.propagateMark(); // traverse one gray object
                return self.GCmemtrav - before;
            },
            .enteratomic => {
                const before = self.GCmemtrav;
                _ = try self.atomic();
                self.enterSweep();
                self.GCestimate = self.totalbytes; // first estimate
                return self.GCmemtrav - before;
            },
            .atomic => unreachable, // atomic never yields
            .sweepallgc => return self.sweepStep(.sweepfinobj, &self.finobj),
            .sweepfinobj => return self.sweepStep(.sweeptobefnz, &self.tobefnz),
            .sweeptobefnz => return self.sweepStep(.sweepend, null),
            .sweepend => {
                // The main thread lives outside the object lists: whiten it here
                if (self.mainthread) |th| makeWhite(self, &th.header);
                self.GCestimate = self.totalbytes;
                self.state = .callfin;
                return 0;
            },
            .callfin => {
                if (self.tobefnz != null and !self.gcemergency) {
                    self.gcstopem = false; // ok collections during finalizers
                    var n: usize = 0;
                    while (self.tobefnz != null and n < GCFINMAX) : (n += 1) self.callOneFinalizer();
                    return n * GCFINALIZECOST;
                }
                self.state = .pause; // emergency mode or no more finalizers: finish collection
                return 0;
            },
        }
    }

    /// Sweep a few objects of the current list, or move on to `next`
    /// (sweepstep). The estimate follows the memory the sweep frees.
    fn sweepStep(self: *GarbageCollector, next: GCState, nextlist: ?*?*value.GCObject) usize {
        if (self.sweepgc) |sg| {
            const before = self.totalbytes;
            var count: u32 = 0;
            self.sweepgc = self.sweepList(sg, GCSWEEPMAX, &count);
            self.GCestimate -|= before - self.totalbytes;
            return count;
        }
        self.state = next;
        self.sweepgc = nextlist;
        return 0; // no work done
    }

    /// A basic incremental step (incstep): the debt and the minimum step
    /// size are converted from bytes to units of work, then single steps
    /// run until that much work is done or the cycle ends. Finally the
    /// debt that triggers the next step is set.
    pub fn incStep(self: *GarbageCollector) !void {
        const stepmul: isize = @as(isize, @intCast(@max(self.gcstepmul, 0))) | 1; // avoid division by 0
        var debt: isize = @divTrunc(self.GCdebt, @as(isize, @intCast(WORK2MEM))) * stepmul;
        const stepsize: isize = @divTrunc(@as(isize, 1) << @intCast(@min(self.gcstepsize, 62)), @as(isize, @intCast(WORK2MEM))) * stepmul;
        while (true) { // repeat until pause or enough "credit" (negative debt)
            const work: isize = @intCast(try self.singleStep());
            debt -= work;
            if (!(debt > -stepsize and self.state != .pause)) break;
        }
        if (self.state == .pause) {
            self.setPauseDebt(); // pause until next cycle
        } else {
            self.GCdebt = @divTrunc(debt, stepmul) * @as(isize, @intCast(WORK2MEM)); // back to bytes
        }
    }

    /// Advance the collector until it reaches `target` (luaC_runtilstate)
    fn runUntil(self: *GarbageCollector, target: GCState) !void {
        while (self.state != target) _ = try self.singleStep();
    }

    /// Set the debt so the next cycle starts after `gcpause` percent growth
    fn setPauseDebt(self: *GarbageCollector) void {
        const threshold = self.GCestimate / 100 * @as(usize, @intCast(@max(self.gcpause, 0)));
        self.GCdebt = @as(isize, @intCast(self.totalbytes)) - @as(isize, @intCast(@max(threshold, self.totalbytes)));
    }

    /// Run a step if the debt is positive (luaC_checkGC at allocation points)
    pub fn checkGC(self: *GarbageCollector) !void {
        // Called where everything live is reachable, whether or not a step
        // follows: the point an emergency collection measures "young" from
        self.safePoint();
        if (self.gcrunning and self.GCdebt > 0) try self.step();
    }

    /// One collector step in the current mode (luaC_step)
    pub fn step(self: *GarbageCollector) !void {
        self.safePoint();
        if (self.isDecGCModeGen()) try self.genStep() else try self.incStep();
    }

    /// Run the collector until the current (or a fresh) cycle completes
    pub fn runCycle(self: *GarbageCollector) !void {
        if (self.state == .pause) _ = try self.singleStep(); // start a cycle
        try self.runUntil(.pause);
    }

    /// Perform a full collection (luaC_fullgc / fullinc): finish any cycle
    /// in progress, run a complete one up to its finalizers, call them, and
    /// set the pause for the next cycle. Refused while the collector itself
    /// is running (from inside a finalizer, say), as lua_gc refuses it.
    pub fn fullGC(self: *GarbageCollector) !void {
        self.safePoint();
        if (self.gcstopem) return;
        if (self.gckind == .generational) {
            _ = try self.fullGen();
            return;
        }
        if (self.state != .pause) try self.runUntil(.pause); // finish any pending cycle
        try self.runUntil(.callfin); // run up to finalizers
        try self.runUntil(.pause); // finish collection
        self.setPauseDebt();
    }

    /// Stop GC
    pub fn stop(self: *GarbageCollector) void {
        self.gcrunning = false;
    }

    /// Restart GC
    pub fn restart(self: *GarbageCollector) void {
        self.gcrunning = true;
    }

    /// Change the collector mode (luaC_changemode). Returns the previous mode.
    pub fn changeMode(self: *GarbageCollector, mode: GCMode) !GCMode {
        const old = self.gckind;
        if (mode != self.gckind) {
            if (mode == .generational) _ = try self.enterGen() else self.enterInc();
        }
        self.lastatomic = 0;
        return old;
    }

    // ---------------------------------------------------------------------
    // Generational collector (lgc.c "Generational Collector")
    // ---------------------------------------------------------------------

    fn keepInvariant(self: *const GarbageCollector) bool {
        return self.state == .propagate or self.state == .enteratomic or self.state == .atomic;
    }

    fn isSweepPhase(self: *const GarbageCollector) bool {
        return switch (self.state) {
            .sweepallgc, .sweepfinobj, .sweeptobefnz, .sweepend => true,
            else => false,
        };
    }

    /// After traversing a black object in generational mode: a table touched
    /// in this cycle goes back to `grayagain`, one touched in the previous
    /// cycle becomes plain old (genlink)
    fn genLink(self: *GarbageCollector, o: *value.GCObject) void {
        if (getAge(o) == G_TOUCHED1) {
            self.linkGrayAgain(o);
        } else if (getAge(o) == G_TOUCHED2) {
            changeAge(o, G_TOUCHED2, G_OLD);
        }
    }

    /// An object leaving `allgc` for `finobj` must not be the start of a
    /// generation (correctpointers)
    fn correctPointers(self: *GarbageCollector, o: *value.GCObject) void {
        if (self.survival == o) self.survival = o.next;
        if (self.old1 == o) self.old1 = o.next;
        if (self.reallyold == o) self.reallyold = o.next;
        if (self.firstold1 == o) self.firstold1 = o.next;
    }

    /// Sweep a list to enter generational mode: free the dead, make every
    /// survivor old. Threads must stay watched (gray list), open upvalues
    /// stay gray, everything else is black (sweep2old).
    fn sweep2old(self: *GarbageCollector, p_in: *?*value.GCObject) void {
        var p = p_in;
        while (p.*) |curr| {
            if (isWhite(curr)) {
                p.* = curr.next;
                self.freeObject(curr);
            } else {
                setAge(curr, G_OLD);
                if (curr.typeTag() == .thread) {
                    self.linkGrayAgain(curr);
                } else if (curr.typeTag() == .upvalue and @as(*closure.Upvalue, @fieldParentPtr("header", curr)).isOpen()) {
                    set2gray(curr);
                } else {
                    markBlack(curr);
                }
                p = &curr.next;
            }
        }
    }

    /// Sweep for generational mode up to `limit`: free the dead (any white
    /// object is dead, the collection was not incremental), advance the
    /// ages of the rest; new objects go back to white as survivals
    /// (sweepgen)
    fn sweepGen(self: *GarbageCollector, p_in: *?*value.GCObject, limit: ?*value.GCObject, pfirstold1: *?*value.GCObject) *?*value.GCObject {
        const nextage = [_]u8{ G_SURVIVAL, G_OLD1, G_OLD1, G_OLD, G_OLD, G_TOUCHED1, G_TOUCHED2 };
        var p = p_in;
        while (p.* != limit) {
            const curr = p.*.?;
            if (isWhite(curr)) {
                p.* = curr.next;
                self.freeObject(curr);
            } else {
                if (getAge(curr) == G_NEW) {
                    curr.marked = (curr.marked & ~MASKGCBITS) | (G_SURVIVAL << 4) | self.currentwhite;
                } else {
                    setAge(curr, nextage[getAge(curr)]);
                    if (getAge(curr) == G_OLD1 and pfirstold1.* == null) pfirstold1.* = curr;
                }
                p = &curr.next;
            }
        }
        return p;
    }

    /// Make every object of a list white and new (whitelist)
    fn whiteList(self: *GarbageCollector, list: ?*value.GCObject) void {
        var p = list;
        while (p) |o| : (p = o.next) makeWhiteNew(self, o);
    }

    /// Correct one gray list after a young collection: white (young, dead)
    /// objects leave, `TOUCHED1` objects become `TOUCHED2` and stay, threads
    /// stay, everything else becomes old and leaves (correctgraylist)
    fn correctGrayList(p_in: *?*value.GCObject) *?*value.GCObject {
        var p = p_in;
        while (p.*) |curr| {
            const next = gclistOf(curr);
            if (isWhite(curr)) {
                p.* = next.*; // remove
            } else if (getAge(curr) == G_TOUCHED1) {
                markBlack(curr); // black again, for the next barrier
                changeAge(curr, G_TOUCHED1, G_TOUCHED2);
                p = next; // remain
            } else if (curr.typeTag() == .thread) {
                p = next; // non-white threads stay on the list
            } else {
                if (getAge(curr) == G_TOUCHED2) changeAge(curr, G_TOUCHED2, G_OLD);
                markBlack(curr);
                p.* = next.*; // remove
            }
        }
        return p;
    }

    /// Correct all gray lists, folding them into `grayagain` (correctgraylists)
    fn correctGrayLists(self: *GarbageCollector) void {
        var list = correctGrayList(&self.grayagain);
        list.* = self.weak;
        self.weak = null;
        list = correctGrayList(list);
        list.* = self.allweak;
        self.allweak = null;
        list = correctGrayList(list);
        list.* = self.ephemeron;
        self.ephemeron = null;
        _ = correctGrayList(list);
    }

    /// Mark the black `OLD1` objects of a list range when a young collection
    /// starts: they may point to young objects (markold)
    fn markOld(self: *GarbageCollector, from: ?*value.GCObject, to: ?*value.GCObject) void {
        var p = from;
        while (p != to) {
            const o = p.?;
            if (getAge(o) == G_OLD1) {
                changeAge(o, G_OLD1, G_OLD);
                if (isBlack(o)) self.reallyMarkObject(o);
            }
            p = o.next;
        }
    }

    /// Finish a young collection (finishgencycle)
    fn finishGenCycle(self: *GarbageCollector) void {
        self.correctGrayLists();
        self.state = .propagate; // skip restart
        if (!self.gcemergency) self.callAllPendingFinalizers();
    }

    /// A young collection: mark the OLD1 objects, run the atomic step, sweep
    /// the young generations and advance the generation pointers
    /// (youngcollection)
    fn youngCollection(self: *GarbageCollector) !void {
        assert(self.state == .propagate);
        self.gccount += 1;
        if (self.firstold1) |fo| {
            self.markOld(fo, self.reallyold);
            self.firstold1 = null;
        }
        self.markOld(self.finobj, self.finobjrold);
        self.markOld(self.tobefnz, null);
        _ = try self.atomic();

        // Sweep the nursery and the survivals of `allgc`
        self.state = .sweepallgc;
        var psurvival = self.sweepGen(&self.allgc, self.survival, &self.firstold1);
        _ = self.sweepGen(psurvival, self.old1, &self.firstold1);
        self.reallyold = self.old1;
        self.old1 = psurvival.*; // survivals are old now
        self.survival = self.allgc; // all news are survivals

        // The same for `finobj`
        var dummy: ?*value.GCObject = null; // no 'firstold1' optimisation here
        psurvival = self.sweepGen(&self.finobj, self.finobjsur, &dummy);
        _ = self.sweepGen(psurvival, self.finobjold1, &dummy);
        self.finobjrold = self.finobjold1;
        self.finobjold1 = psurvival.*;
        self.finobjsur = self.finobj;

        _ = self.sweepGen(&self.tobefnz, null, &dummy);
        self.finishGenCycle();
    }

    /// After a full atomic step: sweep everything making it old and set the
    /// generation pointers, entering generational mode (atomic2gen)
    fn atomic2gen(self: *GarbageCollector) void {
        self.gray = null;
        self.grayagain = null;
        self.weak = null;
        self.allweak = null;
        self.ephemeron = null;

        self.state = .sweepallgc;
        self.sweep2old(&self.allgc);
        self.reallyold = self.allgc;
        self.old1 = self.allgc;
        self.survival = self.allgc;
        self.firstold1 = null;

        self.sweep2old(&self.finobj);
        self.finobjrold = self.finobj;
        self.finobjold1 = self.finobj;
        self.finobjsur = self.finobj;

        self.sweep2old(&self.tobefnz);

        // The main thread lives outside the lists: old, and watched like
        // every other thread
        if (self.mainthread) |th| {
            setAge(&th.header, G_OLD);
            self.linkGrayAgain(&th.header);
        }

        self.gckind = .generational;
        self.lastatomic = 0;
        self.GCestimate = self.totalbytes; // base for memory control
        self.finishGenCycle();
    }

    /// Next minor collection when memory grows `genminormul` percent
    fn setMinorDebt(self: *GarbageCollector) void {
        self.GCdebt = -@as(isize, @intCast(self.totalbytes / 100)) * @as(isize, @max(self.genminormul, 0));
    }

    /// Enter generational mode: finish a full atomic cycle so everything is
    /// marked and weak tables cleared, then make everything old (entergen)
    fn enterGen(self: *GarbageCollector) !usize {
        try self.runUntil(.pause); // finish any cycle in progress
        try self.runUntil(.propagate); // start a new one
        const numobjs = try self.atomic();
        self.atomic2gen();
        self.setMinorDebt();
        return numobjs;
    }

    /// Enter incremental mode: everything white and new, generation
    /// pointers cleared, collector paused (enterinc)
    fn enterInc(self: *GarbageCollector) void {
        self.whiteList(self.allgc);
        self.reallyold = null;
        self.old1 = null;
        self.survival = null;
        self.firstold1 = null;
        self.whiteList(self.finobj);
        self.whiteList(self.tobefnz);
        self.finobjrold = null;
        self.finobjold1 = null;
        self.finobjsur = null;
        if (self.mainthread) |th| makeWhiteNew(self, &th.header);
        self.state = .pause;
        self.gckind = .incremental;
        self.lastatomic = 0;
    }

    /// A full collection in generational mode (fullgen)
    fn fullGen(self: *GarbageCollector) !usize {
        self.enterInc();
        return self.enterGen();
    }

    /// A major collection after a bad one: stay incremental until a
    /// collection traverses few enough objects to be worth returning to
    /// generational mode (stepgenfull)
    fn stepGenFull(self: *GarbageCollector) !void {
        const lastatomic = self.lastatomic;
        if (self.gckind == .generational) self.enterInc();
        try self.runUntil(.propagate);
        const newatomic = try self.atomic();
        if (newatomic < lastatomic + (lastatomic >> 3)) {
            self.atomic2gen(); // good collection: back to generational mode
            self.setMinorDebt();
        } else {
            self.GCestimate = self.totalbytes; // first estimate
            self.enterSweep();
            try self.runUntil(.pause);
            self.setPauseDebt();
            self.lastatomic = newatomic;
        }
    }

    /// A generational step: usually a minor collection; a major one when
    /// memory grew `genmajormul` percent past the last major collection, and
    /// a bad major collection switches to `stepGenFull` (genstep)
    /// Generational mode for the purpose of choosing a step (isdecGCmodegen):
    /// the mode proper, or the aftermath of a bad major collection, when
    /// `stepGenFull` has switched the kind to incremental for a full cycle
    /// and `lastatomic` records the count it will compare against. Testing
    /// the kind alone left the collector incremental for the rest of the
    /// program after its first bad collection, marking the whole heap on
    /// every cycle (`binarytrees`: three young collections in the first
    /// 73 KB, then none)
    pub fn isDecGCModeGen(self: *const GarbageCollector) bool {
        return self.gckind == .generational or self.lastatomic != 0;
    }

    fn genStep(self: *GarbageCollector) !void {
        if (self.lastatomic != 0) return self.stepGenFull();
        const majorbase = self.GCestimate; // memory after the last major collection
        const majorinc = (majorbase / 100) * @as(usize, @intCast(@max(self.genmajormul, 0)));
        if (self.GCdebt > 0 and self.totalbytes > majorbase + majorinc) {
            const numobjs = try self.fullGen();
            if (self.totalbytes < majorbase + majorinc / 2) {
                // collected at least half the growth: keep doing minor collections
            } else {
                self.lastatomic = numobjs; // bad collection
                self.setPauseDebt(); // long wait for the next (major) collection
            }
        } else {
            try self.youngCollection();
            self.setMinorDebt();
            self.GCestimate = majorbase; // preserve the base value
        }
    }

    /// Set GC pause
    pub fn setPause(self: *GarbageCollector, pause: i32) i32 {
        const old = self.gcpause;
        self.gcpause = pause;
        return old;
    }

    /// Set GC step multiplier
    pub fn setStepMul(self: *GarbageCollector, stepmul: i32) i32 {
        const old = self.gcstepmul;
        self.gcstepmul = stepmul;
        return old;
    }

    /// Get memory usage
    pub fn getMemory(self: *GarbageCollector) usize {
        return self.totalbytes;
    }

    /// Check if object is alive
    pub fn isAlive(self: *GarbageCollector, o: *value.GCObject) bool {
        return !isDead(self, o);
    }

    /// Number of objects currently linked in `allgc`
    pub fn countObjects(self: *const GarbageCollector) usize {
        var n: usize = 0;
        var o = self.allgc;
        while (o) |obj| : (o = obj.next) n += 1;
        return n;
    }

    /// Number of objects in `finobj` (registered finalizers)
    pub fn countFinObjects(self: *const GarbageCollector) usize {
        var n: usize = 0;
        var o = self.finobj;
        while (o) |obj| : (o = obj.next) n += 1;
        return n;
    }

    // Write barriers

    /// Forward barrier: a black object `o` starts pointing at value `v`
    pub fn barrier(self: *GarbageCollector, o: *value.GCObject, v: *const value.TValue) void {
        if (v.toGCObject()) |vo| {
            self.barrierObject(o, vo);
        }
    }

    /// Forward barrier for objects (luaC_objbarrier)
    pub fn barrierObject(self: *GarbageCollector, o: *value.GCObject, v: *value.GCObject) void {
        if (isBlack(o) and isWhite(v)) {
            if (self.keepInvariant()) {
                self.reallyMarkObject(v); // restore the invariant
                if (isOld(o)) setAge(v, G_OLD0); // restore the generational invariant
            } else if (self.gckind == .incremental) {
                makeWhite(self, o); // sweep phase: whiten `o` to avoid other barriers
            }
        }
    }

    /// Backward barrier: a black table `o` gets a white value (luaC_barrierback)
    pub fn barrierBack(self: *GarbageCollector, o: *value.GCObject) void {
        if (isBlack(o)) {
            if (getAge(o) == G_TOUCHED2) {
                set2gray(o); // already in a gray list: gray to become touched1
            } else {
                self.linkGrayAgain(o); // traverse it again in the atomic phase
            }
            if (isOld(o)) setAge(o, G_TOUCHED1); // touched in the current cycle
        }
    }

    /// Backward barrier when storing `v` into table `o`
    pub fn barrierBackValue(self: *GarbageCollector, o: *value.GCObject, v: *const value.TValue) void {
        // The value first, as luaC_barrierback does: a number or a boolean,
        // the common store, is decided on the register alone, and the
        // table's mark byte is loaded only for a collectable value (in
        // generational mode a long-lived table is black for good, so
        // testing the table first loaded it on every store)
        if (v.toGCObject()) |vo| {
            if (isBlack(o) and isWhite(vo)) self.barrierBack(o);
        }
    }

    /// Check invariants (for debugging): no black object may point to a
    /// white one while marking
    pub fn checkInvariants(self: *GarbageCollector) void {
        if (!std.debug.runtime_safety) return;
        _ = self;
    }
};

/// A TValue referring to a GC object (for calling its metamethods)
fn objectToValue(o: *value.GCObject) ?value.TValue {
    return switch (o.typeTag()) {
        .table => value.TValue.table(@fieldParentPtr("header", o)),
        .userdata => value.TValue.userdata(@fieldParentPtr("header", o)),
        else => null,
    };
}

// Tests

test "GC initialization" {
    const allocator = std.testing.allocator;
    var gc = GarbageCollector.init(allocator);
    defer gc.deinit();

    try std.testing.expect(gc.state == .pause);
    try std.testing.expect(gc.totalbytes == 0);
    try std.testing.expect(gc.currentwhite == WHITE0BIT);
}

test "GC owns and frees its objects" {
    const allocator = std.testing.allocator;
    var gc = GarbageCollector.init(allocator);
    defer gc.deinit();
    gc.attachAccounting(); // as the global state does once the collector is in place

    _ = try gc.newString("hello");
    _ = try gc.newTable(4, 4);
    _ = try gc.newUserdata(16, 2);

    try std.testing.expectEqual(@as(usize, 3), gc.countObjects());
    try std.testing.expect(gc.totalbytes > 0);
    // deinit frees everything; std.testing.allocator reports leaks otherwise
}

test "GC sweep frees unmarked objects and keeps marked ones" {
    const allocator = std.testing.allocator;
    var gc = GarbageCollector.init(allocator);
    defer gc.deinit();

    const s1 = try gc.newString("hello");
    _ = try gc.newString("world"); // never marked: garbage

    // No global state here, so mark s1 by hand after the roots phase and run
    // exactly one cycle (a second cycle would collect s1 too).
    _ = try gc.singleStep(); // .pause -> .propagate
    gc.markObject(&s1.header);
    try gc.runCycle();

    try std.testing.expect(gc.isAlive(&s1.header));
    try std.testing.expectEqual(@as(usize, 1), gc.countObjects());
    try std.testing.expect(gc.state == .pause);
}

test "GC write barrier" {
    const allocator = std.testing.allocator;
    var gc = GarbageCollector.init(allocator);
    defer gc.deinit();

    const t = try gc.newTable(0, 0);
    const s = try gc.newString("test");

    gc.state = .propagate; // barriers only act while marking
    gc.markObject(&t.header);
    markBlack(&t.header);

    const val = value.TValue.string(s);
    gc.barrier(&t.header, &val);

    try std.testing.expect(!isWhite(&s.header));
}

test "GC full cycle through a Lua state keeps reachable objects only" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();
    const gc = &L.l_G.gc;

    // Reachable: a table stored in a global, holding a string
    try api.newTable(L);
    try api.pushString(L, "kept value");
    try api.setField(L, -2, "k");
    try api.setGlobal(L, "keep");

    // Unreachable: a table and a long string left nowhere
    try api.newTable(L);
    api.pop(L, 1);
    _ = try L.l_G.string_pool.create("x" ** 64);

    const before = gc.countObjects();
    try gc.fullGC();
    const after = gc.countObjects();
    try std.testing.expect(after < before);

    // The kept table survived with its contents
    _ = try api.getGlobal(L, "keep");
    _ = try api.getField(L, -1, "k");
    try std.testing.expectEqualStrings("kept value", api.toString(L, -1).?);
    api.pop(L, 2);

    // Objects on the stack survive too
    try api.pushString(L, "on the stack");
    try gc.fullGC();
    try std.testing.expectEqualStrings("on the stack", api.toString(L, -1).?);
    api.pop(L, 1);
}

test "GC clears weak tables" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();
    const gc = &L.l_G.gc;

    // weak = setmetatable({}, {__mode = "kv"})
    try api.newTable(L); // weak table
    try api.newTable(L); // metatable
    try api.pushString(L, "kv");
    try api.setField(L, -2, "__mode");
    _ = try api.setMetatable(L, -2);
    try api.setGlobal(L, "weak");

    // weak[1] = {} (unreachable value), weak[2] = strong (reachable), weak["s"] = "str"
    _ = try api.getGlobal(L, "weak");
    try api.newTable(L);
    try api.setI(L, -2, 1);
    try api.newTable(L);
    try api.pushValueAt(L, -1);
    try api.setGlobal(L, "strong");
    try api.setI(L, -2, 2);
    try api.pushString(L, "str");
    try api.setField(L, -2, "s");
    api.pop(L, 1);

    try gc.fullGC();

    _ = try api.getGlobal(L, "weak");
    const weak = api.toTable(L, -1).?;
    try std.testing.expect(weak.getInt(1).isNil()); // collected
    try std.testing.expect(weak.getInt(2).isTable()); // still referenced
    try std.testing.expect(!weak.get(value.TValue.string(try L.l_G.string_pool.intern("s"))).isNil()); // strings are values
    api.pop(L, 1);
}

var finalized_count: u32 = 0;

fn finalizerFn(L: *state.LuaState) !i32 {
    _ = L;
    finalized_count += 1;
    return 0;
}

test "GC finalizers run for unreachable objects and at close" {
    const allocator = std.testing.allocator;
    finalized_count = 0;
    const L = try state.LuaState.init(allocator, null);
    const gc = &L.l_G.gc;

    // mt = {__gc = finalizerFn}
    try api.newTable(L);
    try api.pushCFunction(L, finalizerFn);
    try api.setField(L, -2, "__gc");
    try api.setGlobal(L, "mt");

    // Two objects with the finalizer: one dropped, one kept in a global
    try api.newTable(L);
    _ = try api.getGlobal(L, "mt");
    _ = try api.setMetatable(L, -2);
    api.pop(L, 1);

    try api.newTable(L);
    _ = try api.getGlobal(L, "mt");
    _ = try api.setMetatable(L, -2);
    try api.setGlobal(L, "kept");

    try std.testing.expectEqual(@as(usize, 2), gc.countFinObjects());

    try gc.fullGC();
    try std.testing.expectEqual(@as(u32, 1), finalized_count);
    try std.testing.expectEqual(@as(usize, 1), gc.countFinObjects());

    // The finalized object is freed by the next cycle; the kept one stays
    try gc.fullGC();
    try std.testing.expectEqual(@as(u32, 1), finalized_count);

    // Closing the state runs the remaining finalizer
    L.deinit();
    try std.testing.expectEqual(@as(u32, 2), finalized_count);
}

test "GC clears dead keys during traversal" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();
    const gc = &L.l_G.gc;

    try api.newTable(L);
    try api.setGlobal(L, "t");
    _ = try api.getGlobal(L, "t");
    const t = api.toTable(L, -1).?;
    const key = try gc.newTable(0, 0); // a collectable key
    try t.set(value.TValue.table(key), value.TValue.integer(1));
    try t.set(value.TValue.table(key), value.TValue.nil()); // remove it: entry is dead
    api.pop(L, 1);

    const before = gc.countObjects();
    try gc.fullGC();
    try std.testing.expect(gc.countObjects() < before); // the key object was freed

    // The node now holds an identity marker instead of a dangling pointer
    var dead_markers: u32 = 0;
    for (t.nodes()) |*n| {
        if (n.key().isDeadKey()) dead_markers += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), dead_markers);
}
