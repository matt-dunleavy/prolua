// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua bench [flags] [name...]`: time each script of a benchmark
//! directory (`test/bench` by default) as a whole process under this
//! interpreter and, when one is found, under the reference `lua`, and
//! print the best of `--runs` runs with the ratio. `zig build bench` runs
//! it on the tree's own set.

const std = @import("std");
const prolua = @import("prolua");
const stdio = prolua.stdio;
const main = @import("main.zig");

pub const Options = struct {
    dir: []const u8 = "test/bench",
    runs: u32 = 3,
    /// The reference interpreter: a path, or null to look for `lua` on PATH
    lua: ?[]const u8 = null,
    /// `--no-lua`: time this interpreter alone
    no_lua: bool = false,
    /// Script names (without `.lua`) to restrict the run to; empty = all
    names: []const []const u8 = &.{},
};

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, opts: Options) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = std.Io.Dir.cwd().openDir(io, opts.dir, .{ .iterate = true }) catch |err| {
        main.messagef("cannot open benchmark directory {s}: {s}", .{ opts.dir, @errorName(err) });
        return 1;
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lua")) continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        if (opts.names.len > 0) {
            var wanted = false;
            for (opts.names) |o| wanted = wanted or std.mem.eql(u8, o, stem);
            if (!wanted) continue;
        }
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    for (opts.names) |o| {
        var found = false;
        for (names.items) |n| found = found or std.mem.eql(u8, o, n[0 .. n.len - 4]);
        if (!found) {
            main.messagef("no script {s}.lua in {s}", .{ o, opts.dir });
            return 1;
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // This interpreter, by its own path, so `prolua` need not be on PATH
    const self_path = std.process.executablePathAlloc(io, arena) catch |err| {
        main.messagef("cannot find my own executable: {s}", .{@errorName(err)});
        return 1;
    };
    const lua: ?[]const u8 = if (opts.no_lua) null else opts.lua orelse findOnPath(arena, io, environ, "lua");

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    // Flushed line by line: the children write their own stderr between rows
    try out.print("{s: <14} {s: >10} {s: >10} {s: >8}\n", .{ "script", "prolua", "lua", "ratio" });
    try out.flush();
    for (names.items) |name| {
        defer out.flush() catch {};
        const path = try std.fs.path.join(arena, &.{ opts.dir, name });
        const stem = name[0 .. name.len - 4];
        const p = bestOf(io, opts.runs, &.{ self_path, "run", path }) orelse {
            main.messagef("{s} failed under prolua", .{path});
            return 1;
        };
        if (lua) |l| {
            const lns = bestOf(io, opts.runs, &.{ l, path }) orelse {
                main.messagef("{s} failed under {s}", .{ path, l });
                return 1;
            };
            const ratio = @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(lns));
            try out.print("{s: <14} {d: >9.3}s {d: >9.3}s {d: >7.2}x\n", .{ stem, secs(p), secs(lns), ratio });
        } else {
            try out.print("{s: <14} {d: >9.3}s {s: >10} {s: >8}\n", .{ stem, secs(p), "-", "-" });
        }
    }
    if (lua == null and !opts.no_lua) try out.print("(no reference `lua` on PATH: ratios omitted; --lua <path> names one)\n", .{});
    return 0;
}

fn secs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

/// Best wall-clock time of `runs` runs of `argv`, in nanoseconds; null when
/// a run fails to start or exits non-zero
fn bestOf(io: std.Io, runs: u32, argv: []const []const u8) ?u64 {
    var best: u64 = std.math.maxInt(u64);
    var i: u32 = 0;
    while (i < runs) : (i += 1) {
        const start = std.Io.Clock.awake.now(io);
        var child = std.process.spawn(io, .{ .argv = argv, .stdout = .ignore }) catch return null;
        const term = child.wait(io) catch return null;
        const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start.nanoseconds);
        if (term != .exited or term.exited != 0) return null;
        if (elapsed < best) best = elapsed;
    }
    return best;
}

fn findOnPath(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const path_env = environ.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(arena, &.{ dir, name }) catch return null;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return null;
}
