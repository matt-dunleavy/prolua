// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua test [name...]`: run the project's tests, `tests/*_test.lua`,
//! each in its own Lua state with the standard libraries, the module
//! searcher for this project, and `<root>/tests/?.lua` on `package.path`
//! so shared helpers are a plain `require`. A file passes when it returns
//! without raising an error; the report is one line per file and a
//! summary, and the exit status is 1 when any file failed or none ran.

const std = @import("std");
const prolua = @import("prolua");
const state = prolua.state;
const api = prolua.api;
const stdio = prolua.stdio;
const main = @import("main.zig");
const run = @import("run.zig");
const project = @import("project.zig");

const LuaState = state.LuaState;

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, names: []const []const u8) !u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    var proj = project.findFrom(allocator, io, cwd) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    } orelse {
        main.messagef("not inside a project: no module.toml in {s} or above it (prolua init creates one)", .{cwd});
        return 1;
    };
    defer proj.deinit(allocator);

    // The project root as the user sees it: "." when it is the working directory
    const at_root = std.mem.eql(u8, proj.root, cwd);
    const shown_root: []const u8 = if (at_root) "." else proj.root;
    const tests_dir = if (at_root) try allocator.dupe(u8, "tests") else try std.fs.path.join(allocator, &.{ proj.root, "tests" });
    defer allocator.free(tests_dir);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    var dir = std.Io.Dir.cwd().openDir(io, tests_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            main.messagef("no tests: {s} has no tests/ directory (tests are tests/<name>_test.lua)", .{shown_root});
        } else {
            main.messagef("cannot open {s}: {s}", .{ tests_dir, @errorName(err) });
        }
        return 1;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, "_test.lua")) continue;
        const stem = entry.name[0 .. entry.name.len - "_test.lua".len];
        if (names.len > 0) {
            var wanted = false;
            for (names) |n| wanted = wanted or std.mem.eql(u8, n, stem) or std.mem.eql(u8, n, entry.name);
            if (!wanted) continue;
        }
        try files.append(allocator, try std.fs.path.join(allocator, &.{ tests_dir, entry.name }));
    }
    for (names) |n| {
        var found = false;
        for (files.items) |f| {
            const base = std.fs.path.basename(f);
            found = found or std.mem.eql(u8, n, base) or std.mem.eql(u8, n, base[0 .. base.len - "_test.lua".len]);
        }
        if (!found) {
            main.messagef("no test {s}: {s}/{s}_test.lua does not exist", .{ n, tests_dir, n });
            return 1;
        }
    }
    if (files.items.len == 0) {
        main.messagef("no tests: {s} has no *_test.lua files", .{tests_dir});
        return 1;
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    var passed: usize = 0;
    var failed: usize = 0;
    for (files.items) |file| {
        const ok = runOne(allocator, io, environ, &proj, tests_dir, file, out) catch |err| switch (err) {
            error.Reported => return 1, // the searcher refused the project (vendor/ inconsistent): said already
            else => return err,
        };
        if (ok) passed += 1 else failed += 1;
    }
    try out.print("{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed == 0) 0 else 1;
}

/// One test file in a fresh state; true when it ran to completion
fn runOne(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, proj: *const project.Project, tests_dir: []const u8, file: []const u8, out: *std.Io.Writer) !bool {
    const L = try LuaState.init(allocator, null);
    defer L.deinit();
    try main.openLibraries(L, false);
    try run.createArgTable(L, &.{}, file, &.{});
    const modules = run.installResolver(L, allocator, io, environ, proj, proj.root) catch |err| switch (err) {
        error.Reported => return error.Reported,
        else => return err,
    };
    defer {
        modules.deinit();
        allocator.destroy(modules);
    }
    try addTestsToPath(L, tests_dir);

    // Prints from the test come before its verdict line
    try out.flush();
    var status = api.loadFile(L, file, "bt");
    if (status == .ok) status = main.docall(L, 0, 0);
    if (status == .ok) {
        try out.print("ok    {s}\n", .{file});
        return true;
    }
    const msg = api.toString(L, -1) orelse "(error object is not a string)";
    try out.print("FAIL  {s}\n", .{file});
    var lines = std.mem.splitScalar(u8, msg, '\n');
    while (lines.next()) |line| try out.print("      {s}\n", .{line});
    api.pop(L, 1);
    return false;
}

/// `<tests>/?.lua;` before `package.path`, for helpers shared by the tests
fn addTestsToPath(L: *LuaState, tests_dir: []const u8) !void {
    if ((try api.getGlobal(L, "package")) != .table) return error.NoPackageTable;
    _ = try api.getField(L, -1, "path");
    const current = api.toString(L, -1) orelse "";
    try api.pushFString(L, "{s}/?.lua;{s}", .{ tests_dir, current });
    try api.setField(L, -3, "path");
    api.pop(L, 2);
}
