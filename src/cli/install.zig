// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua install`: make every module the project depends on available
//! and record the result (docs/project/package-manager.md §14, §52.2).
//! Walks the dependency graph from the main module with minimum version
//! selection (the highest version any module in the graph asks for wins),
//! fetches into the cache what a replacement or `vendor/` does not provide,
//! checks each cached tree against `module.sum` and records the hash of a
//! new one, then writes `[indirectDependencies]` (every selected module the
//! main manifest does not list directly) and bumps a direct dependency
//! whose selected version rose above the declared one.

const std = @import("std");
const prolua = @import("prolua");
const manifest = prolua.manifest;
const resolver = prolua.resolver;
const source = prolua.source;
const integrity = prolua.integrity;
const stdio = prolua.stdio;
const main = @import("main.zig");
const project = @import("project.zig");

const Selected = struct {
    version: []const u8,
    /// Who asked for this version, for messages
    by: []const u8,
    /// Where it is, once placed
    dir: []const u8 = "",
    /// Whether it came through a replacement path (not hashed, not in module.sum)
    replaced: bool = false,
};

/// The resolved graph: every selected module with its version and
/// directory, for `vendor` and anything else that walks what `install`
/// walked. Strings live in the arena `resolveGraph` was given.
pub const Graph = struct {
    modules: []const GraphModule,
};

pub const GraphModule = struct {
    module: []const u8,
    version: []const u8,
    dir: []const u8,
    replaced: bool,
    /// The `module.sum` hash, when the module is cached
    hash: ?[]const u8,
};

pub const Options = struct {
    /// `--frozen`: fail instead of changing module.sum or module.toml (CI)
    frozen: bool = false,
};

/// Returns the exit code
pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, opts: Options) !u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    var proj = project.findFrom(allocator, io, cwd) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    } orelse {
        main.messagef("not inside a project: no {s} in {s} or above it (prolua init creates one)", .{ manifest.FILE_NAME, cwd });
        return 1;
    };
    defer proj.deinit(allocator);
    return run(allocator, io, environ, &proj, opts.frozen);
}

/// The install itself, on a loaded project: `add`, `remove` and `update`
/// call it after editing the manifest. Returns the exit code.
pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, proj: *const project.Project, frozen: bool) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out_buf: [4096]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    var sum = (try loadSum(allocator, io, proj.root)) orelse return 1;
    defer sum.deinit();
    var fetched: usize = 0;
    var selected = (try resolveGraph(allocator, arena, io, environ, proj, &sum, out, &fetched, false)) orelse return 1;

    switch (try writeManifest(allocator, arena, io, proj, &selected, &sum, out, frozen)) {
        .failed => return 1,
        .frozen_ok => {
            try out.print("{d} module{s} in the graph, {d} fetched; {s} and {s} unchanged\n", .{ selected.count(), if (selected.count() == 1) "" else "s", fetched, manifest.FILE_NAME, integrity.FILE_NAME });
            return 0;
        },
        .written => {},
    }
    sum.store(io, proj.root) catch |err| {
        try out.flush();
        main.messagef("cannot write {s}/{s}: {s}", .{ proj.root, integrity.FILE_NAME, @errorName(err) });
        return 1;
    };
    try out.print("{d} module{s} in the graph, {d} fetched; {s}: {d} entr{s}\n", .{ selected.count(), if (selected.count() == 1) "" else "s", fetched, integrity.FILE_NAME, sum.entries.items.len, if (sum.entries.items.len == 1) "y" else "ies" });
    return 0;
}

