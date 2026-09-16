// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua update [module...]`: move direct dependencies to the latest
//! release their sources have a tag for (all of them, or the named ones),
//! then `install`. A replaced or vendored module has no source to ask and
//! is left where it is, and said so.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const source = prolua.source;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");
const install = @import("install.zig");

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, names: []const []const u8) !u8 {
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
    const m = &proj.fields;

    for (names) |n| {
        var declared = false;
        for (m.dependencies) |d| declared = declared or std.mem.eql(u8, d.module, n);
        if (!declared) {
            main.messagef("{s} is not in [dependencies] of this project", .{n});
            return 1;
        }
    }
    if (m.dependencies.len == 0) {
        stdio.print("no dependencies to update\n", .{});
        return 0;
    }

    const manifest_path = try std.fs.path.join(arena, &.{ proj.root, manifest.FILE_NAME });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(1 << 20));
    var edited: []u8 = try arena.dupe(u8, text);
    var failures: usize = 0;
    for (m.dependencies) |d| {
        if (names.len > 0) {
            var wanted = false;
            for (names) |n| wanted = wanted or std.mem.eql(u8, n, d.module);
            if (!wanted) continue;
        }
        if (m.replacement(d.module) != null) {
            stdio.print("{s} {s}: replaced, left as is\n", .{ d.module, d.version });
            continue;
        }
        const vendored = try std.fs.path.join(arena, &.{ proj.root, "vendor", d.module });
        if (std.Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ vendored, manifest.FILE_NAME }), .{})) |_| {
            stdio.print("{s} {s}: vendored, left as is\n", .{ d.module, d.version });
            continue;
        } else |_| {}
        const repo = (try source.repoFor(arena, d.module, environ)) orelse {
            main.messagef("{s}: no source for host '{s}'; left as is", .{ d.module, hostOf(d.module) });
            failures += 1;
            continue;
        };
        var diagnostic: []const u8 = "";
        const versions = source.listVersions(arena, io, environ, repo, &diagnostic) catch {
            main.messagef("{s}: listing the tags of {s} failed: {s}", .{ d.module, repo.url, diagnostic });
            failures += 1;
            continue;
        };
        const newest = source.latest(versions) orelse {
            main.messagef("{s}: {s} has no version tags; left at {s}", .{ d.module, repo.url, d.version });
            failures += 1;
            continue;
        };
        if (std.mem.eql(u8, newest, d.version) or !install.versionLess(d.version, newest)) {
            stdio.print("{s} {s}: latest\n", .{ d.module, d.version });
            continue;
        }
        edited = try manifest.setDependency(arena, edited, d.module, newest);
        stdio.print("{s} {s} -> {s}\n", .{ d.module, d.version, newest });
    }
    if (failures > 0) {
        main.messagef("{d} dependenc{s} could not be checked; {s} left unchanged", .{ failures, if (failures == 1) "y" else "ies", manifest.FILE_NAME });
        return 1;
    }
    if (!std.mem.eql(u8, edited, text)) {
        manifest.writeFileAtomic(io, arena, manifest_path, edited) catch |err| {
            main.messagef("cannot write {s}: {s}", .{ manifest_path, @errorName(err) });
            return 1;
        };
    }
    var reloaded = project.load(allocator, io, proj.root) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    defer reloaded.deinit(allocator);
    return install.run(allocator, io, environ, &reloaded, false);
}

fn hostOf(module: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, module, '/')) |i| module[0..i] else module;
}
