// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The debug library (ldblib.c), over the introspection in `debug.zig`.
//!
//! Every function that takes an optional thread as its first argument accepts
//! one; until coroutines exist the only thread is the running one.

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const debug = @import("../debug.zig");
const stack = @import("../stack.zig");
const stdio = @import("../utils/stdio.zig");

const LuaState = state.LuaState;

pub fn openDebug(L: *LuaState) !void {
    const regs = [_]aux.Reg{
        .{ .name = "getmetatable", .func = db_getmetatable },
        .{ .name = "setmetatable", .func = db_setmetatable },
        .{ .name = "getregistry", .func = db_getregistry },
        .{ .name = "getupvalue", .func = db_getupvalue },
        .{ .name = "setupvalue", .func = db_setupvalue },
        .{ .name = "traceback", .func = db_traceback },
        .{ .name = "getinfo", .func = db_getinfo },
        .{ .name = "getlocal", .func = db_getlocal },
        .{ .name = "setlocal", .func = db_setlocal },
        .{ .name = "gethook", .func = db_gethook },
        .{ .name = "setcstacklimit", .func = db_setcstacklimit },
        .{ .name = "debug", .func = db_debug },
        .{ .name = "sethook", .func = db_sethook },
        .{ .name = "getuservalue", .func = db_getuservalue },
        .{ .name = "setuservalue", .func = db_setuservalue },
        .{ .name = "upvalueid", .func = db_upvalueid },
        .{ .name = "upvaluejoin", .func = db_upvaluejoin },
    };
    try aux.registerLib(L, "debug", &regs);
    api.pop(L, 1);
}

/// The thread a debug function operates on, and the position of its first
/// real argument (getthread)
fn getThread(L: *LuaState) struct { L1: *LuaState, arg: i32 } {
    if (api.isThread(L, 1)) {
        return .{ .L1 = api.toThread(L, 1).?, .arg = 1 };
    }
    return .{ .L1 = L, .arg = 0 };
}

/// Unlike the base library's version, this ignores `__metatable`
fn db_getmetatable(L: *LuaState) !i32 {
    try aux.checkAny(L, 1);
    if (!api.getMetatable(L, 1)) {
        try api.pushNil(L);
    }
    return 1;
}

fn db_setmetatable(L: *LuaState) !i32 {
    const t = api.type_(L, 2);
    try aux.argCheck(L, t == .nil or t == .table, 2, "nil or table expected");
    api.setTop(L, 2) catch {};
    _ = try api.setMetatable(L, 1);
    try api.pushValueAt(L, 1);
    return 1;
}

fn db_getregistry(L: *LuaState) !i32 {
    try api.getRegistry(L);
    return 1;
}

fn db_getupvalue(L: *LuaState) !i32 {
    try aux.checkFunction(L, 1);
    const n = try api.checkInteger(L, 2);
    if (api.getUpvalue(L, 1, @intCast(n))) |name| {
        try api.pushString(L, name);
        try api.insert(L, -2);
        return 2;
    }
    try api.pushNil(L);
    return 1;
}

fn db_setupvalue(L: *LuaState) !i32 {
    try aux.checkFunction(L, 1);
    const n = try api.checkInteger(L, 2);
    try aux.checkAny(L, 3);
    api.setTop(L, 3) catch {};

    // lua_setupvalue names the upvalue ("(no name)" without debug info) and
    // returns null only when there is no such upvalue
    if (api.setUpvalue(L, 1, @intCast(n))) |name| {
        try api.pushString(L, name);
        return 1;
    }
    try api.pushNil(L);
    return 1;
}

/// debug.traceback([thread,] [message [, level]])
fn db_traceback(L: *LuaState) !i32 {
    const th = getThread(L);
    const arg = th.arg;
    const msg_type = api.type_(L, arg + 1);
    if (msg_type != .string and msg_type != .nil and api.getTop(L) >= arg + 1) {
        // A non-string message is returned untouched
        try api.pushValueAt(L, arg + 1);
        return 1;
    }
    const msg: ?[]const u8 = if (msg_type == .string) api.toString(L, arg + 1) else null;
    // Level 1 is the caller of traceback in the running thread, level 0 the
    // top of another thread
    const level = try aux.optInteger(L, arg + 2, if (th.L1 == L) 1 else 0);
    try debug.traceback(L, th.L1, msg, @intCast(level));
    return 1;
}

