// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Call Stack Implementation
//!
//! This module implements stack manipulation, call frame management, and
//! related operations for the VM. It handles the value stack, call info
//! chain, and provides utilities for stack operations.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const math = std.math;

const value = @import("value.zig");
const state = @import("state.zig");
const config = @import("config.zig");
const proto = @import("proto.zig");
const opcode = @import("opcode.zig");
const table = @import("table.zig");
const closure = @import("closure.zig");

/// Stack constants
pub const EXTRA_STACK = 5;
pub const MAXSTACK = 1000000;
pub const ERRORSTACKSIZE = MAXSTACK + 200;
pub const MIN_STACK = 20;

/// Registry indices
pub const REGISTRY_INDEX = -MAXSTACK - 1000;
pub const FIRSTPSEUDOIDX = REGISTRY_INDEX;
pub const LAST_RESERVED = REGISTRY_INDEX;

/// Error types
pub const StackError = error{
    StackOverflow,
    StackUnderflow,
    InvalidIndex,
    NotEnoughSpace,
    TooManyArguments,
    TooManyResults,
    NoFunction,
};

/// Stack manipulation functions
/// Check if stack has space for n extra slots
pub fn checkStack(L: *state.LuaState, n: i32) !void {
    const space = @intFromPtr(L.stack_last) - @intFromPtr(L.top);
    if (space < @as(usize, @intCast(n)) * @sizeOf(value.TValue)) {
        try growStack(L, n);
    }
}

/// Grow stack to accommodate n extra values
pub fn growStack(L: *state.LuaState, n: i32) !void {
    const size = L.stacksize;
    const needed = (@intFromPtr(L.top) - @intFromPtr(L.stack)) / @sizeOf(value.TValue) + @as(usize, @intCast(n)) + EXTRA_STACK;

    if (size > MAXSTACK) {
        return StackError.StackOverflow;
    }

    const newsize = if (size >= MAXSTACK / 2)
        MAXSTACK
    else
        @min(size * 2, MAXSTACK);

    const realsize = if (newsize < needed) needed else newsize;

    if (realsize > MAXSTACK) {
        return StackError.StackOverflow;
    }

    try reallocStack(L, @intCast(realsize));
}

/// Reallocate stack
pub fn reallocStack(L: *state.LuaState, newsize: u32) !void {
    assert(newsize <= MAXSTACK or newsize == ERRORSTACKSIZE);

    const old_stack = L.stack;
    const old_size = L.stacksize;

    // Allocate new stack
    const new_stack = try L.allocator.alloc(value.TValue, newsize);

    // Copy the part that survives (all of it when growing, the used prefix
    // when shrinking after an overflow) and clear the rest
    const keep = @min(old_size, newsize);
    @memcpy(new_stack[0..keep], old_stack[0..keep]);
    for (new_stack[keep..]) |*slot| {
        slot.* = value.TValue.nil();
    }

    // Calculate pointer difference
    const diff = @intFromPtr(new_stack.ptr) -% @intFromPtr(old_stack);

    // Update all pointers
    L.stack = new_stack.ptr;
    L.stacksize = newsize;
    L.stack_last = L.stack + newsize - EXTRA_STACK;
    L.top = @ptrFromInt(@intFromPtr(L.top) +% diff);

    // Update call info pointers
    var ci: ?*state.CallInfo = &L.base_ci;
    while (ci) |c| : (ci = c.next) {
        c.func = @ptrFromInt(@intFromPtr(c.func) +% diff);
        c.top = @ptrFromInt(@intFromPtr(c.top) +% diff);
        if (c.callstatus.isLua) {
            if (c.u.l.savedpc != null) {
                // savedpc points to Proto's code, not stack
            }
        }
        if (c.extra != null) {
            c.extra = @ptrFromInt(@intFromPtr(c.extra.?) +% diff);
        }
    }

    // Update open upvalues
    correctUpvalues(L, old_stack);

    // Free old stack
    L.allocator.free(old_stack[0..old_size]);
}

