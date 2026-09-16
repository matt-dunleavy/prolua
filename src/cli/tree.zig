// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua tree`: the project's dependency graph as the module searcher
//! sees it: each module's declared dependencies, the version each is
//! placed at and where from (replacement, vendor/, the cache), with a
//! module the main manifest does not declare marked as reached through
//! its requirer, and a module nothing places marked missing.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const resolver = prolua.resolver;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !u8 {
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

    var r = try resolver.Resolver.init(allocator, io, environ, proj.root, &proj.fields, cwd);
    defer r.deinit();

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    const shown_root: []const u8 = if (std.mem.eql(u8, proj.root, cwd)) "." else proj.root;
    try out.print("{s} {s} ({s})\n", .{ proj.fields.module, proj.fields.version orelse "-", shown_root });
    var path: std.ArrayList([]const u8) = .empty;
    try path.append(arena, proj.fields.module);
    var missing: usize = 0;
    try children(&r, arena, out, &proj.fields, proj.root, "", &path, &missing);
    if (missing > 0) {
        try out.print("{d} missing: declared but nothing places them (run prolua install; or vendor, or [replacements] to a checkout)\n", .{missing});
        return 1;
    }
    return 0;
}

/// The dependencies of the module at `dir`, one line each, then theirs
fn children(r: *resolver.Resolver, arena: std.mem.Allocator, out: *std.Io.Writer, m: *const manifest.Manifest, dir: []const u8, prefix: []const u8, path: *std.ArrayList([]const u8), missing: *usize) !void {
    for (m.dependencies, 0..) |dep, i| {
        const last = i + 1 == m.dependencies.len;
        try out.print("{s}{s} {s} {s}", .{ prefix, if (last) "└──" else "├──", dep.module, dep.version });
        var notes: std.Io.Writer.Allocating = .init(arena);
        const placed = try r.place(arena, dep.module, dir, &notes);
        if (placed) |p| {
            switch (p.how) {
                .main => try out.writeAll(" (this project)"),
                .requirer => try out.writeAll(" (itself)"),
                .replacement_path => try out.print(" (replaced by {s})", .{r.main.?.replacement(dep.module).?.path.?}),
                .replacement_module => try out.print(" (replaced by {s} at {s})", .{ r.main.?.replacement(dep.module).?.target_module.?, p.dir }),
                .vendor => try out.writeAll(" (vendor/)"),
                .cache => try out.writeAll(" (cache)"),
                .cache_via_requirer => try out.writeAll(" (cache, via this requirer: not in the project's [indirectDependencies])"),
            }
            if (p.version) |v| if (!std.mem.eql(u8, v, dep.version)) try out.print(" [{s} selected]", .{v});
        } else {
            missing.* += 1;
            try out.writeAll(" (missing)");
        }
        try out.writeByte('\n');
        if (placed == null) continue;
        // a module already on the path from the root is a cycle; one shown elsewhere is not repeated
        var seen = false;
        for (path.items) |seen_module| seen = seen or std.mem.eql(u8, seen_module, dep.module);
        if (seen) {
            try out.print("{s}{s} (cycle)\n", .{ prefix, if (last) "    └──" else "│   └──" });
            continue;
        }
        const known = (try r.moduleAt(placed.?.dir)) orelse continue;
        const child_prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, if (last) "    " else "│   " });
        try path.append(arena, dep.module);
        try children(r, arena, out, &known.fields, placed.?.dir, child_prefix, path, missing);
        _ = path.pop();
    }
}
