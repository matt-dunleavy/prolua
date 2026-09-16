// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua add <module>[@<version>|@latest] [--path <dir>]`: declare a
//! dependency in the project's `module.toml` and install it. With
//! `--path`, the checkout at `dir` (whose manifest must name that module)
//! also becomes a `[replacements."<module>"] path = "..."` entry,
//! relative to the project root, and supplies the default version.
//! Without it, `@latest` (the default) asks the module's source for its
//! highest release tag. The file is edited in place, one line changed or
//! added, and then `install` runs, so the module and its own dependencies
//! are fetched, selected and recorded in one step.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const import_path = prolua.import_path;
const resolver = prolua.resolver;
const source = prolua.source;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");
const install = @import("install.zig");

pub const Options = struct {
    /// `<module>` or `<module>@<version>`
    spec: []const u8,
    path: ?[]const u8 = null,
};

pub const isVersion = manifest.isVersion;

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, opts: Options) !u8 {
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

    // The module and, if given, the version
    var module = opts.spec;
    var version: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, opts.spec, '@')) |at| {
        module = opts.spec[0..at];
        const v = opts.spec[at + 1 ..];
        if (std.mem.eql(u8, v, "latest")) {
            version = null;
        } else if (isVersion(v)) {
            version = v;
        } else {
            main.messagef("'{s}' is not a version: vMAJOR.MINOR.PATCH, or latest, as in {s}@v1.0.0", .{ v, module });
            return 1;
        }
    }
    if (!import_path.isNamespace(module)) {
        main.messagef("'{s}' is not a module path: the first component is a host, as in github.com/matt-dunleavy/json", .{module});
        return 1;
    }
    import_path.validate(module) catch |err| {
        main.messagef("invalid module path '{s}': {s}", .{ module, import_path.describe(err) });
        return 1;
    };
    if (std.mem.eql(u8, module, proj.fields.module)) {
        main.messagef("{s} is this project's own module", .{module});
        return 1;
    }

    var r = try resolver.Resolver.init(allocator, io, environ, proj.root, &proj.fields, cwd);
    defer r.deinit();

    // Where the module comes from: a checkout, or a placement that already exists
    var replacement_path: ?[]const u8 = null;
    if (opts.path) |p| {
        const known = (try r.moduleAt(p)) orelse {
            main.messagef("{s} has no valid {s}: --path names a module's checkout", .{ p, manifest.FILE_NAME });
            return 1;
        };
        if (!std.mem.eql(u8, known.fields.module, module)) {
            main.messagef("{s}/{s} declares module {s}, not {s}", .{ p, manifest.FILE_NAME, known.fields.module, module });
            return 1;
        }
        if (version == null) {
            version = known.fields.version orelse {
                main.messagef("{s}/{s} has no version: give one, as in {s}@v0.1.0", .{ p, manifest.FILE_NAME, module });
                return 1;
            };
        }
        // Recorded relative to the project root, absolute if it was given absolute
        if (std.fs.path.isAbsolute(p)) {
            replacement_path = p;
        } else {
            const abs = try std.fs.path.resolve(arena, &.{ cwd, p });
            const root_abs = try std.fs.path.resolve(arena, &.{ cwd, proj.root });
            replacement_path = try std.fs.path.relative(arena, cwd, environ, root_abs, abs);
        }
    } else if (version == null) {
        // @latest: the highest release the source has a tag for
        const vendored = try std.fs.path.join(arena, &.{ proj.root, "vendor", module });
        if (try r.moduleAt(vendored)) |k| {
            version = k.fields.version orelse {
                main.messagef("{s} is vendored without a version in its {s}: give one, as in {s}@v0.1.0", .{ module, manifest.FILE_NAME, module });
                return 1;
            };
        } else {
            const repo = (try source.repoFor(arena, module, environ)) orelse {
                main.messagef("{s}: no source for host '{s}' (github.com, gitlab.com and codeberg.org are built in; PROLUA_SOURCES=host=url names another; DNS discovery is not implemented yet); give --path <checkout> or vendor it", .{ module, hostOf(module) });
                return 1;
            };
            var diagnostic: []const u8 = "";
            const versions = source.listVersions(arena, io, environ, repo, &diagnostic) catch {
                main.messagef("{s}: listing the tags of {s} failed: {s}", .{ module, repo.url, diagnostic });
                return 1;
            };
            version = source.latest(versions) orelse {
                main.messagef("{s}: {s} has no version tags (vMAJOR.MINOR.PATCH); give --path <checkout>", .{ module, repo.url });
                return 1;
            };
            stdio.print("{s}: latest is {s} ({d} version{s} at {s})\n", .{ module, version.?, versions.len, if (versions.len == 1) "" else "s", repo.url });
        }
    }

    // Edit the manifest text, check it still reads, write it back
    const manifest_path = try std.fs.path.join(arena, &.{ proj.root, manifest.FILE_NAME });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(1 << 20));
    var edited = try manifest.setDependency(arena, text, module, version.?);
    if (replacement_path) |rp| edited = try manifest.setReplacementPath(arena, edited, module, rp);
    var diag = manifest.Diagnostic{};
    var doc = manifest.parse(allocator, edited, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            main.messagef("internal error: the edited {s} does not read (line {d}: {s}); nothing written", .{ manifest.FILE_NAME, diag.line, diag.message });
            return 1;
        },
    };
    defer doc.deinit();
    _ = manifest.Manifest.fromDocument(&doc, &diag) catch {
        main.messagef("internal error: the edited {s} is invalid ({s}); nothing written", .{ manifest.FILE_NAME, diag.message });
        return 1;
    };
    manifest.writeFileAtomic(io, arena, manifest_path, edited) catch |err| {
        main.messagef("cannot write {s}: {s}", .{ manifest_path, @errorName(err) });
        return 1;
    };

    // what the direct dependency was, if it was one (an indirect one is new here)
    var was: ?[]const u8 = null;
    for (proj.fields.dependencies) |d| if (std.mem.eql(u8, d.module, module)) {
        was = d.version;
    };
    if (was) |w| {
        stdio.print("{s}: {s} {s} -> {s}\n", .{ manifest.FILE_NAME, module, w, version.? });
    } else {
        stdio.print("{s}: added {s} {s}\n", .{ manifest.FILE_NAME, module, version.? });
    }
    if (replacement_path) |rp| stdio.print("  replaced by the checkout at {s}\n", .{rp});

    // Then install: fetch, select, record, on the manifest as it now reads
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

test "versions" {
    try std.testing.expect(isVersion("v1.0.0"));
    try std.testing.expect(isVersion("v0.1.0-beta.1"));
    try std.testing.expect(!isVersion("1.0.0"));
    try std.testing.expect(!isVersion("v1.0"));
    try std.testing.expect(!isVersion("latest"));
}