/// Correct upvalue pointers after stack reallocation
fn correctUpvalues(L: *state.LuaState, old_stack: [*]value.TValue) void {
    const diff = @intFromPtr(L.stack) -% @intFromPtr(old_stack);

    // Open upvalues always point into the stack; shift them with it.
    var uv = L.openupval;
    while (uv) |u| : (uv = u.u.open.next) {
        if (u.isOpen()) {
            u.p = @ptrFromInt(@intFromPtr(u.p) +% diff);
        }
    }
}

/// Shrink stack to its current usage
pub fn shrinkStack(L: *state.LuaState) void {
    const inuse = stackInUse(L);
    if (inuse > MAXSTACK) return; // still handling a stack overflow: keep the extra space
    const goodsize = inuse + @divTrunc(inuse, 8) + 2 * EXTRA_STACK;

    if (goodsize < L.stacksize) {
        const size = if (goodsize > MAXSTACK / 2)
            MAXSTACK
        else if (goodsize < MIN_STACK)
            MIN_STACK
        else
            goodsize;

        reallocStack(L, size) catch {
            // If shrinking fails, keep current size
        };
    }
}

/// Calculate stack slots in use
pub fn stackInUse(L: *const state.LuaState) u32 {
    var lim = L.top;
    // Only the active frames count (stackinuse): the CallInfo chain keeps
    // finished frames for reuse, and their `top` fields are stale
    var ci: ?*const state.CallInfo = L.ci;
    while (ci) |c| : (ci = c.previous) {
        if (@intFromPtr(lim) < @intFromPtr(c.top)) lim = c.top;
    }
    const used = (@intFromPtr(lim) - @intFromPtr(L.stack)) / @sizeOf(value.TValue);
    return @intCast(@max(used + 1, MIN_STACK)); // +1 to include lim
}

/// Index conversion functions
/// Check if index is valid
pub fn isValidIndex(L: *const state.LuaState, idx: i32) bool {
    if (idx > 0) {
        const ci = L.ci;
        const o = ci.func + @as(usize, @intCast(idx));
        return @intFromPtr(o) < @intFromPtr(L.top); // top itself is the first free slot
    } else if (idx < 0 and idx > REGISTRY_INDEX) {
        const ci = L.ci;
        const o = @intFromPtr(L.top) - @as(usize, @intCast(-idx)) * @sizeOf(value.TValue);
        const base = @intFromPtr(ci.func + 1);
        return o >= base;
    } else if (idx == REGISTRY_INDEX) {
        return true;
    }
    return false;
}

/// Convert acceptable index to absolute index
pub fn absIndex(L: *const state.LuaState, idx: i32) i32 {
    if (idx > 0 or idx <= REGISTRY_INDEX) {
        return idx;
    } else {
        const rel = @as(i32, @intCast((@intFromPtr(L.top) - @intFromPtr(L.ci.func + 1)) / @sizeOf(value.TValue)));
        return rel + idx + 1;
    }
}

/// Convert index to pointer
pub fn index2Stack(L: *state.LuaState, idx: i32) !*value.TValue {
    if (idx > 0) {
        const o = L.ci.func + @as(usize, @intCast(idx));
        if (@intFromPtr(o) >= @intFromPtr(L.top)) {
            return StackError.InvalidIndex;
        }
        return &o[0];
    } else if (idx < 0 and idx > REGISTRY_INDEX) {
        const o = L.top - @as(usize, @intCast(-idx));
        if (@intFromPtr(o) < @intFromPtr(L.ci.func + 1)) {
            return StackError.InvalidIndex;
        }
        return &o[0];
    } else if (idx == REGISTRY_INDEX) {
        return &L.l_G.l_registry;
    } else {
        // Upvalue pseudo-index: lua_upvalueindex(i) == REGISTRY_INDEX - i
        return index2Upvalue(L, REGISTRY_INDEX - idx);
    }
}