/// debug.getinfo([thread,] f [, what])
fn db_getinfo(L: *LuaState) !i32 {
    const th = getThread(L);
    const L1 = th.L1;
    const arg = th.arg;
    const options = try aux.optString(L, arg + 2, "flnSrtu");
    _ = api.checkStack(L, 3);
    // '>' is only for the C API; a function argument means the same thing
    if (std.mem.indexOfScalar(u8, options, '>') != null) return aux.argError(L, arg + 2, "invalid option '>'");

    var ar = debug.Info{};
    var ci: ?*state.CallInfo = null;
    var func = value.TValue.nil();
    if (api.isFunction(L, arg + 1)) {
        func = (try L.index2Value(arg + 1)).*;
    } else {
        const level = try api.checkInteger(L, arg + 1);
        ci = debug.getStack(L1, @intCast(@min(level, std.math.maxInt(i32)))) orelse {
            try api.pushNil(L); // level out of range
            return 1;
        };
    }
    debug.getInfo(L, options, ci, func, &ar) catch |err| switch (err) {
        error.InvalidOption => return aux.argError(L, arg + 2, "invalid option"),
        else => return err,
    };
    // 'f' and 'L' left their values on the stack, in that order
    const pushed_f = std.mem.indexOfScalar(u8, options, 'f') != null;
    const pushed_l = std.mem.indexOfScalar(u8, options, 'L') != null;

    try api.newTable(L);
    if (std.mem.indexOfScalar(u8, options, 'S') != null) {
        try setStr(L, "source", ar.source);
        try setStr(L, "short_src", ar.shortSrc());
        try setInt(L, "linedefined", ar.linedefined);
        try setInt(L, "lastlinedefined", ar.lastlinedefined);
        try setStr(L, "what", ar.what);
    }
    if (std.mem.indexOfScalar(u8, options, 'l') != null) try setInt(L, "currentline", ar.currentline);
    if (std.mem.indexOfScalar(u8, options, 'u') != null) {
        try setInt(L, "nups", ar.nups);
        try setInt(L, "nparams", ar.nparams);
        try setBool(L, "isvararg", ar.isvararg);
    }
    if (std.mem.indexOfScalar(u8, options, 'n') != null) {
        if (ar.name) |n| try setStr(L, "name", n);
        try setStr(L, "namewhat", ar.namewhat);
    }
    if (std.mem.indexOfScalar(u8, options, 'r') != null) {
        try setInt(L, "ftransfer", ar.ftransfer);
        try setInt(L, "ntransfer", ar.ntransfer);
    }
    if (std.mem.indexOfScalar(u8, options, 't') != null) try setBool(L, "istailcall", ar.istailcall);
    // The table is on top; move the pushed values into it
    if (pushed_l) {
        try api.pushValueAt(L, -2); // the activelines table (or nil)
        try api.setField(L, -2, "activelines");
        try api.remove(L, -2);
    }
    if (pushed_f) {
        try api.pushValueAt(L, -2); // the function
        try api.setField(L, -2, "func");
        try api.remove(L, -2);
    }
    return 1;
}

fn setStr(L: *LuaState, k: []const u8, v: []const u8) !void {
    try api.pushString(L, v);
    try api.setField(L, -2, k);
}

fn setInt(L: *LuaState, k: []const u8, v: anytype) !void {
    try api.pushInteger(L, @intCast(v));
    try api.setField(L, -2, k);
}

fn setBool(L: *LuaState, k: []const u8, v: bool) !void {
    try api.pushBoolean(L, v);
    try api.setField(L, -2, k);
}

/// debug.getlocal([thread,] f | level, n)
fn db_getlocal(L: *LuaState) !i32 {
    const th = getThread(L);
    const L1 = th.L1;
    const arg = th.arg;
    const nvar: i32 = @intCast(try api.checkInteger(L, arg + 2));
    if (api.isFunction(L, arg + 1)) {
        // A function: only its parameter names are known
        const f = (try L.index2Value(arg + 1)).*;
        if (f.asClosure()) |cl| {
            if (debug.getLocalName(cl.proto, nvar, 0)) |name| {
                try api.pushString(L, name);
                return 1;
            }
        }
        try api.pushNil(L);
        return 1;
    }
    const level = try api.checkInteger(L, arg + 1);
    const ci = debug.getStack(L1, @intCast(@min(level, std.math.maxInt(i32)))) orelse
        return aux.argError(L, arg + 1, "level out of range");
    if (debug.findLocal(L1, ci, nvar)) |loc| {
        try api.pushString(L, loc.name);
        try api.pushValue(L, loc.pos.*);
        return 2;
    }
    try api.pushNil(L);
    return 1;
}

