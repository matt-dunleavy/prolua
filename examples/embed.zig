// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Embedding Prolua: the program from docs/embedding.md. Creates a state,
//! opens the standard libraries, registers a native function, runs a chunk,
//! calls a Lua function from Zig, and shows how errors come back.
//!
//!     zig build example

const std = @import("std");
const prolua = @import("prolua");
const api = prolua.api;
const LuaState = prolua.LuaState;

/// A native function: `add(a, b)`. Native functions take the state, read
/// their arguments from the stack, push their results and return how many.
/// A Lua error is raised by returning a Zig error; `api.argError` and
/// friends build the reference's messages.
fn add(L: *LuaState) !i32 {
    const a = try api.checkInteger(L, 1);
    const b = try api.checkInteger(L, 2);
    try api.pushInteger(L, a + b);
    return 1;
}

pub fn main(init: std.process.Init) !void {
    var out_buf: [512]u8 = undefined;
    var stdout = prolua.stdio.stdoutWriter(&out_buf);
    const out = &stdout.interface;

    // A state owns everything it allocates; `deinit` runs pending
    // finalizers and frees it all.
    const L = try LuaState.init(init.gpa, null);
    defer L.deinit();
    try prolua.lib.openLibs(L);

    // Register `add` as a global
    try api.pushCFunction(L, add);
    try api.setGlobal(L, "add");

    // Load and run a chunk. `loadString` leaves the compiled function (or an
    // error message) on the stack; `pcall` runs it protected.
    const chunk =
        \\local total = 0
        \\for i = 1, 10 do total = add(total, i) end
        \\function greet(name) return "hello, " .. name .. " (" .. total .. ")" end
        \\return total
    ;
    if (api.loadString(L, chunk, "=example") != .ok) {
        try out.print("compile error: {s}\n", .{api.toString(L, -1).?});
        try out.flush();
        return;
    }
    if (api.pcall(L, 0, 1, 0) != .ok) {
        try out.print("runtime error: {s}\n", .{api.toString(L, -1).?});
        try out.flush();
        return;
    }
    try out.print("chunk returned {d}\n", .{api.toInteger(L, -1).?});
    api.pop(L, 1);

    // Call a Lua function defined by the chunk: push it, push the arguments,
    // call, read the result
    _ = try api.getGlobal(L, "greet");
    try api.pushString(L, "embedder");
    try api.call(L, 1, 1);
    try out.print("{s}\n", .{api.toString(L, -1).?});
    api.pop(L, 1);

    // Errors: a failed protected call leaves the error object on the stack
    _ = try api.getGlobal(L, "add");
    try api.pushString(L, "not a number");
    try api.pushInteger(L, 1);
    const status = api.pcall(L, 2, 1, 0);
    try out.print("status {s}: {s}\n", .{ @tagName(status), api.toString(L, -1).? });
    api.pop(L, 1);
    try out.flush();
}
