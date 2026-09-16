// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Core API Implementation
//!
//! This module implements the core Lua C API, providing functions for
//! stack manipulation, type checking, value conversion, table access,
//! function calling, and error handling.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;

const value = @import("value.zig");
const state = @import("state.zig");
const stack = @import("stack.zig");
const table = @import("table.zig");
const vm = @import("vm.zig");
const debug = @import("debug.zig");
const syserr = @import("utils/syserr.zig");
const coroutine_module = @import("coroutine.zig");
const dump_module = @import("dump.zig");
const undump_module = @import("undump.zig");
const opcode = @import("opcode.zig");
const proto = @import("proto.zig");
const string_module = @import("string.zig");
const gc_module = @import("gc.zig");
const config = @import("config.zig");
const lex = @import("lex.zig");
const parser = @import("parser.zig");
const codegen = @import("codegen.zig");
const closure_module = @import("closure.zig");
const stdio = @import("utils/stdio.zig");

/// API error types
pub const APIError = error{
    InvalidIndex,
    TypeError,
    StackOverflow,
    OutOfMemory,
    RuntimeError,
};

// Constants
pub const LUA_MULTRET = -1;
pub const REGISTRY_INDEX = stack.REGISTRY_INDEX;

// Thread status
pub const ThreadStatus = state.ThreadStatus;

// Native function signature (see state.CFunction)
pub const CFunction = state.CFunction;

// GC options
pub const GCOpt = GCWhat;

// Stack manipulation

/// Get absolute index
pub fn absIndex(L: *state.LuaState, idx: i32) i32 {
    if (idx > 0 or idx <= stack.REGISTRY_INDEX) {
        return idx;
    } else {
        const top = getTop(L);
        return top + idx + 1;
    }
}

/// Get top of stack
pub fn getTop(L: *state.LuaState) i32 {
    return @intCast((@intFromPtr(L.top) - @intFromPtr((L.ci.func + 1))) / @sizeOf(value.TValue));
}

/// Set top of stack
pub fn setTop(L: *state.LuaState, idx: i32) !void {
    if (idx >= 0) {
        const newtop = (L.ci.func + 1) + @as(usize, @intCast(idx));

        // Check if we need to grow stack
        if (@intFromPtr(newtop) > @intFromPtr(L.stack_last)) {
            try stack.checkStack(L, idx);
        }

        // Fill with nil if growing
        while (@intFromPtr(L.top) < @intFromPtr(newtop)) {
            L.top[0] = value.TValue.nil();
            L.top += 1;
        }

        L.top = newtop;
    } else {
        // Negative index: lua_settop(L, -n-1) pops n values, i.e. the new
        // top is top + (idx + 1)
        const drop: usize = @intCast(-idx - 1);
        const newtop = L.top - drop;
        if (@intFromPtr(newtop) < @intFromPtr(L.ci.func + 1)) {
            return APIError.InvalidIndex;
        }
        L.top = newtop;
    }
}

/// Push value onto stack
pub fn pushValue(L: *state.LuaState, val: value.TValue) !void {
    try stack.push(L, val);
}

/// Pop n values from stack
pub fn pop(L: *state.LuaState, n: i32) void {
    setTop(L, -n - 1) catch unreachable; // Should not fail for negative index
}

/// Push nil
pub fn pushNil(L: *state.LuaState) !void {
    try pushValue(L, value.TValue.nil());
}

/// Push boolean
pub fn pushBoolean(L: *state.LuaState, b: bool) !void {
    try pushValue(L, value.TValue.boolean(b));
}

/// Push integer
pub fn pushInteger(L: *state.LuaState, n: i64) !void {
    try pushValue(L, try value.TValue.integerOrBox(&L.l_G.gc, n));
}

/// Push number
pub fn pushNumber(L: *state.LuaState, n: f64) !void {
    try pushValue(L, value.TValue.float(n));
}

/// Push string
pub fn pushString(L: *state.LuaState, s: []const u8) !void {
    const str = try L.l_G.string_pool.create(s); // interns short strings only
    try pushValue(L, value.TValue.string(str));
}

/// Push formatted string
pub fn pushFString(L: *state.LuaState, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(L.allocator, fmt, args);
    defer L.allocator.free(s);
    try pushString(L, s);
}

/// Push C function
pub fn pushCFunction(L: *state.LuaState, f: state.CFunction) !void {
    try pushValue(L, value.TValue.function(.{ .native_fn = f }));
}

/// Pseudo-index of the `n`-th upvalue of the running C closure (lua_upvalueindex)
pub fn upvalueIndex(n: i32) i32 {
    return stack.REGISTRY_INDEX - n;
}

/// Pop the top `n` values and push a native function that closes over them
/// (lua_pushcclosure). Reachable from inside `f` via `upvalueIndex`.
///
/// Iterators such as `gmatch` need this: their position advances between
/// calls, and the state has to live somewhere the collector can see.
pub fn pushCClosure(L: *state.LuaState, f: state.CFunction, n: u8) !void {
    if (n == 0) return pushCFunction(L, f);

    const cl = try closure_module.newCClosure(L, n);
    cl.f = f;
    const base = L.top - n;
    for (0..n) |i| cl.upvals[i] = base[i];
    L.top -= n;
    try pushValue(L, value.TValue.cclosure(cl));
}

/// Push light userdata
pub fn pushLightUserdata(L: *state.LuaState, p: *anyopaque) !void {
    try pushValue(L, value.TValue.lightUserdata(p));
}

/// Copy value at index
pub fn pushValueAt(L: *state.LuaState, idx: i32) !void {
    const val = try index2Value(L, idx);
    try pushValue(L, val.*);
}

/// Insert value at index
pub fn insert(L: *state.LuaState, idx: i32) !void {
    const p: [*]value.TValue = @ptrCast(try index2Stack(L, idx));
    var q = L.top - 1; // the value to move
    const tmp = q[0];
    while (@intFromPtr(q) > @intFromPtr(p)) : (q -= 1) {
        q[0] = (q - 1)[0];
    }
    p[0] = tmp;
}

/// Remove value at index
pub fn remove(L: *state.LuaState, idx: i32) !void {
    var q: [*]value.TValue = @ptrCast(try index2Stack(L, idx));
    L.top -= 1;
    while (@intFromPtr(q) < @intFromPtr(L.top)) : (q += 1) {
        q[0] = q[1];
    }
}

/// Replace value at index
pub fn replace(L: *state.LuaState, idx: i32) !void {
    // Unlike insert/remove, which shuffle stack slots, this only overwrites a
    // destination, so pseudo-indices such as an upvalue are valid targets
    const v = try index2Value(L, idx);
    L.top -= 1;
    v.* = L.top[0];
}

/// Copy value
pub fn copy(L: *state.LuaState, fromidx: i32, toidx: i32) !void {
    const from = try index2Value(L, fromidx);
    const to = try index2Value(L, toidx);
    to.* = from.*;
}

/// Rotate stack elements
pub fn rotate(L: *state.LuaState, idx: i32, n: i32) !void {
    const p: [*]value.TValue = @ptrCast(try index2Stack(L, idx));
    const t = L.top - 1;

    if (n > 0) {
        // Rotate right
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const tmp = t[0];
            var q = t;
            while (@intFromPtr(q) > @intFromPtr(p)) : (q -= 1) {
                q[0] = (q - 1)[0];
            }
            p[0] = tmp;
        }
    } else if (n < 0) {
        // Rotate left
        var i: u32 = 0;
        while (i < -n) : (i += 1) {
            const tmp = p[0];
            var q = p;
            while (@intFromPtr(q) < @intFromPtr(t)) : (q += 1) {
                q[0] = q[1];
            }
            t[0] = tmp;
        }
    }
}

// Type checking

/// Get type of value
pub fn type_(L: *state.LuaState, idx: i32) value.ValueType {
    const v = index2Value(L, idx) catch return .nil;
    return v.tag();
}

/// Get type name
pub fn typeName(L: *state.LuaState, tp: value.ValueType) []const u8 {
    _ = L;
    return tp.name();
}

/// Check if nil
pub fn isNil(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isNil();
}

/// Check if boolean
pub fn isBoolean(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isBoolean();
}

/// Check if number
pub fn isNumber(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isNumber();
}

/// Check if integer
pub fn isInteger(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isInteger();
}

