// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Virtual machine: the Lua 5.4 bytecode interpreter and call protocol.
//!
//! Modelled on `lvm.c`, `ldo.c` and `ltm.c`:
//!
//! - `execute` runs one Lua frame at a time in a single loop. Calls to Lua
//!   functions do not recurse in Zig: `precall` pushes a `CallInfo` and the
//!   loop re-enters at `startfunc`; `RETURN` pops it and continues the caller
//!   unless the frame was entered through `call` (`isFresh`), which returns.
//! - Vararg functions move their function and fixed parameters above the
//!   extra arguments (`adjustVarargs`), so a frame's base is always
//!   `ci.func + 1`.
//! - Every helper that may call back into Lua, allocate, or grow the stack is
//!   invoked through the `protect` pattern: the pc is saved, `L.top` is set
//!   to the frame top, and the frame base is reloaded afterwards, since the
//!   stack may have been reallocated.
//! - Metamethod dispatch (`__index`, `__newindex`, arithmetic, comparison,
//!   `__concat`, `__len`, `__eq`, `__call`, `__close`) follows `ltm.c`.
//! - Numbers follow Lua 5.4: integer arithmetic wraps, `//` and `%` floor,
//!   int/float comparisons are exact, floats format as `%.14g`.
//!
//! - Hooks are checked once per instruction when one is set (`debug.zig`
//!   does the work), and errors name the variable involved through the same
//!   module's symbolic execution of the bytecode.
//! - Coroutines live in `coroutine.zig`: a yield leaves this loop through
//!   `error.Yield`, and `resume` re-enters it from the saved `CallInfo`.

const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;

const value = @import("value.zig");
const opcode = @import("opcode.zig");
const state = @import("state.zig");
const proto = @import("proto.zig");
const table = @import("table.zig");
const stack = @import("stack.zig");
const gc = @import("gc.zig");
const string_module = @import("string.zig");
const config = @import("config.zig");
const closure_module = @import("closure.zig");
const numeral = @import("numeral.zig");
const lex = @import("lex.zig");
const debug = @import("debug.zig");

const TValue = value.TValue;
const LuaState = state.LuaState;
const CallInfo = state.CallInfo;
const Instruction = opcode.Instruction;

/// Maximum depth of __index/__newindex chains
const MAX_TAG_LOOP = 2000;

/// Arithmetic operation types (also used by the API)
pub const ArithOp = enum {
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,
    unm,
    band,
    bor,
    bxor,
    shl,
    shr,
    bnot,

    fn event(self: ArithOp) value.TMS {
        return switch (self) {
            .add => .__add,
            .sub => .__sub,
            .mul => .__mul,
            .div => .__div,
            .idiv => .__idiv,
            .mod => .__mod,
            .pow => .__pow,
            .unm => .__unm,
            .band => .__band,
            .bor => .__bor,
            .bxor => .__bxor,
            .shl => .__shl,
            .shr => .__shr,
            .bnot => .__bnot,
        };
    }

    fn isBitwise(self: ArithOp) bool {
        return switch (self) {
            .band, .bor, .bxor, .shl, .shr, .bnot => true,
            else => false,
        };
    }
};

/// Comparison operation types
pub const CompareOp = enum { eq, lt, le };

/// VM error types (Lua-level errors are `error.LuaError` with the message on the stack)
pub const VMError = error{
    TypeError,
    ArithmeticError,
    ConcatenationError,
    TableIndexError,
    CallError,
    StackOverflow,
    OutOfMemory,
    RuntimeError,
    YieldError,
    InvalidOpcode,
};

/// Errors that can escape the interpreter. Lua errors, allocator failures
/// and VM faults all travel through here, and native functions are
/// `anyerror` already.
pub const ExecError = anyerror;

/// Integer result of an arithmetic arm: inline when it fits 48 bits, else
/// a box owned by the collector
inline fn intResult(L: *LuaState, r: i64) ExecError!TValue {
    return TValue.integerChecked(r) orelse TValue.boxedInteger(try L.l_G.gc.newBoxedInt(r));
}

/// A `Number` (rawArith's result) as a value
inline fn numResult(L: *LuaState, n: value.Number) ExecError!TValue {
    return switch (n) {
        .integer => |i| intResult(L, i),
        .float => |f| TValue.float(f),
    };
}

/// Multiple results marker
pub const MULTRET: i32 = -1;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Short source name for messages ("=name" -> name, "@file" -> file, else [string "..."])
fn chunkId(buf: []u8, source: ?*value.String) []const u8 {
    // No source at all (a stripped binary chunk) is shown as a bare "?"
    return if (source) |s| shortSource(buf, s.slice()) else "?";
}

/// Size of the buffer `shortSource` needs
pub const IDSIZE = config.IDSIZE;

/// How a chunk name appears in messages (luaO_chunkid). `=name` is shown
/// verbatim and cut at the end; `@name` is a file name and keeps its *end*,
/// with `...` in front; anything else is source text, shown as
/// `[string "..."]` up to its first newline. `buf` plays the part of the
/// fixed `LUA_IDSIZE` output buffer, so it should be `IDSIZE` bytes.
pub fn shortSource(buf: []u8, src_in: []const u8) []const u8 {
    // luaO_chunkid measures the source with strlen: a NUL ends it
    const src = lex.LexState.cString(src_in);
    // C counts the terminating NUL in its budget, so the usable width is one
    // less than the buffer
    const bufflen = buf.len - 1;
    if (src.len > 0 and src[0] == '=') {
        const rest = src[1..];
        const n = @min(rest.len, bufflen);
        @memcpy(buf[0..n], rest[0..n]);
        return buf[0..n];
    }
    if (src.len > 0 and src[0] == '@') {
        const rest = src[1..];
        if (rest.len <= bufflen) {
            @memcpy(buf[0..rest.len], rest);
            return buf[0..rest.len];
        }
        const keep = bufflen - 3;
        @memcpy(buf[0..3], "...");
        @memcpy(buf[3 .. 3 + keep], rest[rest.len - keep ..]);
        return buf[0 .. 3 + keep];
    }
    const pre = "[string \"";
    const pos = "\"]";
    const rets = "...";
    const room = bufflen - (pre.len + rets.len + pos.len);
    const nl = mem.indexOfScalar(u8, src, '\n');
    var shown = src;
    var truncated = false;
    if (nl != null or src.len >= room) {
        if (nl) |at| shown = src[0..at];
        if (shown.len > room) shown = shown[0..room];
        truncated = true;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ pre, shown, if (truncated) rets else "", pos }) catch buf[0..0];
}

/// Current line of a Lua frame
pub fn currentLine(ci: *const CallInfo) i32 {
    if (!ci.callstatus.isLua) return 0;
    const cl = ci.func[0].asClosure() orelse return 0;
    if (cl.proto.sizelineinfo == 0) return -1; // stripped: no line information
    const savedpc = ci.u.l.savedpc orelse return @intCast(cl.proto.linedefined);
    const pc = (@intFromPtr(savedpc) - @intFromPtr(cl.proto.code.ptr)) / @sizeOf(Instruction);
    return @intCast(cl.proto.getLine(@intCast(if (pc > 0) pc - 1 else 0)));
}

/// Raise a runtime error with a formatted message prefixed by "source:line:"
/// A `for` loop control value that is not a number (luaG_forerror)
fn forError(L: *LuaState, o: *const TValue, what: []const u8) anyerror {
    return runtimeError(L, "bad 'for' {s} (number expected, got {s})", .{ what, debug.objTypeName(L, o) });
}

pub fn runtimeError(L: *LuaState, comptime fmt: []const u8, args: anytype) ExecError {
    // Built on the heap, as luaG_runerror's luaO_pushvfstring is: a variable
    // name in "attempt to index a nil value (local '...')" has no bound
    const body = std.fmt.allocPrint(L.allocator, fmt, args) catch |e| return e;
    defer L.allocator.free(body);
    var idbuf: [IDSIZE]u8 = undefined;
    var full: ?[]u8 = null;
    defer if (full) |f| L.allocator.free(f);
    var text: []const u8 = body;
    if (L.ci.callstatus.isLua) {
        if (L.ci.func[0].asClosure()) |cl| {
            const id = chunkId(&idbuf, cl.proto.source);
            full = std.fmt.allocPrint(L.allocator, "{s}:{d}: {s}", .{ id, currentLine(L.ci), body }) catch |e| return e;
            text = full.?;
        }
    }
    const s = L.l_G.string_pool.create(text) catch |e| return e;
    stack.push(L, TValue.string(s)) catch |e| return e;
    L.throw(.errrun) catch |e| return e;
    unreachable;
}

// ---------------------------------------------------------------------------
// Number conversions (lvm.c / lobject.c)
// ---------------------------------------------------------------------------

pub const F2Imod = enum { eq, floor, ceil };

/// Convert a float to an integer (exactly, or rounding down/up)
pub fn floatToInteger(n: f64, mode: F2Imod) ?i64 {
    var f = @floor(n);
    if (f != n) {
        switch (mode) {
            .eq => return null,
            .ceil => f += 1,
            .floor => {},
        }
    }
    // Range check (2^63 is not representable)
    if (f >= 9223372036854775808.0 or f < -9223372036854775808.0 or math.isNan(f)) return null;
    return @intFromFloat(f);
}

/// Parse a Lua numeral (decimal or hex, integer or float, surrounding spaces
/// allowed); see `numeral.zig`
pub const stringToNumber = numeral.parse;

/// Value as a number, with string coercion (luaV_tonumber_)
pub fn toNumber(v: *const TValue) ?value.Number {
    return switch (v.tag()) {
        .number => v.numberValue(),
        .string => stringToNumber(v.stringValue().slice()),
        else => null,
    };
}

/// Value as an integer with the given rounding mode (luaV_tointeger)
pub fn toInteger(v: *const TValue, mode: F2Imod) ?i64 {
    const n = toNumber(v) orelse return null;
    return switch (n) {
        .integer => |i| i,
        .float => |f| floatToInteger(f, mode),
    };
}

/// Integer conversion without string coercion (for bitwise operations)
fn toIntegerNs(v: *const TValue) ?i64 {
    if (v.tag() != .number) return null;
    return switch (v.numberValue()) {
        .integer => |i| i,
        .float => |f| floatToInteger(f, .eq),
    };
}

extern "c" fn snprintf(noalias buf: [*]u8, size: usize, noalias fmt: [*:0]const u8, ...) c_int;

/// Format a number as Lua does (lua_Number2str is `snprintf("%.14g")`,
/// and tostringbuff adds ".0" when the result looks like an integer)
pub fn numberToStringBuf(buf: []u8, n: value.Number) []const u8 {
    switch (n) {
        .integer => |i| return std.fmt.bufPrint(buf, "{d}", .{i}) catch "?",
        .float => |f| {
            const n_out = snprintf(buf.ptr, buf.len, "%.14g", f);
            if (n_out < 0 or n_out >= buf.len) return "?";
            const len: usize = @intCast(n_out);
            if (mem.indexOfNone(u8, buf[0..len], "-0123456789") == null and len + 2 <= buf.len) {
                buf[len] = numeral.localeDecimalPoint(); // "looks like an int": add the locale's ".0"
                buf[len + 1] = '0';
                return buf[0 .. len + 2];
            }
            return buf[0..len];
        },
    }
}

/// Convert a number on the stack to a string, in place (luaO_tostring)
fn toStringInPlace(L: *LuaState, v: *TValue) ExecError!bool {
    if (v.tag() != .number) return false;
    var buf: [64]u8 = undefined;
    const s = numberToStringBuf(&buf, v.numberValue());
    const str = try L.l_G.string_pool.create(s);
    v.* = TValue.string(str);
    return true;
}

// ---------------------------------------------------------------------------
// Metamethods (ltm.c)
// ---------------------------------------------------------------------------