/// Get upvalue from index
/// Upvalue `n` (1-based) of the running C closure
pub fn index2Upvalue(L: *state.LuaState, n: i32) !*value.TValue {
    const func = L.ci.func[0];
    const cl = func.asCClosure() orelse return StackError.InvalidIndex;
    if (n < 1 or n > cl.nupvalues) return StackError.InvalidIndex;
    return &cl.upvals[@intCast(n - 1)];
}

/// Value stack operations
/// Push a value onto the stack
pub fn push(L: *state.LuaState, v: value.TValue) !void {
    L.top[0] = v;
    try incTop(L);
}

/// Pop n values from stack
pub fn pop(L: *state.LuaState, n: u32) void {
    assert(@intFromPtr(L.top) - n * @sizeOf(value.TValue) >= @intFromPtr(L.ci.func + 1));
    L.top -= n;
}

/// Increment top (with stack check)
pub fn incTop(L: *state.LuaState) !void {
    L.top += 1;
    if (@intFromPtr(L.top) > @intFromPtr(L.stack_last)) {
        L.top -= 1;
        try growStack(L, 1);
        L.top += 1;
    }
}

/// Move value from one stack slot to another
pub fn move(from: *value.TValue, to: *value.TValue) void {
    to.* = from.*;
}

/// Copy n values from one location to another
pub fn moveValues(from: [*]value.TValue, to: [*]value.TValue, n: usize) void {
    if (@intFromPtr(from) < @intFromPtr(to)) {
        // Copy backwards to handle overlap
        var i = n;
        while (i > 0) : (i -= 1) {
            to[i - 1] = from[i - 1];
        }
    } else if (@intFromPtr(from) > @intFromPtr(to)) {
        // Copy forwards
        for (0..n) |i| {
            to[i] = from[i];
        }
    }
}

/// Reverse n elements from the top
pub fn reverse(L: *state.LuaState, from: [*]value.TValue, to: [*]value.TValue) void {
    _ = L;
    var f = from;
    var t = to;
    while (@intFromPtr(f) < @intFromPtr(t)) : ({
        f += 1;
        t -= 1;
    }) {
        const temp = f[0];
        f[0] = t[0];
        t[0] = temp;
    }
}

/// Call frame management
/// Get current call info
pub fn getCurrentCI(L: *state.LuaState) *state.CallInfo {
    return L.ci;
}

/// Enter the next CallInfo, reusing one from the chain when there is one
/// (luaE_extendCI's `next_ci`)
pub inline fn nextCI(L: *state.LuaState) !*state.CallInfo {
    if (L.ci.next) |next| {
        L.ci = next;
        return next;
    }
    return newCI(L);
}

/// Allocate a fresh CallInfo, link it after the current one and enter it
/// (luaE_extendCI). Kept out of line: it runs once per new call depth.
pub fn newCI(L: *state.LuaState) !*state.CallInfo {
    @branchHint(.cold);
    const ci = try L.allocator.create(state.CallInfo);
    ci.* = state.CallInfo.init();
    ci.previous = L.ci;
    ci.next = null;
    L.ci.next = ci;
    L.ci = ci;
    L.nci += 1;
    return ci;
}

/// Return to previous call info
pub fn previousCI(L: *state.LuaState) void {
    const ci = L.ci;
    L.ci = ci.previous orelse &L.base_ci;
    // Note: we don't free the CallInfo, it's kept in the chain for reuse
}