/// `module.sum` read, or null after reporting a malformed line
pub fn loadSum(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !?integrity.Sum {
    return integrity.Sum.load(allocator, io, root) catch |err| switch (err) {
        error.BadSumLine => {
            main.messagef("{s}/{s}:{d}: malformed line (expected '<module> <version> h1:<hash>'); fix or delete the line", .{ root, integrity.FILE_NAME, integrity.Sum.bad_line });
            return null;
        },
        else => return err,
    };
}

pub const WriteResult = enum { written, frozen_ok, failed };

/// After the graph: bump direct dependencies whose selected version rose,
/// rewrite [indirectDependencies], and write the manifest when it changed;
/// with `frozen`, fail instead when it or module.sum would change. Reports
/// its own failures.
pub fn writeManifest(allocator: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, proj: *const project.Project, selected: *const SelectedMap, sum: *integrity.Sum, out: *std.Io.Writer, frozen: bool) !WriteResult {
    const m = &proj.fields;
    const manifest_path = try std.fs.path.join(arena, &.{ proj.root, manifest.FILE_NAME });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(1 << 20));
    var edited: []u8 = try arena.dupe(u8, text);
    for (m.dependencies) |d| {
        const sel = selected.get(d.module).?;
        if (!std.mem.eql(u8, sel.version, d.version)) {
            edited = try manifest.setDependency(arena, edited, d.module, sel.version);
            try out.print("bumped {s} {s} -> {s} (required by {s})\n", .{ d.module, d.version, sel.version, sel.by });
        }
    }
    var indirect: std.ArrayList(manifest.Dependency) = .empty;
    var it = selected.iterator();
    while (it.next()) |e| {
        if (m.dependencyVersion(e.key_ptr.*) != null and isDirect(m, e.key_ptr.*)) continue;
        try indirect.append(arena, .{ .module = e.key_ptr.*, .version = e.value_ptr.version });
    }
    edited = try manifest.setIndirectDependencies(arena, edited, indirect.items);
    if (frozen) {
        const manifest_changes = !std.mem.eql(u8, edited, text);
        const sum_changes = try sum.differsFromFile(io, proj.root);
        if (manifest_changes or sum_changes) {
            try out.flush();
            main.messagef("--frozen: install would change {s}{s}{s}; run prolua install and commit the result", .{ if (manifest_changes) manifest.FILE_NAME else "", if (manifest_changes and sum_changes) " and " else "", if (sum_changes) integrity.FILE_NAME else "" });
            return .failed;
        }
        return .frozen_ok;
    }
    if (!std.mem.eql(u8, edited, text)) {
        var diag = manifest.Diagnostic{};
        var doc = manifest.parse(allocator, edited, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                try out.flush();
                main.messagef("internal error: the edited {s} does not read (line {d}: {s}); nothing written", .{ manifest.FILE_NAME, diag.line, diag.message });
                return .failed;
            },
        };
        defer doc.deinit();
        _ = manifest.Manifest.fromDocument(&doc, &diag) catch {
            try out.flush();
            main.messagef("internal error: the edited {s} is invalid ({s}); nothing written", .{ manifest.FILE_NAME, diag.message });
            return .failed;
        };
        manifest.writeFileAtomic(io, arena, manifest_path, edited) catch |err| {
            try out.flush();
            main.messagef("cannot write {s}: {s}", .{ manifest_path, @errorName(err) });
            return .failed;
        };
        if (indirect.items.len > 0) {
            try out.print("{s}: [indirectDependencies] {d} module{s}\n", .{ manifest.FILE_NAME, indirect.items.len, if (indirect.items.len == 1) "" else "s" });
        } else if (m.indirect.len > 0) {
            try out.print("{s}: [indirectDependencies] cleared\n", .{manifest.FILE_NAME});
        }
    }
    return .written;
}

pub const SelectedMap = std.StringArrayHashMapUnmanaged(Selected);