/// Check if string
pub fn isString(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isString();
}

/// Check if table
pub fn isTable(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isTable();
}

/// Check if function
pub fn isFunction(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isFunction();
}

/// Check if C function
pub fn isCFunction(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.tag() == .function and v.functionValue() == .native_fn;
}

/// Check if userdata
pub fn isUserdata(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isUserdata() or v.isLightUserdata();
}

/// Check if thread
pub fn isThread(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isThread();
}

/// Check if light userdata
pub fn isLightUserdata(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isLightUserdata();
}

// Value conversion

/// Convert to boolean
pub fn toBoolean(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;
    return v.isTruthy();
}

/// Convert to integer
pub fn toInteger(L: *state.LuaState, idx: i32) ?i64 {
    const v = index2Value(L, idx) catch return null;
    // asInteger already folds the float case through the range-checked
    // conversion in value.zig, so there is no second bound test here.
    if (v.asInteger()) |i| return i;
    if (v.asString()) |s| {
        // Strings convert by Lua's numeral rules, so "0x10" and " 3.0 " work
        // and "inf"/"nan" do not (lua_tointegerx via luaO_str2num).
        const n = vm.stringToNumber(s.slice()) orelse return null;
        return n.toInteger();
    }
    return null;
}

/// Convert to integer with status
pub fn toIntegerX(L: *state.LuaState, idx: i32, isnum: *bool) i64 {
    isnum.* = true;
    return toInteger(L, idx) orelse {
        isnum.* = false;
        return 0;
    };
}

/// Convert to number
pub fn toNumber(L: *state.LuaState, idx: i32) ?f64 {
    const v = index2Value(L, idx) catch return null;
    if (v.asFloat()) |f| return f;
    if (v.asInteger()) |i| return @floatFromInt(i);
    if (v.asString()) |s| {
        return std.fmt.parseFloat(f64, s.slice()) catch null;
    }
    return null;
}

/// Convert to number with status
pub fn toNumberX(L: *state.LuaState, idx: i32, isnum: *bool) f64 {
    isnum.* = true;
    return toNumber(L, idx) orelse {
        isnum.* = false;
        return 0;
    };
}

/// Convert to string
pub fn toString(L: *state.LuaState, idx: i32) ?[]const u8 {
    const v = index2Value(L, idx) catch return null;
    const s = v.asString() orelse return null;
    return s.slice();
}

/// As `toString`, but numbers are accepted and the stack slot is converted to
/// a string in place, exactly as `lua_tolstring` does. The library functions
/// need this: Lua accepts `("x"):rep(2)` and equally `string.rep(5, 2)`.
pub fn toStringCoerce(L: *state.LuaState, idx: i32) !?[]const u8 {
    const v = index2Value(L, idx) catch return null;
    if (v.asString()) |s| return s.slice();
    if (v.tag() != .number) return null;

    var buf: [64]u8 = undefined;
    const num: value.Number = if (v.asInteger()) |i|
        .{ .integer = i }
    else
        .{ .float = v.asFloat().? };
    const interned = try L.l_G.string_pool.intern(vm.numberToStringBuf(&buf, num));
    v.* = value.TValue.string(interned);
    return interned.slice();
}

/// Convert to string with length
pub fn toStringLen(L: *state.LuaState, idx: i32, len: *usize) ?[]const u8 {
    if (toString(L, idx)) |s| {
        len.* = s.len;
        return s;
    }
    return null;
}

/// Convert to C function
pub fn toCFunction(L: *state.LuaState, idx: i32) ?state.CFunction {
    const v = index2Value(L, idx) catch return null;
    if (v.tag() == .function and v.functionValue() == .native_fn) {
        return v.functionValue().native_fn;
    }
    return null;
}

/// Convert to userdata
pub fn toUserdata(L: *state.LuaState, idx: i32) ?*anyopaque {
    const v = index2Value(L, idx) catch return null;
    return switch (v.tag()) {
        // The payload, not the header: this has to agree with what
        // newUserdata hands back, which is what a caller stores through.
        .userdata => @ptrCast(v.userdataValue().data),
        .light_userdata => v.asLightUserdata().?,
        else => null,
    };
}

/// Convert to thread
pub fn toThread(L: *state.LuaState, idx: i32) ?*state.LuaState {
    const v = index2Value(L, idx) catch return null;
    return v.asThread();
}

/// Convert to pointer
pub fn toPointer(L: *state.LuaState, idx: i32) ?*const anyopaque {
    const v = index2Value(L, idx) catch return null;
    return switch (v.tag()) {
        .table => @ptrCast(v.tableValue()),
        .function => if (v.functionValue() == .closure) @ptrCast(v.functionValue().closure) else @ptrCast(v.functionValue().native_fn),
        .userdata => @ptrCast(v.userdataValue()),
        .thread => @ptrCast(v.threadValue()),
        .light_userdata => v.asLightUserdata().?,
        .string => @ptrCast(v.stringValue()), // every collectable value has an address
        else => null,
    };
}

// Table operations

/// Create new table
pub fn newTable(L: *state.LuaState) !void {
    const t = try L.l_G.gc.newTable(0, 0);
    try pushValue(L, value.TValue.table(t));
}

/// Create table with size hints
pub fn createTable(L: *state.LuaState, narr: i32, nrec: i32) !void {
    const t = try L.l_G.gc.newTable(@intCast(@max(narr, 0)), @intCast(@max(nrec, 0)));
    try pushValue(L, value.TValue.table(t));
}

/// Get table field
pub fn getTable(L: *state.LuaState, idx: i32) !void {
    const t = try index2Value(L, idx);
    const key = &(L.top - 1)[0];
    const val = try vm.getTable(L, t, key);
    key.* = val;
}

/// Get table field by string key
pub fn getField(L: *state.LuaState, idx: i32, k: []const u8) !value.ValueType {
    const t = try index2Value(L, idx);
    try pushString(L, k);
    const key = &(L.top - 1)[0];
    const val = try vm.getTable(L, t, key);
    key.* = val;
    return val.tag();
}

/// Get table field by integer key
pub fn getI(L: *state.LuaState, idx: i32, n: i64) !void {
    const t = try index2Value(L, idx);
    const val = try vm.getTableInt(L, t, n);
    try pushValue(L, val);
}

/// Raw get (no metamethods)
pub fn rawGet(L: *state.LuaState, idx: i32) !void {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    const key = &(L.top - 1)[0];
    key.* = tbl.get(key.*);
}

/// Raw get by integer
pub fn rawGetI(L: *state.LuaState, idx: i32, n: i64) !void {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    try pushValue(L, tbl.getInt(n));
}

/// Raw get by pointer
pub fn rawGetP(L: *state.LuaState, idx: i32, p: *const anyopaque) !void {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    const key = value.TValue.lightUserdata(@constCast(p));
    try pushValue(L, tbl.get(key));
}

/// Set table field
pub fn setTable(L: *state.LuaState, idx: i32) !void {
    const t = try index2Value(L, idx);
    const val = &(L.top - 1)[0];
    const key = &(L.top - 2)[0];
    try vm.setTable(L, t, key, val);
    L.top -= 2;
}

/// Set table field by string key
pub fn setField(L: *state.LuaState, idx: i32, k: []const u8) !void {
    const t = try index2Value(L, idx);
    try pushString(L, k);
    try insert(L, -2);
    const key = &(L.top - 2)[0];
    const val = &(L.top - 1)[0];
    try vm.setTable(L, t, key, val);
    L.top -= 2;
}

/// Set table field by integer key
pub fn setI(L: *state.LuaState, idx: i32, n: i64) !void {
    const t = try index2Value(L, idx);
    const val = &(L.top - 1)[0];
    try vm.setTableInt(L, t, n, val);
    L.top -= 1;
}

/// Raw set (no metamethods)
pub fn rawSet(L: *state.LuaState, idx: i32) !void {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    const val = &(L.top - 1)[0];
    const key = &(L.top - 2)[0];
    try tbl.set(key.*, val.*);
    L.l_G.gc.barrierBackValue(&tbl.header, key);
    L.l_G.gc.barrierBackValue(&tbl.header, val);
    L.top -= 2;
}

/// Raw set by integer
pub fn rawSetI(L: *state.LuaState, idx: i32, n: i64) !void {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    const val = &(L.top - 1)[0];
    try tbl.setInt(n, val.*);
    L.l_G.gc.barrierBackValue(&tbl.header, val);
    L.top -= 1;
}