/// Get the metamethod `tm` for a value: from the metatable of a table or
/// full userdata, otherwise from the per-type metatables in the global state.
pub fn getMetamethod(L: *LuaState, obj: *const TValue, tm: value.TMS) ?TValue {
    const mt: ?*table.Table = switch (obj.tag()) {
        .table => obj.tableValue().metatable,
        .userdata => obj.userdataValue().metatable,
        else => L.l_G.mt[@intFromEnum(obj.tag())],
    };
    const m = mt orelse return null;
    const idx = @intFromEnum(tm);
    if (idx <= @intFromEnum(value.TMS.__eq)) {
        // The "fast" events keep an absence bit on the metatable (fasttm /
        // luaT_gettm): a metatable without `__index` answers with one test
        // instead of a hash lookup. Any string-keyed store into the table
        // clears the bits (invalidateTMcache).
        const bit: u8 = @as(u8, 1) << @intCast(idx);
        if (m.flags.no_tag_method & bit != 0) return null;
        const v = m.getShortStr(L.l_G.tmname[idx]);
        if (v.isNil()) {
            m.flags.no_tag_method |= bit;
            return null;
        }
        return v;
    }
    const v = m.getShortStr(L.l_G.tmname[idx]);
    return if (v.isNil()) null else v;
}

/// Call `f(p1, p2)` discarding results (callclosemethod)
fn callTM2(L: *LuaState, f: TValue, p1: TValue, p2: TValue) ExecError!void {
    try stack.checkStack(L, 3);
    L.top[0] = f;
    L.top[1] = p1;
    L.top[2] = p2;
    const func = L.top;
    L.top += 3;
    try call(L, func, 0);
}

/// Call `f(p1, p2, p3)` discarding results (luaT_callTM)
fn callTM3(L: *LuaState, f: TValue, p1: TValue, p2: TValue, p3: TValue) ExecError!void {
    try stack.checkStack(L, 4);
    L.top[0] = f;
    L.top[1] = p1;
    L.top[2] = p2;
    L.top[3] = p3;
    const func = L.top;
    L.top += 4;
    try call(L, func, 0);
}

/// Call `f(p1, p2)` and return its first result (luaT_callTMres)
fn callTMres(L: *LuaState, f: TValue, p1: TValue, p2: TValue) ExecError!TValue {
    try stack.checkStack(L, 3);
    L.top[0] = f;
    L.top[1] = p1;
    L.top[2] = p2;
    const func = L.top;
    L.top += 3;
    try call(L, func, 1);
    L.top -= 1;
    return L.top[0];
}

/// Try the binary metamethod for `event` on p1 or p2 (callbinTM)
fn callBinTM(L: *LuaState, p1: TValue, p2: TValue, event: value.TMS) ExecError!?TValue {
    var tm = getMetamethod(L, &p1, event);
    if (tm == null) tm = getMetamethod(L, &p2, event);
    const f = tm orelse return null;
    return try callTMres(L, f, p1, p2);
}

/// Binary metamethod or error (luaT_trybinTM). The operands are pointers so
/// that, when no metamethod exists, the error can say which variable held the
/// offending value; they are only dereferenced before any call is made.
fn tryBinTM(L: *LuaState, p1: *const TValue, p2: *const TValue, event: value.TMS) ExecError!TValue {
    if (try callBinTM(L, p1.*, p2.*, event)) |r| return r;
    switch (event) {
        .__band, .__bor, .__bxor, .__shl, .__shr, .__bnot => {
            if (p1.isNumber() and p2.isNumber()) return debug.toIntError(L, p1, p2);
            return debug.opIntError(L, p1, p2, "perform bitwise operation on");
        },
        .__concat => return debug.concatError(L, p1, p2),
        else => return debug.opIntError(L, p1, p2, "perform arithmetic on"),
    }
}

/// Order metamethod (luaT_callorderTM): true/false or error
fn callOrderTM(L: *LuaState, p1: TValue, p2: TValue, event: value.TMS) ExecError!bool {
    if (try callBinTM(L, p1, p2, event)) |r| return r.isTruthy();
    return debug.orderError(L, &p1, &p2);
}

// ---------------------------------------------------------------------------
// Arithmetic (lvm.c / lobject.c)
// ---------------------------------------------------------------------------

fn intArith(L: *LuaState, op: ArithOp, a: i64, b: i64) ExecError!i64 {
    return switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .idiv => blk: {
            if (b == 0) return runtimeError(L, "attempt to divide by zero", .{});
            if (b == -1) break :blk 0 -% a; // avoid overflow with minint // -1
            break :blk @divFloor(a, b);
        },
        .mod => blk: {
            // Not a Zig format escape: the message contains a literal '%'
            if (b == 0) return runtimeError(L, "attempt to perform 'n%0'", .{});
            if (b == -1) break :blk 0;
            break :blk @mod(a, b);
        },
        .band => a & b,
        .bor => a | b,
        .bxor => a ^ b,
        .shl => shiftLeft(a, b),
        .shr => shiftLeft(a, 0 -% b),
        .unm => 0 -% a,
        .bnot => ~a,
        else => unreachable,
    };
}

pub fn shiftLeft(x: i64, y: i64) i64 {
    if (y <= -64 or y >= 64) return 0;
    if (y >= 0) return @bitCast(@as(u64, @bitCast(x)) << @intCast(y));
    return @bitCast(@as(u64, @bitCast(x)) >> @intCast(-y));
}

fn floatMod(a: f64, b: f64) f64 {
    var m = @rem(a, b);
    if ((m > 0 and b < 0) or (m < 0 and b > 0)) m += b;
    return m;
}

fn floatArith(op: ArithOp, a: f64, b: f64) f64 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        .pow => if (b == 2) a * a else math.pow(f64, a, b),
        .idiv => @floor(a / b),
        .mod => floatMod(a, b),
        .unm => -a,
        else => unreachable,
    };
}

/// Raw arithmetic on two numbers (luaO_rawarith); null when a bitwise
/// operand has no integer representation
fn rawArith(L: *LuaState, op: ArithOp, a: value.Number, b: value.Number) ExecError!?value.Number {
    switch (op) {
        .band, .bor, .bxor, .shl, .shr, .bnot => {
            const ia = (if (a == .integer) a.integer else floatToInteger(a.float, .eq)) orelse return null;
            const ib = (if (b == .integer) b.integer else floatToInteger(b.float, .eq)) orelse return null;
            return .{ .integer = try intArith(L, op, ia, ib) };
        },
        .div, .pow => return .{ .float = floatArith(op, a.toFloat(), b.toFloat()) },
        else => {
            if (a == .integer and b == .integer) {
                return .{ .integer = try intArith(L, op, a.integer, b.integer) };
            }
            return .{ .float = floatArith(op, a.toFloat(), b.toFloat()) };
        },
    }
}

/// Arithmetic with metamethod fall-back (luaO_arith / luaT_trybinTM)
pub fn arithOp(L: *LuaState, v1: *const TValue, v2: *const TValue, op: ArithOp) ExecError!TValue {
    const p1 = v1.*;
    const p2 = v2.*;
    if (p1.tag() == .number and p2.tag() == .number) {
        if (try rawArith(L, op, p1.numberValue(), p2.numberValue())) |r| return numResult(L, r);
    }
    return tryBinTM(L, v1, v2, op.event());
}

/// Unary arithmetic (`-x`, `~x`)
pub fn unaryOp(L: *LuaState, v: *const TValue, op: ArithOp) ExecError!TValue {
    return arithOp(L, v, v, op);
}

// ---------------------------------------------------------------------------
// Comparison (lvm.c)
// ---------------------------------------------------------------------------

/// Whether an integer is exactly representable as a float
fn intFitsFloat(i: i64) bool {
    const lim: i64 = 1 << 53;
    return -lim <= i and i <= lim;
}

fn ltIntFloat(i: i64, f: f64) bool {
    if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) < f;
    // i < f  <=>  i < ceil(f)
    if (floatToInteger(f, .ceil)) |fi| return i < fi;
    return f > 0;
}

fn leIntFloat(i: i64, f: f64) bool {
    if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) <= f;
    if (floatToInteger(f, .floor)) |fi| return i <= fi;
    return f > 0;
}

fn ltFloatInt(f: f64, i: i64) bool {
    if (intFitsFloat(i)) return f < @as(f64, @floatFromInt(i));
    if (floatToInteger(f, .floor)) |fi| return fi < i;
    return f < 0;
}

fn leFloatInt(f: f64, i: i64) bool {
    if (intFitsFloat(i)) return f <= @as(f64, @floatFromInt(i));
    if (floatToInteger(f, .ceil)) |fi| return fi <= i;
    return f < 0;
}

fn ltNum(a: value.Number, b: value.Number) bool {
    return switch (a) {
        .integer => |i| switch (b) {
            .integer => |j| i < j,
            .float => |g| ltIntFloat(i, g),
        },
        .float => |f| switch (b) {
            .integer => |j| ltFloatInt(f, j),
            .float => |g| f < g,
        },
    };
}

fn leNum(a: value.Number, b: value.Number) bool {
    return switch (a) {
        .integer => |i| switch (b) {
            .integer => |j| i <= j,
            .float => |g| leIntFloat(i, g),
        },
        .float => |f| switch (b) {
            .integer => |j| leFloatInt(f, j),
            .float => |g| f <= g,
        },
    };
}

/// Exact int/float equality (luaV_equalobj for numbers)
pub fn numEq(a: value.Number, b: value.Number) bool {
    return switch (a) {
        .integer => |i| switch (b) {
            .integer => |j| i == j,
            .float => |g| if (floatToInteger(g, .eq)) |gi| gi == i else false,
        },
        .float => |f| switch (b) {
            .integer => |j| if (floatToInteger(f, .eq)) |fi| fi == j else false,
            .float => |g| f == g,
        },
    };
}

pub fn lessThan(L: *LuaState, a: TValue, b: TValue) ExecError!bool {
    if (a.isNumber() and b.isNumber()) return ltNum(a.numberValue(), b.numberValue());
    if (a.isString() and b.isString()) return mem.order(u8, a.stringValue().slice(), b.stringValue().slice()) == .lt;
    return callOrderTM(L, a, b, .__lt);
}

pub fn lessEqual(L: *LuaState, a: TValue, b: TValue) ExecError!bool {
    if (a.isNumber() and b.isNumber()) return leNum(a.numberValue(), b.numberValue());
    if (a.isString() and b.isString()) return mem.order(u8, a.stringValue().slice(), b.stringValue().slice()) != .gt;
    return callOrderTM(L, a, b, .__le);
}

/// Raw equality without metamethods (luaV_rawequalobj)
pub fn rawEqual(a: TValue, b: TValue) bool {
    if (a.isNumber() and b.isNumber()) return numEq(a.numberValue(), b.numberValue());
    if (a.tag() != b.tag()) return false;
    if (a.isString()) {
        return a.stringValue() == b.stringValue() or mem.eql(u8, a.stringValue().slice(), b.stringValue().slice());
    }
    return a.rawEqual(b);
}

/// Equality with `__eq` for tables and full userdata (luaV_equalobj)
pub fn equalObj(L: *LuaState, a: TValue, b: TValue) ExecError!bool {
    if (rawEqual(a, b)) return true;
    if (a.tag() != b.tag()) return false;
    if (a.tag() != .table and a.tag() != .userdata) return false;
    if (try callBinTM(L, a, b, .__eq)) |r| return r.isTruthy();
    return false;
}

pub fn compareOp(L: *LuaState, v1: *const TValue, v2: *const TValue, op: CompareOp) ExecError!bool {
    const a = v1.*;
    const b = v2.*;
    return switch (op) {
        .eq => equalObj(L, a, b),
        .lt => lessThan(L, a, b),
        .le => lessEqual(L, a, b),
    };
}

// ---------------------------------------------------------------------------
// Table access with metamethods (lvm.c luaV_finishget / luaV_finishset)
// ---------------------------------------------------------------------------

pub fn getTable(L: *LuaState, t: *const TValue, key: *const TValue) ExecError!TValue {
    return finishGet(L, t, key, false);
}

