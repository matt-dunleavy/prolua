// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua remove <module>`: the inverse of `add`. Drops the module from
//! `[dependencies]` (its `[replacements]` entry, if any, stays: it is
//! configuration, and inert without a dependency) and runs `install`, so
//! `[indirectDependencies]` and `module.sum` shrink to what the graph
//! still needs.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");
const install = @import("install.zig");

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, module: []const u8) !u8 {
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

    const manifest_path = try std.fs.path.join(arena, &.{ proj.root, manifest.FILE_NAME });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(1 << 20));
    const edited = (try manifest.removeDependency(arena, text, module)) orelse {
        if (proj.fields.dependencyVersion(module)) |v| {
            main.messagef("{s} {s} is an indirect dependency, not one this project declares; remove the dependency that needs it", .{ module, v });
        } else {
            main.messagef("{s} is not in [dependencies] of {s}", .{ module, manifest_path });
        }
        return 1;
    };
    manifest.writeFileAtomic(io, arena, manifest_path, edited) catch |err| {
        main.messagef("cannot write {s}: {s}", .{ manifest_path, @errorName(err) });
        return 1;
    };
    stdio.print("{s}: removed {s}\n", .{ manifest.FILE_NAME, module });
    if (proj.fields.replacement(module) != null) stdio.print("  ([replacements.\"{s}\"] kept; delete it by hand if it is no longer wanted)\n", .{module});

    var reloaded = project.load(allocator, io, proj.root) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    defer reloaded.deinit(allocator);
    return install.run(allocator, io, environ, &reloaded, false);
}