/// Raw set by pointer
pub fn rawSetP(L: *state.LuaState, idx: i32, p: *const anyopaque) !void {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    const key = value.TValue.lightUserdata(@constCast(p));
    const val = &(L.top - 1)[0];
    try tbl.set(key, val.*);
    L.l_G.gc.barrierBackValue(&tbl.header, val);
    L.top -= 1;
}

/// Get/set metatable
pub fn getMetatable(L: *state.LuaState, idx: i32) bool {
    const v = index2Value(L, idx) catch return false;

    // Tables and full userdata each carry their own metatable; everything else
    // shares the per-type one. Reading l_G.mt for userdata made getmetatable
    // and getMetafield blind to a handle's __tostring / __index.
    const mt = switch (v.tag()) {
        .table => v.tableValue().metatable,
        .userdata => v.userdataValue().metatable,
        else => L.l_G.mt[@intFromEnum(v.tag())],
    };

    if (mt) |metatable| {
        pushValue(L, value.TValue.table(metatable)) catch return false;
        return true;
    }

    return false;
}

pub fn setMetatable(L: *state.LuaState, idx: i32) !bool {
    const v = try index2Value(L, idx);
    const mt = &(L.top - 1)[0];

    switch (v.tag()) {
        .table => {
            const t = v.tableValue();
            const new_mt = if (mt.isNil()) null else mt.asTable();
            t.setMetatable(new_mt);
            t.updateWeakFlags(L.l_G.tmname[@intFromEnum(value.TMS.__mode)]);
            if (new_mt) |m| {
                L.l_G.gc.barrierObject(&t.header, &m.header);
                L.l_G.gc.checkFinalizer(&t.header, m);
            }
            L.top -= 1;
            return true;
        },
        .userdata => {
            const u = v.userdataValue();
            const new_mt = if (mt.isNil()) null else mt.asTable();
            u.metatable = new_mt;
            if (new_mt) |m| {
                L.l_G.gc.barrierObject(&u.header, &m.header);
                L.l_G.gc.checkFinalizer(&u.header, m);
            }
            L.top -= 1;
            return true;
        },
        else => {
            const new_mt = if (mt.isNil()) null else mt.asTable();
            L.l_G.mt[@intFromEnum(v.tag())] = new_mt;
            L.top -= 1;
            return true;
        },
    }
}

/// Install the shared metatable for a basic type, popping it from the stack.
///
/// Lua has no public call for this; `luaL_openlibs` reaches into the global
/// state to give strings their metatable so that `("x"):upper()` resolves. The
/// read side already consults `l_G.mt`, so this is the missing half.
pub fn setTypeMetatable(L: *state.LuaState, tp: value.ValueType) !void {
    const mt = &(L.top - 1)[0];
    L.l_G.mt[@intFromEnum(tp)] = if (mt.isNil()) null else mt.asTable();
    L.top -= 1;
}

/// Get uservalue
pub fn getUservalue(L: *state.LuaState, idx: i32, n: i32) !?value.ValueType {
    const v = try index2Value(L, idx);
    const u = v.asUserdata() orelse return APIError.TypeError;

    if (n <= 0 or n > u.nuvalue) {
        try pushNil(L);
        return null; // lua_getiuservalue: LUA_TNONE for a missing user value
    }

    try pushValue(L, u.values[@intCast(n - 1)]);
    return u.values[@intCast(n - 1)].tag();
}

/// Set uservalue
pub fn setUservalue(L: *state.LuaState, idx: i32, n: i32) !void {
    const v = try index2Value(L, idx);
    const u = v.asUserdata() orelse return APIError.TypeError;

    if (n <= 0 or n > u.nuvalue) {
        return APIError.InvalidIndex;
    }

    const val = (L.top - 1)[0];
    u.values[@intCast(n - 1)] = val;
    L.l_G.gc.barrier(&u.header, &val);
    L.top -= 1;
}

// Length operations

/// Get length
pub fn length(L: *state.LuaState, idx: i32) !void {
    const v = try index2Value(L, idx);
    const len = try vm.lenOp(L, v);
    try pushValue(L, len);
}

/// Raw length (no metamethods)
pub fn rawLen(L: *state.LuaState, idx: i32) usize {
    const v = index2Value(L, idx) catch return 0;
    return switch (v.tag()) {
        .string => v.stringValue().len(),
        .table => v.tableValue().arrayLen(),
        .userdata => v.userdataValue().len,
        else => 0,
    };
}

// Arithmetic and comparison operations

/// Arithmetic operations
pub fn arith(L: *state.LuaState, op: ArithOp) !void {
    switch (op) {
        .UNM, .BNOT => {
            // Unary operation
            const v = &(L.top - 1)[0];
            v.* = try vm.unaryOp(L, v, arithOpToVM(op));
        },
        else => {
            // Binary operation
            const v1 = &(L.top - 2)[0];
            const v2 = &(L.top - 1)[0];
            v1.* = try vm.arithOp(L, v1, v2, arithOpToVM(op));
            L.top -= 1;
        },
    }
}

/// Compare values
pub fn compare(L: *state.LuaState, idx1: i32, idx2: i32, op: CompareOp) !bool {
    const v1 = try index2Value(L, idx1);
    const v2 = try index2Value(L, idx2);
    return vm.compareOp(L, v1, v2, compareOpToVM(op));
}

/// Raw equality
pub fn rawEqual(L: *state.LuaState, idx1: i32, idx2: i32) bool {
    const v1 = index2Value(L, idx1) catch return false;
    const v2 = index2Value(L, idx2) catch return false;
    return rawEqualValue(v1, v2);
}

// Function calls

/// Call function (lua_call). A native function that calls back into Lua
/// this way cannot be resumed after a yield, since its own frame would be
/// gone, so the thread is non-yieldable for the duration.
pub fn call(L: *state.LuaState, nargs: i32, nresults: i32) !void {
    try checkArgs(L, nargs + 1);
    const func = L.top - @as(usize, @intCast(nargs)) - 1;
    L.nny += 1;
    defer L.nny -= 1;
    try vm.doCall(L, func, @intCast(nargs), @intCast(nresults));
}

/// Call with a continuation (lua_callk). In a yieldable thread the callee
/// may yield: `error.Yield` then passes through the calling native function,
/// whose Zig frame is gone for good, and `k` is called with `ctx` when the
/// coroutine is resumed to produce the function's results in its place (see
/// `coroutine.finishCcall`). Without a continuation, or in a non-yieldable
/// thread, this is `call`.
pub fn callk(L: *state.LuaState, nargs: i32, nresults: i32, ctx: usize, k: ?state.ContinuationFn) !void {
    if (k == null or !coroutine_module.isYieldable(L)) return call(L, nargs, nresults);
    try checkArgs(L, nargs + 1);
    const func = L.top - @as(usize, @intCast(nargs)) - 1;
    L.ci.u.c.k = k;
    L.ci.u.c.ctx = ctx;
    try vm.doCall(L, func, @intCast(nargs), @intCast(nresults));
}

/// Protected call
pub fn pcall(L: *state.LuaState, nargs: i32, nresults: i32, errfunc: i32) state.ThreadStatus {
    // Without a continuation the call cannot survive a yield (lua_pcall)
    L.nny += 1;
    defer L.nny -= 1;
    return pcallk(L, nargs, nresults, errfunc, null, 0) catch |e| {
        // Non-yieldable, so no Yield can escape; what can, when memory is
        // gone, is the error machinery itself failing to build its result.
        // Then the preallocated memory message is the error object.
        pushValue(L, L.l_G.memerrmsg) catch {};
        return if (e == error.OutOfMemory) .errmem else .errrun;
    };
}

/// Emit one piece of a warning (lua_warning); `tocont` says more pieces
/// follow. This is the reference's `warnfon`/`warnfcont` pair: the first
/// piece of a message is prefixed "Lua warning: ", the last is followed by a
/// newline, and nothing is printed while warnings are off (`warn("@on")`,
/// `-W`). Control messages are handled by the `warn` builtin before they
/// get here.
pub fn warning(L: *state.LuaState, msg: []const u8, tocont: bool) void {
    const g = L.l_G;
    if (!g.warn_on) return;
    var buf: [256]u8 = undefined;
    var w = stdio.stderrWriter(&buf);
    const writer = &w.interface;
    if (!g.warn_cont) writer.writeAll("Lua warning: ") catch return;
    writer.writeAll(msg) catch return;
    if (!tocont) writer.writeAll("\n") catch return;
    writer.flush() catch {};
    g.warn_cont = tocont;
}

