// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua clean`: remove the module cache (docs/project/package-manager.md
//! §51), the machine-level store `install` fills; the next `install` or
//! `run` fetches again. Nothing in a project is touched: `vendor/` is the
//! project's own and `prolua vendor` regenerates it. The command works
//! outside a project too, since the cache is not a project's.

const std = @import("std");
const prolua = @import("prolua");
const resolver = prolua.resolver;
const manifest = prolua.manifest;
const stdio = prolua.stdio;
const main = @import("main.zig");

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The cache location, by the same rule the searcher uses
    var r = try resolver.Resolver.init(allocator, io, environ, null, null, ".");
    defer r.deinit();
    const modules = try std.fs.path.join(arena, &.{ r.cache, "modules" });
    const cwd = std.Io.Dir.cwd();

    // Count what is there: every directory holding a module.toml
    var count: usize = 0;
    if (cwd.openDir(io, modules, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file and std.mem.eql(u8, entry.basename, manifest.FILE_NAME)) count += 1;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            stdio.print("nothing cached at {s}\n", .{modules});
            return 0;
        },
        else => {
            main.messagef("cannot open {s}: {s}", .{ modules, @errorName(err) });
            return 1;
        },
    }
    cwd.deleteTree(io, modules) catch |err| {
        main.messagef("cannot remove {s}: {s}", .{ modules, @errorName(err) });
        return 1;
    };
    stdio.print("removed {d} module version{s} from {s}\n", .{ count, if (count == 1) "" else "s", modules });
    return 0;
}
