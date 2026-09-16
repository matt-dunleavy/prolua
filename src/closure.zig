// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Closure and Upvalue Implementation

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const value = @import("value.zig");
const state = @import("state.zig");
const proto = @import("proto.zig");
const gc = @import("gc.zig");
const vm = @import("vm.zig");
const table = @import("table.zig");
const config = @import("config.zig");

/// Closure types
pub const ClosureType = enum {
    lua, // Lua closure
    c, // C closure
};

/// Base closure structure
pub const ClosureHeader = struct {
    header: value.GCObject,
    nupvalues: u8,
};

/// Lua closure
pub const LClosure = struct {
    header: value.GCObject,
    gclist: ?*value.GCObject = null, // link in the gray / grayagain lists
    nupvalues: u8,
    proto: *proto.Proto,
    upvals: [*]?*Upvalue, // null until `createClosure` fills the slot

    /// Get upvalue at index
    pub fn getUpvalue(self: *const LClosure, idx: u8) *Upvalue {
        assert(idx < self.nupvalues);
        return self.upvals[idx].?;
    }

    /// Get upvalue array as slice
    pub fn upvalueSlice(self: *LClosure) []?*Upvalue {
        return self.upvals[0..self.nupvalues];
    }
};

/// C closure
pub const CClosure = struct {
    header: value.GCObject,
    gclist: ?*value.GCObject = null, // link in the gray / grayagain lists
    nupvalues: u8,
    f: state.CFunction,
    upvals: [*]value.TValue,

    /// Get upvalue at index
    pub fn getUpvalue(self: *const CClosure, idx: u8) value.TValue {
        assert(idx < self.nupvalues);
        return self.upvals[idx];
    }

    /// Get upvalue array as slice
    pub fn upvalueSlice(self: *CClosure) []value.TValue {
        return self.upvals[0..self.nupvalues];
    }
};

/// Unified closure type
pub const Closure = union(enum) {
    lua: *LClosure,
    c: *CClosure,

    /// Get number of upvalues
    pub fn nupvalues(self: Closure) u8 {
        return switch (self) {
            .lua => |l| l.nupvalues,
            .c => |c| c.nupvalues,
        };
    }

    /// Check if this is a Lua closure
    pub fn isLua(self: Closure) bool {
        return self == .lua;
    }

    /// Check if this is a C closure
    pub fn isC(self: Closure) bool {
        return self == .c;
    }

    /// Get GC object header
    pub fn getGCObject(self: Closure) *value.GCObject {
        return switch (self) {
            .lua => |l| &l.header,
            .c => |c| &c.header,
        };
    }
};

/// Upvalue status
pub const UpvalStatus = enum {
    open, // Still on stack
    closed, // Copied to heap
    tbc, // To-be-closed variable
};

/// Upvalue structure
pub const Upvalue = struct {
    header: value.GCObject,
    gclist: ?*value.GCObject = null, // link in the gray / grayagain lists

    // `p` always points at the live value: a stack slot while open,
    // `u.value` once closed (Lua's `v.p`), so reading an upvalue is one load
    // with no status test.
    p: *value.TValue,

    // Status
    status: UpvalStatus,

    // As in Lua's UpVal, the open-list links and the closed value share
    // storage: an open upvalue keeps its value on the stack, a closed one
    // is on no list.
    u: extern union {
        open: extern struct {
            next: ?*Upvalue, // Next in open list
            previous: ?*?*Upvalue, // The link that points here (so freeing can unlink)
        },
        value: value.TValue,
    },

    // To-be-closed info: the `__close` handler, nil if none
    tbc: value.TValue,

    /// Initialize an open upvalue
    pub fn initOpen(self: *Upvalue, level: *value.TValue) void {
        self.* = .{
            .header = self.header,
            .p = level,
            .status = .open,
            .u = .{ .open = .{ .next = null, .previous = null } },
            .tbc = value.TValue.nil(),
        };
    }

    /// Get value (works for both open and closed)
    pub inline fn getValue(self: *const Upvalue) *value.TValue {
        return self.p;
    }

    /// Set value
    pub inline fn setValue(self: *Upvalue, val: *const value.TValue) void {
        self.p.* = val.*;
    }

    /// Check if upvalue is open
    pub fn isOpen(self: *const Upvalue) bool {
        return self.status == .open or self.status == .tbc;
    }

    /// Check if upvalue is closed
    pub fn isClosed(self: *const Upvalue) bool {
        return self.status == .closed;
    }

    /// Check if this is a to-be-closed variable
    pub fn isTBC(self: *const Upvalue) bool {
        return self.status == .tbc;
    }

    /// Close the upvalue
    pub fn close(self: *Upvalue) void {
        assert(self.isOpen());
        const v = self.p.*; // the stack slot, read before the links are overwritten
        self.u = .{ .value = v };
        self.p = &self.u.value;
        self.status = .closed;
    }
};