/// Turn the error object on top of the stack into the warning
/// "error in <where> (<message>)" (luaE_warnerror), as the collector does
/// for a failing `__gc` and `lua_close` for a failing `__close`.
pub fn warnError(L: *state.LuaState, site: []const u8) void {
    const msg = if (type_(L, -1) == .string) toString(L, -1).? else "error object is not a string";
    warning(L, "error in ", true);
    warning(L, site, true);
    warning(L, " (", true);
    warning(L, msg, true);
    warning(L, ")", false);
}

/// Protected call with a continuation (lua_pcallk). In a yieldable thread the
/// callee may yield: the call's native frame is then unwound, and `k` is
/// called later to finish the job, either when the coroutine is resumed or
/// when an error is recovered (see coroutine.zig). `error.Yield` passes
/// through this function; anything else is caught and reported as a status.
pub fn pcallk(L: *state.LuaState, nargs: i32, nresults: i32, errfunc: i32, k: ?state.ContinuationFn, ctx: usize) anyerror!state.ThreadStatus {
    // Save what a failed call must restore (luaD_pcall / luaD_rawrunprotected).
    // Stack positions are kept as offsets: the stack can move while the
    // callee, the message handler or a `__close` handler runs.
    const old_ci = L.ci;
    const old_nccalls = L.nCcalls;
    const old_allowhook = L.allowhook;
    const func_off = (@intFromPtr(L.top) - @intFromPtr(L.stack)) / @sizeOf(value.TValue) - @as(usize, @intCast(nargs)) - 1;
    const handler_off: ?usize = if (errfunc != 0) blk: {
        const h = index2Value(L, errfunc) catch break :blk null;
        break :blk (@intFromPtr(h) - @intFromPtr(L.stack)) / @sizeOf(value.TValue);
    } else null;

    // `L->errfunc`: the handler in effect for errors raised outside this
    // function's own unwinding, e.g. a runtime error inside the protected
    // parser (`load` at the nesting limit). A yield restores it early; the
    // frames finished by `resume` do not consult it.
    const old_errfunc = L.errfunc;
    L.errfunc = handler_off orelse 0;
    defer L.errfunc = old_errfunc;

    var jmp = state.ErrorJmp{
        .previous = L.errorJmp,
        .status = .ok,
    };
    L.errorJmp = &jmp;
    defer L.errorJmp = jmp.previous;

    checkArgs(L, nargs + 1) catch {
        return .errrun;
    };

    // A yieldable protected call records enough in its frame for the
    // coroutine machinery to finish it without this Zig frame
    const yieldable = k != null and coroutine_module.isYieldable(L);
    if (yieldable) {
        old_ci.u.c.k = k;
        old_ci.u.c.ctx = ctx;
        old_ci.u.c.funcidx = func_off;
        old_ci.u.c.errfunc = handler_off orelse 0;
        old_ci.u.c.recst = .ok;
        old_ci.callstatus.isYpcall = true;
    }
    // The mark is cleared when the call completes here, one way or the
    // other. A yield leaves it set on purpose: that is how the coroutine
    // machinery later finds this call to finish it.

    vm.call(L, L.stack + func_off, nresults) catch |err| {
        if (err == error.Yield) return error.Yield; // not an error: on its way to resume
        if (yieldable) {
            // As lua_pcallk does in a yieldable thread: the error unwinds
            // to `resume`, which finds this frame by its mark, runs the
            // message handler, closes the callee's to-be-closed variables
            // (a `__close` handler may yield there) and then calls `k`
            // (coroutine.precover / finishPcallk)
            if (jmp.previous) |prev| prev.status = jmp.status;
            return err;
        }
        old_ci.callstatus.isYpcall = false;
        var st: state.ThreadStatus = if (jmp.status != .ok) jmp.status else if (err == error.OutOfMemory) .errmem else .errrun;
        var errobj = errorObject(L, err, st, jmp.status != .ok);

        // The message handler runs first, while the frames that failed are
        // still in the CallInfo chain, so a traceback can see them
        // (luaG_errormsg)
        if (handler_off) |hoff| {
            if (st == .errrun) errobj = applyHandler(L, hoff, errobj, &st);
        }

        // Unwind to the calling frame
        L.ci = old_ci;
        L.nCcalls = old_nccalls;
        L.allowhook = old_allowhook;

        // Close upvalues and to-be-closed variables of the unwound frames. A
        // `__close` handler that raises replaces the error object, and the
        // remaining variables are still closed (luaD_closeprotected). Yields
        // are not allowed while closing here.
        L.nny += 1;
        defer L.nny -= 1;
        while (true) {
            vm.closeAll(L, L.stack + func_off, errobj) catch |cerr| {
                st = if (jmp.status != .ok) jmp.status else if (cerr == error.OutOfMemory) .errmem else .errrun;
                errobj = errorObject(L, cerr, st, jmp.status != .ok);
                L.ci = old_ci;
                L.nCcalls = old_nccalls;
                continue;
            };
            break;
        }

        // Leave the error object where the function was
        const func = L.stack + func_off;
        func[0] = errobj;
        L.top = func + 1;
        L.status = .ok;
        stack.shrinkStack(L); // restore the stack size after an overflow (luaD_pcall)
        return st;
    };

    old_ci.callstatus.isYpcall = false;
    return .ok;
}

/// The error object for a failed call: what `throw` left on top of the stack,
/// or a message standing in for a Zig error that never became a Lua value
fn errorObject(L: *state.LuaState, err: anyerror, st: state.ThreadStatus, thrown: bool) value.TValue {
    if (st == .errerr) { // the message is fixed (luaD_seterrorobj)
        const s = L.l_G.string_pool.intern("error in error handling") catch return value.TValue.nil();
        return value.TValue.string(s);
    }
    if (thrown and @intFromPtr(L.top) > @intFromPtr(L.ci.func + 1)) {
        return (L.top - 1)[0]; // pushed by `throw`
    }
    if (st == .errmem) return L.l_G.memerrmsg; // preallocated: nothing to make at this moment
    const s = L.l_G.string_pool.intern(@errorName(err)) catch return L.l_G.memerrmsg;
    return value.TValue.string(s);
}

/// Run `xpcall`'s message handler over the error object and return whatever it
/// produced. Called before unwinding, as Lua does, so `debug.traceback` in a
/// handler reports the frames that failed. A handler that itself fails turns
/// the status into `errerr` with Lua's message for it.
fn applyHandler(L: *state.LuaState, handler_off: usize, errobj: value.TValue, st: *state.ThreadStatus) value.TValue {
    const handler = L.stack[handler_off];
    if (!handler.isFunction()) return errobj;

    stack.checkStack(L, 2) catch return errobj;
    const call_base = L.top;
    call_base[0] = handler;
    call_base[1] = errobj;
    L.top = call_base + 2;

    vm.call(L, call_base, 1) catch {
        st.* = .errerr;
        const s = L.l_G.string_pool.intern("error in error handling") catch return errobj;
        return value.TValue.string(s);
    };

    const result = (L.top - 1)[0];
    L.top -= 1;
    return result;
}

/// Load a chunk from a string (luaL_loadstring)
pub fn loadString(L: *state.LuaState, s: []const u8, chunkname: []const u8) state.ThreadStatus {
    return loadBuffer(L, s, chunkname, "bt");
}

/// Load a chunk from memory, honouring `mode` ("t", "b" or "bt") (luaL_loadbufferx).
///
/// Follows the `lua_load` contract every caller depends on: on `.ok` the main
/// closure is on top of the stack, and on any error the message is there
/// instead.
pub fn loadBuffer(L: *state.LuaState, buff: []const u8, name: []const u8, mode: []const u8) state.ThreadStatus {
    if (isBinaryChunk(buff)) {
        if (mem.indexOfScalar(u8, mode, 'b') == null) {
            return loadFailure(L, "attempt to load a binary chunk (mode is '{s}')", .{mode});
        }
        return loadBinary(L, buff, name);
    }
    if (mem.indexOfScalar(u8, mode, 't') == null) {
        return loadFailure(L, "attempt to load a text chunk (mode is '{s}')", .{mode});
    }
    return compileChunk(L, buff, name);
}

