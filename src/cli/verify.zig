// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua verify`: check what is on disk against what was recorded
//! (docs/project/package-manager.md §48, §52.2). Every `module.sum` entry
//! whose version is in the cache is hashed again and must match; when
//! `vendor/` exists, its manifest must carry the current fingerprint and
//! every vendored module must hash to what `vendor/modules.toml` records
//! and, when `module.sum` has the entry, to that as well. One line per
//! module, a summary, exit 1 on any mismatch.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const resolver = prolua.resolver;
const integrity = prolua.integrity;
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

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    var sum = (try @import("install.zig").loadSum(allocator, io, proj.root)) orelse return 1;
    defer sum.deinit();
    // The placement rules are not needed, only the cache location
    var r = try resolver.Resolver.initWith(allocator, io, environ, proj.root, &proj.fields, cwd, true);
    defer r.deinit();

    var verified: usize = 0;
    var mismatched: usize = 0;
    var skipped: usize = 0;

    // The cache, against module.sum
    for (sum.entries.items) |e| {
        const dir = try r.cachePath(arena, e.module, e.version);
        if ((try r.moduleAt(dir)) == null) {
            try out.print("-     {s} {s}: not in the cache, nothing to verify\n", .{ e.module, e.version });
            skipped += 1;
            continue;
        }
        const hash = integrity.hashTree(arena, io, dir) catch |err| switch (err) {
            error.LinkToDirectory, error.DanglingLink => {
                try out.print("FAIL  {s} {s} (cache): {s}/{s} is a symbolic link to {s}\n", .{ e.module, e.version, dir, integrity.bad_link[0..integrity.bad_link_len], if (err == error.DanglingLink) "nothing" else "a directory" });
                mismatched += 1;
                continue;
            },
            else => return err,
        };
        if (std.mem.eql(u8, hash, e.hash)) {
            try out.print("ok    {s} {s} (cache)\n", .{ e.module, e.version });
            verified += 1;
        } else {
            try out.print("FAIL  {s} {s} (cache): {s}\n      recorded {s}\n      found    {s}\n", .{ e.module, e.version, dir, e.hash, hash });
            mismatched += 1;
        }
    }

    // vendor/, against its own manifest, the fingerprint, and module.sum
    const vendor_dir = try std.fs.path.join(arena, &.{ proj.root, integrity.VENDOR_DIR });
    const vendor_manifest = try std.fs.path.join(arena, &.{ vendor_dir, integrity.VENDOR_FILE });
    if (std.Io.Dir.cwd().readFileAlloc(io, vendor_manifest, arena, .limited(1 << 24))) |text| {
        var diag = manifest.Diagnostic{};
        var doc = manifest.parse(allocator, text, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                try out.print("FAIL  {s}/{s}: line {d}: {s}\n", .{ integrity.VENDOR_DIR, integrity.VENDOR_FILE, diag.line, diag.message });
                mismatched += 1;
                return finish(out, verified, mismatched, skipped);
            },
        };
        defer doc.deinit();
        const recorded_fp = doc.getString("", "fingerprint") orelse "";
        const now_fp = try integrity.fingerprint(arena, io, proj.root, &proj.fields);
        if (std.mem.eql(u8, recorded_fp, now_fp)) {
            try out.print("ok    {s}/ matches {s} and {s}\n", .{ integrity.VENDOR_DIR, manifest.FILE_NAME, integrity.FILE_NAME });
        } else {
            try out.print("FAIL  {s}/ is inconsistent with {s} or {s}: run prolua vendor\n", .{ integrity.VENDOR_DIR, manifest.FILE_NAME, integrity.FILE_NAME });
            mismatched += 1;
        }
        var i: usize = 0;
        while (true) : (i += 1) {
            const table = try std.fmt.allocPrint(arena, "modules[{d}]", .{i});
            const module = doc.getString(table, "module") orelse break;
            const version = doc.getString(table, "version") orelse "-";
            const recorded = doc.getString(table, "hash") orelse "";
            if (prolua.import_path.validate(module)) |_| {} else |err| {
                try out.print("FAIL  {s}/{s}: entry {d} names '{s}': {s}\n", .{ integrity.VENDOR_DIR, integrity.VENDOR_FILE, i + 1, module, prolua.import_path.describe(err) });
                mismatched += 1;
                continue;
            }
            const dir = try std.fs.path.join(arena, &.{ vendor_dir, module });
            if ((try r.moduleAt(dir)) == null) {
                try out.print("FAIL  {s} {s} (vendor): {s} is missing or has no valid {s}\n", .{ module, version, dir, manifest.FILE_NAME });
                mismatched += 1;
                continue;
            }
            const hash = integrity.hashTree(arena, io, dir) catch |err| switch (err) {
                error.LinkToDirectory, error.DanglingLink => {
                    try out.print("FAIL  {s} {s} (vendor): {s}/{s} is a symbolic link to {s}\n", .{ module, version, dir, integrity.bad_link[0..integrity.bad_link_len], if (err == error.DanglingLink) "nothing" else "a directory" });
                    mismatched += 1;
                    continue;
                },
                else => return err,
            };
            const in_sum = sum.get(module, version);
            if (!std.mem.eql(u8, hash, recorded)) {
                try out.print("FAIL  {s} {s} (vendor): {s}\n      recorded {s}\n      found    {s}\n", .{ module, version, dir, recorded, hash });
                mismatched += 1;
            } else if (in_sum != null and !std.mem.eql(u8, hash, in_sum.?)) {
                try out.print("FAIL  {s} {s} (vendor): matches {s} but not {s}\n      {s} {s}\n      vendor    {s}\n", .{ module, version, integrity.VENDOR_FILE, integrity.FILE_NAME, integrity.FILE_NAME, in_sum.?, hash });
                mismatched += 1;
            } else {
                try out.print("ok    {s} {s} (vendor{s})\n", .{ module, version, if (in_sum != null) ", module.sum" else "" });
                verified += 1;
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (verified + mismatched + skipped == 0) {
        try out.print("nothing to verify: {s} has no entries and there is no {s}/\n", .{ integrity.FILE_NAME, integrity.VENDOR_DIR });
        return 0;
    }
    return finish(out, verified, mismatched, skipped);
}

fn finish(out: *std.Io.Writer, verified: usize, mismatched: usize, skipped: usize) !u8 {
    try out.print("{d} verified, {d} mismatched, {d} not cached\n", .{ verified, mismatched, skipped });
    return if (mismatched == 0) 0 else 1;
}