/// Walk the graph from the main manifest with minimum version selection,
/// placing (and fetching) each module and checking it against `sum`,
/// which is pruned to the selected versions. Null after reporting
/// failures. Every string in the result is copied into `arena`: the
/// manifests they were read from belong to the resolver, which is gone
/// when this returns (reading them after that produced module names made
/// of manifest fragments, once, in a vendor tree).
pub fn resolveGraph(allocator: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, proj: *const project.Project, sum: *integrity.Sum, out: *std.Io.Writer, fetched: *usize, ignore_vendor: bool) !?SelectedMap {
    const m = &proj.fields;
    const cwd = try std.process.currentPathAlloc(io, arena);
    // Placement here is the install's own; a stale vendor/ must not stop it
    var r = try resolver.Resolver.initWith(allocator, io, environ, proj.root, m, cwd, true);
    defer r.deinit();

    var selected: SelectedMap = .empty;
    var work: std.ArrayList([]const u8) = .empty;
    for (m.dependencies) |d| {
        const module = try arena.dupe(u8, d.module);
        try selected.put(arena, module, .{ .version = try arena.dupe(u8, d.version), .by = try arena.dupe(u8, m.module) });
        try work.append(arena, module);
    }
    var failures: usize = 0;
    // The cached module versions in the final graph: what module.sum keeps
    var hashed: std.ArrayList([4][]const u8) = .empty;
    // A module already placed at its selected version is not placed again
    var done: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    while (work.pop()) |module| {
        const sel = selected.getPtr(module).?;
        if (done.get(module)) |v| if (std.mem.eql(u8, v, sel.version)) continue;
        try done.put(arena, module, sel.version);
        const placed = (try placeOrFetch(&r, arena, allocator, io, environ, m, proj.root, module, sel.*, sum, out, fetched, &hashed, ignore_vendor)) orelse {
            failures += 1;
            continue;
        };
        sel.dir = try arena.dupe(u8, placed.dir);
        sel.replaced = placed.replaced;
        const known = (try r.moduleAt(placed.dir)) orelse {
            try out.flush();
            main.messagef("{s} {s} at {s} has no valid {s}", .{ module, sel.version, placed.dir, manifest.FILE_NAME });
            failures += 1;
            continue;
        };
        for (known.fields.dependencies) |dep| {
            if (std.mem.eql(u8, dep.module, m.module)) continue;
            const dep_module = try arena.dupe(u8, dep.module);
            const dep_version = try arena.dupe(u8, dep.version);
            if (selected.get(dep_module)) |cur| {
                if (versionLess(cur.version, dep_version)) {
                    try selected.put(arena, dep_module, .{ .version = dep_version, .by = module });
                    try work.append(arena, dep_module);
                }
            } else {
                try selected.put(arena, dep_module, .{ .version = dep_version, .by = module });
                try work.append(arena, dep_module);
            }
        }
    }
    if (failures > 0) {
        try out.flush();
        main.messagef("{d} module{s} could not be installed; {s} and {s} left unchanged", .{ failures, if (failures == 1) "" else "s", manifest.FILE_NAME, integrity.FILE_NAME });
        return null;
    }
    // Only the selected versions stay in module.sum
    var keep: std.ArrayList([2][]const u8) = .empty;
    for (hashed.items) |h| {
        const sel = selected.get(h[2]) orelse continue;
        if (std.mem.eql(u8, sel.version, h[3])) try keep.append(arena, .{ h[0], h[1] });
    }
    sum.retain(keep.items);
    // `by` for a module selected by a transitive requirer names that module: copied above
    return selected;
}

fn isDirect(m: *const manifest.Manifest, module: []const u8) bool {
    for (m.dependencies) |d| if (std.mem.eql(u8, d.module, module)) return true;
    return false;
}

/// `a < b` for two `vX.Y.Z` strings (a malformed one sorts low)
pub fn versionLess(a: []const u8, b: []const u8) bool {
    const va = std.SemanticVersion.parse(if (a.len > 0 and a[0] == 'v') a[1..] else a) catch return true;
    const vb = std.SemanticVersion.parse(if (b.len > 0 and b[0] == 'v') b[1..] else b) catch return false;
    return std.SemanticVersion.order(va, vb) == .lt;
}

const Placed = struct { dir: []const u8, replaced: bool };