/// Load a chunk from a file, or from stdin when `filename` is null (luaL_loadfilex)
pub fn loadFile(L: *state.LuaState, filename: ?[]const u8, mode: []const u8) state.ThreadStatus {
    const fname = filename orelse {
        var in_buf: [4096]u8 = undefined;
        var stdin_reader = stdio.stdinReader(&in_buf);
        const content = stdin_reader.interface.allocRemaining(L.allocator, .limited(MAX_CHUNK_BYTES)) catch {
            return loadFailure(L, "cannot read stdin", .{});
        };
        defer L.allocator.free(content);
        return loadBuffer(L, skipFilePrefix(content), "=stdin", mode);
    };

    const content = std.Io.Dir.cwd().readFileAlloc(stdio.io(), fname, L.allocator, .limited(MAX_CHUNK_BYTES)) catch |err| {
        return loadFailure(L, "cannot open {s}: {s}", .{ fname, syserr.describe(err).text });
    };
    defer L.allocator.free(content);

    // '@' marks a file name, so messages read "file.lua:3:" rather than
    // quoting the source text back at the user (luaO_chunkid).
    var namebuf: [512]u8 = undefined;
    const chunkname = std.fmt.bufPrint(&namebuf, "@{s}", .{fname}) catch fname;
    return loadBuffer(L, skipFilePrefix(content), chunkname, mode);
}

/// What `luaL_loadfilex` does before handing a file to the loader: drop a
/// UTF-8 byte order mark and a first line starting with `#` (a Unix
/// "shebang"). For a text chunk the line's newline is kept so that line
/// numbers stay right; for a binary chunk following the comment it is not.
fn skipFilePrefix(content: []const u8) []const u8 {
    var rest = content;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    if (rest.len > 0 and rest[0] == '#') {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
        rest = rest[nl..];
        if (rest.len > 1 and rest[1] == dump_module.LUA_SIGNATURE[0]) rest = rest[1..];
    }
    return rest;
}

/// Write the Lua function on top of the stack as a binary chunk (lua_dump).
/// Returns `error.NotLuaFunction` for anything else, which is what makes
/// `string.dump` say "unable to dump given function".
pub fn dump(L: *state.LuaState, writer: dump_module.WriterFn, data: *anyopaque, strip: bool) !void {
    const f = (L.top - 1)[0];
    const cl = f.asClosure() orelse return error.NotLuaFunction;
    try dump_module.dump(L, cl.proto, writer, data, strip);
}

/// Load a precompiled chunk and push its closure, like `compileChunk` does
/// for source text (luaU_undump plus lua_load's `_ENV` binding)
fn loadBinary(L: *state.LuaState, buff: []const u8, name: []const u8) state.ThreadStatus {
    var why: []const u8 = "";
    const p = undump_module.undump(L, buff, name, &why) catch |err| {
        if (err == error.OutOfMemory) return memoryFailure(L);
        return loadFailure(L, "{s}: bad binary format ({s})", .{ undump_module.messageName(name), why });
    };
    const cl = closure_module.newLClosure(L, p.sizeupvalues) catch return memoryFailure(L);
    cl.proto = p;
    // Every upvalue starts out closed and nil, except the first, which is
    // the environment of a main chunk
    var i: usize = 0;
    while (i < p.sizeupvalues) : (i += 1) {
        const init = if (i == 0) L.l_G.l_registry.asTable().?.getInt(state.RIDX_GLOBALS) else value.TValue.nil();
        cl.upvals[i] = closure_module.newClosedUpvalue(L, init) catch return memoryFailure(L);
    }
    pushValue(L, value.TValue.closure(cl)) catch return memoryFailure(L);
    return .ok;
}

/// An out-of-memory result of `load`: the status and, as luaD_seterrorobj
/// leaves it for LUA_ERRMEM, the message on the stack
fn memoryFailure(L: *state.LuaState) state.ThreadStatus {
    pushValue(L, L.l_G.memerrmsg) catch {};
    return .errmem;
}

// Chunk loading (ldo.c, lauxlib.c)

const MAX_CHUNK_BYTES = 10 * 1024 * 1024;

/// Precompiled chunks start with the Lua signature byte
fn isBinaryChunk(s: []const u8) bool {
    return s.len > 0 and s[0] == 0x1b;
}