/// Prepare call frame for Lua function
pub fn prepareCallFrame(
    L: *state.LuaState,
    func: [*]value.TValue,
    nargs: u32,
    nresults: i16,
    p: *proto.Proto,
) !*state.CallInfo {
    const ci = try nextCI(L);

    ci.func = func;
    ci.nresults = nresults;
    ci.callstatus = .{ .isLua = true, .isFresh = true };

    // Setup Lua-specific info
    const base = func + 1;
    ci.top = base + p.maxstacksize;

    // Ensure stack space
    const needed = @intFromPtr(ci.top) - @intFromPtr(L.stack);
    if (needed > L.stacksize * @sizeOf(value.TValue)) {
        const n = (needed - @intFromPtr(L.top) + @intFromPtr(L.stack)) / @sizeOf(value.TValue);
        try growStack(L, @intCast(n));
    }

    // Move fixed parameters
    const nfixparams = p.numparams;
    const actual = if (nargs > nfixparams) nfixparams else nargs;

    var i: u32 = 0;
    while (i < actual) : (i += 1) {
        move(&func[i + 1], &base[i]);
    }

    // Fill missing parameters with nil
    while (i < nfixparams) : (i += 1) {
        base[i] = value.TValue.nil();
    }

    // Handle varargs
    if (p.is_vararg) {
        ci.extra = func + 1 + nfixparams;
        // Copy extra args after fixed params
        var j: u32 = 0;
        while (j < nargs - nfixparams and @intFromPtr(ci.extra.? + j) < @intFromPtr(L.top)) : (j += 1) {
            move(&func[1 + nfixparams + j], &ci.extra.?[j]);
        }
        L.top = ci.extra.? + j;
    } else {
        ci.extra = null;
        L.top = base + nfixparams;
    }

    ci.u.l.savedpc = p.code.ptr;
    ci.callstatus.isFresh = true;

    return ci;
}

/// Prepare call frame for C function
pub fn prepareCCallFrame(
    L: *state.LuaState,
    func: [*]value.TValue,
    _: u32, // nargs - unused for C functions
    nresults: i16,
) !*state.CallInfo {
    const ci = try nextCI(L);

    ci.func = func;
    ci.nresults = nresults;
    ci.callstatus = .{ .isLua = false };
    ci.top = L.top + config.MINSTACK;

    // Ensure stack space
    try checkStack(L, config.MINSTACK);

    // Setup C-specific info
    ci.u.c.k = null;
    ci.u.c.ctx = 0;
    ci.u.c.old_errfunc = L.errfunc;

    return ci;
}

/// Finish call (adjust results)
pub fn finishCall(L: *state.LuaState, ci: *state.CallInfo, nres: i32) i32 {
    const wanted = ci.nresults;
    const firstResult = ci.func;

    // Move results to proper place
    var i: i32 = 0;
    const actual_nres = if (wanted == -1) nres else @min(nres, wanted);

    while (i < actual_nres) : (i += 1) {
        move(&L.top[@intCast(-nres + i)], &firstResult[@intCast(i)]);
    }

    // Pad with nils or adjust top
    if (wanted == -1) {
        L.top = firstResult + @as(usize, @intCast(nres));
    } else {
        while (i < wanted) : (i += 1) {
            firstResult[@intCast(i)] = value.TValue.nil();
        }
        L.top = firstResult + @as(usize, @intCast(wanted));
    }

    // Return to previous call info
    previousCI(L);

    return if (wanted == -1) nres else wanted;
}

/// Move results for return
pub fn moveResults(L: *state.LuaState, firstResult: [*]value.TValue, nres: i32, wanted: i16) i32 {
    switch (wanted) {
        0 => {}, // Nothing wanted
        1 => {
            if (nres == 0) {
                firstResult[0] = value.TValue.nil();
            } else {
                move(&L.top[@intCast(-nres)], &firstResult[0]);
            }
        },
        -1 => {
            // All results wanted
            var i: i32 = 0;
            while (i < nres) : (i += 1) {
                move(&L.top[@intCast(-nres + i)], &firstResult[@intCast(i)]);
            }
            L.top = firstResult + @as(usize, @intCast(nres));
            return nres;
        },
        else => {
            // Specific number wanted
            var i: i32 = 0;
            const n = @min(nres, wanted);
            while (i < n) : (i += 1) {
                move(&L.top[@intCast(-nres + i)], &firstResult[@intCast(i)]);
            }
            while (i < wanted) : (i += 1) {
                firstResult[@intCast(i)] = value.TValue.nil();
            }
        },
    }

    L.top = firstResult + @as(usize, @intCast(if (wanted < 0) nres else wanted));
    return if (wanted < 0) nres else wanted;
}