/// debug.setlocal([thread,] level, n, value)
fn db_setlocal(L: *LuaState) !i32 {
    const th = getThread(L);
    const L1 = th.L1;
    const arg = th.arg;
    const level = try api.checkInteger(L, arg + 1);
    const nvar: i32 = @intCast(try api.checkInteger(L, arg + 2));
    const ci = debug.getStack(L1, @intCast(@min(level, std.math.maxInt(i32)))) orelse
        return aux.argError(L, arg + 1, "level out of range");
    try aux.checkAny(L, arg + 3);
    api.setTop(L, arg + 3) catch {};
    if (debug.findLocal(L1, ci, nvar)) |loc| {
        loc.pos.* = (L.top - 1)[0];
        api.pop(L, 1);
        try api.pushString(L, loc.name);
        return 1;
    }
    api.pop(L, 1);
    try api.pushNil(L);
    return 1;
}

// Hooks. The Lua function installed with `sethook` is kept in a registry
// table keyed by thread, and `hookf` fetches and calls it.

const HOOKKEY = "_HOOKKEY";

const hook_names = [_][]const u8{ "call", "return", "line", "count", "tail call" };

/// Push the registry's hook table, creating it on first use
fn hookTable(L: *LuaState) !void {
    try api.getRegistry(L);
    if ((try api.getField(L, -1, HOOKKEY)) != .table) {
        api.pop(L, 1);
        try api.newTable(L);
        // Weak keys, so a hook does not keep its thread alive
        try api.newTable(L);
        try api.pushString(L, "k");
        try api.setField(L, -2, "__mode");
        _ = try api.setMetatable(L, -2);
        try api.pushValueAt(L, -1);
        try api.setField(L, -3, HOOKKEY);
    }
    try api.remove(L, -2);
}

fn hookf(L: *LuaState, ar: *debug.Info) anyerror!void {
    try hookTable(L);
    try api.pushValue(L, value.TValue.thread(L));
    _ = try api.rawGet(L, -2);
    if (!api.isFunction(L, -1)) {
        api.pop(L, 2);
        return;
    }
    try api.remove(L, -2); // the table
    try api.pushString(L, hook_names[@intFromEnum(ar.event)]);
    if (ar.currentline >= 0) {
        try api.pushInteger(L, ar.currentline);
    } else {
        try api.pushNil(L);
    }
    try api.call(L, 2, 0);
}

fn makeMask(smask: []const u8, count: i64) state.HookMask {
    return .{
        .call = std.mem.indexOfScalar(u8, smask, 'c') != null,
        .ret = std.mem.indexOfScalar(u8, smask, 'r') != null,
        .line = std.mem.indexOfScalar(u8, smask, 'l') != null,
        .count = count > 0,
    };
}

/// debug.sethook([thread,] hook, mask [, count])
fn db_sethook(L: *LuaState) !i32 {
    const th = getThread(L);
    const L1 = th.L1;
    const arg = th.arg;
    var mask: state.HookMask = .{};
    var count: i64 = 0;
    var func: ?state.HookFn = null;
    if (aux.isNoneOrNil(L, arg + 1)) {
        api.setTop(L, arg + 1) catch {};
        // Turn off hooks
    } else {
        const smask = try api.checkString(L, arg + 2);
        try aux.checkFunction(L, arg + 1);
        count = try aux.optInteger(L, arg + 3, 0);
        mask = makeMask(smask, count);
        func = hookf;
    }
    try hookTable(L);
    try api.pushValue(L, value.TValue.thread(L1));
    try api.pushValueAt(L, arg + 1);
    try api.rawSet(L, -3); // hooktable[L1] = new Lua hook
    api.pop(L, 1);

    L1.hook = func;
    L1.basehookcount = @intCast(@max(count, 0));
    L1.hookcount = L1.basehookcount;
    L1.hookmask = if (func == null) .{} else mask;
    return 0;
}

/// debug.gethook([thread])
fn db_gethook(L: *LuaState) !i32 {
    const th = getThread(L);
    const L1 = th.L1;
    const hook = L1.hook orelse {
        try api.pushNil(L);
        return 1;
    };
    if (hook != hookf) {
        try api.pushString(L, "external hook");
    } else {
        try hookTable(L);
        try api.pushValue(L, value.TValue.thread(L1));
        _ = try api.rawGet(L, -2);
        try api.remove(L, -2);
    }
    var smask: [4]u8 = undefined;
    var n: usize = 0;
    if (L1.hookmask.call) {
        smask[n] = 'c';
        n += 1;
    }
    if (L1.hookmask.ret) {
        smask[n] = 'r';
        n += 1;
    }
    if (L1.hookmask.line) {
        smask[n] = 'l';
        n += 1;
    }
    try api.pushString(L, smask[0..n]);
    try api.pushInteger(L, L1.basehookcount);
    return 3;
}