/// `t[key]` after a raw lookup (luaV_finishget). With `probed` the caller
/// already searched `t` (a table) for the key and found nil, so the chain
/// starts at its `__index` without searching again.
pub fn finishGet(L: *LuaState, t: *const TValue, key: *const TValue, probed: bool) ExecError!TValue {
    var current = t.*;
    const k = key.*;
    var skip = probed;
    var loop: u32 = 0;
    while (loop < MAX_TAG_LOOP) : (loop += 1) {
        var tm: TValue = undefined;
        if (current.asTable()) |tbl| {
            if (!skip) {
                const v = tbl.get(k);
                if (!v.isNil()) return v;
            }
            skip = false;
            tm = getMetamethod(L, &current, .__index) orelse return TValue.nil(); // no metamethod: nil
        } else {
            // Only the original operand can be named; a metamethod value
            // reached through the chain is not a variable
            tm = getMetamethod(L, &current, .__index) orelse return debug.typeError(L, if (loop == 0) t else &current, "index");
        }
        if (tm.isFunction()) return callTMres(L, tm, current, k);
        current = tm; // repeat the access over the metamethod value
    }
    return runtimeError(L, "'__index' chain too long; possible loop", .{});
}

/// `t[key] = val` with metamethods (luaV_fastset followed by
/// luaV_finishset). The opcode arms run the probe themselves and call
/// `finishSet` with its result; this entry is for the API.
pub fn setTable(L: *LuaState, t: *const TValue, key: *const TValue, val: *const TValue) ExecError!void {
    if (t.asTable()) |tbl| {
        const slot = tbl.findSlot(key.*);
        if (slot) |s| {
            if (!s.isNil()) {
                s.* = val.*;
                L.l_G.gc.barrierBackValue(&tbl.header, val);
                return;
            }
        }
        return finishSet(L, t, key, val, slot);
    }
    return finishSet(L, t, key, val, null);
}

/// Finish a store whose probe found no non-nil entry (luaV_finishset).
/// `slot` is that probe's result for `t` when `t` is a table: the slot of
/// a nil-valued entry, or null when the key is absent, so the raw store
/// does not search the table again.
pub fn finishSet(L: *LuaState, t: *const TValue, key: *const TValue, val: *const TValue, slot0: ?*TValue) ExecError!void {
    var current = t.*;
    var slot = slot0;
    const k = key.*;
    const v = val.*;
    var loop: u32 = 0;
    while (loop < MAX_TAG_LOOP) : (loop += 1) {
        var tm: TValue = undefined;
        if (current.asTable()) |tbl| {
            tm = getMetamethod(L, &current, .__newindex) orelse {
                try rawSetSlot(L, tbl, k, v, slot);
                return;
            };
        } else {
            tm = getMetamethod(L, &current, .__newindex) orelse return debug.typeError(L, if (loop == 0) t else &current, "index");
        }
        if (tm.isFunction()) {
            try callTM3(L, tm, current, k, v);
            return;
        }
        current = tm; // repeat the assignment over the metamethod value
        slot = null;
        if (current.asTable()) |tbl| {
            slot = tbl.findSlot(k);
            if (slot) |s| {
                if (!s.isNil()) {
                    s.* = v;
                    L.l_G.gc.barrierBackValue(&tbl.header, &v);
                    return;
                }
            }
        }
    }
    return runtimeError(L, "'__newindex' chain too long; possible loop", .{});
}

/// Raw store into `tbl` after a probe (luaH_finishset): into the existing
/// nil-valued `slot`, or a fresh key when `slot` is null. Raises the
/// reference's key errors and applies the GC write barrier.
fn rawSetSlot(L: *LuaState, tbl: *table.Table, k: TValue, v: TValue, slot: ?*TValue) ExecError!void {
    if (slot) |s| {
        if (k.isString()) tbl.flags.no_tag_method = 0; // invalidateTMcache
        s.* = v;
    } else {
        tbl.setAbsent(k, v) catch |err| switch (err) {
            error.InvalidKey => {
                if (k.isNil()) return runtimeError(L, "table index is nil", .{});
                return runtimeError(L, "table index is NaN", .{});
            },
            else => return err,
        };
        // A white key stored into a black table (luaH_newkey's barrier)
        L.l_G.gc.barrierBackValue(&tbl.header, &k);
    }
    L.l_G.gc.barrierBackValue(&tbl.header, &v);
}

pub fn getTableInt(L: *LuaState, t: *const TValue, idx: i64) ExecError!TValue {
    if (t.asTable()) |tbl| {
        const v = tbl.getInt(idx);
        if (!v.isNil() or tbl.metatable == null) return v;
    }
    return getTable(L, t, &(try TValue.integerOrBox(&L.l_G.gc, idx)));
}

pub fn setTableInt(L: *LuaState, t: *const TValue, idx: i64, val: *const TValue) ExecError!void {
    return setTable(L, t, &(try TValue.integerOrBox(&L.l_G.gc, idx)), val);
}

/// Length operator (luaV_objlen)
pub fn lenOp(L: *LuaState, v: *const TValue) ExecError!TValue {
    const o = v.*;
    switch (o.tag()) {
        .table => {
            if (getMetamethod(L, &o, .__len)) |tm| return callTMres(L, tm, o, o);
            return TValue.integer(@intCast(o.tableValue().arrayLen()));
        },
        .string => return TValue.integer(@intCast(o.stringValue().len())),
        else => {
            if (getMetamethod(L, &o, .__len)) |tm| return callTMres(L, tm, o, o);
            return debug.typeError(L, v, "get length of");
        },
    }
}

// ---------------------------------------------------------------------------
// Concatenation (luaV_concat)
// ---------------------------------------------------------------------------

fn isStringOrNumber(v: *const TValue) bool {
    return v.isString() or v.isNumber();
}

/// Concatenate the `total` values on top of the stack into one (luaV_concat)
pub fn concatenate(L: *LuaState, total_in: u32) ExecError!void {
    var total = total_in;
    if (total == 1) return;
    while (total > 1) {
        const top = L.top;
        var n: u32 = 2; // number of elements handled in this pass
        const a = &(top - 2)[0];
        const b = &(top - 1)[0];
        if (!(isStringOrNumber(a) or isStringOrNumber(b)) or !(isStringOrNumber(b) or isStringOrNumber(a)) or !isStringOrNumber(a) or !isStringOrNumber(b)) {
            // At least one operand is not a string or number: metamethod
            const r = (try callBinTM(L, a.*, b.*, .__concat)) orelse return debug.concatError(L, a, b);
            (L.top - 2)[0] = r; // the stack may have moved: use L.top again
        } else if (b.isString() and b.stringValue().len() == 0) {
            _ = try toStringInPlace(L, a); // result is the first operand (as a string)
        } else if (a.isString() and a.stringValue().len() == 0) {
            _ = try toStringInPlace(L, b); // result is the second operand (as a string)
            a.* = b.*;
        } else {
            // Collect as many string/number values as possible
            var tl: usize = 0;
            n = 1;
            while (n <= total and isStringOrNumber(&(top - n)[0])) : (n += 1) {
                _ = try toStringInPlace(L, &(top - n)[0]);
                tl += (top - n)[0].stringValue().len();
            }
            n -= 1;
            const buffer = try L.allocator.alloc(u8, tl);
            defer L.allocator.free(buffer);
            var pos: usize = 0;
            var i: usize = n;
            while (i > 0) : (i -= 1) {
                const s = (top - i)[0].stringValue().slice();
                @memcpy(buffer[pos .. pos + s.len], s);
                pos += s.len;
            }
            const result = try L.l_G.string_pool.create(buffer);
            (top - n)[0] = TValue.string(result);
        }
        total -= n - 1; // got `n` strings to create one new
        L.top -= n - 1; // popped `n` strings and pushed one
    }
}

// ---------------------------------------------------------------------------
// To-be-closed variables and upvalues (lfunc.c)
// ---------------------------------------------------------------------------

pub fn closeUpvalues(L: *LuaState, level: [*]TValue) ExecError!void {
    try closure_module.closeUpvalues(L, &level[0]);
}

/// Mark the value at `level` as to-be-closed (luaF_newtbcupval)
fn newTbcUpval(L: *LuaState, level: [*]TValue) ExecError!void {
    const v = level[0];
    if (v.isFalsy()) return; // false/nil: nothing to close
    if (getMetamethod(L, &v, .__close) == null) {
        const idx: i32 = @intCast((@intFromPtr(level) - @intFromPtr(L.ci.func)) / @sizeOf(TValue));
        const vname = if (debug.findLocal(L, L.ci, idx)) |loc| loc.name else "?";
        return runtimeError(L, "variable '{s}' got a non-closable value", .{vname});
    }
    const off: u32 = @intCast((@intFromPtr(level) - @intFromPtr(L.stack)) / @sizeOf(TValue));
    try L.tbclist.append(L.allocator, off);
}

/// Close upvalues and to-be-closed variables down to `level` (luaF_close).
///
/// With an error object, each `__close` handler receives it, and it is kept
/// on the stack just above the variable being closed while the handler runs
/// (prepcallclosemth), so the collector cannot free it and a handler's frames
/// cannot overwrite variables still waiting to be closed. If a handler raises,
/// the variable is already off the list, so a caller can catch the new error
/// and call again to close the rest (luaD_closeprotected).
pub fn closeAll(L: *LuaState, level: [*]TValue, err: ?TValue) ExecError!void {
    try closeUpvalues(L, level);
    const level_off: u32 = @intCast((@intFromPtr(level) - @intFromPtr(L.stack)) / @sizeOf(TValue));
    while (L.tbclist.items.len > 0) {
        const off = L.tbclist.items[L.tbclist.items.len - 1];
        if (off < level_off) break;
        L.tbclist.items.len -= 1;
        const obj = L.stack[off];
        // The metamethod may have been removed since the variable was
        // declared; calling the missing handler is the reported error
        const tm = getMetamethod(L, &obj, .__close) orelse
            return runtimeError(L, "attempt to call a nil value (metamethod 'close')", .{});
        if (err) |e| {
            L.stack[off + 1] = e;
            L.top = L.stack + off + 2;
        }
        try callTM2(L, tm, obj, err orelse TValue.nil());
    }
}

// ---------------------------------------------------------------------------
// Calls (ldo.c)
// ---------------------------------------------------------------------------

/// Grow the stack if needed, keeping `func` (a pointer into it) valid
fn checkStackP(L: *LuaState, n: u32, func: *[*]TValue) ExecError!void {
    const space = @intFromPtr(L.stack_last) - @intFromPtr(L.top);
    if (space < @as(usize, n) * @sizeOf(TValue)) {
        const off = @intFromPtr(func.*) - @intFromPtr(L.stack);
        stack.growStack(L, @intCast(n)) catch |err| switch (err) {
            error.StackOverflow => {
                // Lua recursion is bounded by the stack size: report it as a
                // Lua error, using some extra room to build the message
                // (luaD_growstack). A second overflow while handling one is fatal.
                if (L.stacksize > stack.MAXSTACK) {
                    // Already using the space reserved for handling an
                    // overflow: an error while handling an error
                    // (luaD_growstack → LUA_ERRERR)
                    L.throw(.errerr) catch |e| return e;
                    unreachable;
                }
                try stack.reallocStack(L, stack.ERRORSTACKSIZE);
                func.* = @ptrFromInt(@intFromPtr(L.stack) + off);
                return runtimeError(L, "stack overflow", .{});
            },
            else => return err,
        };
        func.* = @ptrFromInt(@intFromPtr(L.stack) + off);
    }
}

/// Like `checkStackP`, and also run a GC step if due
fn checkStackGCP(L: *LuaState, n: u32, func: *[*]TValue) ExecError!void {
    try checkStackP(L, n, func);
    // Every call is a point where all live objects are reachable, whether
    // or not a collector step is due (an emergency collection measures
    // "young" from the last such point)
    L.l_G.gc.safePoint();
    if (L.l_G.gc.GCdebt > 0 and L.l_G.gc.gcrunning) {
        const off = @intFromPtr(func.*) - @intFromPtr(L.stack);
        try L.l_G.gc.checkGC();
        func.* = @ptrFromInt(@intFromPtr(L.stack) + off);
    }
}

/// Insert the `__call` metamethod of `func` below it (luaD_tryfuncTM)
fn tryFuncTM(L: *LuaState, func_in: *[*]TValue) ExecError!void {
    const f = func_in.*[0];
    const tm = getMetamethod(L, &f, .__call) orelse return debug.callError(L, &func_in.*[0]);
    try checkStackP(L, 1, func_in);
    const func = func_in.*;
    // Open a hole where the function is
    var p = L.top;
    while (@intFromPtr(p) > @intFromPtr(func)) : (p -= 1) {
        p[0] = (p - 1)[0];
    }
    L.top += 1;
    func[0] = tm;
}