/// Stack debugging
/// Dump stack for debugging
pub fn dumpStack(L: *state.LuaState, writer: anytype) !void {
    try writer.print("=== Stack dump ===\n", .{});
    try writer.print("Stack size: {}, Top: {}\n", .{
        L.stacksize,
        (@intFromPtr(L.top) - @intFromPtr(L.stack)) / @sizeOf(value.TValue),
    });

    var ci: ?*state.CallInfo = &L.base_ci;
    var level: u32 = 0;

    while (ci) |c| : ({
        ci = c.next;
        level += 1;
    }) {
        try writer.print("\nLevel {}: ", .{level});
        if (c.callstatus.isLua) {
            try writer.print("Lua function\n", .{});
            try writer.print("  Base: {}, Top: {}\n", .{
                (@intFromPtr((c.func + 1)) - @intFromPtr(L.stack)) / @sizeOf(value.TValue),
                (@intFromPtr(c.top) - @intFromPtr(L.stack)) / @sizeOf(value.TValue),
            });

            // Dump locals
            const base = (c.func + 1);
            const top = if (c.next) |next| next.func else L.top;
            var i: usize = 0;
            while (@intFromPtr(base + i) < @intFromPtr(top)) : (i += 1) {
                const slot = (@intFromPtr(base + i) - @intFromPtr(L.stack)) / @sizeOf(value.TValue);
                try writer.print("  [{d:3}] ", .{slot});
                try dumpValue(writer, base[i]);
                try writer.print("\n", .{});
            }
        } else {
            try writer.print("C function\n", .{});
        }
    }
}

/// Dump a single value
fn dumpValue(writer: anytype, v: value.TValue) !void {
    switch (v.tag()) {
        .nil => try writer.print("nil", .{}),
        .boolean => try writer.print("{}", .{v.booleanValue()}),
        .number => {
            switch (v.numberValue()) {
                .integer => |i| try writer.print("{d}", .{i}),
                .float => |f| try writer.print("{d}", .{f}),
            }
        },
        .string => try writer.print("\"{s}\"", .{v.stringValue().slice()}),
        .table => try writer.print("table:0x{x}", .{@intFromPtr(v.tableValue())}),
        .function => {
            try writer.print("function:0x{x}", .{v.rawPointer()});
        },
        .thread => try writer.print("thread:0x{x}", .{@intFromPtr(v.threadValue())}),
        .userdata => try writer.print("userdata:0x{x}", .{@intFromPtr(v.userdataValue())}),
        .light_userdata => try writer.print("lightuserdata:0x{x}", .{@intFromPtr(v.asLightUserdata().?)}),
        else => try writer.print("<{s}>", .{v.tag().name()}),
    }
}

/// Get info about local variable
pub fn getLocalName(ci: *state.CallInfo, n: u32) ?[]const u8 {
    if (!ci.callstatus.isLua) return null;

    // Would need debug info from Proto
    _ = n;
    return null;
}

/// Stack invariant checking (debug builds only)
pub fn checkStackConsistency(L: *state.LuaState) void {
    if (@import("builtin").mode != .Debug) return;

    // Basic pointer checks
    assert(@intFromPtr(L.stack) <= @intFromPtr(L.top));
    assert(@intFromPtr(L.top) <= @intFromPtr(L.stack_last));
    assert(@intFromPtr(L.stack_last) < @intFromPtr(L.stack + L.stacksize));

    // Check all call infos
    var ci: ?*state.CallInfo = &L.base_ci;
    while (ci) |c| : (ci = c.next) {
        assert(@intFromPtr(c.func) >= @intFromPtr(L.stack));
        assert(@intFromPtr(c.func) < @intFromPtr(L.stack + L.stacksize));
        assert(@intFromPtr(c.top) >= @intFromPtr(c.func));
        assert(@intFromPtr(c.top) <= @intFromPtr(L.stack + L.stacksize));

        if (c.callstatus.isLua) {
            assert(@intFromPtr((c.func + 1)) >= @intFromPtr(c.func));
            assert(@intFromPtr((c.func + 1)) <= @intFromPtr(c.top));
        }
    }
}

