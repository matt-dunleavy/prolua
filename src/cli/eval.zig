// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua eval [--print] <code> [args...]`: run a chunk given on the
//! command line, with the standard libraries, this project's modules
//! resolving when the working directory is in one, and what follows the
//! code as both `arg[1..]` and the chunk's `...`, as a script gets it from
//! `run`. `--print` treats the code as an expression list and prints its
//! values, as the REPL does for a bare expression.

const std = @import("std");
const prolua = @import("prolua");
const state = prolua.state;
const api = prolua.api;
const main = @import("main.zig");
const run = @import("run.zig");
const project = @import("project.zig");

const LuaState = state.LuaState;

pub const Options = struct {
    code: []const u8,
    print: bool = false,
    /// argv up to and including the flags: `arg`'s negative indices
    before: []const []const u8 = &.{},
    /// what follows the code: `arg[1..]`
    args: []const []const u8 = &.{},
};

/// Returns the exit code
pub fn execute(L: *LuaState, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, opts: Options) !u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    var proj = project.findFrom(allocator, io, cwd) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    defer if (proj) |*p| p.deinit(allocator);

    try main.openLibraries(L, false);
    try run.createArgTable(L, opts.before, "(command line)", opts.args);
    const modules = run.installResolver(L, allocator, io, environ, if (proj) |*p| p else null, cwd) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    defer {
        modules.deinit();
        allocator.destroy(modules);
    }

    // `return <code>` with --print, the code itself otherwise; the words
    // after the code are the chunk's `...`
    const text = if (opts.print) try std.fmt.allocPrint(allocator, "return {s}", .{opts.code}) else opts.code;
    defer if (opts.print) allocator.free(text);
    var status = api.loadBuffer(L, text, "=(command line)", "t");
    if (status != .ok) {
        main.report(L, status);
        return 1;
    }
    const base = api.getTop(L) - 1;
    if (!api.checkStack(L, @intCast(opts.args.len + 3))) return error.StackOverflow;
    for (opts.args) |a| try api.pushString(L, a);
    status = main.docall(L, @intCast(opts.args.len), if (opts.print) api.LUA_MULTRET else 0);
    if (status != .ok) {
        main.report(L, status);
        return 1;
    }
    if (!opts.print) return 0;
    const n = api.getTop(L) - base;
    if (n > 0) {
        _ = try api.getGlobal(L, "print");
        try api.insert(L, base + 1);
        status = api.pcall(L, n, 0, 0);
        if (status != .ok) {
            main.report(L, status);
            return 1;
        }
    }
    return 0;
}