/// Move `nres` results from `firstresult` to `res` and adjust to `wanted` (moveresults)
fn moveResults(L: *LuaState, res: [*]TValue, nres: u32, wanted: i32) void {
    const firstresult = L.top - nres;
    switch (wanted) {
        0 => {
            L.top = res;
            return;
        },
        1 => {
            res[0] = if (nres == 0) TValue.nil() else firstresult[0];
            L.top = res + 1;
            return;
        },
        MULTRET => {
            var i: u32 = 0;
            while (i < nres) : (i += 1) res[i] = firstresult[i];
            L.top = res + nres;
            return;
        },
        else => {
            const w: u32 = @intCast(wanted);
            const n = @min(nres, w);
            var i: u32 = 0;
            while (i < n) : (i += 1) res[i] = firstresult[i];
            while (i < w) : (i += 1) res[i] = TValue.nil();
            L.top = res + w;
        },
    }
}

/// Finish a call: move results to `ci.func` and pop the frame (luaD_poscall)
pub fn posCall(L: *LuaState, ci: *CallInfo, nres: u32) ExecError!void {
    if (L.hookmask.any()) try debug.retHook(L, ci, nres);
    moveResults(L, ci.func, nres, ci.nresults);
    L.ci = ci.previous orelse &L.base_ci;
}

/// The Lua-closure half of luaD_precall: push a frame for `cl` at `func`.
/// Inlined into the `CALL` arm; growing the stack, a pending GC step and
/// allocating a CallInfo are the rare paths and stay out of line.
inline fn precallLua(L: *LuaState, func_in: [*]TValue, nresults: i32, cl: *closure_module.LClosure) ExecError!*CallInfo {
    var func = func_in;
    const p = cl.proto;
    const fsize: u32 = p.maxstacksize;
    const g = &L.l_G.gc;
    if (@intFromPtr(L.stack_last) - @intFromPtr(L.top) < @as(usize, fsize) * @sizeOf(TValue) or (g.GCdebt > 0 and g.gcrunning)) {
        try checkStackGCP(L, fsize, &func);
    }
    const narg: u32 = @intCast((@intFromPtr(L.top) - @intFromPtr(func)) / @sizeOf(TValue) - 1);
    const ci = try stack.nextCI(L);
    ci.func = func;
    ci.nresults = @intCast(nresults);
    ci.callstatus = .{ .isLua = true };
    ci.top = func + 1 + fsize;
    ci.u = .{ .l = .{ .savedpc = p.code.ptr, .nextraargs = 0, .nres = 0 } };
    var n = narg;
    while (n < p.numparams) : (n += 1) {
        L.top[0] = TValue.nil(); // complete missing arguments
        L.top += 1;
    }
    return ci;
}

/// Prepare a call. Returns the new frame for a Lua function (to be executed
/// by the caller) or null after running a native function (luaD_precall).
fn precall(L: *LuaState, func_in: [*]TValue, nresults: i32) ExecError!?*CallInfo {
    var func = func_in;
    while (true) {
        const f = func[0];
        if (f.isFunction()) {
            if (f.asClosure()) |cl| return try precallLua(L, func, nresults, cl);
            if (f.asCClosure()) |cc| {
                try precallC(L, &func, nresults, cc.f);
                return null;
            }
            {
                try precallC(L, &func, nresults, f.asNativeFunction().?);
                return null;
            }
        }
        try tryFuncTM(L, &func); // try to get '__call' metamethod
        // and retry with the metamethod as the function
    }
}

/// Call a native function (precallC)
fn precallC(L: *LuaState, func: *[*]TValue, nresults: i32, f: state.CFunction) ExecError!void {
    try checkStackGCP(L, config.MINSTACK, func);
    const ci = try stack.nextCI(L);
    ci.func = func.*;
    ci.nresults = @intCast(nresults);
    ci.callstatus = .{};
    ci.top = L.top + config.MINSTACK;
    ci.u = .{ .c = state.CCallInfo.init() };
    if (L.hookmask.any()) {
        const narg: u16 = @intCast((@intFromPtr(L.top) - @intFromPtr(func.*)) / @sizeOf(TValue) - 1);
        try debug.hookCallC(L, narg);
    }
    const n = try f(L);
    if (n < 0) return runtimeError(L, "native function returned a negative result count", .{});
    try posCall(L, ci, @intCast(n));
}

/// Call the value at `func` with the arguments above it (luaD_call)
pub fn call(L: *LuaState, func: [*]TValue, nresults: i32) ExecError!void {
    if (L.nCcalls >= config.MAXCCALLS) {
        return runtimeError(L, "C stack overflow", .{});
    }
    L.nCcalls += 1;
    defer L.nCcalls -= 1;
    if (try precall(L, func, nresults)) |ci| {
        ci.callstatus.isFresh = true; // mark that it is a "fresh" execute
        try execute(L, ci);
    }
}

/// Call with an explicit argument count: `func` followed by `nargs` values
pub fn doCall(L: *LuaState, func: [*]TValue, nargs: u32, nresults: i16) ExecError!void {
    L.top = func + 1 + nargs;
    return call(L, func, nresults);
}

/// Move the function and fixed parameters above the varargs (luaT_adjustvarargs)
fn adjustVarargs(L: *LuaState, nfixparams: u32, ci: *CallInfo, p: *proto.Proto) ExecError!void {
    const actual: u32 = @intCast((@intFromPtr(L.top) - @intFromPtr(ci.func)) / @sizeOf(TValue) - 1);
    const nextra: u32 = actual - nfixparams;
    ci.u.l.nextraargs = nextra;
    var func = ci.func;
    try checkStackGCP(L, p.maxstacksize + 1, &func);
    ci.func = func;
    // Copy function to the top of the stack
    L.top[0] = func[0];
    L.top += 1;
    // Move fixed parameters to their final position
    var i: u32 = 1;
    while (i <= nfixparams) : (i += 1) {
        L.top[0] = func[i];
        L.top += 1;
        func[i] = TValue.nil(); // erase original parameter (for GC)
    }
    ci.func += actual + 1;
    ci.top += actual + 1;
    assert(@intFromPtr(L.top) <= @intFromPtr(ci.top) and @intFromPtr(ci.top) <= @intFromPtr(L.stack_last));
}

/// Copy `wanted` varargs (or all, for MULTRET) to `where` (luaT_getvarargs)
fn getVarargs(L: *LuaState, ci: *CallInfo, where_off: usize, wanted_in: i32) ExecError!void {
    const nextra = ci.u.l.nextraargs;
    var wanted: u32 = undefined;
    if (wanted_in < 0) {
        wanted = nextra;
        var dummy = ci.func;
        try checkStackGCP(L, nextra, &dummy);
        ci.func = dummy;
        L.top = L.stack + where_off + nextra;
    } else {
        wanted = @intCast(wanted_in);
    }
    const where = L.stack + where_off;
    var i: u32 = 0;
    while (i < wanted and i < nextra) : (i += 1) {
        where[i] = (ci.func - nextra + i)[0];
    }
    while (i < wanted) : (i += 1) {
        where[i] = TValue.nil(); // complete required results with nil
    }
}

/// Prepare a tail call in the current frame (luaD_pretailcall). Returns
/// the number of results for a native function, or null for a Lua function
/// whose frame now replaces the current one.
fn preTailCall(L: *LuaState, ci: *CallInfo, func_in: [*]TValue, narg1_in: u32, delta: u32) ExecError!?u32 {
    var func = func_in;
    var narg1 = narg1_in;
    while (true) {
        switch (func[0].tag()) {
            .function => switch (func[0].functionValue()) {
                .closure => |cl| {
                    const p = cl.proto;
                    const fsize: u32 = p.maxstacksize;
                    const nfixparams: u32 = p.numparams;
                    // A vararg caller's extra arguments (delta) already occupy
                    // stack space the callee can reuse; nothing to check when
                    // they exceed its frame
                    if (fsize > delta) try checkStackGCP(L, fsize - delta, &func);
                    ci.func -= delta; // restore 'func' (if vararg)
                    var i: u32 = 0;
                    while (i < narg1) : (i += 1) { // move down function and arguments
                        ci.func[i] = func[i];
                    }
                    func = ci.func;
                    while (narg1 <= nfixparams) : (narg1 += 1) {
                        func[narg1] = TValue.nil(); // complete missing arguments
                    }
                    ci.top = func + 1 + fsize;
                    ci.u.l.savedpc = p.code.ptr;
                    ci.u.l.nextraargs = 0;
                    ci.callstatus.isTailCall = true;
                    L.top = func + narg1;
                    return null;
                },
                .cclosure => |cl| return try preTailCallC(L, &func, cl.f),
                .native_fn => |f| return try preTailCallC(L, &func, f),
            },
            else => {
                try tryFuncTM(L, &func);
                narg1 += 1;
            },
        }
    }
}