// Tests

test "stack growth" {
    const allocator = std.testing.allocator;

    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    const initial_size = L.stacksize;

    // Force stack growth
    try checkStack(L, @intCast(initial_size));

    try std.testing.expect(L.stacksize > initial_size);
}

test "index conversion" {
    const allocator = std.testing.allocator;

    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Push some values
    try push(L, value.TValue.integer(1));
    try push(L, value.TValue.integer(2));
    try push(L, value.TValue.integer(3));

    // Test positive indices
    try std.testing.expect(isValidIndex(L, 1));
    try std.testing.expect(isValidIndex(L, 2));
    try std.testing.expect(isValidIndex(L, 3));
    try std.testing.expect(!isValidIndex(L, 4));

    // Test negative indices
    try std.testing.expect(isValidIndex(L, -1));
    try std.testing.expect(isValidIndex(L, -2));
    try std.testing.expect(isValidIndex(L, -3));
    try std.testing.expect(!isValidIndex(L, -4));

    // Test absolute index conversion
    try std.testing.expect(absIndex(L, -1) == 3);
    try std.testing.expect(absIndex(L, -2) == 2);
    try std.testing.expect(absIndex(L, -3) == 1);
    try std.testing.expect(absIndex(L, 1) == 1);
    try std.testing.expect(absIndex(L, 2) == 2);
    try std.testing.expect(absIndex(L, 3) == 3);
}

test "stack operations" {
    const allocator = std.testing.allocator;

    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Test push/pop
    try push(L, value.TValue.integer(42));
    try push(L, value.TValue.float(3.14));
    try push(L, value.TValue.boolean(true));

    try std.testing.expect(L.getTop() == 3);

    pop(L, 1);
    try std.testing.expect(L.getTop() == 2);

    // Test index2Stack
    const v1 = try index2Stack(L, 1);
    try std.testing.expect(v1.asInteger().? == 42);

    const v2 = try index2Stack(L, -1);
    try std.testing.expect(v2.asFloat().? == 3.14);

    // Test reverse
    try push(L, value.TValue.integer(1));
    try push(L, value.TValue.integer(2));
    try push(L, value.TValue.integer(3));

    reverse(L, L.top - 3, L.top - 1);

    const r1 = try index2Stack(L, -3);
    const r2 = try index2Stack(L, -2);
    const r3 = try index2Stack(L, -1);

    try std.testing.expect(r1.asInteger().? == 3);
    try std.testing.expect(r2.asInteger().? == 2);
    try std.testing.expect(r3.asInteger().? == 1);
}

test "call frame management" {
    const allocator = std.testing.allocator;

    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Create a dummy proto
    var p = try proto.Proto.init(allocator);
    defer p.deinit(allocator);

    p.numparams = 2;
    p.maxstacksize = 10;
    p.is_vararg = false;

    // Push a placeholder in the function slot and two arguments; the frame
    // setup under test does not read the function value
    try push(L, value.TValue.nil());
    try push(L, value.TValue.integer(10));
    try push(L, value.TValue.integer(20));

    // Prepare call frame
    const func = L.top - 3;
    const ci = try prepareCallFrame(L, func, 2, 1, p);

    try std.testing.expect(ci.callstatus.isLua);
    try std.testing.expect(ci.nresults == 1);

    // Check parameters were moved
    const base = (ci.func + 1);
    try std.testing.expect(base[0].asInteger().? == 10);
    try std.testing.expect(base[1].asInteger().? == 20);
}
