// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua init [module path]`: a `module.toml` and a `src/main.lua` in the
//! working directory (docs/project/project.md 3.2, package-manager.md §6,
//! §7, §17).

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const import_path = prolua.import_path;
const version = prolua.version;
const stdio = prolua.stdio;
const main = @import("main.zig");

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, name_arg: ?[]const u8) !u8 {
    const dir = std.Io.Dir.cwd();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    if (dir.statFile(io, manifest.FILE_NAME, .{})) |_| {
        main.messagef("{s} already exists in {s}", .{ manifest.FILE_NAME, cwd });
        return 1;
    } else |_| {}

    const derived = name_arg == null;
    const name = name_arg orelse std.fs.path.basename(cwd);
    import_path.validate(name) catch |err| {
        main.messagef("invalid module path '{s}': {s}", .{ name, import_path.describe(err) });
        if (derived) stdio.eprint("  (the directory's name was used; give a path: prolua init <host>/<path>)\n", .{});
        return 1;
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try manifest.write(&aw.writer, name, "v0.1.0", version.VERSION);
    dir.writeFile(io, .{ .sub_path = manifest.FILE_NAME, .data = aw.written() }) catch |err| {
        main.messagef("cannot write {s}/{s}: {s}", .{ cwd, manifest.FILE_NAME, @errorName(err) });
        return 1;
    };

    dir.createDirPath(io, "src") catch |err| {
        main.messagef("cannot create {s}/src: {s}", .{ cwd, @errorName(err) });
        return 1;
    };
    const entry = "src/main.lua";
    const wrote_entry = blk: {
        if (dir.statFile(io, entry, .{})) |_| break :blk false else |_| {}
        var text: std.Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        try text.writer.print("print(\"hello from {s}\")\n", .{name});
        try dir.writeFile(io, .{ .sub_path = entry, .data = text.written() });
        break :blk true;
    };

    stdio.print("initialized module {s}\n  {s}\n", .{ name, manifest.FILE_NAME });
    if (wrote_entry) stdio.print("  {s}\n", .{entry});
    if (!import_path.isNamespace(name)) {
        stdio.print("a local module: without a namespace (<host>/<path>) it cannot be published\n", .{});
    }
    return 0;
}