fn preTailCallC(L: *LuaState, func: *[*]TValue, f: state.CFunction) ExecError!u32 {
    try checkStackGCP(L, config.MINSTACK, func);
    const ci = try stack.nextCI(L);
    ci.func = func.*;
    ci.nresults = MULTRET;
    ci.callstatus = .{};
    ci.top = L.top + config.MINSTACK;
    ci.u = .{ .c = state.CCallInfo.init() };
    if (L.hookmask.any()) {
        const narg: u16 = @intCast((@intFromPtr(L.top) - @intFromPtr(func.*)) / @sizeOf(TValue) - 1);
        try debug.hookCallC(L, narg);
    }
    const n = try f(L);
    if (n < 0) return runtimeError(L, "native function returned a negative result count", .{});
    if (L.hookmask.any()) try debug.retHook(L, ci, @intCast(n));
    // Leave the results at the top (the caller's frame moves them)
    L.ci = ci.previous orelse &L.base_ci;
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// For loops (lvm.c)
// ---------------------------------------------------------------------------

/// Try to convert the limit of a numeric for loop to an integer, clipping
/// it if necessary. Returns whether the loop must be skipped (forlimit).
fn forLimit(L: *LuaState, init: i64, lim: *const TValue, p: *i64, step: i64) ExecError!bool {
    if (toInteger(lim, if (step < 0) .ceil else .floor)) |li| {
        p.* = li;
    } else {
        // Not coercible to an integer
        const n = toNumber(lim) orelse return forError(L, lim, "limit");
        const flim = n.toFloat();
        if (math.isNan(flim)) return true;
        if (flim > 0) {
            p.* = math.maxInt(i64);
            if (step < 0) return true; // initial value must be less than it
        } else {
            p.* = math.minInt(i64);
            if (step >= 0) return true; // initial value must be greater than it
        }
    }
    return if (step > 0) init > p.* else init < p.*;
}

/// Prepare a numeric for loop. Returns true when the loop must be skipped.
fn forPrep(L: *LuaState, ra: [*]TValue) ExecError!bool {
    const pinit = &ra[0];
    const plimit = &ra[1];
    const pstep = &ra[2];
    if (pinit.isInteger() and pstep.isInteger()) {
        const init = pinit.integerValue();
        const step = pstep.integerValue();
        if (step == 0) return runtimeError(L, "'for' step is zero", .{});
        ra[3] = try TValue.integerOrBox(&L.l_G.gc, init); // control variable
        var limit: i64 = undefined;
        if (try forLimit(L, init, plimit, &limit, step)) return true;
        // Prepare loop counter (number of iterations, unsigned)
        var count: u64 = undefined;
        if (step > 0) {
            count = @as(u64, @bitCast(limit)) -% @as(u64, @bitCast(init));
            if (step != 1) count /= @as(u64, @intCast(step));
        } else {
            count = @as(u64, @bitCast(init)) -% @as(u64, @bitCast(limit));
            // step < 0: avoid negating minint
            count /= @as(u64, @bitCast(0 -% (step + 1))) + 1;
        }
        plimit.* = try TValue.integerOrBox(&L.l_G.gc, @bitCast(count)); // the limit slot holds the counter
        // FORLOOP tests the step alone, so the step stays inline only when
        // the initial value and the count are inline too
        if (pstep.isInlineInt() and !(pinit.isInlineInt() and plimit.isInlineInt())) {
            pstep.* = TValue.boxedInteger(try L.l_G.gc.newBoxedInt(step));
        }
    } else {
        // Float loop
        const ninit = toNumber(pinit) orelse return forError(L, pinit, "initial value");
        const nlimit = toNumber(plimit) orelse return forError(L, plimit, "limit");
        const nstep = toNumber(pstep) orelse return forError(L, pstep, "step");
        const init = ninit.toFloat();
        const limit = nlimit.toFloat();
        const step = nstep.toFloat();
        if (step == 0) return runtimeError(L, "'for' step is zero", .{});
        if (if (step > 0) limit < init else init < limit) return true;
        plimit.* = TValue.float(limit);
        pstep.* = TValue.float(step);
        ra[0] = TValue.float(init);
        ra[3] = TValue.float(init);
    }
    return false;
}

/// One iteration of a float for loop. Returns true to continue.
fn floatForLoop(ra: [*]TValue) bool {
    const step = ra[2].floatValue();
    const limit = ra[1].floatValue();
    var idx = ra[0].floatValue();
    idx += step;
    if (if (step > 0) idx <= limit else limit <= idx) {
        ra[0] = TValue.float(idx);
        ra[3] = TValue.float(idx);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The interpreter loop (luaV_execute)
// ---------------------------------------------------------------------------

/// Advance the program counter by a signed instruction offset
inline fn jumpPc(pc: [*]const Instruction, offset: anytype) [*]const Instruction {
    const off: isize = @intCast(offset);
    return if (off >= 0) pc + @as(usize, @intCast(off)) else pc - @as(usize, @intCast(-off));
}

/// Fetch the next instruction: the per-instruction hook check, then the
/// decode that heads the `for (;;)` in luaV_execute. Every arm of the
/// dispatch switch ends with `continue :vm try fetch(...)`, so the opcode
/// it returns is dispatched with an indirect jump of the arm's own (what
/// `ljumptab.h` does with computed gotos).
inline fn fetch(L: *LuaState, ci: *CallInfo, base: *[*]TValue, pc: *[*]const Instruction, inst: *Instruction, a: *u32, trap: *bool) ExecError!opcode.OpCode {
    if (trap.*) {
        @branchHint(.unlikely);
        try debug.traceExec(L, pc.*);
        base.* = ci.func + 1;
        // `trap` is left as it is: a hook that removed the hooks costs a
        // few early returns from traceExec until the next call-out or
        // backward jump reloads it, and keeping it out of this block keeps
        // the flag a plain register on the fast path
    }
    inst.* = pc.*[0];
    pc.* += 1;
    a.* = opcode.getA(inst.*);
    return opcode.getOpcode(inst.*);
}

/// Run the Lua frame `ci_start` (and every frame it calls) until it returns
pub fn execute(L: *LuaState, ci_start: *CallInfo) ExecError!void {
    // The labeled switch with every arm's inline fetch is one very large
    // function; its analysis needs more than the default branch quota
    @setEvalBranchQuota(100_000);
    var ci = ci_start;

    startfunc: while (true) {
        // (Re)load the frame state
        // A frame this loop runs is a Lua closure's, with its pc set: the
        // pre-call put both there, so neither is checked (Lua's `ci_func`)
        const cl = ci.func[0].closureValue();
        const k = cl.proto.constants;
        var base = ci.func + 1;
        // Lua's `trap`: the hook mask, held in a local so the fetch tests a
        // register and not the state; reloaded wherever `base` is, which is
        // after every operation that can run code that installs a hook
        var trap = L.hookmask.any();
        var pc: [*]const Instruction = ci.u.l.savedpc.?;

        // A hook is rare enough that one flag test per instruction is the
        // whole cost of supporting it (Lua's `trap`)
        if (L.hookmask.any() and pc == cl.proto.code.ptr and !cl.proto.is_vararg) {
            // The call hook for a vararg function waits for VARARGPREP
            ci.u.l.savedpc = pc;
            try debug.hookCall(L, ci);
            base = ci.func + 1;
            trap = L.hookmask.any();
        }

        // Dispatch: every arm ends by continuing the labeled switch with
        // the next opcode (computed goto), see `fetch`
        var inst: Instruction = undefined;
        var a: u32 = undefined;
        vm: switch (try fetch(L, ci, &base, &pc, &inst, &a, &trap)) {
            .MOVE => {
                base[a] = base[opcode.getB(inst)];
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADI => {
                base[a] = TValue.integer(opcode.getsBx(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADF => {
                base[a] = TValue.float(@floatFromInt(opcode.getsBx(inst)));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADK => {
                base[a] = k[opcode.getBx(inst)];
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADKX => {
                base[a] = k[opcode.getAx(pc[0])];
                pc += 1;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADFALSE => {
                base[a] = TValue.boolean(false);
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LFALSESKIP => {
                base[a] = TValue.boolean(false);
                pc += 1; // skip next instruction
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADTRUE => {
                base[a] = TValue.boolean(true);
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LOADNIL => {
                var n: u32 = opcode.getB(inst);
                var i: u32 = 0;
                while (true) : (i += 1) {
                    base[a + i] = TValue.nil();
                    if (n == 0) break;
                    n -= 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            .GETUPVAL => {
                base[a] = cl.upvals[opcode.getB(inst)].?.getValue().*;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SETUPVAL => {
                const uv = cl.upvals[opcode.getB(inst)].?;
                uv.setValue(&base[a]);
                L.l_G.gc.barrier(&uv.header, &base[a]);
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            // Table accesses pass the operand's own slot (a register or an
            // upvalue) rather than a copy, so a failure can be reported as
            // "(global 'x')" or "(local 't')"; the helpers copy what they
            // need before making any call that could move the stack.
            .GETTABUP => {
                const tp = cl.upvals[opcode.getB(inst)].?.getValue();
                const key = k[opcode.getC(inst)];
                var v: TValue = undefined;
                if (tp.asTable()) |tbl| {
                    v = tbl.getShortStr(key.stringValue());
                    if (v.isNil() and tbl.metatable != null) {
                        ci.u.l.savedpc = pc;
                        L.top = ci.top;
                        v = try finishGet(L, tp, &key, true);
                        base = ci.func + 1;
                        trap = L.hookmask.any();
                    }
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    v = try getTable(L, tp, &key);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                base[a] = v;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .GETTABLE => {
                const b: u32 = opcode.getB(inst);
                const key = base[opcode.getC(inst)];
                var v: TValue = undefined;
                if (base[b].asTable()) |tbl| {
                    if (key.isInlineInt() and @as(u64, @bitCast(key.inlineInt() -% 1)) < tbl.alimit) {
                        v = tbl.arr()[@intCast(key.inlineInt() - 1)]; // luaV_fastgeti: within the border hint
                    } else {
                        v = tbl.get(key);
                    }
                    if (v.isNil() and tbl.metatable != null) {
                        ci.u.l.savedpc = pc;
                        L.top = ci.top;
                        v = try finishGet(L, &base[b], &key, true);
                        base = ci.func + 1;
                        trap = L.hookmask.any();
                    }
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    v = try getTable(L, &base[b], &key);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                base[a] = v;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .GETI => {
                const b: u32 = opcode.getB(inst);
                const c: u32 = opcode.getC(inst);
                var v: TValue = undefined;
                if (base[b].asTable()) |tbl| {
                    if (c >= 1 and c - 1 < tbl.alimit) {
                        v = tbl.arr()[c - 1]; // within the border hint
                    } else {
                        v = tbl.getInt(c);
                    }
                    if (v.isNil() and tbl.metatable != null) {
                        ci.u.l.savedpc = pc;
                        L.top = ci.top;
                        v = try finishGet(L, &base[b], &TValue.integer(c), true);
                        base = ci.func + 1;
                        trap = L.hookmask.any();
                    }
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    v = try getTable(L, &base[b], &TValue.integer(c));
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                base[a] = v;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .GETFIELD => {
                const b: u32 = opcode.getB(inst);
                const key = k[opcode.getC(inst)];
                var v: TValue = undefined;
                if (base[b].asTable()) |tbl| {
                    v = tbl.getShortStr(key.stringValue());
                    if (v.isNil() and tbl.metatable != null) {
                        ci.u.l.savedpc = pc;
                        L.top = ci.top;
                        v = try finishGet(L, &base[b], &key, true);
                        base = ci.func + 1;
                        trap = L.hookmask.any();
                    }
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    v = try getTable(L, &base[b], &key);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                base[a] = v;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            // Stores: when the table already holds a non-nil value for
            // the key, the slot is overwritten in place (luaV_fastset);
            // only the value needs a barrier. Everything else goes
            // through `setTable`, which handles `__newindex`, new keys
            // and non-table operands.
            .SETTABUP => {
                const tp = cl.upvals[a].?.getValue();
                const key = k[opcode.getB(inst)];
                const c: u32 = opcode.getC(inst);
                const v = if (opcode.getk(inst)) k[c] else base[c];
                var slot: ?*TValue = null;
                if (tp.asTable()) |tbl| {
                    slot = tbl.findShortStrSlot(key.stringValue());
                    if (slot) |s| {
                        if (!s.isNil()) {
                            s.* = v;
                            L.l_G.gc.barrierBackValue(&tbl.header, &v);
                            continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
                        }
                    }
                }
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                try finishSet(L, tp, &key, &v, slot);
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SETTABLE => {
                const key = base[opcode.getB(inst)];
                const c: u32 = opcode.getC(inst);
                const v = if (opcode.getk(inst)) k[c] else base[c];
                var slot: ?*TValue = null;
                if (base[a].asTable()) |tbl| {
                    if (key.isInlineInt() and @as(u64, @bitCast(key.inlineInt() -% 1)) < tbl.alimit) {
                        slot = &tbl.arr()[@intCast(key.inlineInt() - 1)]; // luaV_fastseti: within the border hint
                    } else {
                        slot = tbl.findSlot(key);
                    }
                    if (slot) |s| {
                        if (!s.isNil()) {
                            s.* = v;
                            L.l_G.gc.barrierBackValue(&tbl.header, &v);
                            continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
                        }
                    }
                }
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                try finishSet(L, &base[a], &key, &v, slot);
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SETI => {
                const c: u32 = opcode.getC(inst);
                const v = if (opcode.getk(inst)) k[c] else base[c];
                var slot: ?*TValue = null;
                if (base[a].asTable()) |tbl| {
                    const ib: u32 = opcode.getB(inst);
                    if (ib >= 1 and ib - 1 < tbl.alimit) {
                        slot = &tbl.arr()[ib - 1]; // within the border hint
                    } else {
                        slot = tbl.findIntSlot(ib);
                    }
                    if (slot) |s| {
                        if (!s.isNil()) {
                            s.* = v;
                            L.l_G.gc.barrierBackValue(&tbl.header, &v);
                            continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
                        }
                    }
                }
                const key = TValue.integer(opcode.getB(inst));
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                try finishSet(L, &base[a], &key, &v, slot);
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SETFIELD => {
                const key = k[opcode.getB(inst)];
                const c: u32 = opcode.getC(inst);
                const v = if (opcode.getk(inst)) k[c] else base[c];
                var slot: ?*TValue = null;
                if (base[a].asTable()) |tbl| {
                    slot = tbl.findShortStrSlot(key.stringValue());
                    if (slot) |s| {
                        if (!s.isNil()) {
                            s.* = v;
                            L.l_G.gc.barrierBackValue(&tbl.header, &v);
                            continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
                        }
                    }
                }
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                try finishSet(L, &base[a], &key, &v, slot);
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .NEWTABLE => {
                var b: u32 = opcode.getB(inst); // log2(hash size) + 1
                var c: u32 = opcode.getC(inst); // array size
                if (b > 0) b = @as(u32, 1) << @intCast(b - 1);
                if (opcode.getk(inst)) c += @as(u32, opcode.getAx(pc[0])) * (opcode.MAXARG_C + 1);
                pc += 1; // skip the extra argument
                ci.u.l.savedpc = pc;
                L.top = base + a + 1; // correct top in case of emergency GC
                const t = try L.l_G.gc.newTable(c, b);
                base = ci.func + 1;
                trap = L.hookmask.any();
                base[a] = TValue.table(t);
                try L.l_G.gc.checkGC();
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SELF => {
                const b: u32 = opcode.getB(inst);
                const c: u32 = opcode.getC(inst);
                const key = if (opcode.getk(inst)) k[c] else base[c]; // always a short string
                base[a + 1] = base[b];
                var v: TValue = undefined;
                if (base[b].asTable()) |tbl| {
                    v = tbl.getShortStr(key.stringValue());
                    if (v.isNil() and tbl.metatable != null) {
                        ci.u.l.savedpc = pc;
                        L.top = ci.top;
                        v = try finishGet(L, &base[b], &key, true);
                        base = ci.func + 1;
                        trap = L.hookmask.any();
                    }
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    v = try getTable(L, &base[b], &key);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                base[a] = v;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            // Arithmetic with an immediate or constant operand. On success
            // the following MMBIN* instruction is skipped.
            .ADDI => {
                const v1 = base[opcode.getB(inst)];
                const imm: i64 = opcode.getsC(inst);
                if (v1.isInlineInt()) {
                    base[a] = v1.addInlineImm(imm) orelse try intResult(L, v1.inlineInt() +% imm);
                    pc += 1;
                } else if (v1.isFloat()) {
                    base[a] = TValue.float(v1.floatValue() + @as(f64, @floatFromInt(imm)));
                    pc += 1;
                } else if (v1.isBoxedInt()) {
                    base[a] = try intResult(L, v1.integerValue() +% imm);
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .ADDK, .SUBK, .MULK => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = k[opcode.getC(inst)];
                const op = opc;
                if (TValue.bothInlineInts(v1, v2)) {
                    // Add and subtract work on the encoded words; the range
                    // check is the prefix of the result
                    base[a] = (switch (op) {
                        .ADDK => v1.addInline(v2),
                        .SUBK => v1.subInline(v2),
                        else => TValue.integerChecked(v1.inlineInt() *% v2.inlineInt()),
                    }) orelse try intResult(L, switch (op) {
                        .ADDK => v1.inlineInt() +% v2.inlineInt(),
                        .SUBK => v1.inlineInt() -% v2.inlineInt(),
                        else => v1.inlineInt() *% v2.inlineInt(),
                    });
                    pc += 1;
                } else if (TValue.bothFloats(v1, v2)) {
                    const x = v1.floatValue();
                    const y = v2.floatValue();
                    base[a] = TValue.float(switch (op) {
                        .ADDK => x + y,
                        .SUBK => x - y,
                        else => x * y,
                    });
                    pc += 1;
                } else if (v1.isNumber() and v2.isNumber()) {
                    if (v1.isInteger() and v2.isInteger()) {
                        // a boxed integer operand: integer arithmetic all the same
                        const x = v1.integerValue();
                        const y = v2.integerValue();
                        base[a] = try intResult(L, switch (op) {
                            .ADDK => x +% y,
                            .SUBK => x -% y,
                            else => x *% y,
                        });
                    } else {
                        const x = v1.asFloat().?;
                        const y = v2.asFloat().?;
                        base[a] = TValue.float(switch (op) {
                            .ADDK => x + y,
                            .SUBK => x - y,
                            else => x * y,
                        });
                    }
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .POWK, .DIVK => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = k[opcode.getC(inst)];
                if (v1.isNumber() and v2.isNumber()) {
                    const x = v1.asFloat().?;
                    const y = v2.asFloat().?;
                    base[a] = TValue.float(if (opc == .DIVK) x / y else floatArith(.pow, x, y));
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .MODK, .IDIVK => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = k[opcode.getC(inst)];
                const op: ArithOp = if (opc == .MODK) .mod else .idiv;
                if (TValue.bothInlineInts(v1, v2)) {
                    const x = v1.inlineInt();
                    const y = v2.inlineInt();
                    if (y != 0 and y != -1) {
                        // No error, no overflow, and the result fits inline
                        base[a] = TValue.integer(if (op == .mod) @mod(x, y) else @divFloor(x, y));
                        pc += 1;
                        continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
                    }
                }
                if (v1.isInteger() and v2.isInteger()) {
                    ci.u.l.savedpc = pc;
                    base[a] = try intResult(L, try intArith(L, op, v1.integerValue(), v2.integerValue()));
                    pc += 1;
                } else if (v1.isNumber() and v2.isNumber()) {
                    base[a] = TValue.float(floatArith(op, v1.asFloat().?, v2.asFloat().?));
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .BANDK, .BORK, .BXORK => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = k[opcode.getC(inst)];
                if (toIntegerNs(&v1)) |x1| {
                    if (toIntegerNs(&v2)) |x2| {
                        base[a] = try intResult(L, switch (opc) {
                            .BANDK => x1 & x2,
                            .BORK => x1 | x2,
                            else => x1 ^ x2,
                        });
                        pc += 1;
                    }
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SHRI => {
                const v1 = base[opcode.getB(inst)];
                const ic: i64 = opcode.getsC(inst);
                if (toIntegerNs(&v1)) |x1| {
                    base[a] = try intResult(L, shiftLeft(x1, 0 -% ic));
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .SHLI => {
                const v1 = base[opcode.getB(inst)];
                const ic: i64 = opcode.getsC(inst);
                if (toIntegerNs(&v1)) |x1| {
                    base[a] = try intResult(L, shiftLeft(ic, x1));
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            // Integer and float fast paths first (op_arith in lvm.c); the
            // generic helper only for mixed operands. Only `%` and `//`
            // can fail (division by zero), so only they save `pc`.
            inline .ADD, .SUB, .MUL => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = base[opcode.getC(inst)];
                const op = opc;
                if (TValue.bothInlineInts(v1, v2)) {
                    // Add and subtract work on the encoded words; the range
                    // check is the prefix of the result
                    base[a] = (switch (op) {
                        .ADD => v1.addInline(v2),
                        .SUB => v1.subInline(v2),
                        else => TValue.integerChecked(v1.inlineInt() *% v2.inlineInt()),
                    }) orelse try intResult(L, switch (op) {
                        .ADD => v1.inlineInt() +% v2.inlineInt(),
                        .SUB => v1.inlineInt() -% v2.inlineInt(),
                        else => v1.inlineInt() *% v2.inlineInt(),
                    });
                    pc += 1;
                } else if (TValue.bothFloats(v1, v2)) {
                    const x = v1.floatValue();
                    const y = v2.floatValue();
                    base[a] = TValue.float(switch (op) {
                        .ADD => x + y,
                        .SUB => x - y,
                        else => x * y,
                    });
                    pc += 1;
                } else if (v1.isNumber() and v2.isNumber()) {
                    if (v1.isInteger() and v2.isInteger()) {
                        // a boxed integer operand: integer arithmetic all the same
                        const x = v1.integerValue();
                        const y = v2.integerValue();
                        base[a] = try intResult(L, switch (op) {
                            .ADD => x +% y,
                            .SUB => x -% y,
                            else => x *% y,
                        });
                    } else {
                        const x = v1.asFloat().?;
                        const y = v2.asFloat().?;
                        base[a] = TValue.float(switch (op) {
                            .ADD => x + y,
                            .SUB => x - y,
                            else => x * y,
                        });
                    }
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .POW, .DIV => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = base[opcode.getC(inst)];
                if (TValue.bothFloats(v1, v2)) {
                    const x = v1.floatValue();
                    const y = v2.floatValue();
                    base[a] = TValue.float(if (opc == .DIV) x / y else floatArith(.pow, x, y));
                    pc += 1;
                } else if (v1.isNumber() and v2.isNumber()) {
                    const x = v1.asFloat().?;
                    const y = v2.asFloat().?;
                    base[a] = TValue.float(if (opc == .DIV) x / y else floatArith(.pow, x, y));
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .MOD, .IDIV => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = base[opcode.getC(inst)];
                const op: ArithOp = if (opc == .MOD) .mod else .idiv;
                if (TValue.bothInlineInts(v1, v2)) {
                    const x = v1.inlineInt();
                    const y = v2.inlineInt();
                    if (y != 0 and y != -1) {
                        // No error, no overflow, and the result fits inline
                        base[a] = TValue.integer(if (op == .mod) @mod(x, y) else @divFloor(x, y));
                        pc += 1;
                        continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
                    }
                }
                if (v1.isInteger() and v2.isInteger()) {
                    ci.u.l.savedpc = pc;
                    base[a] = try intResult(L, try intArith(L, op, v1.integerValue(), v2.integerValue()));
                    pc += 1;
                } else if (v1.isNumber() and v2.isNumber()) {
                    base[a] = TValue.float(floatArith(op, v1.asFloat().?, v2.asFloat().?));
                    pc += 1;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .BAND, .BOR, .BXOR, .SHL, .SHR => |opc| {
                const v1 = base[opcode.getB(inst)];
                const v2 = base[opcode.getC(inst)];
                if (toIntegerNs(&v1)) |x1| {
                    if (toIntegerNs(&v2)) |x2| {
                        base[a] = try intResult(L, switch (opc) {
                            .BAND => x1 & x2,
                            .BOR => x1 | x2,
                            .BXOR => x1 ^ x2,
                            .SHL => shiftLeft(x1, x2),
                            else => shiftLeft(x1, 0 -% x2),
                        });
                        pc += 1;
                    }
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            // Metamethod fall-backs for the arithmetic instruction just before
            .MMBIN => {
                const prev = (pc - 2)[0]; // the arithmetic instruction
                const result: u32 = opcode.getA(prev);
                const event: value.TMS = @enumFromInt(opcode.getC(inst));
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                const r = try tryBinTM(L, &base[a], &base[opcode.getB(inst)], event);
                base = ci.func + 1;
                trap = L.hookmask.any();
                base[result] = r;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .MMBINI => {
                const prev = (pc - 2)[0];
                const result: u32 = opcode.getA(prev);
                const imm = TValue.integer(opcode.getsB(inst));
                const flip = opcode.getk(inst);
                const event: value.TMS = @enumFromInt(opcode.getC(inst));
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                const r = if (flip) try tryBinTM(L, &imm, &base[a], event) else try tryBinTM(L, &base[a], &imm, event);
                base = ci.func + 1;
                trap = L.hookmask.any();
                base[result] = r;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .MMBINK => {
                const prev = (pc - 2)[0];
                const result: u32 = opcode.getA(prev);
                const kb = &k[opcode.getB(inst)];
                const flip = opcode.getk(inst);
                const event: value.TMS = @enumFromInt(opcode.getC(inst));
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                const r = if (flip) try tryBinTM(L, kb, &base[a], event) else try tryBinTM(L, &base[a], kb, event);
                base = ci.func + 1;
                trap = L.hookmask.any();
                base[result] = r;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            .UNM => {
                const rb = base[opcode.getB(inst)];
                if (rb.isInteger()) {
                    base[a] = try intResult(L, 0 -% rb.integerValue());
                } else if (rb.isFloat()) {
                    base[a] = TValue.float(-rb.floatValue());
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    const r = try tryBinTM(L, &base[opcode.getB(inst)], &base[opcode.getB(inst)], .__unm);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                    base[a] = r;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .BNOT => {
                const rb = base[opcode.getB(inst)];
                if (toIntegerNs(&rb)) |i| {
                    base[a] = try intResult(L, ~i);
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    const r = try tryBinTM(L, &base[opcode.getB(inst)], &base[opcode.getB(inst)], .__bnot);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                    base[a] = r;
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .NOT => {
                base[a] = TValue.boolean(base[opcode.getB(inst)].isFalsy());
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LEN => {
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                const r = try lenOp(L, &base[opcode.getB(inst)]);
                base = ci.func + 1;
                trap = L.hookmask.any();
                base[a] = r;
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .CONCAT => {
                const n: u32 = opcode.getB(inst); // number of elements to concatenate
                L.top = base + a + n; // mark the end of the concat operands
                ci.u.l.savedpc = pc;
                try concatenate(L, n);
                base = ci.func + 1;
                trap = L.hookmask.any();
                try L.l_G.gc.checkGC();
                base = ci.func + 1;
                trap = L.hookmask.any();
                L.top = ci.top; // restore top
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            .CLOSE => {
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                try closeAll(L, base + a, null);
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TBC => {
                ci.u.l.savedpc = pc;
                try newTbcUpval(L, base + a);
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .JMP => {
                pc = jumpPc(pc, opcode.getsJ(inst));
                trap = L.hookmask.any(); // a hook installed asynchronously (Ctrl-C) takes effect at a backward jump, as in the reference
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            // Comparisons: skip the following jump when the result differs from k
            // Only tables and full userdata can have `__eq`; everything
            // else is raw equality, which cannot fail
            .EQ => {
                const ra = base[a];
                const rb = base[opcode.getB(inst)];
                var cond: bool = undefined;
                if (ra.isInlineInt() and rb.isInlineInt()) {
                    cond = ra.bits == rb.bits;
                } else if (TValue.bothFloats(ra, rb)) {
                    cond = ra.floatValue() == rb.floatValue();
                } else if ((ra.tag() == .table or ra.tag() == .userdata) and ra.tag() == rb.tag()) {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    cond = try equalObj(L, ra, rb);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                } else {
                    cond = rawEqual(ra, rb);
                }
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LT => {
                const ra = base[a];
                const rb = base[opcode.getB(inst)];
                var cond: bool = undefined;
                if (ra.isInlineInt() and rb.isInlineInt()) {
                    cond = ra.inlineInt() < rb.inlineInt();
                } else if (TValue.bothFloats(ra, rb)) {
                    cond = ra.floatValue() < rb.floatValue();
                } else if (ra.isNumber() and rb.isNumber()) {
                    cond = ltNum(ra.numberValue(), rb.numberValue());
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    cond = try lessThan(L, ra, rb);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .LE => {
                const ra = base[a];
                const rb = base[opcode.getB(inst)];
                var cond: bool = undefined;
                if (ra.isInlineInt() and rb.isInlineInt()) {
                    cond = ra.inlineInt() <= rb.inlineInt();
                } else if (TValue.bothFloats(ra, rb)) {
                    cond = ra.floatValue() <= rb.floatValue();
                } else if (ra.isNumber() and rb.isNumber()) {
                    cond = leNum(ra.numberValue(), rb.numberValue());
                } else {
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    cond = try lessEqual(L, ra, rb);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .EQK => {
                const cond = rawEqual(base[a], k[opcode.getB(inst)]);
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .EQI => {
                const ra = base[a];
                const im: i64 = opcode.getsB(inst);
                const cond = if (ra.isInteger()) ra.integerValue() == im else if (ra.isFloat()) ra.floatValue() == @as(f64, @floatFromInt(im)) else false;
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            inline .LTI, .LEI, .GTI, .GEI => |opc| {
                const op = opc;
                const ra = base[a];
                const im: i64 = opcode.getsB(inst);
                var cond: bool = undefined;
                if (ra.isInteger()) {
                    const i = ra.integerValue();
                    cond = switch (op) {
                        .LTI => i < im,
                        .LEI => i <= im,
                        .GTI => i > im,
                        else => i >= im,
                    };
                } else if (ra.isFloat()) {
                    const f = ra.floatValue();
                    const fim: f64 = @floatFromInt(im);
                    cond = switch (op) {
                        .LTI => f < fim,
                        .LEI => f <= fim,
                        .GTI => f > fim,
                        else => f >= fim,
                    };
                } else {
                    // Metamethod with the immediate as a number (float if C says so)
                    const isf = opcode.getC(inst) != 0;
                    const imv = if (isf) TValue.float(@floatFromInt(im)) else TValue.integer(im);
                    ci.u.l.savedpc = pc;
                    L.top = ci.top;
                    cond = switch (op) {
                        .LTI => try callOrderTM(L, ra, imv, .__lt),
                        .LEI => try callOrderTM(L, ra, imv, .__le),
                        .GTI => try callOrderTM(L, imv, ra, .__lt),
                        else => try callOrderTM(L, imv, ra, .__le),
                    };
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TEST => {
                const cond = !base[a].isFalsy();
                pc = condJump(pc, cond, opcode.getk(inst));
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TESTSET => {
                const rb = base[opcode.getB(inst)];
                if (rb.isFalsy() == opcode.getk(inst)) {
                    pc += 1;
                } else {
                    base[a] = rb;
                    pc = jumpPc(pc, @as(i64, opcode.getsJ(pc[0])) + 1); // do the next jump
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            .CALL => {
                const b: u32 = opcode.getB(inst);
                const nresults: i32 = @as(i32, opcode.getC(inst)) - 1;
                if (b != 0) L.top = base + a + b; // fixed number of arguments (else top is already set)
                ci.u.l.savedpc = pc;
                const fv = base[a];
                if (fv.asClosure()) |callee| {
                    ci = try precallLua(L, base + a, nresults, callee); // Lua function: run it in this loop
                    continue :startfunc;
                }
                if (try precall(L, base + a, nresults)) |newci| {
                    ci = newci; // a `__call` chain ending in a Lua function
                    continue :startfunc;
                }
                base = ci.func + 1;
                trap = L.hookmask.any(); // native function done: results already in place
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TAILCALL => {
                var b: u32 = opcode.getB(inst);
                const nparams1: u32 = opcode.getC(inst);
                // Delta is virtual 'func' - real 'func' (vararg functions)
                const delta: u32 = if (nparams1 != 0) ci.u.l.nextraargs + nparams1 else 0;
                if (b != 0) {
                    L.top = base + a + b;
                } else {
                    b = @intCast((@intFromPtr(L.top) - @intFromPtr(base + a)) / @sizeOf(TValue));
                }
                ci.u.l.savedpc = pc;
                if (opcode.getk(inst)) {
                    try closeUpvalues(L, base); // close upvalues from the current call
                    assert(L.tbclist.items.len == 0 or @intFromPtr(L.stack + L.tbclist.items[L.tbclist.items.len - 1]) < @intFromPtr(base));
                }
                if (try preTailCall(L, ci, base + a, b, delta)) |n| {
                    // Native function: finish the caller's frame with its results
                    ci.func -= delta;
                    try posCall(L, ci, n);
                    if (ci.callstatus.isFresh) return;
                    ci = L.ci;
                    continue :startfunc;
                }
                continue :startfunc; // Lua function: frame replaced
            },
            .RETURN => {
                var n: u32 = opcode.getB(inst);
                const nparams1: u32 = opcode.getC(inst);
                if (n != 0) {
                    n -= 1;
                } else {
                    n = @intCast((@intFromPtr(L.top) - @intFromPtr(base + a)) / @sizeOf(TValue));
                }
                ci.u.l.savedpc = pc;
                if (opcode.getk(inst)) {
                    // Close upvalues and to-be-closed variables of this frame
                    L.top = base + a + n; // results are what must be preserved
                    ci.u.l.nres = n; // a yielding __close resumes this instruction
                    try closeAll(L, base, null);
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                if (nparams1 != 0) {
                    ci.func -= ci.u.l.nextraargs + nparams1; // vararg function: restore func
                }
                L.top = base + a + n;
                try posCall(L, ci, n);
                if (ci.callstatus.isFresh) return;
                ci = L.ci;
                continue :startfunc;
            },
            .RETURN0 => {
                if (L.hookmask.any()) { // the general path runs the return hook
                    L.top = base + a;
                    ci.u.l.savedpc = pc;
                    try posCall(L, ci, 0);
                    if (ci.callstatus.isFresh) return;
                    ci = L.ci;
                    continue :startfunc;
                }
                const nres = ci.nresults;
                L.ci = ci.previous orelse &L.base_ci;
                L.top = base - 1;
                var i: i32 = 0;
                while (i < nres) : (i += 1) {
                    L.top[0] = TValue.nil();
                    L.top += 1;
                }
                if (ci.callstatus.isFresh) return;
                ci = L.ci;
                continue :startfunc;
            },
            .RETURN1 => {
                if (L.hookmask.any()) {
                    L.top = base + a + 1;
                    ci.u.l.savedpc = pc;
                    try posCall(L, ci, 1);
                    if (ci.callstatus.isFresh) return;
                    ci = L.ci;
                    continue :startfunc;
                }
                var nres = ci.nresults;
                L.ci = ci.previous orelse &L.base_ci;
                if (nres == 0) {
                    L.top = base - 1;
                } else {
                    (base - 1)[0] = base[a];
                    L.top = base;
                    while (nres > 1) : (nres -= 1) {
                        L.top[0] = TValue.nil();
                        L.top += 1;
                    }
                }
                if (ci.callstatus.isFresh) return;
                ci = L.ci;
                continue :startfunc;
            },

            .FORLOOP => {
                const ra = base + a;
                if (ra[2].isInlineInt()) {
                    // Integer loop with every slot inline: FORPREP boxes the
                    // step whenever the initial value or the count does not
                    // fit inline, so this one test covers the three slots.
                    // The limit slot holds the remaining count
                    const count = ra[1].inlineInt();
                    if (count > 0) {
                        ra[1] = TValue.integer(count - 1);
                        if (ra[0].addInline(ra[2])) |idx| {
                            ra[0] = idx;
                        } else {
                            // The index leaves the inline range: box it, and
                            // box the step so the next iteration takes the
                            // general path below
                            const step = ra[2].inlineInt();
                            ra[0] = try intResult(L, ra[0].inlineInt() +% step);
                            ra[2] = TValue.boxedInteger(try L.l_G.gc.newBoxedInt(step));
                        }
                        ra[3] = ra[0];
                        pc = pc - opcode.getBx(inst); // jump back
                    }
                } else if (ra[2].isInteger()) {
                    // A boxed integer in the loop state: a huge count (kept
                    // in its box and decremented in place, so the loop does
                    // not allocate) or an index beyond 48 bits
                    const count: u64 = @bitCast(ra[1].integerValue());
                    if (count > 0) {
                        const idx = ra[0].integerValue() +% ra[2].integerValue();
                        if (ra[1].isInlineInt()) {
                            ra[1] = TValue.integer(@bitCast(count - 1));
                        } else {
                            ra[1].boxedIntObject().v = @bitCast(count - 1);
                        }
                        ra[0] = try intResult(L, idx);
                        ra[3] = ra[0];
                        pc = pc - opcode.getBx(inst); // jump back
                    }
                } else if (floatForLoop(ra)) {
                    pc = pc - opcode.getBx(inst);
                }
                trap = L.hookmask.any(); // a hook installed asynchronously (Ctrl-C) takes effect at a backward jump, as in the reference
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .FORPREP => {
                ci.u.l.savedpc = pc;
                if (try forPrep(L, base + a)) {
                    pc = pc + opcode.getBx(inst) + 1; // skip the loop
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TFORPREP => {
                ci.u.l.savedpc = pc;
                try newTbcUpval(L, base + a + 3); // create to-be-closed upvalue (if needed)
                pc = pc + opcode.getBx(inst); // go to the TFORCALL
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TFORCALL => {
                // 'ra' has the iterator function, 'ra + 1' the state, 'ra + 2'
                // the control variable, 'ra + 3' the closing variable; the call
                // goes to 'ra + 4' so the loop variables get the results
                const ra = base + a;
                ra[4] = ra[0];
                ra[5] = ra[1];
                ra[6] = ra[2];
                L.top = ra + 4 + 3;
                ci.u.l.savedpc = pc;
                try call(L, ra + 4, @intCast(opcode.getC(inst)));
                base = ci.func + 1;
                trap = L.hookmask.any();
                L.top = ci.top;
                // The next instruction is the TFORLOOP
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .TFORLOOP => {
                const ra = base + a;
                if (!ra[4].isNil()) { // continue loop?
                    ra[2] = ra[4]; // save control variable
                    pc = pc - opcode.getBx(inst); // jump back
                }
                trap = L.hookmask.any(); // a hook installed asynchronously (Ctrl-C) takes effect at a backward jump, as in the reference
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            .SETLIST => {
                // R[A][C+i] := R[A+i] for 1 <= i <= B; B == 0 means "up to top"
                const b: u32 = opcode.getB(inst);
                const n: u32 = if (b != 0) b else @intCast((@intFromPtr(L.top) - @intFromPtr(base + a + 1)) / @sizeOf(TValue));
                var last: u32 = opcode.getC(inst);
                if (opcode.getk(inst)) {
                    last += @as(u32, opcode.getAx(pc[0])) * (opcode.MAXARG_C + 1);
                    pc += 1;
                }
                const tbl = base[a].asTable() orelse return VMError.TypeError;
                // Grow the array part once to hold every element, then
                // store straight into it (luaH_resizearray + setobj2t)
                if (last + n > tbl.asize) {
                    ci.u.l.savedpc = pc;
                    try tbl.resize(last + n, tbl.hashSize());
                }
                var i: u32 = 1;
                while (i <= n) : (i += 1) {
                    tbl.arr()[last + i - 1] = base[a + i];
                    L.l_G.gc.barrierBackValue(&tbl.header, &base[a + i]);
                }
                if (b == 0) L.top = ci.top; // correct top after a multi-value list
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },

            .CLOSURE => {
                const p = cl.proto.protos[opcode.getBx(inst)];
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                const ncl = try closure_module.createClosure(L, p, cl, base);
                base = ci.func + 1;
                trap = L.hookmask.any();
                base[a] = TValue.closure(ncl);
                try L.l_G.gc.checkGC();
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .VARARG => {
                const n: i32 = @as(i32, opcode.getC(inst)) - 1; // required results
                ci.u.l.savedpc = pc;
                L.top = ci.top;
                const off = (@intFromPtr(base + a) - @intFromPtr(L.stack)) / @sizeOf(TValue);
                try getVarargs(L, ci, off, n);
                base = ci.func + 1;
                trap = L.hookmask.any();
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .VARARGPREP => {
                ci.u.l.savedpc = pc;
                try adjustVarargs(L, a, ci, cl.proto);
                base = ci.func + 1;
                trap = L.hookmask.any();
                L.top = ci.top;
                if (L.hookmask.any()) {
                    try debug.hookCall(L, ci);
                    L.oldpc = 1; // next opcode will be seen as a "new" line
                    base = ci.func + 1;
                    trap = L.hookmask.any();
                }
                continue :vm try fetch(L, ci, &base, &pc, &inst, &a, &trap);
            },
            .EXTRAARG => unreachable, // consumed by the previous instruction
        }
    }
}

/// Conditional skip: Lua skips the following jump when `cond != k`, and
/// otherwise executes that jump immediately (docondjump)
inline fn condJump(pc: [*]const Instruction, cond: bool, k: bool) [*]const Instruction {
    if (cond != k) return pc + 1;
    return jumpPc(pc, @as(i64, opcode.getsJ(pc[0])) + 1);
}

// ---------------------------------------------------------------------------
// Tests: run Lua programs through the whole pipeline
// ---------------------------------------------------------------------------

const api = @import("api.zig");
const baselib = @import("lib/baselib.zig");

/// Run `src` as a chunk and return its first result (or nil)
fn runLua(L: *LuaState, src: []const u8) !TValue {
    switch (api.load(L, src, "=test")) {
        .ok => {},
        .errmem => return error.OutOfMemory,
        else => {
            if (api.toString(L, -1)) |msg| std.debug.print("{s}\n", .{msg});
            api.pop(L, 1);
            return error.SyntaxError;
        },
    }
    // Protected, so the state stays usable after a Lua error (the message
    // is left on the stack for the caller)
    if (api.pcall(L, 0, 1, 0) != .ok) return error.LuaError;
    const v = (L.top - 1)[0];
    api.pop(L, 1);
    return v;
}

fn expectInt(L: *LuaState, src: []const u8, expected: i64) !void {
    const v = try runLua(L, src);
    if (!v.isInteger() or v.integerValue() != expected) {
        std.debug.print("\n{s}\n  => {s} (expected integer {d})\n", .{ src, v.tag().name(), expected });
        if (v.isNumber()) std.debug.print("  got number {}\n", .{v.numberValue()});
        return error.TestUnexpectedResult;
    }
}

fn expectStr(L: *LuaState, src: []const u8, expected: []const u8) !void {
    const v = try runLua(L, src);
    const s = v.asString() orelse {
        std.debug.print("\n{s}\n  => {s} (expected string)\n", .{ src, v.tag().name() });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, s.slice());
}

fn expectBool(L: *LuaState, src: []const u8, expected: bool) !void {
    const v = try runLua(L, src);
    if (!v.isBoolean() or v.booleanValue() != expected) {
        std.debug.print("\n{s}\n  => {s} (expected boolean {})\n", .{ src, v.tag().name(), expected });
        return error.TestUnexpectedResult;
    }
}

fn newState() !*LuaState {
    const L = try LuaState.init(std.testing.allocator, null);
    errdefer L.deinit();
    try baselib.openBase(L);
    return L;
}

test "vm: arithmetic and numbers" {
    const L = try newState();
    defer L.deinit();
    try expectInt(L, "return 1 + 2 * 3", 7);
    try expectInt(L, "local a, b = 10, 3 return a // b + a % b", 4);
    try expectInt(L, "local a = -7 return a // 2", -4);
    try expectInt(L, "local a = -7 return a % 3", 2);
    try expectInt(L, "local m = math_max or 9223372036854775807 return m + 1", math.minInt(i64)); // wraps
    try expectInt(L, "local x = 1 return x << 3 | 1", 9);
    try expectInt(L, "local x = 9007199254740993 return x == 2^53 and 1 or 0", 0); // exact int/float comparison
    try expectBool(L, "local x = 3.0 return x == 3", true);
    try expectBool(L, "return 1 < 2.5 and 2.5 < 3", true);
    try expectStr(L, "return 1 .. 2.0 .. 'x'", "12.0x");
    try expectStr(L, "return tostring(1e100)", "1e+100");
    try expectStr(L, "return tostring(0.1)", "0.1");
    try expectStr(L, "return tostring(1/0)", "inf");
    try expectStr(L, "return tostring(10 // 4.0)", "2.0");
}

test "vm: tables, strings and length" {
    const L = try newState();
    defer L.deinit();
    try expectInt(L, "local t = {10, 20, 30, n = 'x'} return #t + t[2]", 23);
    try expectStr(L, "local t = {} t.a = 'v' t['b'] = t.a .. '!' return t.b", "v!");
    try expectInt(L, "local t = {} for i = 1, 100 do t[i] = i end return #t", 100);
    try expectInt(L, "local t = {1, 2, 3} t[2] = nil t[2] = 5 return t[2]", 5);
    try expectInt(L, "local t = {[1.0] = 7} return t[1]", 7);
    try expectInt(L, "local n = 0 for k, v in pairs({a = 1, b = 2, 3}) do n = n + v end return n", 6);
    try expectInt(L, "local n = 0 for i, v in ipairs({5, 6, 7}) do n = n + i * v end return n", 38);
    try expectInt(L, "return #'hello'", 5);
    try expectInt(L, "return select('#', 1, 2, 3)", 3);
}

test "vm: control flow and functions" {
    const L = try newState();
    defer L.deinit();
    try expectInt(L, "local s = 0 for i = 1, 10 do s = s + i end return s", 55);
    try expectInt(L, "local s = 0 for i = 10, 1, -3 do s = s + i end return s", 22);
    try expectInt(L, "local n = 0 for i = 1.0, 2.0, 0.5 do n = n + 1 end return n", 3);
    try expectInt(L, "local i = 0 while i < 5 do i = i + 1 end return i", 5);
    try expectInt(L, "local i = 0 repeat i = i + 1 local j = i until j >= 3 return i", 3);
    try expectInt(L, "local x = 5 if x > 3 then return 1 elseif x > 1 then return 2 else return 3 end", 1);
    try expectInt(L, "local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end return fact(10)", 3628800);
    try expectInt(L, "local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end return fib(15)", 610);
    try expectInt(L, "local function f(...) return select('#', ...), ... end local a, b, c = f(7, 8) return a * 100 + b * 10 + c", 278);
    try expectInt(L, "local function f(a, b, ...) local t = {...} return a + b + #t end return f(1, 2, 3, 4, 5)", 6);
    try expectInt(L, "local function tail(n, acc) if n == 0 then return acc end return tail(n - 1, acc + n) end return tail(10000, 0)", 50005000);
    try expectInt(L, "local i = 1 ::top:: if i < 10 then i = i * 2 goto top end return i", 16);
    try expectInt(L, "local n = 0 for i = 1, 10 do if i % 2 == 0 then goto continue end n = n + i ::continue:: end return n", 25);
    try expectInt(L, "local a, b = (function() return 1, 2 end)() return a + b", 3);
    try expectInt(L, "local t = {(function() return 1, 2, 3 end)()} return #t", 3);
    try expectInt(L, "local t = {((function() return 1, 2, 3 end)())} return #t", 1);
}

test "vm: closures and upvalues" {
    const L = try newState();
    defer L.deinit();
    try expectInt(L,
        \\local function counter()
        \\  local n = 0
        \\  return function() n = n + 1 return n end
        \\end
        \\local c1, c2 = counter(), counter()
        \\c1() c1() c2()
        \\return c1() * 10 + c2()
    , 32);
    try expectInt(L,
        \\local fns = {}
        \\for i = 1, 3 do fns[i] = function() return i end end
        \\return fns[1]() + fns[2]() * 10 + fns[3]() * 100
    , 321);
    try expectInt(L,
        \\local x = 1
        \\local function get() return x end
        \\local function set(v) x = v end
        \\set(42)
        \\return get()
    , 42);
}

test "vm: metamethods" {
    const L = try newState();
    defer L.deinit();
    try expectInt(L,
        \\local V = {}
        \\V.__index = V
        \\V.__add = function(a, b) return setmetatable({x = a.x + b.x}, V) end
        \\V.__eq = function(a, b) return a.x == b.x end
        \\V.__lt = function(a, b) return a.x < b.x end
        \\V.__len = function(a) return a.x end
        \\V.__call = function(self, k) return self.x * k end
        \\V.__concat = function(a, b) return 'cat' end
        \\function V.new(x) return setmetatable({x = x}, V) end
        \\function V:double() return self.x * 2 end
        \\local a, b = V.new(2), V.new(3)
        \\local c = a + b
        \\local r = c.x
        \\if c == V.new(5) then r = r + 100 end
        \\if a < b then r = r + 1000 end
        \\r = r + #c + c(2) + a:double()
        \\if (a .. b) == 'cat' then r = r + 10000 end
        \\return r
    , 11124); // 5 + 100 + 1000 + #c(5) + c(2)(10) + a:double()(4) + 10000
    try expectInt(L,
        \\local log = {}
        \\local t = setmetatable({}, {
        \\  __index = function(t, k) return k * 2 end,
        \\  __newindex = function(t, k, v) rawset(t, k, v + 1) end,
        \\})
        \\t.a = 1
        \\return t[21] + rawget(t, 'a')
    , 44);
    try expectInt(L,
        \\local base = {greet = function() return 5 end}
        \\local mid = setmetatable({}, {__index = base})
        \\local obj = setmetatable({}, {__index = mid})
        \\return obj.greet()
    , 5);
}

test "vm: runtime errors carry position and message" {
    const L = try newState();
    defer L.deinit();
    const res = runLua(L, "local t = nil\nreturn t.x");
    try std.testing.expectError(error.LuaError, res);
    const msg = api.toString(L, -1).?;
    try std.testing.expectEqualStrings("test:2: attempt to index a nil value (local 't')", msg);
    api.pop(L, 1);
    try std.testing.expectError(error.LuaError, runLua(L, "return 1 + {}"));
    try std.testing.expectEqualStrings("test:1: attempt to perform arithmetic on a table value", api.toString(L, -1).?);
    api.pop(L, 1);
    try std.testing.expectError(error.LuaError, runLua(L, "return 1 // 0"));
    api.pop(L, 1);
    try std.testing.expectError(error.LuaError, runLua(L, "local function f() return f() + 1 end return f()"));
    api.pop(L, 1);
}

test "vm: to-be-closed variables via generic for" {
    const L = try newState();
    defer L.deinit();
    // The 4th slot of a generic `for` is to-be-closed: a closable value gets __close on exit
    try expectInt(L,
        \\local closed = 0
        \\local function iter()
        \\  local closer = setmetatable({}, {__close = function() closed = closed + 1 end})
        \\  local i = 0
        \\  return function() i = i + 1 if i <= 2 then return i end end, nil, nil, closer
        \\end
        \\local n = 0
        \\for v in iter() do n = n + v end
        \\for v in iter() do break end
        \\return n * 10 + closed
    , 32);
}