/// Leave a formatted message on the stack and report a syntax error
fn loadFailure(L: *state.LuaState, comptime fmt: []const u8, args: anytype) state.ThreadStatus {
    var buf: [vm.IDSIZE + 512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "cannot load chunk";
    pushString(L, msg) catch return .errmem;
    return .errsyntax;
}

/// As `loadFailure`, but prefixed "chunkname:line: " the way Lua reports
/// compile errors
fn loadFailureAt(L: *state.LuaState, name: []const u8, line: anytype, msg: []const u8) state.ThreadStatus {
    var namebuf: [vm.IDSIZE]u8 = undefined;
    const short = vm.shortSource(&namebuf, name);
    return loadFailure(L, "{s}:{d}: {s}", .{ short, line, msg });
}

/// Lex, parse and compile `source`, pushing the main closure with its `_ENV`
/// upvalue bound to the globals table
fn compileChunk(L: *state.LuaState, source: []const u8, name: []const u8) state.ThreadStatus {
    var arena = std.heap.ArenaAllocator.init(L.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var lexer = lex.LexState.init(source, name, scratch) catch return .errmem;
    defer lexer.deinit();

    var parser_instance = parser.Parser.init(&lexer, scratch) catch |err| {
        // Reading the first token failed: the lexer has the message
        if (err == error.OutOfMemory) return .errmem;
        var buf: [256]u8 = undefined;
        return loadFailureAt(L, name, lexer.linenumber, lexer.errorMessage(&buf));
    };
    defer parser_instance.deinit();
    // The parser's nesting limit stands in for the C stack: it counts from
    // the calls already active, as `luaE_incCstack` does
    parser_instance.level = L.nCcalls;

    var tree = parser_instance.parse() catch |err| {
        if (err == error.OutOfMemory) return .errmem;
        if (parser_instance.errors.items.len > 0) {
            const first = parser_instance.errors.items[0];
            if (!first.positioned) {
                // The nesting limit is a runtime error in the reference
                // (luaG_runerror inside the protected parser), so it goes
                // through the message handler in effect; under lua.c that
                // means the message carries a traceback
                pushString(L, first.msg) catch return .errmem;
                if (L.errfunc != 0) {
                    var st: state.ThreadStatus = .errrun;
                    const handled = applyHandler(L, L.errfunc, (L.top - 1)[0], &st);
                    (L.top - 1)[0] = handled;
                }
                return .errrun;
            }
            return loadFailureAt(L, name, first.line, first.msg);
        }
        return loadFailureAt(L, name, lexer.linenumber, @errorName(err));
    };
    defer tree.deinit();

    var diag: ?codegen.Diagnostic = null;
    const main_proto = codegen.compileWithDiag(L, &tree, name, &diag) catch |err| {
        if (diag) |*d| return loadFailureAt(L, name, d.line, d.text());
        if (err == error.OutOfMemory) return .errmem;
        return loadFailure(L, "{s}", .{@errorName(err)});
    };

    const cl = closure_module.newLClosure(L, main_proto.sizeupvalues) catch return .errmem;
    cl.proto = main_proto;
    if (main_proto.sizeupvalues > 0) {
        const globals = L.l_G.l_registry.asTable().?.getInt(state.RIDX_GLOBALS);
        cl.upvals[0] = closure_module.newClosedUpvalue(L, globals) catch return .errmem;
    }
    pushValue(L, value.TValue.closure(cl)) catch return .errmem;
    return .ok;
}

// Coroutine functions

/// Yield the running coroutine with the top `nresults` values (lua_yield).
/// Returns the error a native function must return to let the yield
/// propagate, or a Lua error when the thread cannot yield here.
pub fn yield(L: *state.LuaState, nresults: i32) anyerror {
    return coroutine_module.yield(L, nresults);
}

/// Resume `co` with `nargs` arguments from its stack top (lua_resume). On
/// return `nres` values (or the error object) are on top of `co`'s stack.
pub fn resume_(L: *state.LuaState, co: *state.LuaState, nargs: i32, nres: *i32) state.ThreadStatus {
    var n: usize = 0;
    const st = coroutine_module.resumeThread(co, L, @intCast(nargs), &n);
    nres.* = @intCast(n);
    return st;
}

/// Get coroutine status (lua_status)
pub fn status(L: *state.LuaState, co: *state.LuaState) state.ThreadStatus {
    _ = L;
    return co.status;
}

/// Whether the running function can yield (lua_isyieldable)
pub fn isYieldable(L: *state.LuaState) bool {
    return coroutine_module.isYieldable(L);
}

/// Reset a thread, closing its pending to-be-closed variables (lua_closethread)
pub fn closeThread(L: *state.LuaState, from: ?*state.LuaState) state.ThreadStatus {
    return coroutine_module.closeThread(L, from);
}

/// Push the thread `L` itself, reporting whether it is the main thread
/// (lua_pushthread)
pub fn pushThread(L: *state.LuaState) !bool {
    try pushValue(L, value.TValue.thread(L));
    return L == L.l_G.mainthread;
}

// Garbage collection

/// Garbage collection operations
pub const GCWhat = enum(c_int) {
    stop = 0,
    restart = 1,
    collect = 2,
    count = 3,
    countb = 4,
    step = 5,
    setpause = 6,
    setstepmul = 7,
    isrunning = 9,
    gen = 10,
    inc = 11,
};

/// Switch to generational mode with its parameters (lua_gc LUA_GCGEN);
/// zero keeps a parameter. Returns the previous mode as a `GCWhat` value.
pub fn gcGenerational(L: *state.LuaState, minormul: i32, majormul: i32) i32 {
    const g = &L.l_G.gc;
    const prev: i32 = if (g.isDecGCModeGen()) @intFromEnum(GCWhat.gen) else @intFromEnum(GCWhat.inc); // lapi.c: isdecGCmodegen
    if (minormul != 0) g.genminormul = minormul;
    if (majormul != 0) g.genmajormul = majormul;
    _ = g.changeMode(.generational) catch return -1;
    return prev;
}

/// Switch to incremental mode with its parameters (lua_gc LUA_GCINC)
pub fn gcIncremental(L: *state.LuaState, pause: i32, stepmul: i32, stepsize: i32) i32 {
    const g = &L.l_G.gc;
    const prev: i32 = if (g.isDecGCModeGen()) @intFromEnum(GCWhat.gen) else @intFromEnum(GCWhat.inc); // lapi.c: isdecGCmodegen
    if (pause != 0) g.gcpause = pause;
    if (stepmul != 0) g.gcstepmul = stepmul;
    if (stepsize != 0) g.gcstepsize = @intCast(std.math.clamp(stepsize, 0, 62));
    _ = g.changeMode(.incremental) catch return -1;
    return prev;
}

/// Control garbage collector
pub fn gc(L: *state.LuaState, what: GCWhat, arg: i32) i32 {
    const g = &L.l_G.gc;
    switch (what) {
        .stop => {
            g.stop();
            return 0;
        },
        .restart => {
            g.restart();
            return 0;
        },
        .collect => {
            g.fullGC() catch return -1;
            return 0;
        },
        .count => return @intCast(g.totalbytes / 1024),
        .countb => return @intCast(g.totalbytes % 1024),
        .step => {
            // The collector runs for this step even when it is stopped
            const was_running = g.gcrunning;
            g.gcrunning = true;
            defer g.gcrunning = was_running;
            var debt: isize = 1; // =1 to signal that it did an actual step
            if (arg == 0) {
                g.GCdebt = 0; // do a basic step (a young collection in generational mode)
                g.step() catch return -1;
            } else { // add 'arg' KB to the total debt
                debt = @as(isize, arg) * 1024 + g.GCdebt;
                g.GCdebt = debt;
                g.checkGC() catch return -1;
            }
            return if (debt > 0 and g.state == .pause) 1 else 0; // end of cycle?
        },
        .setpause => return g.setPause(arg),
        .setstepmul => return g.setStepMul(arg),
        .isrunning => return if (g.gcrunning) 1 else 0,
        .gen => return @intFromEnum(g.changeMode(.generational) catch return -1),
        .inc => return @intFromEnum(g.changeMode(.incremental) catch return -1),
    }
}

/// Metamethod `tm` of a value, if any (see vm.getMetamethod)
pub fn getMetamethodOf(L: *state.LuaState, v: *const value.TValue, tm: value.TMS) ?value.TValue {
    return vm.getMetamethod(L, v, tm);
}

// Miscellaneous functions

/// Get next key-value pair
pub fn next(L: *state.LuaState, idx: i32) !bool {
    const t = try index2Value(L, idx);
    const tbl = t.asTable() orelse return APIError.TypeError;
    const key = &(L.top - 1)[0];

    // A key that is not in the table cannot be continued from (luaH_next)
    if (!key.isNil() and tbl.findIndex(key.*) == null) {
        return vm.runtimeError(L, "invalid key to 'next'", .{});
    }
    // Table.next advances `key` in place and reports whether a pair was found
    if (tbl.next(key)) {
        try pushValue(L, tbl.get(key.*));
        return true;
    }

    L.top -= 1;
    return false;
}

/// Concatenate values
pub fn concat(L: *state.LuaState, n: i32) !void {
    if (n >= 2) {
        try vm.concatenate(L, @intCast(n));
    } else if (n == 0) {
        try pushString(L, "");
    }
}

/// Get allocator function
pub fn getAllocf(L: *state.LuaState, ud: *?*anyopaque) state.AllocFn {
    ud.* = L.l_G.ud;
    return L.l_G.frealloc;
}

/// Set allocator function
pub fn setAllocf(L: *state.LuaState, f: state.AllocFn, ud: ?*anyopaque) void {
    L.l_G.frealloc = f;
    L.l_G.ud = ud;
}

/// Get/set panic function
pub fn atPanic(L: *state.LuaState, panicf: ?state.PanicFn) ?state.PanicFn {
    const old = L.l_G.panic;
    L.l_G.panic = panicf;
    return old;
}

/// Get version
pub fn version(L: *state.LuaState) *const f64 {
    _ = L;
    return &config.LUA_VERSION_NUM;
}

// Error handling

/// Throw the value on top of the stack as an error (lua_error).
///
/// Returns the error so it unwinds through Zig's error unions up to the
/// nearest `pcall`, which is what stands in for C's longjmp here.
pub fn error_(L: *state.LuaState) error{LuaError} {
    L.throw(.errrun) catch |err| return err;
    return error.LuaError;
}

/// Throw error with message
pub fn errorMsg(L: *state.LuaState, comptime fmt: []const u8, args: anytype) !noreturn {
    try pushFString(L, fmt, args);
    return error_(L);
}

// Memory and userdata

/// Allocate memory
pub fn newUserdata(L: *state.LuaState, size: usize, nuvalue: i32) !*anyopaque {
    const u = try L.l_G.gc.newUserdata(size, @intCast(@max(nuvalue, 0)));
    try pushValue(L, value.TValue.userdata(u));
    return @ptrCast(u.data);
}

// Global state

/// Get global
pub fn getGlobal(L: *state.LuaState, name: []const u8) !value.ValueType {
    const globals = L.l_G.l_registry.asTable().?.getInt(state.RIDX_GLOBALS).asTable().?;
    const key = try L.l_G.string_pool.intern(name);
    const val = try vm.getTable(L, &value.TValue.table(globals), &value.TValue.string(key));
    try pushValue(L, val);
    return val.tag();
}

/// Table at index, if it is one
pub fn toTable(L: *state.LuaState, idx: i32) ?*value.Table {
    const v = index2Value(L, idx) catch return null;
    return v.asTable();
}

/// Push the globals table
pub fn pushGlobalTable(L: *state.LuaState) !void {
    const globals = L.l_G.l_registry.asTable().?.getInt(state.RIDX_GLOBALS);
    try pushValue(L, globals);
}

/// Set global
pub fn setGlobal(L: *state.LuaState, name: []const u8) !void {
    const globals = L.l_G.l_registry.asTable().?.getInt(state.RIDX_GLOBALS).asTable().?;
    const key = try L.l_G.string_pool.intern(name);
    const val = &(L.top - 1)[0];
    try vm.setTable(L, &value.TValue.table(globals), &value.TValue.string(key), val);
    L.top -= 1;
}

// Registry access

/// Get from registry
pub fn getRegistry(L: *state.LuaState) !void {
    try pushValue(L, L.l_G.l_registry);
}

/// Raw get from registry
pub fn rawGetI_(L: *state.LuaState, idx: i32, n: i64) !void {
    _ = idx;
    const reg = L.l_G.l_registry.asTable().?;
    try pushValue(L, reg.getInt(n));
}

/// Raw set in registry
pub fn rawSetI_(L: *state.LuaState, idx: i32, n: i64) !void {
    _ = idx;
    const reg = L.l_G.l_registry.asTable().?;
    const val = &(L.top - 1)[0];
    try reg.setInt(n, val.*);
    L.top -= 1;
}

// Stack checks

/// Check if stack has space
pub fn checkStack(L: *state.LuaState, n: i32) bool {
    stack.checkStack(L, n) catch return false;
    return true;
}

/// Exchange values between threads
pub fn xmove(from: *state.LuaState, to: *state.LuaState, n: i32) !void {
    if (from == to) return;

    const num = @as(usize, @intCast(n));
    from.top -= num;

    for (0..num) |i| {
        try to.pushValue(from.top[i]);
        from.top[i] = value.TValue.nil();
    }
}

// Helper functions

/// Convert index to value pointer
fn index2Value(L: *state.LuaState, idx: i32) !*value.TValue {
    return stack.index2Stack(L, idx) catch APIError.InvalidIndex;
}

/// Convert index to stack pointer
fn index2Stack(L: *state.LuaState, idx: i32) !*value.TValue {
    const v = try index2Value(L, idx);
    if (@intFromPtr(v) >= @intFromPtr(L.stack) and
        @intFromPtr(v) < @intFromPtr(L.stack) + L.stacksize * @sizeOf(value.TValue))
    {
        return v;
    }
    return APIError.InvalidIndex;
}

/// Check if we have enough arguments
fn checkArgs(L: *state.LuaState, n: i32) !void {
    if (getTop(L) < n) {
        return APIError.InvalidIndex;
    }
}

/// Raw equality check
fn rawEqualValue(v1: *const value.TValue, v2: *const value.TValue) bool {
    return v1.rawEqual(v2.*);
}

/// Arithmetic operation enum for API
pub const ArithOp = enum(c_int) {
    ADD = 0,
    SUB = 1,
    MUL = 2,
    DIV = 3,
    MOD = 4,
    POW = 5,
    UNM = 6,
    IDIV = 7,
    BAND = 8,
    BOR = 9,
    BXOR = 10,
    SHL = 11,
    SHR = 12,
    BNOT = 13,
    LEN = 14,
};

/// Convert API arithmetic op to VM op
fn arithOpToVM(op: ArithOp) vm.ArithOp {
    return switch (op) {
        .ADD => .add,
        .SUB => .sub,
        .MUL => .mul,
        .DIV => .div,
        .MOD => .mod,
        .POW => .pow,
        .UNM => .unm,
        .IDIV => .idiv,
        .BAND => .band,
        .BOR => .bor,
        .BXOR => .bxor,
        .SHL => .shl,
        .SHR => .shr,
        .BNOT => .bnot,
        .LEN => unreachable, // Handled separately
    };
}

/// Compare operation enum
pub const CompareOp = enum(c_int) {
    EQ = 0,
    LT = 1,
    LE = 2,
};

/// Convert API compare op to VM op
fn compareOpToVM(op: CompareOp) vm.CompareOp {
    return switch (op) {
        .EQ => .eq,
        .LT => .lt,
        .LE => .le,
    };
}

/// Writer function type
pub const WriterFn = dump_module.WriterFn;

// Tests

test "basic stack operations" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Test push/pop
    try pushInteger(L, 42);
    try pushNumber(L, 3.14);
    try pushString(L, "hello");

    try std.testing.expect(getTop(L) == 3);

    // Test type checking
    try std.testing.expect(isInteger(L, 1));
    try std.testing.expect(isNumber(L, 2));
    try std.testing.expect(isString(L, 3));

    // Test conversion
    try std.testing.expect(toInteger(L, 1).? == 42);
    try std.testing.expect(toNumber(L, 2).? == 3.14);
    try std.testing.expect(mem.eql(u8, toString(L, 3).?, "hello"));

    // Test pop
    pop(L, 2);
    try std.testing.expect(getTop(L) == 1);
}

test "table operations" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Create table
    try newTable(L);

    // Set field
    try pushString(L, "value");
    try setField(L, -2, "key");

    // Get field
    _ = try getField(L, -1, "key");
    try std.testing.expect(isString(L, -1));
    try std.testing.expect(mem.eql(u8, toString(L, -1).?, "value"));

    pop(L, 1);

    // Set integer index
    try pushInteger(L, 100);
    try setI(L, -2, 1);

    // Get integer index
    try getI(L, -1, 1);
    try std.testing.expect(toInteger(L, -1).? == 100);
}