/// Size in bytes of a Lua closure with `n` upvalue slots (one allocation)
pub fn lclosureSize(n: usize) usize {
    return @sizeOf(LClosure) + n * @sizeOf(?*Upvalue);
}

/// Size in bytes of a C closure with `n` upvalues (one allocation)
pub fn cclosureSize(n: usize) usize {
    return @sizeOf(CClosure) + n * @sizeOf(value.TValue);
}

/// Create a new Lua closure, owned by the garbage collector
pub fn newLClosure(L: *state.LuaState, nupvals: u8) !*LClosure {
    const size = lclosureSize(nupvals);
    const cl = try L.l_G.allocator.alignedAlloc(u8, .of(LClosure), size);

    const lcl = @as(*LClosure, @ptrCast(cl.ptr));
    lcl.* = .{
        .header = .{
            .next = null,
            .tt = @intFromEnum(value.ValueType.lclosure),
            .marked = 0,
        },
        .nupvalues = nupvals,
        .proto = undefined,
        .upvals = @ptrCast(cl.ptr + @sizeOf(LClosure)),
    };

    // Initialize upvalue pointers to null
    for (lcl.upvalueSlice()) |*uv| {
        uv.* = null;
    }

    L.l_G.gc.linkObject(&lcl.header, size);
    return lcl;
}

/// Create a new C closure, owned by the garbage collector
pub fn newCClosure(L: *state.LuaState, nupvals: u8) !*CClosure {
    const size = cclosureSize(nupvals);
    const cl = try L.l_G.allocator.alignedAlloc(u8, .of(CClosure), size);

    const ccl = @as(*CClosure, @ptrCast(cl.ptr));
    ccl.* = .{
        .header = .{
            .next = null,
            .tt = @intFromEnum(value.ValueType.cclosure),
            .marked = 0,
        },
        .nupvalues = nupvals,
        .f = undefined,
        .upvals = @ptrCast(cl.ptr + @sizeOf(CClosure)),
    };

    // Initialize upvalues to nil
    for (ccl.upvalueSlice()) |*uv| {
        uv.* = value.TValue.nil();
    }

    L.l_G.gc.linkObject(&ccl.header, size);
    return ccl;
}

/// Free a Lua closure block (called by the collector)
pub fn freeLClosure(allocator: std.mem.Allocator, cl: *LClosure) void {
    const block: [*]align(@alignOf(LClosure)) u8 = @ptrCast(cl);
    allocator.free(block[0..lclosureSize(cl.nupvalues)]);
}

/// Free a C closure block (called by the collector)
pub fn freeCClosure(allocator: std.mem.Allocator, cl: *CClosure) void {
    const block: [*]align(@alignOf(CClosure)) u8 = @ptrCast(cl);
    allocator.free(block[0..cclosureSize(cl.nupvalues)]);
}

/// Create a closed upvalue holding `val` (e.g. `_ENV` of a main chunk)
pub fn newClosedUpvalue(L: *state.LuaState, val: value.TValue) !*Upvalue {
    const uv = try L.l_G.allocator.create(Upvalue);
    uv.* = .{
        .header = .{ .next = null, .tt = @intFromEnum(value.ValueType.upvalue), .marked = 0 },
        .p = undefined, // set below: it must point into this object
        .status = .closed,
        .u = .{ .value = val },
        .tbc = value.TValue.nil(),
    };
    uv.p = &uv.u.value;
    L.l_G.gc.linkObject(&uv.header, @sizeOf(Upvalue));
    return uv;
}

