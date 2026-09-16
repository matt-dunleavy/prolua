// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua vendor`: copy every module the project depends on into
//! `<root>/vendor/<module path>/` and write `vendor/modules.toml`
//! (docs/project/package-manager.md §39–§42). The graph is resolved as
//! `install` resolves it (fetching what is missing, ignoring any existing
//! `vendor/`), `module.sum` is stored, the old `vendor/` is removed, each
//! module's tree is copied without `.git` or a nested `vendor/`, and the
//! vendor manifest records the fingerprint of the main manifest and sum
//! that the copies correspond to. From then on the searcher runs in
//! vendor mode: modules come from `vendor/` and nowhere else, and a
//! manifest that changed without `prolua vendor` is an error.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const integrity = prolua.integrity;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");
const install = @import("install.zig");

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

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    var sum = (try install.loadSum(allocator, io, proj.root)) orelse return 1;
    defer sum.deinit();
    var fetched: usize = 0;
    var selected = (try install.resolveGraph(allocator, arena, io, environ, &proj, &sum, out, &fetched, true)) orelse return 1;
    // The manifest and sum as install would leave them: the fingerprint is taken from that state
    if ((try install.writeManifest(allocator, arena, io, &proj, &selected, &sum, out, false)) == .failed) return 1;
    sum.store(io, proj.root) catch |err| {
        try out.flush();
        main.messagef("cannot write {s}/{s}: {s}", .{ proj.root, integrity.FILE_NAME, @errorName(err) });
        return 1;
    };
    var current = project.load(allocator, io, proj.root) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    defer current.deinit(allocator);

    // A fresh vendor/: what was there is generated output, not anyone's work
    const vendor_dir = try std.fs.path.join(arena, &.{ proj.root, integrity.VENDOR_DIR });
    const cwd_dir = std.Io.Dir.cwd();
    cwd_dir.deleteTree(io, vendor_dir) catch |err| {
        try out.flush();
        main.messagef("cannot remove the old {s}: {s}", .{ vendor_dir, @errorName(err) });
        return 1;
    };
    cwd_dir.createDirPath(io, vendor_dir) catch |err| {
        try out.flush();
        main.messagef("cannot create {s}: {s}", .{ vendor_dir, @errorName(err) });
        return 1;
    };
    // a refused or failed copy leaves no half-written vendor/ behind
    var complete = false;
    defer if (!complete) cwd_dir.deleteTree(io, vendor_dir) catch {};

    var modules: std.ArrayList(Vendored) = .empty;
    var it = selected.iterator();
    while (it.next()) |e| {
        const module = e.key_ptr.*;
        const sel = e.value_ptr.*;
        const dest = try std.fs.path.join(arena, &.{ vendor_dir, module });
        copyTree(io, sel.dir, dest) catch |err| switch (err) {
            error.LinkToDirectory, error.DanglingLink => {
                try out.flush();
                main.messagef("{s}: {s}/{s} is a symbolic link to {s}; a module's files must all lie inside it", .{ module, sel.dir, integrity.bad_link[0..integrity.bad_link_len], if (err == error.DanglingLink) "nothing" else "a directory" });
                return 1;
            },
            else => {
                try out.flush();
                main.messagef("{s}: cannot copy {s} into {s}: {s}", .{ module, sel.dir, dest, @errorName(err) });
                return 1;
            },
        };
        const hash = try integrity.hashTree(arena, io, dest);
        try modules.append(arena, .{ .module = module, .version = sel.version, .hash = hash });
        try out.print("vendored {s} {s}{s}\n", .{ module, sel.version, if (sel.replaced) " (from its replacement)" else "" });
    }
    std.mem.sort(Vendored, modules.items, {}, Vendored.lessThan);

    var text: std.Io.Writer.Allocating = .init(arena);
    const fp = try integrity.fingerprint(arena, io, proj.root, &current.fields);
    try text.writer.print("# Written by prolua vendor; do not edit. Run prolua vendor after changing dependencies.\nschema = 1\nfingerprint = \"{s}\"\n", .{fp});
    for (modules.items) |mod| {
        try text.writer.print("\n[[modules]]\nmodule = \"{s}\"\nversion = \"{s}\"\nhash = \"{s}\"\n", .{ mod.module, mod.version, mod.hash });
    }
    const vendor_manifest = try std.fs.path.join(arena, &.{ vendor_dir, integrity.VENDOR_FILE });
    manifest.writeFileAtomic(io, arena, vendor_manifest, text.written()) catch |err| {
        try out.flush();
        main.messagef("cannot write {s}: {s}", .{ vendor_manifest, @errorName(err) });
        return 1;
    };
    complete = true;
    const shown = if (std.mem.eql(u8, proj.root, cwd)) "vendor" else vendor_dir;
    try out.print("{d} module{s} in {s}/; {s}/{s} written\n", .{ modules.items.len, if (modules.items.len == 1) "" else "s", shown, shown, integrity.VENDOR_FILE });
    return 0;
}

const Vendored = struct {
    module: []const u8,
    version: []const u8,
    hash: []const u8,

    fn lessThan(_: void, a: Vendored, b: Vendored) bool {
        return std.mem.lessThan(u8, a.module, b.module);
    }
};

/// Copy the tree at `src` to `dest` (created), without `.git` and without
/// a nested `vendor/`
fn copyTree(io: std.Io, src: []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest);
    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    var dest_dir = try cwd.openDir(io, dest, .{});
    defer dest_dir.close(io);
    var walker = try src_dir.walk(std.heap.page_allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.basename, ".git") or (entry.depth() == 1 and std.mem.eql(u8, entry.basename, integrity.VENDOR_DIR))) {
                walker.leave(io);
                continue;
            }
            try dest_dir.createDirPath(io, entry.path);
            continue;
        }
        if (entry.kind == .sym_link) {
            // a link to a file is copied as that file; anything else is refused
            integrity.linkTarget(src_dir, io, entry.path) catch |err| {
                integrity.noteLink(entry.path);
                return err;
            };
        } else if (entry.kind != .file) continue;
        try std.Io.Dir.copyFile(src_dir, entry.path, dest_dir, entry.path, io, .{});
    }
}
