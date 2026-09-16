// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Shared helpers for the standard libraries (lauxlib.c).
//!
//! Native functions in this codebase are `fn (*LuaState) anyerror!i32`, not the
//! C ABI, so the `luaL_*` shapes are adapted rather than copied: a `Reg` list
//! plus `newLib` replaces `luaL_Reg`/`luaL_newlib`, and the argument checks
//! return Zig errors instead of longjmping.

const std = @import("std");
const api = @import("../api.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const vm = @import("../vm.zig");

/// One entry of a library table
pub const Reg = struct {
    name: []const u8,
    func: api.CFunction,
};

/// Convert the value at `idx` to a string, push it, and return it
/// (luaL_tolstring): `__tostring` when the metatable has one; numbers,
/// strings, booleans and nil as `tostring` prints them; anything else as
/// "<type>: <address>", where a `__name` metafield names the type.
pub fn toLString(L: *state.LuaState, idx: i32) ![]const u8 {
    const abs = api.absIndex(L, idx);
    if (try api.getMetafield(L, abs, "__tostring")) {
        try api.pushValueAt(L, abs);
        try api.call(L, 1, 1);
        if (!api.isString(L, -1)) return err(L, "'__tostring' must return a string", .{});
        return api.toString(L, -1).?;
    }
    switch (api.type_(L, abs)) {
        .number => {
            const n: value.Number = if (api.isInteger(L, abs))
                .{ .integer = api.toInteger(L, abs).? }
            else
                .{ .float = api.toNumber(L, abs).? };
            var buf: [64]u8 = undefined;
            try api.pushString(L, vm.numberToStringBuf(&buf, n));
        },
        .string => try api.pushValueAt(L, abs),
        .boolean => try api.pushString(L, if (api.toBoolean(L, abs)) "true" else "false"),
        .nil => try api.pushString(L, "nil"),
        else => {
            var kind: []const u8 = api.typeName(L, api.type_(L, abs));
            var namebuf: [128]u8 = undefined;
            if (try api.getMetafield(L, abs, "__name")) {
                if (api.type_(L, -1) == .string) {
                    const n = api.toString(L, -1).?;
                    if (n.len <= namebuf.len) {
                        @memcpy(namebuf[0..n.len], n);
                        kind = namebuf[0..n.len];
                    }
                }
                api.pop(L, 1);
            }
            var buf: [192]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{s}: 0x{x}", .{ kind, @intFromPtr(api.toPointer(L, abs)) }) catch kind;
            try api.pushString(L, str);
        },
    }
    return api.toString(L, -1).?;
}

/// Create a table, fill it with `regs`, and leave it on the stack (luaL_newlib)
pub fn newLib(L: *state.LuaState, regs: []const Reg) !void {
    try api.createTable(L, 0, @intCast(regs.len));
    try setFuncs(L, regs);
}

/// Register `regs` into the table on top of the stack (luaL_setfuncs)
pub fn setFuncs(L: *state.LuaState, regs: []const Reg) !void {
    for (regs) |r| {
        try api.pushCFunction(L, r.func);
        try api.setField(L, -2, r.name);
    }
}

/// Register a library table as a global, leaving it on the stack
pub fn registerLib(L: *state.LuaState, name: []const u8, regs: []const Reg) !void {
    try newLib(L, regs);
    try api.pushValueAt(L, -1);
    try api.setGlobal(L, name);
}

// Argument checking.
//
// These forward to `api.zig` so there is a single implementation, and add the
// `opt*` variants plus the table/function checks the libraries need.

pub const checkAny = api.checkAny;
pub const checkString = api.checkString;
pub const checkInteger = api.checkInteger;
pub const checkNumber = api.checkNumber;
pub const checkType = api.checkType;
pub const checkOption = api.checkOption;
pub const argError = api.argError;
pub const typeError = api.typeError;

/// Is the argument at `idx` absent or nil?
pub fn isNoneOrNil(L: *state.LuaState, idx: i32) bool {
    return idx > api.getTop(L) or api.isNil(L, idx);
}

pub fn optInteger(L: *state.LuaState, idx: i32, def: i64) !i64 {
    if (isNoneOrNil(L, idx)) return def;
    return checkInteger(L, idx);
}

pub fn optNumber(L: *state.LuaState, idx: i32, def: f64) !f64 {
    if (isNoneOrNil(L, idx)) return def;
    return checkNumber(L, idx);
}

pub fn optString(L: *state.LuaState, idx: i32, def: []const u8) ![]const u8 {
    if (isNoneOrNil(L, idx)) return def;
    return checkString(L, idx);
}

pub fn optBoolean(L: *state.LuaState, idx: i32, def: bool) bool {
    if (isNoneOrNil(L, idx)) return def;
    return api.toBoolean(L, idx);
}

/// Check that the argument is a table
pub fn checkTable(L: *state.LuaState, idx: i32) !void {
    if (!api.isTable(L, idx)) return typeError(L, idx, "table");
}

/// Check that the argument is callable
pub fn checkFunction(L: *state.LuaState, idx: i32) !void {
    if (!api.isFunction(L, idx)) return typeError(L, idx, "function");
}

/// Raise `cond` as an argument error when it does not hold (luaL_argcheck)
pub fn argCheck(L: *state.LuaState, cond: bool, idx: i32, msg: []const u8) !void {
    if (!cond) return argError(L, idx, msg);
}

/// Raise a formatted error (luaL_error).
///
/// Returns the error as a value rather than `!noreturn` so call sites can
/// write `return aux.err(...)` from a function of any return type.
pub fn err(L: *state.LuaState, comptime fmt: []const u8, args: anytype) anyerror {
    var wherebuf: [api.WHERE_SIZE]u8 = undefined;

    // The message is blamed on the Lua code that called this function, which
    // is what makes library errors point at a line the user wrote. The text
    // is built on the heap, as luaL_error's luaL_Buffer grows: `require`'s
    // "module not found" report lists every path every searcher tried.
    const text = std.fmt.allocPrint(L.allocator, fmt, args) catch |e| return e;
    defer L.allocator.free(text);
    api.pushFString(L, "{s}{s}", .{ api.where(L, &wherebuf), text }) catch |e| return e;
    return api.error_(L);
}

/// Convert a 1-based Lua string position, which may be negative to count from
/// the end, into a 0-based offset clamped to `len` (posrelatI / getendpos)
pub fn strIndex(pos: i64, len: usize) usize {
    if (pos > 0) {
        const p: u64 = @intCast(pos);
        return @min(p - 1, len);
    }
    if (pos == 0) return 0;
    // `-pos` would trap on minint; the wrapped value reads correctly as u64
    const back: u64 = @bitCast(-%pos);
    if (back >= len) return 0;
    return len - back;
}

/// Like `strIndex` but not clamped at the end: a position past the end
/// stays past it, so a search starting there can fail (posrelatI - 1)
pub fn strStart(pos: i64, len: usize) usize {
    if (pos > 0) return @intCast(pos - 1);
    if (pos == 0) return 0;
    const back: u64 = @bitCast(-%pos);
    if (back > len) return 0;
    return len - back;
}

/// A growable byte buffer for building strings (luaL_Buffer).
///
/// Backed by the state's allocator rather than the Lua stack, so an in-progress
/// buffer never interferes with the stack slots a library function is using.
pub const Buffer = struct {
    L: *state.LuaState,
    bytes: std.ArrayList(u8),

    pub fn init(L: *state.LuaState) Buffer {
        return .{ .L = L, .bytes = .empty };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.L.allocator);
    }

    pub fn addChar(self: *Buffer, c: u8) !void {
        try self.bytes.append(self.L.allocator, c);
    }

    pub fn addString(self: *Buffer, s: []const u8) !void {
        try self.bytes.appendSlice(self.L.allocator, s);
    }

    pub fn addFmt(self: *Buffer, comptime fmt: []const u8, args: anytype) !void {
        try self.bytes.print(self.L.allocator, fmt, args);
    }

    /// Append the value at `idx`, converting numbers and strings the way Lua's
    /// string functions do
    pub fn addValue(self: *Buffer, idx: i32) !void {
        const s = (try api.toStringCoerce(self.L, idx)) orelse
            return typeError(self.L, idx, "string");
        try self.addString(s);
    }

    pub fn items(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }

    /// Push the accumulated bytes as a Lua string
    pub fn pushResult(self: *Buffer) !void {
        try api.pushString(self.L, self.bytes.items);
    }
};

test "strIndex maps Lua string positions" {
    // 1-based from the front
    try std.testing.expectEqual(@as(usize, 0), strIndex(1, 5));
    try std.testing.expectEqual(@as(usize, 4), strIndex(5, 5));
    // negative counts back from the end
    try std.testing.expectEqual(@as(usize, 4), strIndex(-1, 5));
    try std.testing.expectEqual(@as(usize, 0), strIndex(-5, 5));
    // out of range clamps rather than wrapping
    try std.testing.expectEqual(@as(usize, 5), strIndex(99, 5));
    try std.testing.expectEqual(@as(usize, 0), strIndex(-99, 5));
    try std.testing.expectEqual(@as(usize, 0), strIndex(0, 5));
    try std.testing.expectEqual(@as(usize, 0), strIndex(std.math.minInt(i64), 5));
    try std.testing.expectEqual(@as(usize, 6), strStart(7, 5));
    try std.testing.expectEqual(@as(usize, 5), strStart(6, 5));
    try std.testing.expectEqual(@as(usize, 4), strStart(-1, 5));
    try std.testing.expectEqual(@as(usize, 0), strStart(-99, 5));
    try std.testing.expectEqual(@as(usize, 0), strStart(std.math.minInt(i64), 5));
}
