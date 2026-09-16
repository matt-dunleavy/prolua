// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Project discovery: the directory holding `module.toml`, found from a
//! given directory or by walking up from the working directory, and the
//! entry point `src/main.lua` (docs/project/package-manager.md §6, §33).

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const stdio = prolua.stdio;
const main = @import("main.zig");

pub const Project = struct {
    /// The directory holding `module.toml`, as given or as found
    root: []const u8,
    doc: manifest.Document,
    fields: manifest.Manifest,

    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        self.doc.deinit();
        allocator.free(self.root);
    }

    /// `<root>/src/main.lua`
    pub fn entryPath(self: *const Project, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root, "src", "main.lua" });
    }

    /// Whether `<root>/src/main.lua` exists
    pub fn hasEntry(self: *const Project, allocator: std.mem.Allocator, io: std.Io) !bool {
        const entry = try self.entryPath(allocator);
        defer allocator.free(entry);
        if (std.Io.Dir.cwd().statFile(io, entry, .{})) |_| return true else |_| return false;
    }

    /// The entry point, checked to exist. A project without one is a
    /// library (its root is `src/init.lua`) or is empty; either way there
    /// is nothing for `run` to run, and the message says which and what
    /// to do instead. Reported on stderr before `error.Reported`.
    pub fn programEntry(self: *const Project, allocator: std.mem.Allocator, io: std.Io) Error![]u8 {
        const entry = try self.entryPath(allocator);
        errdefer allocator.free(entry);
        if (std.Io.Dir.cwd().statFile(io, entry, .{})) |_| return entry else |_| {}
        const init_path = try std.fs.path.join(allocator, &.{ self.root, "src", "init.lua" });
        defer allocator.free(init_path);
        const is_library = if (std.Io.Dir.cwd().statFile(io, init_path, .{})) |_| true else |_| false;
        if (is_library) {
            main.messagef("{s} is a library, not a program: it has src/init.lua and no src/main.lua to run (prolua run <file.lua> runs a file)", .{self.fields.module});
        } else {
            main.messagef("{s} has no src/main.lua, the entry point of a program (prolua run <file.lua> runs a file)", .{self.fields.module});
        }
        return error.Reported;
    }
};

/// Errors here are reported on stderr before they are returned
pub const Error = error{ Reported, OutOfMemory };

/// The project rooted at `dir`, which must hold a `module.toml`
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) Error!Project {
    const path = try std.fs.path.join(allocator, &.{ dir, manifest.FILE_NAME });
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| {
        switch (err) {
            error.FileNotFound => main.messagef("no {s} in {s}", .{ manifest.FILE_NAME, dir }),
            error.StreamTooLong => main.messagef("{s} is larger than 1 MB, which no manifest is", .{path}),
            else => main.messagef("cannot read {s}: {s}", .{ path, @errorName(err) }),
        }
        return error.Reported;
    };
    defer allocator.free(text);
    var diag = manifest.Diagnostic{};
    var doc = manifest.parse(allocator, text, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            stdio.eprint("{s}:{d}: {s}\n", .{ path, diag.line, diag.message });
            return error.Reported;
        },
    };
    errdefer doc.deinit();
    const fields = manifest.Manifest.fromDocument(&doc, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            if (diag.line != 0) {
                stdio.eprint("{s}:{d}: {s}\n", .{ path, diag.line, diag.message });
            } else {
                stdio.eprint("{s}: {s}\n", .{ path, diag.message });
            }
            return error.Reported;
        },
    };
    return .{ .root = try allocator.dupe(u8, dir), .doc = doc, .fields = fields };
}

/// Whether `dir` holds a `module.toml`
pub fn hasManifest(io: std.Io, dir: []const u8, allocator: std.mem.Allocator) bool {
    const path = std.fs.path.join(allocator, &.{ dir, manifest.FILE_NAME }) catch return false;
    defer allocator.free(path);
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// The project the working directory is in, walking up to the root of the
/// file system; null when there is none
pub fn find(allocator: std.mem.Allocator, io: std.Io) Error!?Project {
    const cwd = std.process.currentPathAlloc(io, allocator) catch return error.OutOfMemory;
    defer allocator.free(cwd);
    return findFrom(allocator, io, cwd);
}

/// The project `start` (a directory) is in, walking up
pub fn findFrom(allocator: std.mem.Allocator, io: std.Io, start: []const u8) Error!?Project {
    var dir: []const u8 = start;
    while (true) {
        if (hasManifest(io, dir, allocator)) return try load(allocator, io, dir);
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
}