/// debug.getuservalue(u, n)
fn db_getuservalue(L: *LuaState) !i32 {
    const n = try aux.optInteger(L, 2, 1);
    if (api.type_(L, 1) != .userdata) {
        try api.pushNil(L); // fail
        return 1;
    }
    if ((try api.getUservalue(L, 1, @intCast(n))) != null) {
        try api.pushBoolean(L, true);
        return 2;
    }
    return 1; // the nil pushed for a missing value
}

fn db_setuservalue(L: *LuaState) !i32 {
    const n = try aux.optInteger(L, 3, 1);
    try api.checkType(L, 1, .userdata);
    try aux.checkAny(L, 2);
    api.setTop(L, 2) catch {};
    api.setUservalue(L, 1, @intCast(n)) catch {
        try api.pushNil(L); // fail: no such user value
        return 1;
    };
    try api.pushValueAt(L, 1);
    return 1;
}

/// The upvalue object of a Lua closure, for identity comparison
fn upvalueRef(L: *LuaState, argf: i32, n: i64, pnup: ?*u8) !?*anyopaque {
    try aux.checkFunction(L, argf);
    const f = (try L.index2Value(argf)).*;
    if (f.asClosure()) |cl| {
        if (pnup) |p| p.* = cl.nupvalues;
        if (n < 1 or n > cl.nupvalues) return null;
        const uv = cl.upvals[@intCast(n - 1)] orelse return null;
        return @ptrCast(uv);
    }
    if (f.asCClosure()) |cc| {
        if (pnup) |p| p.* = cc.nupvalues;
        if (n < 1 or n > cc.nupvalues) return null;
        return @ptrCast(&cc.upvals[@intCast(n - 1)]);
    }
    return null; // a light native function has no upvalues
}

/// debug.upvalueid(f, n)
fn db_upvalueid(L: *LuaState) !i32 {
    const n = try api.checkInteger(L, 2);
    if (try upvalueRef(L, 1, n, null)) |id| {
        try api.pushLightUserdata(L, id);
    } else {
        try api.pushNil(L);
    }
    return 1;
}

/// debug.upvaluejoin(f1, n1, f2, n2): f1's n1-th upvalue becomes f2's n2-th
fn db_upvaluejoin(L: *LuaState) !i32 {
    const n1 = try api.checkInteger(L, 2);
    const n2 = try api.checkInteger(L, 4);
    try aux.checkFunction(L, 1);
    try aux.checkFunction(L, 3);
    const f1 = (try L.index2Value(1)).*;
    const f2 = (try L.index2Value(3)).*;
    const c1 = f1.asClosure() orelse return aux.argError(L, 1, "Lua function expected");
    const c2 = f2.asClosure() orelse return aux.argError(L, 3, "Lua function expected");
    try aux.argCheck(L, n1 >= 1 and n1 <= c1.nupvalues, 2, "invalid upvalue index");
    try aux.argCheck(L, n2 >= 1 and n2 <= c2.nupvalues, 4, "invalid upvalue index");
    const uv = c2.upvals[@intCast(n2 - 1)];
    c1.upvals[@intCast(n1 - 1)] = uv;
    if (uv) |u| L.l_G.gc.barrierObject(&c1.header, &u.header);
    return 0;
}

/// debug.setcstacklimit(limit): deprecated in 5.4, kept for compatibility;
/// returns the old fixed limit as lua_setcstacklimit does
fn db_setcstacklimit(L: *state.LuaState) !i32 {
    _ = try aux.checkInteger(L, 1);
    try api.pushInteger(L, 200); // LUAI_MAXCCALLS, what 5.4's lua_setcstacklimit answers
    return 1;
}

/// debug.debug(): read and run lines from stdin until "cont" or the end of
/// input, reporting errors on stderr (ldblib.c, with its `lua_debug>` prompt)
fn db_debug(L: *state.LuaState) !i32 {
    var buf: [4096]u8 = undefined;
    var reader = stdio.stdinReader(&buf);
    while (true) {
        stdio.eprint("lua_debug> ", .{});
        const line = reader.interface.takeDelimiter('\n') catch return 0;
        const text = line orelse return 0;
        if (std.mem.eql(u8, text, "cont")) return 0;
        if (api.loadBuffer(L, text, "=(debug command)", "t") != .ok or api.pcall(L, 0, 0, 0) != .ok) {
            const msg = api.toString(L, -1) orelse "(error object is not a string)";
            stdio.eprint("{s}\n", .{msg});
        }
        api.setTop(L, 0) catch {}; // remove eventual returns
    }
}