test "load compiles a chunk into a callable function" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    try std.testing.expectEqual(ThreadStatus.ok, load(L, "return 1 + 1", "=chunk"));
    try std.testing.expect(isFunction(L, -1));

    try call(L, 0, 1);
    try std.testing.expectEqual(@as(i64, 2), toInteger(L, -1).?);
}

test "load reports a syntax error instead of a bare .ok" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    const st = load(L, "return 1 +", "=chunk");
    try std.testing.expect(st != .ok);
    // The message, not a function, is what is left behind
    try std.testing.expect(!isFunction(L, -1));
    try std.testing.expect(isString(L, -1));
    try std.testing.expect(mem.startsWith(u8, toString(L, -1).?, "chunk:1:"));
}

test "load honours the mode argument" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Text source refused when only binary is allowed
    try std.testing.expect(loadBuffer(L, "return 1", "=chunk", "b") != .ok);
    pop(L, 1);

    // A binary chunk is refused rather than silently mis-parsed as text
    try std.testing.expect(loadBuffer(L, "\x1bLua\x54", "=chunk", "bt") != .ok);
    pop(L, 1);

    try std.testing.expectEqual(ThreadStatus.ok, loadBuffer(L, "return 1", "=chunk", "bt"));
}

test "checkAny accepts an explicit nil" {
    const allocator = std.testing.allocator;
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Only an absent argument is an error, so `print(nil)` and the `nil, msg`
    // that `load` returns on failure must both get through.
    try pushNil(L);
    try checkAny(L, 1);
    try std.testing.expectEqual(@as(i32, 1), getTop(L));
}

// Type checking and argument validation

/// Check that an argument was supplied at all. An explicit nil counts as a
/// value; only an absent argument is rejected (luaL_checkany).
pub fn checkAny(L: *state.LuaState, idx: i32) !void {
    if (idx > 0 and idx > getTop(L)) {
        return argError(L, idx, "value expected");
    }
}

/// Check and return string
pub fn checkString(L: *state.LuaState, idx: i32) ![]const u8 {
    if (try toStringCoerce(L, idx)) |s| {
        return s;
    }
    return typeError(L, idx, "string");
}

/// Report "<expected> expected, got <actual>" for the argument at `idx`
/// (luaL_typeerror). A `__name` metafield names the actual type.
pub fn typeError(L: *state.LuaState, idx: i32, expected: []const u8) error{LuaError} {
    var actual: []const u8 = undefined;
    if (idx > 0 and idx > getTop(L)) {
        actual = "no value";
    } else if (type_(L, idx) == .light_userdata) {
        actual = "light userdata";
    } else {
        const v = index2Value(L, idx) catch return error.LuaError;
        actual = debug.objTypeName(L, v);
    }
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} expected, got {s}", .{ expected, actual }) catch expected;
    return argError(L, idx, msg);
}

/// Check and return integer
pub fn checkInteger(L: *state.LuaState, idx: i32) !i64 {
    if (toInteger(L, idx)) |i| {
        return i;
    }
    // A number that simply has no integer representation is its own error in
    // Lua, distinct from being the wrong type altogether
    if (isNumber(L, idx)) {
        return argError(L, idx, "number has no integer representation");
    }
    return typeError(L, idx, "number");
}

/// Check and return number
pub fn checkNumber(L: *state.LuaState, idx: i32) !f64 {
    if (toNumber(L, idx)) |n| {
        return n;
    }
    return typeError(L, idx, "number");
}