/// Create or reuse an upvalue for a stack level
pub fn findUpvalue(L: *state.LuaState, level: *value.TValue) !*Upvalue {
    // Search for existing open upvalue at this level
    var pp = &L.openupval;
    var p = pp.*;

    while (p) |uv| {
        if (@intFromPtr(uv.p) >= @intFromPtr(level)) {
            if (uv.p == level) {
                // Found existing upvalue
                return uv;
            }
            pp = &uv.u.open.next;
            p = uv.u.open.next;
        } else {
            break;
        }
    }

    // Create new upvalue, owned by the garbage collector
    const uv = try L.l_G.allocator.create(Upvalue);
    uv.header = .{
        .next = null,
        .tt = @intFromEnum(value.ValueType.upvalue),
        .marked = 0,
    };

    uv.initOpen(level);

    // Insert in the correct position (ordered by stack level)
    uv.u.open.next = pp.*;
    uv.u.open.previous = pp;
    if (pp.*) |n| n.u.open.previous = &uv.u.open.next;
    pp.* = uv;

    // A thread with open upvalues is watched by the collector's `twups`
    // list (lfunc.c newupval), so the values of its open upvalues are
    // re-marked in the atomic phase even if the thread itself has died
    if (L.twups == L) {
        L.twups = L.l_G.gc.twups;
        L.l_G.gc.twups = L;
    }

    L.l_G.gc.linkObject(&uv.header, @sizeOf(Upvalue));
    return uv;
}

/// Close all upvalues pointing to stack level or above
pub fn closeUpvalues(L: *state.LuaState, level: *value.TValue) !void {
    while (L.openupval) |uv| {
        if (@intFromPtr(uv.p) < @intFromPtr(level)) {
            break;
        }

        // Remove from open list
        L.openupval = uv.u.open.next;
        if (L.openupval) |n| n.u.open.previous = &L.openupval;

        // Call __close metamethod for to-be-closed variables
        if (uv.isTBC()) {
            try callCloseMethod(L, uv);
        }

        // Close the upvalue
        uv.close();

        // An upvalue that is already marked must not hold an unmarked value
        // (luaF_closeupval): the stack slot was written without barriers
        if (!gc.isWhite(&uv.header)) {
            gc.markBlack(&uv.header); // closed upvalues cannot be gray
            L.l_G.gc.barrier(&uv.header, uv.p);
        }
    }
}

/// Take an open upvalue out of its thread's list without closing it
/// (luaF_unlinkupval): for the collector, which frees a dead open upvalue
/// while its thread may live on
pub fn unlinkUpvalue(uv: *Upvalue) void {
    std.debug.assert(uv.status != .closed);
    uv.u.open.previous.?.* = uv.u.open.next;
    if (uv.u.open.next) |n| n.u.open.previous = uv.u.open.previous;
}

/// Mark an upvalue as to-be-closed
pub fn markTBC(L: *state.LuaState, uv: *Upvalue) !void {
    // Check if value has __close metamethod
    const tm = getCloseMethod(L, uv.getValue());
    if (tm == null and !uv.getValue().isFalsy()) {
        // Error: to-be-closed variable without __close
        return vm.VMError.RuntimeError;
    }

    uv.status = .tbc;
    uv.tbc = tm orelse value.TValue.nil();
}

/// Get __close metamethod for a value
fn getCloseMethod(L: *state.LuaState, val: *value.TValue) ?value.TValue {
    const mt: ?*table.Table = switch (val.tag()) {
        .table => val.asTable().?.metatable,
        .userdata => val.asUserdata().?.metatable,
        else => null,
    };
    if (mt) |m| {
        const key = value.TValue.string(L.l_G.tmname[@intFromEnum(value.TMS.__close)]);
        const method = m.get(key);
        if (!method.isNil()) return method;
    }
    return null;
}

/// Call __close metamethod
fn callCloseMethod(L: *state.LuaState, uv: *Upvalue) !void {
    if (!uv.tbc.isNil()) {
        const method = uv.tbc;
        // Save current state
        const oldtop = L.top;
        const oldallowshook = L.allowhook;

        // Prepare call
        L.top[0] = method; // __close method
        L.top[1] = uv.getValue().*; // self
        L.top[2] = value.TValue.nil(); // error object (nil for normal close)
        L.top += 3;

        // Disable hooks during __close
        L.allowhook = 0;

        // Call __close method
        vm.doCall(L, L.top - 3, 2, 0) catch |err| {
            // Restore state
            L.top = oldtop;
            L.allowhook = oldallowshook;
            return err;
        };

        // Restore state
        L.top = oldtop;
        L.allowhook = oldallowshook;
    }
}

