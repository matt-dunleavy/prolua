// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The coroutine library (lcorolib.c), over `coroutine.zig`.

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const debug = @import("../debug.zig");

const LuaState = state.LuaState;

pub fn openCoroutine(L: *LuaState) !void {
    const regs = [_]aux.Reg{
        .{ .name = "create", .func = co_create },
        .{ .name = "close", .func = co_close },
        .{ .name = "isyieldable", .func = co_isyieldable },
        .{ .name = "resume", .func = co_resume },
        .{ .name = "running", .func = co_running },
        .{ .name = "status", .func = co_status },
        .{ .name = "wrap", .func = co_wrap },
        .{ .name = "yield", .func = co_yield },
    };
    try aux.registerLib(L, "coroutine", &regs);
    api.pop(L, 1);
}

/// The coroutine argument, which must be a thread (getco)
fn getCo(L: *LuaState) !*LuaState {
    return api.toThread(L, 1) orelse return api.typeError(L, 1, "thread");
}

/// Resume `co` with the top `narg` values of `L` as arguments; move its
/// results (or its error object, returning null) back to `L` (auxresume)
fn auxResume(L: *LuaState, co: *LuaState, narg: i32) !?i32 {
    if (!api.checkStack(co, narg)) {
        try api.pushString(L, "too many arguments to resume");
        return null;
    }
    try api.xmove(L, co, narg);
    var nres: i32 = 0;
    const status = api.resume_(L, co, narg, &nres);
    if (status == .ok or status == .yield) {
        if (!api.checkStack(L, nres + 1)) {
            api.pop(co, nres); // remove results anyway
            try api.pushString(L, "too many results to resume");
            return null;
        }
        try api.xmove(co, L, nres); // move yielded values
        return nres;
    }
    try api.xmove(co, L, 1); // move error message
    return null;
}

/// coroutine.resume(co [, val1, ···])
fn co_resume(L: *LuaState) !i32 {
    const co = try getCo(L);
    if (try auxResume(L, co, api.getTop(L) - 1)) |r| {
        try api.pushBoolean(L, true);
        try api.insert(L, -(r + 1));
        return r + 1; // return true + results
    }
    try api.pushBoolean(L, false);
    try api.insert(L, -2);
    return 2; // return false + error message
}

/// The function behind a wrapped coroutine: resumes it, and turns a failure
/// into an error in the caller, closing the coroutine first (auxwrap)
fn auxWrap(L: *LuaState) !i32 {
    const co = api.toThread(L, api.upvalueIndex(1)).?;
    if (try auxResume(L, co, api.getTop(L))) |r| return r;

    const stat = api.status(L, co);
    if (stat != .ok and stat != .yield) { // error in the coroutine?
        const close_status = api.closeThread(co, L); // close its tbc variables
        std.debug.assert(close_status != .ok);
        api.pop(L, 1); // the error message, replaced by the one from closing
        try api.xmove(co, L, 1); // move error message to the caller
    }
    if (stat != .errmem and api.type_(L, -1) == .string) { // error object is a string?
        // Prepend the position of the call, as `error` would
        var wherebuf: [api.WHERE_SIZE]u8 = undefined;
        const w = api.where(L, &wherebuf);
        try api.pushString(L, w);
        try api.insert(L, -2);
        try api.concat(L, 2);
    }
    return api.error_(L); // propagate error
}

/// coroutine.create(f)
fn co_create(L: *LuaState) !i32 {
    try aux.checkFunction(L, 1);
    const nl = try L.newThread(); // pushes the thread
    try api.pushValueAt(L, 1); // move function to top
    try api.xmove(L, nl, 1); // move function from L to NL
    return 1;
}

/// coroutine.wrap(f)
fn co_wrap(L: *LuaState) !i32 {
    _ = try co_create(L);
    try api.pushCClosure(L, auxWrap, 1);
    return 1;
}

/// coroutine.yield(···)
fn co_yield(L: *LuaState) !i32 {
    return api.yield(L, api.getTop(L));
}

const CoStatus = enum(u8) { running, dead, suspended, normal };
const status_names = [_][]const u8{ "running", "dead", "suspended", "normal" };

/// The state of `co` as seen from `L` (auxstatus)
fn auxStatus(L: *LuaState, co: *LuaState) CoStatus {
    if (L == co) return .running;
    switch (api.status(L, co)) {
        .yield => return .suspended,
        .ok => {
            if (debug.getStack(co, 0) != null) return .normal; // it has frames: it is running
            if (api.getTop(co) == 0) return .dead;
            return .suspended; // initial state
        },
        else => return .dead, // some error occurred
    }
}

/// coroutine.status(co)
fn co_status(L: *LuaState) !i32 {
    const co = try getCo(L);
    try api.pushString(L, status_names[@intFromEnum(auxStatus(L, co))]);
    return 1;
}

/// coroutine.isyieldable([co])
fn co_isyieldable(L: *LuaState) !i32 {
    const co = if (aux.isNoneOrNil(L, 1)) L else try getCo(L);
    try api.pushBoolean(L, api.isYieldable(co));
    return 1;
}

/// coroutine.running()
fn co_running(L: *LuaState) !i32 {
    const ismain = try api.pushThread(L);
    try api.pushBoolean(L, ismain);
    return 2;
}

/// coroutine.close(co)
fn co_close(L: *LuaState) !i32 {
    const co = try getCo(L);
    const st = auxStatus(L, co);
    switch (st) {
        .dead, .suspended => {
            const status = api.closeThread(co, L);
            if (status == .ok) {
                try api.pushBoolean(L, true);
                return 1;
            }
            try api.pushBoolean(L, false);
            try api.xmove(co, L, 1); // move error message
            return 2;
        },
        else => return aux.err(L, "cannot close a {s} coroutine", .{status_names[@intFromEnum(st)]}),
    }
}