/// Check type at index
pub fn checkType(L: *state.LuaState, idx: i32, t: value.ValueType) !void {
    if (type_(L, idx) != t) {
        return typeError(L, idx, typeName(L, t));
    }
}

/// Check option in string array
pub fn checkOption(L: *state.LuaState, idx: i32, def: ?[]const u8, lst: []const []const u8) !usize {
    // `def == null` means the argument is required, matching luaL_checkoption.
    // An absent argument otherwise takes the default, not just an explicit nil;
    // isNil alone reports false for an out-of-range index.
    const name = if (idx > getTop(L) or isNil(L, idx))
        (def orelse return typeError(L, idx, "string"))
    else
        try checkString(L, idx);

    for (lst, 0..) |option, i| {
        if (std.mem.eql(u8, name, option)) {
            return i;
        }
    }

    var msg_buf: [100]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "invalid option '{s}'", .{name});
    return argError(L, idx, msg);
}

/// Position to blame for an error raised inside a native function, formatted
/// as "chunkname:line: " (luaL_where at level 1).
///
/// A native function is not itself a source position, so the caller's frame is
/// what a user can act on. Returns an empty string when no Lua frame is
/// running, which is what makes `error("x", 0)` and errors from the C boundary
/// come out unprefixed.
pub const WHERE_SIZE = vm.IDSIZE + 32;

pub fn where(L: *state.LuaState, buf: []u8) []const u8 {
    return whereLevel(L, 1, buf);
}

/// "source:line: " for the function at stack `level` (luaL_where): level 0
/// is the running function, 1 its caller, and so on. Empty when that
/// function is not Lua code, or has no line information.
pub fn whereLevel(L: *state.LuaState, level: i64, buf: []u8) []const u8 {
    var ci: ?*state.CallInfo = L.ci;
    var n = level;
    while (n > 0 and ci != null) : (n -= 1) ci = ci.?.previous;
    const frame = ci orelse return "";
    if (frame == &L.base_ci or !frame.callstatus.isLua) return "";
    const cl = frame.func[0].asClosure() orelse return "";
    const line = vm.currentLine(frame);
    if (line <= 0) return ""; // no line information
    var idbuf: [vm.IDSIZE]u8 = undefined;
    const id = if (cl.proto.source) |s| vm.shortSource(&idbuf, s.slice()) else "?";
    return std.fmt.bufPrint(buf, "{s}:{d}: ", .{ id, line }) catch "";
}

/// Report a bad argument as a catchable Lua error (luaL_argerror).
///
/// The function is named the way it was called when the caller is Lua code
/// (`rep` for `string.rep(...)`, `rep` as a method for `s:rep(...)`, in which
/// case `self` is not counted), and by its qualified name in the loaded
/// modules otherwise (`string.rep` under `pcall`).
pub fn argError(L: *state.LuaState, arg_in: i32, msg: []const u8) error{LuaError} {
    var namebuf: [128]u8 = undefined;
    var wherebuf: [WHERE_SIZE]u8 = undefined;
    var buf: [WHERE_SIZE + 512]u8 = undefined;

    const w = where(L, &wherebuf);
    var arg = arg_in;
    const ci = debug.getStack(L, 0) orelse {
        const full = std.fmt.bufPrint(&buf, "{s}bad argument #{d} ({s})", .{ w, arg, msg }) catch msg;
        pushString(L, full) catch return error.LuaError;
        return error_(L);
    };
    var ar = debug.Info{};
    debug.getInfo(L, "n", ci, value.TValue.nil(), &ar) catch {};
    if (mem.eql(u8, ar.namewhat, "method")) {
        arg -= 1; // do not count `self`
        if (arg == 0) {
            const full = std.fmt.bufPrint(&buf, "{s}calling '{s}' on bad self ({s})", .{ w, ar.name orelse "?", msg }) catch msg;
            pushString(L, full) catch return error.LuaError;
            return error_(L);
        }
    }
    const name = ar.name orelse debug.globalFuncName(L, ci.func[0], &namebuf) orelse "?";
    const full = std.fmt.bufPrint(&buf, "{s}bad argument #{d} to '{s}' ({s})", .{ w, arg, name, msg }) catch msg;
    pushString(L, full) catch return error.LuaError;
    return error_(L);
}

/// Push `s` parsed as a Lua numeral, reporting whether it was one
/// (lua_stringtonumber).
///
/// Delegates to the VM's parser rather than Zig's: `std.fmt` trims nothing,
/// reads `0x1F` as a float, and accepts `inf` and `nan`, none of which match
/// Lua. Sharing the parser also keeps `tonumber` and arithmetic coercion in
/// agreement about what a numeral is.
pub fn stringToNumber(L: *state.LuaState, s: []const u8) bool {
    const n = vm.stringToNumber(s) orelse return false;
    switch (n) {
        .integer => |i| pushInteger(L, i) catch return false,
        .float => |f| pushNumber(L, f) catch return false,
    }
    return true;
}

/// Get metamethod field
pub fn getMetafield(L: *state.LuaState, obj: i32, field: []const u8) !bool {
    if (!getMetatable(L, obj)) {
        return false;
    }

    _ = try getField(L, -1, field);
    if (isNil(L, -1)) {
        pop(L, 2); // Remove metatable and nil
        return false;
    }

    remove(L, -2) catch {}; // Remove metatable, keep field
    return true;
}

/// Load Lua chunk (lua_load)
pub fn load(L: *state.LuaState, source: []const u8, chunkname: []const u8) ThreadStatus {
    return loadBuffer(L, source, chunkname, "bt");
}

/// Assign the value on top of the stack to the `n`-th upvalue (1-based) of the
/// function at `funcindex`, popping it, and return the upvalue's name
/// (lua_setupvalue).
///
/// Nothing is popped and null is returned when the function has no such
/// upvalue. This is what gives `load`'s and `loadfile`'s `env` argument its
/// effect, by rebinding `_ENV`.
pub fn setUpvalue(L: *state.LuaState, funcindex: i32, n: i32) ?[]const u8 {
    if (n < 1) return null;
    const fval = index2Value(L, funcindex) catch return null;
    const cl = fval.asClosure() orelse return null;
    const idx: u8 = @intCast(n - 1);
    if (idx >= cl.nupvalues) return null;

    const val = (L.top - 1)[0];
    if (cl.upvals[idx]) |uv| {
        uv.getValue().* = val;
    } else {
        cl.upvals[idx] = closure_module.newClosedUpvalue(L, val) catch return null;
    }
    L.l_G.gc.barrier(&cl.header, &val);
    pop(L, 1);
    return upvalueName(L, funcindex, n) orelse "(no name)"; // stripped debug info (aux_upvalue)
}

/// Push the `n`-th upvalue of the function at `funcindex` and return its name
/// (lua_getupvalue). Pushes nothing and returns null when there is no such
/// upvalue.
pub fn getUpvalue(L: *state.LuaState, funcindex: i32, n: i32) ?[]const u8 {
    if (n < 1) return null;
    const fval = index2Value(L, funcindex) catch return null;

    if (fval.asClosure()) |cl| {
        const idx: u8 = @intCast(n - 1);
        if (idx >= cl.nupvalues) return null;
        const v = if (cl.upvals[idx]) |uv| uv.getValue().* else value.TValue.nil();
        pushValue(L, v) catch return null;
        return upvalueName(L, funcindex, n) orelse "(no name)"; // stripped debug info (aux_upvalue)
    }
    if (fval.asCClosure()) |cl| {
        const idx: u8 = @intCast(n - 1);
        if (idx >= cl.nupvalues) return null;
        pushValue(L, cl.upvals[idx]) catch return null;
        return ""; // C closures carry no upvalue names
    }
    return null;
}

/// Debug name of an upvalue, when the prototype recorded one
pub fn upvalueName(L: *state.LuaState, funcindex: i32, n: i32) ?[]const u8 {
    if (n < 1) return null;
    const fval = index2Value(L, funcindex) catch return null;
    const cl = fval.asClosure() orelse return null;
    const idx: usize = @intCast(n - 1);
    if (idx >= cl.proto.sizeupvalues or idx >= cl.proto.upvalues.len) return null;
    const name = cl.proto.upvalues[idx].name orelse return null;
    return name.slice();
}