/// Half-close all upvalues (for coroutine reset)
pub fn halfCloseUpvalues(L: *state.LuaState, level: *value.TValue) void {
    while (L.openupval) |uv| {
        if (@intFromPtr(uv.p) < @intFromPtr(level)) {
            break;
        }

        // Remove from open list but don't close
        L.openupval = uv.u.open.next;

        // Mark for finalization if TBC
        if (uv.isTBC()) {
            // Add to to-be-finalized list
            // This would be handled by the GC
        }
    }
}

/// Create a closure from a prototype
pub fn createClosure(L: *state.LuaState, p: *proto.Proto, env: ?*LClosure, base: [*]value.TValue) !*LClosure {
    const ncl = try newLClosure(L, p.sizeupvalues);
    ncl.proto = p;

    // Initialize upvalues
    for (p.upvalues[0..p.sizeupvalues], 0..) |desc, i| {
        if (desc.instack) {
            // Upvalue refers to local variable in enclosing function
            ncl.upvals[i] = try findUpvalue(L, &base[desc.idx]);
        } else {
            // Upvalue refers to upvalue in enclosing function
            assert(env != null);
            ncl.upvals[i] = env.?.upvals[desc.idx];
        }
    }

    return ncl;
}

/// Link upvalues for generational GC
pub fn linkUpval(L: *state.LuaState, uv: *Upvalue) void {
    const g = L.l_G;
    const o = &uv.header;

    if (o.isBlack() and uv.isOpen()) {
        // Mark upvalue gray again
        o.marked &= ~@as(u8, gc.BLACKBIT);
        g.gc.linkGrayAgain(o);
    }
}

/// Get size of closure
pub fn closureSize(cl: Closure) usize {
    return switch (cl) {
        .lua => |l| @sizeOf(LClosure) + @as(usize, l.nupvalues) * @sizeOf(*Upvalue),
        .c => |c| @sizeOf(CClosure) + @as(usize, c.nupvalues) * @sizeOf(value.TValue),
    };
}

// Tests

test "upvalue creation and closing" {
    const allocator = std.testing.allocator;

    // Create a mock Lua state
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Create stack values
    L.top[0] = value.TValue.integer(42);
    L.top[1] = value.TValue.integer(100);
    L.top += 2;

    // Create upvalues
    const uv1 = try findUpvalue(L, &(L.top - 2)[0]);
    const uv2 = try findUpvalue(L, &(L.top - 1)[0]);

    // Check they're open and have correct values
    try std.testing.expect(uv1.isOpen());
    try std.testing.expect(uv2.isOpen());
    try std.testing.expect(uv1.getValue().asInteger().? == 42);
    try std.testing.expect(uv2.getValue().asInteger().? == 100);

    // Check they're in the open list
    try std.testing.expect(L.openupval == uv2);
    try std.testing.expect(uv2.u.open.next == uv1);

    // Close upvalues
    try closeUpvalues(L, &(L.top - 1)[0]);

    // Check uv2 is closed but uv1 is still open
    try std.testing.expect(uv2.isClosed());
    try std.testing.expect(uv1.isOpen());
    try std.testing.expect(L.openupval == uv1);

    // Value should still be accessible
    try std.testing.expect(uv2.getValue().asInteger().? == 100);
}

test "closure creation" {
    const allocator = std.testing.allocator;

    // Create Lua closure
    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    const lcl = try newLClosure(L, 3);
    try std.testing.expect(lcl.nupvalues == 3);
    try std.testing.expect(lcl.upvalueSlice().len == 3);

    // Create C closure
    const ccl = try newCClosure(L, 2);
    try std.testing.expect(ccl.nupvalues == 2);
    try std.testing.expect(ccl.upvalueSlice().len == 2);

    // Check initial values
    for (ccl.upvalueSlice()) |uv| {
        try std.testing.expect(uv.isNil());
    }
}

test "find or create upvalue" {
    const allocator = std.testing.allocator;

    const L = try state.LuaState.init(allocator, null);
    defer L.deinit();

    // Create a stack value
    L.top[0] = value.TValue.integer(42);
    const level = &L.top[0];

    // First call should create new upvalue
    const uv1 = try findUpvalue(L, level);
    try std.testing.expect(uv1.isOpen());
    try std.testing.expect(uv1.p == level);

    // Second call should return same upvalue
    const uv2 = try findUpvalue(L, level);
    try std.testing.expect(uv1 == uv2);
}
