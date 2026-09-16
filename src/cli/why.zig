// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua why <module>`: every chain of declared dependencies from this
//! project down to the module, one tree per chain, so a surprising module
//! in the graph can be traced to the direct dependency that brings it in
//! (docs/project/package-manager.md §50). Placement follows the searcher's
//! rules, as `tree` does; a declared module nothing places still shows,
//! marked missing, since the declaration is what `why` explains.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const resolver = prolua.resolver;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, target: []const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = try std.process.currentPathAlloc(io, arena);
    var proj = project.findFrom(allocator, io, cwd) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    } orelse {
        main.messagef("not inside a project: no {s} in {s} or above it (prolua init creates one)", .{ manifest.FILE_NAME, cwd });
        return 1;
    };
    defer proj.deinit(allocator);

    if (std.mem.eql(u8, target, proj.fields.module)) {
        main.messagef("{s} is this project", .{target});
        return 1;
    }

    var r = try resolver.Resolver.init(allocator, io, environ, proj.root, &proj.fields, cwd);
    defer r.deinit();

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    var path: std.ArrayList([]const u8) = .empty;
    try path.append(arena, proj.fields.module);
    var found: usize = 0;
    try search(&r, arena, out, &proj.fields, proj.root, target, &path, &found);
    if (found == 0) {
        try out.flush();
        main.messagef("{s} is not in the dependency graph of {s}", .{ target, proj.fields.module });
        return 1;
    }
    return 0;
}

/// Depth-first over declared dependencies; each arrival at `target`
/// prints the chain from the root
fn search(r: *resolver.Resolver, arena: std.mem.Allocator, out: *std.Io.Writer, m: *const manifest.Manifest, dir: []const u8, target: []const u8, path: *std.ArrayList([]const u8), found: *usize) !void {
    for (m.dependencies) |dep| {
        try path.append(arena, dep.module);
        defer _ = path.pop();
        var notes: std.Io.Writer.Allocating = .init(arena);
        const placed = try r.place(arena, dep.module, dir, &notes);
        if (std.mem.eql(u8, dep.module, target)) {
            if (found.* > 0) try out.writeByte('\n');
            found.* += 1;
            try printChain(out, path.items, placed == null);
            continue;
        }
        const p = placed orelse continue;
        // a module already on the path is a cycle: it cannot lead anywhere new
        var seen = false;
        for (path.items[0 .. path.items.len - 1]) |on_path| seen = seen or std.mem.eql(u8, on_path, dep.module);
        if (seen) continue;
        const known = (try r.moduleAt(p.dir)) orelse continue;
        try search(r, arena, out, &known.fields, p.dir, target, path, found);
    }
}

fn printChain(out: *std.Io.Writer, chain: []const []const u8, missing: bool) !void {
    for (chain, 0..) |module, depth| {
        if (depth == 0) {
            try out.print("{s}\n", .{module});
            continue;
        }
        var i: usize = 1;
        while (i < depth) : (i += 1) try out.writeAll("    ");
        try out.print("└── {s}{s}\n", .{ module, if (depth + 1 == chain.len and missing) " (missing)" else "" });
    }
}