/// The directory `module` at the selected version comes from: a
/// replacement or vendor/ as they are, the cache after a fetch when it is
/// not there yet, checked against module.sum. Null after reporting a failure.
fn placeOrFetch(r: *resolver.Resolver, arena: std.mem.Allocator, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, m: *const manifest.Manifest, root: []const u8, module: []const u8, sel: Selected, sum: *integrity.Sum, out: *std.Io.Writer, fetched: *usize, hashed: *std.ArrayList([4][]const u8), ignore_vendor: bool) !?Placed {
    var cache_module = module;
    var cache_version = sel.version;
    if (m.replacement(module)) |rep| {
        if (rep.path) |p| {
            const dir = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ root, p });
            if ((try r.moduleAt(dir)) == null) {
                try out.flush();
                main.messagef("{s}: the replacement path {s} has no valid {s}", .{ module, p, manifest.FILE_NAME });
                return null;
            }
            try out.print("replaced {s} -> {s}\n", .{ module, p });
            return .{ .dir = dir, .replaced = true };
        }
        cache_module = rep.target_module.?;
        cache_version = rep.target_version.?;
    }
    if (!ignore_vendor) {
        const vendored = try std.fs.path.join(arena, &.{ root, "vendor", module });
        if ((try r.moduleAt(vendored)) != null) {
            try out.print("vendored {s}\n", .{module});
            return .{ .dir = vendored, .replaced = false };
        }
    }

    const dir = try r.cachePath(arena, cache_module, cache_version);
    if ((try r.moduleAt(dir)) == null) {
        const repo = (try source.repoFor(arena, cache_module, environ)) orelse {
            try out.flush();
            main.messagef("{s}: no source for host '{s}' (github.com, gitlab.com and codeberg.org are built in; PROLUA_SOURCES=host=url names another; DNS discovery is not implemented yet); vendor it or add [replacements.\"{s}\"] path = \"...\"", .{ cache_module, hostOf(cache_module), module });
            return null;
        };
        var diagnostic: []const u8 = "";
        source.fetch(allocator, io, environ, repo, cache_version, dir, &diagnostic) catch |err| {
            try out.flush();
            main.messagef("{s} {s}: fetch from {s} failed: {s}", .{ cache_module, cache_version, repo.url, diagnostic });
            if (err == error.GitFailed) allocator.free(diagnostic);
            return null;
        };
        if ((try r.moduleAt(dir)) == null) {
            try out.flush();
            main.messagef("{s} {s}: the fetched tree has no valid {s}", .{ cache_module, cache_version, manifest.FILE_NAME });
            return null;
        }
        fetched.* += 1;
        try out.print("fetched {s} {s} ({s})\n", .{ cache_module, cache_version, repo.url });
    } else {
        try out.print("cached {s} {s}\n", .{ cache_module, cache_version });
    }
    const known = (try r.moduleAt(dir)).?;
    if (!std.mem.eql(u8, known.fields.module, cache_module)) {
        try out.flush();
        main.messagef("{s} {s}: the tree at {s} declares module {s}", .{ cache_module, cache_version, dir, known.fields.module });
        return null;
    }
    // Integrity: the tree must match what module.sum recorded, or be new to it
    const hash = integrity.hashTree(allocator, io, dir) catch |err| switch (err) {
        error.LinkToDirectory, error.DanglingLink => {
            try out.flush();
            main.messagef("{s} {s}: {s}/{s} is a symbolic link to {s}; a module's files must all lie inside it", .{ cache_module, cache_version, dir, integrity.bad_link[0..integrity.bad_link_len], if (err == error.DanglingLink) "nothing" else "a directory" });
            return null;
        },
        else => return err,
    };
    defer allocator.free(hash);
    if (sum.get(cache_module, cache_version)) |recorded| {
        if (!std.mem.eql(u8, recorded, hash)) {
            try out.flush();
            main.messagef("integrity: {s} {s} in the cache ({s}) does not match {s}\n\trecorded {s}\n\tfound    {s}\n\tdelete the cached copy to fetch it again, or remove the line if the change is yours", .{ cache_module, cache_version, dir, integrity.FILE_NAME, recorded, hash });
            return null;
        }
    } else {
        try sum.set(cache_module, cache_version, hash);
    }
    // cached identity, then the graph identity it was selected under
    try hashed.append(arena, .{ cache_module, cache_version, module, sel.version });
    return .{ .dir = dir, .replaced = false };
}

fn hostOf(module: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, module, '/')) |i| module[0..i] else module;
}

test "version order" {
    try std.testing.expect(versionLess("v1.0.0", "v1.0.1"));
    try std.testing.expect(versionLess("v1.9.0", "v1.10.0"));
    try std.testing.expect(!versionLess("v2.0.0", "v1.10.0"));
    try std.testing.expect(!versionLess("v1.0.0", "v1.0.0"));
    try std.testing.expect(versionLess("v1.0.0-beta", "v1.0.0"));
}
