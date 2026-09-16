// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.
//! The module searcher (docs/project/package-manager.md, Phase 1: no
//! network). `require "<host>/<path>"`, a package path whose first
//! component is a DNS name, resolves to a file on disk through the main
//! module's manifest:
//!
//!   1. the main module itself, and the module the requiring file lives in
//!   2. `[replacements."<module>"]` in the main module's `module.toml`:
//!      `path` to a local checkout, or another `module` at a `version`
//!   3. `<root>/vendor/<module>/`
//!   4. the module cache, `<cache>/modules/<module>/<version>/`, at the
//!      version `[dependencies]` or `[indirectDependencies]` gives, or,
//!      until `prolua install` maintains the indirect list, the version
//!      the requiring module's own manifest gives
//!
//! and then `<module>/src/<package>/init.lua` or `<module>/src/<package>.lua`
//! (`src/init.lua` for the module itself). A package with an `internal`
//! component loads only from files inside the same module. Outside a
//! project, module paths fail with a message that says so; ordinary
//! `require` names never reach this searcher.

const std = @import("std");
const manifest = @import("manifest.zig");
const import_path = @import("import_path.zig");
pub const integrity = @import("integrity.zig");
const state = @import("../state.zig");
const api = @import("../api.zig");
const aux = @import("../lib/auxlib.zig");
const debug = @import("../debug.zig");

const LuaState = state.LuaState;

/// A module whose manifest has been read: a dependency loaded from a
/// replacement, the vendor tree or the cache, or the module a requiring
/// file turned out to live in
pub const Known = struct {
    dir: []const u8,
    doc: manifest.Document,
    fields: manifest.Manifest,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The main module: its root directory and manifest, or null outside a
    /// project (then `where` says where the search started)
    root: ?[]const u8,
    main: ?*const manifest.Manifest,
    where: []const u8,
    cwd: []const u8,
    cache: []const u8,
    /// Vendor mode (§41): `<root>/vendor/modules.toml` exists and matches
    /// the manifest, so modules come from `vendor/` and nowhere else
    vendor_mode: bool = false,
    /// Manifests read on demand, by module directory
    known: std.StringHashMapUnmanaged(*Known) = .empty,

    pub const InitError = error{ VendorInconsistent, VendorManifestInvalid } || std.mem.Allocator.Error || anyerror;

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        root: ?[]const u8,
        main: ?*const manifest.Manifest,
        where: []const u8,
    ) InitError!Resolver {
        return initWith(allocator, io, environ, root, main, where, false);
    }

    /// `ignore_vendor`: place nothing from `vendor/` and do not check it,
    /// for the command that regenerates it
    pub fn initWith(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        root: ?[]const u8,
        main: ?*const manifest.Manifest,
        where: []const u8,
        ignore_vendor: bool,
    ) InitError!Resolver {
        const cwd_z: ?[:0]u8 = std.process.currentPathAlloc(io, allocator) catch null;
        defer if (cwd_z) |c| allocator.free(c);
        const cwd = try allocator.dupe(u8, if (cwd_z) |c| c else ".");
        errdefer allocator.free(cwd);
        const cache = try cacheDir(allocator, environ);
        errdefer allocator.free(cache);
        var self: Resolver = .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .main = main,
            .where = try allocator.dupe(u8, where),
            .cwd = cwd,
            .cache = cache,
        };
        errdefer allocator.free(self.where);
        if (!ignore_vendor) if (root) |r| if (main) |m| {
            self.vendor_mode = try vendorModeFor(allocator, io, r, m);
        };
        return self;
    }

    /// Whether `<root>/vendor/modules.toml` exists; when it does, it must
    /// carry the fingerprint of the current manifest and module.sum (§42)
    fn vendorModeFor(allocator: std.mem.Allocator, io: std.Io, root: []const u8, m: *const manifest.Manifest) InitError!bool {
        const path = try std.fs.path.join(allocator, &.{ root, integrity.VENDOR_DIR, integrity.VENDOR_FILE });
        defer allocator.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 24)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer allocator.free(text);
        var diag = manifest.Diagnostic{};
        var doc = manifest.parse(allocator, text, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => return error.VendorManifestInvalid,
        };
        defer doc.deinit();
        const recorded = doc.getString("", "fingerprint") orelse return error.VendorManifestInvalid;
        const now = try integrity.fingerprint(allocator, io, root, m);
        defer allocator.free(now);
        if (!std.mem.eql(u8, recorded, now)) return error.VendorInconsistent;
        return true;
    }

    pub fn deinit(self: *Resolver) void {
        var it = self.known.iterator();
        while (it.next()) |e| {
            const k = e.value_ptr.*;
            k.doc.deinit();
            self.allocator.free(k.dir);
            self.allocator.destroy(k);
        }
        self.known.deinit(self.allocator);
        self.allocator.free(self.where);
        self.allocator.free(self.cwd);
        self.allocator.free(self.cache);
    }

    /// `$PROLUA_CACHE`, else `$XDG_CACHE_HOME/prolua`, else `~/.cache/prolua`
    fn cacheDir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
        if (environ.get("PROLUA_CACHE")) |d| if (d.len > 0) return allocator.dupe(u8, d);
        if (environ.get("XDG_CACHE_HOME")) |d| if (d.len > 0) return std.fs.path.join(allocator, &.{ d, "prolua" });
        if (environ.get("HOME")) |h| if (h.len > 0) return std.fs.path.join(allocator, &.{ h, ".cache", "prolua" });
        return allocator.dupe(u8, ".prolua-cache");
    }

    fn exists(self: *const Resolver, path: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }

    /// The manifest of the module rooted at `dir`, read once; null when
    /// `dir` has no readable, valid manifest
    pub fn moduleAt(self: *Resolver, dir: []const u8) !?*const Known {
        if (self.known.get(dir)) |k| return k;
        const path = try std.fs.path.join(self.allocator, &.{ dir, manifest.FILE_NAME });
        defer self.allocator.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 20)) catch return null;
        defer self.allocator.free(text);
        var diag = manifest.Diagnostic{};
        var doc = manifest.parse(self.allocator, text, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => return null,
        };
        errdefer doc.deinit();
        const fields = manifest.Manifest.fromDocument(&doc, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return null,
        };
        const k = try self.allocator.create(Known);
        errdefer self.allocator.destroy(k);
        k.* = .{ .dir = try self.allocator.dupe(u8, dir), .doc = doc, .fields = fields };
        try self.known.put(self.allocator, k.dir, k);
        return k;
    }

    /// The module the file at `file` belongs to: the nearest `module.toml`
    /// above it
    fn moduleOf(self: *Resolver, file: []const u8) !?*const Known {
        var dir: []const u8 = std.fs.path.dirname(file) orelse ".";
        while (true) {
            if (self.root) |r| if (std.mem.eql(u8, dir, r)) return null; // the main module: handled by the caller
            if (try self.moduleAt(dir)) |k| return k;
            const parent = std.fs.path.dirname(dir) orelse return null;
            if (parent.len == dir.len) return null;
            dir = parent;
        }
    }

    fn absolute(self: *const Resolver, arena: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fs.path.resolve(arena, &.{ self.cwd, path });
    }

    fn isInside(self: *const Resolver, arena: std.mem.Allocator, file: []const u8, dir: []const u8) !bool {
        const f = try self.absolute(arena, file);
        const d = try self.absolute(arena, dir);
        return std.mem.startsWith(u8, f, d) and f.len > d.len and f[d.len] == std.fs.path.sep;
    }

    pub const Result = union(enum) {
        /// Not a module path: leave it to the other searchers
        not_module,
        /// The file to load, and the module it belongs to
        found: struct { file: []u8, module: []const u8 },
        /// Why not, for `require`'s report
        not_found: []u8,

        pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .found => |f| allocator.free(f.file),
                .not_found => |m| allocator.free(m),
                .not_module => {},
            }
        }
    };

    /// Where `package_path` resolves for a `require` issued from the chunk
    /// loaded from `requirer` (null when unknown, as from `-e` or the REPL)
    pub fn resolve(self: *Resolver, package_path: []const u8, requirer: ?[]const u8) !Result {
        if (!import_path.isNamespace(package_path)) return .not_module;
        if (import_path.validate(package_path)) |_| {} else |err| {
            return .{ .not_found = try std.fmt.allocPrint(self.allocator, "invalid module path '{s}': {s}", .{ package_path, import_path.describe(err) }) };
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const requirer_module: ?*const Known = if (requirer) |r| try self.moduleOf(r) else null;

        // The longest prefix of the package path that names a module we can place
        var notes: std.Io.Writer.Allocating = .init(arena);
        var end: usize = package_path.len;
        while (true) {
            const module = package_path[0..end];
            const suffix = if (end < package_path.len) package_path[end + 1 ..] else "";
            if (try self.locate(arena, module, requirer_module, &notes)) |dir| {
                return self.packageIn(dir, module, suffix, requirer, arena);
            }
            end = std.mem.lastIndexOfScalar(u8, package_path[0..end], '/') orelse break;
        }

        var msg: std.Io.Writer.Allocating = .init(arena);
        const w = &msg.writer;
        try w.print("no module provides '{s}'", .{package_path});
        if (self.root) |r| {
            try w.print("\n\t(main module {s} at {s}", .{ self.main.?.module, r });
            if (requirer_module) |k| try w.print("; required from module {s} at {s}", .{ k.fields.module, k.dir });
            if (self.vendor_mode) {
                try w.print(": not in vendor/ (vendor mode: {s}/{s} exists; run prolua vendor after changing dependencies){s}", .{ integrity.VENDOR_DIR, integrity.VENDOR_FILE, notes.written() });
            } else {
                try w.print(": no [replacements] entry, not in vendor/{s}", .{notes.written()});
            }
            try w.writeAll(")");
        } else {
            try w.print("\n\t(not inside a project: no {s} in {s} or above it; prolua init creates one)", .{ manifest.FILE_NAME, self.where });
        }
        return .{ .not_found = try self.allocator.dupe(u8, msg.written()) };
    }

    /// How a module was placed, for `tree` and for messages
    pub const How = enum {
        main,
        requirer,
        replacement_path,
        replacement_module,
        vendor,
        cache,
        /// From the requiring module's own manifest, not the main module's
        cache_via_requirer,
    };

    pub const Placement = struct {
        dir: []const u8,
        how: How,
        /// The version the placement was made at, when one was involved
        version: ?[]const u8 = null,
    };

    /// Where `module` (a module path, no package suffix) is placed for a
    /// require from inside the module at `requirer_dir`, or null with the
    /// reasons appended to `notes`; strings live in `arena`
    pub fn place(self: *Resolver, arena: std.mem.Allocator, module: []const u8, requirer_dir: ?[]const u8, notes: *std.Io.Writer.Allocating) !?Placement {
        const requirer_module: ?*const Known = if (requirer_dir) |d| try self.moduleAt(d) else null;
        return self.placeModule(arena, module, requirer_module, notes);
    }

    fn placeModule(self: *Resolver, arena: std.mem.Allocator, module: []const u8, requirer_module: ?*const Known, notes: *std.Io.Writer.Allocating) !?Placement {
        if (self.main) |m| if (std.mem.eql(u8, module, m.module)) return .{ .dir = self.root.?, .how = .main, .version = m.version };
        if (requirer_module) |k| if (std.mem.eql(u8, module, k.fields.module)) return .{ .dir = k.dir, .how = .requirer, .version = k.fields.version };
        if (self.vendor_mode) {
            const vendored = try std.fs.path.join(arena, &.{ self.root.?, integrity.VENDOR_DIR, module });
            if (try self.moduleAt(vendored)) |k| return .{ .dir = vendored, .how = .vendor, .version = k.fields.version };
            return null; // the summary says vendor mode is on
        }
        if (self.main) |m| {
            if (m.replacement(module)) |rep| {
                if (rep.path) |p| {
                    const dir = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ self.root.?, p });
                    if (try self.moduleAt(dir)) |k| return .{ .dir = dir, .how = .replacement_path, .version = k.fields.version };
                    try notes.writer.print(", replacement path {s} has no {s}", .{ dir, manifest.FILE_NAME });
                    return null;
                }
                if (try self.cached(arena, rep.target_module.?, rep.target_version.?, notes)) |dir| {
                    return .{ .dir = dir, .how = .replacement_module, .version = rep.target_version };
                }
                return null;
            }
            const vendored = try std.fs.path.join(arena, &.{ self.root.?, "vendor", module });
            if (try self.moduleAt(vendored)) |k| return .{ .dir = vendored, .how = .vendor, .version = k.fields.version };
            if (m.dependencyVersion(module)) |v| {
                if (try self.cached(arena, module, v, notes)) |dir| return .{ .dir = dir, .how = .cache, .version = v };
                return null;
            }
        }
        if (requirer_module) |k| {
            if (k.fields.dependencyVersion(module)) |v| {
                if (try self.cached(arena, module, v, notes)) |dir| return .{ .dir = dir, .how = .cache_via_requirer, .version = v };
                return null;
            }
        }
        return null;
    }

    /// The directory of `module`, if the main module, the requiring
    /// module, a replacement, the vendor tree or the cache places it
    fn locate(self: *Resolver, arena: std.mem.Allocator, module: []const u8, requirer_module: ?*const Known, notes: *std.Io.Writer.Allocating) !?[]const u8 {
        const p = (try self.placeModule(arena, module, requirer_module, notes)) orelse return null;
        return p.dir;
    }

    /// `<cache>/modules/<module>/<version>`, when it holds a manifest
    pub fn cachePath(self: *const Resolver, arena: std.mem.Allocator, module: []const u8, version: []const u8) ![]u8 {
        return std.fs.path.join(arena, &.{ self.cache, "modules", module, version });
    }

    fn cached(self: *Resolver, arena: std.mem.Allocator, module: []const u8, version: []const u8, notes: *std.Io.Writer.Allocating) !?[]const u8 {
        const dir = try self.cachePath(arena, module, version);
        if (try self.moduleAt(dir)) |_| return dir;
        try notes.writer.print(", {s} {s} is declared but not in the cache at {s} (run prolua install; or vendor it, or point [replacements.\"{s}\"] path = \"...\" at a checkout)", .{ module, version, dir, module });
        return null;
    }

    fn packageIn(self: *Resolver, dir: []const u8, module: []const u8, suffix: []const u8, requirer: ?[]const u8, arena: std.mem.Allocator) !Result {
        if (hasComponent(suffix, "internal")) {
            const inside = if (requirer) |r| try self.isInside(arena, r, dir) else false;
            if (!inside) {
                return .{ .not_found = try std.fmt.allocPrint(self.allocator, "'{s}/{s}' is internal to module {s}: only its own files may require it", .{ module, suffix, module }) };
            }
        }
        const src = try std.fs.path.join(arena, &.{ dir, "src" });
        var candidates: [2][]const u8 = undefined;
        var n: usize = 0;
        if (suffix.len == 0) {
            candidates[0] = try std.fs.path.join(arena, &.{ src, "init.lua" });
            n = 1;
        } else {
            candidates[0] = try std.fs.path.join(arena, &.{ src, suffix, "init.lua" });
            candidates[1] = try std.fmt.allocPrint(arena, "{s}/{s}.lua", .{ src, suffix });
            n = 2;
        }
        for (candidates[0..n]) |c| {
            if (!self.exists(c)) continue;
            // The file, with links followed, must lie inside the module's
            // directory: a link out of the tree is not a package of it
            const real_file = std.Io.Dir.cwd().realPathFileAlloc(self.io, c, arena) catch continue;
            const real_dir = std.Io.Dir.cwd().realPathFileAlloc(self.io, dir, arena) catch continue;
            if (!(std.mem.startsWith(u8, real_file, real_dir) and real_file.len > real_dir.len and real_file[real_dir.len] == std.fs.path.sep)) {
                return .{ .not_found = try std.fmt.allocPrint(self.allocator, "'{s}/{s}' resolves to {s}, outside module {s} at {s}: a link out of a module is not a package of it", .{ module, suffix, real_file, module, dir }) };
            }
            return .{ .found = .{ .file = try self.allocator.dupe(u8, c), .module = module } };
        }
        var msg: std.Io.Writer.Allocating = .init(arena);
        const w = &msg.writer;
        try w.print("module {s} at {s} has no package '{s}'", .{ module, dir, if (suffix.len == 0) "(root)" else suffix });
        for (candidates[0..n]) |c| try w.print("\n\tno file '{s}'", .{c});
        return .{ .not_found = try self.allocator.dupe(u8, msg.written()) };
    }
};

fn hasComponent(path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// The searcher, as `package.searchers[2]`
// ---------------------------------------------------------------------------

/// Put the resolver's searcher after the preload searcher, so module paths
/// are handled before `package.path` is consulted. The searcher keeps the
/// pointer, so `r` must stay at that address for as long as the state can
/// call `require`: heap-allocate it (`create`), never install a local.
pub fn install(L: *LuaState, r: *Resolver) !void {
    if ((try api.getGlobal(L, "package")) != .table) return error.NoPackageTable;
    if ((try api.getField(L, -1, "searchers")) != .table) return error.NoSearchers;
    var i: i64 = @intCast(api.rawLen(L, -1));
    while (i >= 2) : (i -= 1) {
        try api.rawGetI(L, -1, i);
        try api.rawSetI(L, -2, i + 1);
    }
    try api.pushLightUserdata(L, @ptrCast(r));
    try api.pushCClosure(L, searcher, 1);
    try api.rawSetI(L, -2, 2);
    api.pop(L, 2);
}

/// The source file of the nearest Lua function up the stack: the chunk
/// that called `require`
fn requirerFile(L: *LuaState) ?[]const u8 {
    var level: i32 = 1;
    while (level < 16) : (level += 1) {
        const ci = debug.getStack(L, level) orelse return null;
        const cl = ci.func[0].asClosure() orelse continue;
        const src = cl.proto.source orelse continue;
        const s = src.slice();
        if (s.len > 1 and s[0] == '@') return s[1..];
    }
    return null;
}

fn searcher(L: *LuaState) !i32 {
    const name = try api.checkString(L, 1);
    const r: *Resolver = @ptrCast(@alignCast(api.toUserdata(L, api.upvalueIndex(1)) orelse return error.NoResolver));
    var result = try r.resolve(name, requirerFile(L));
    defer result.deinit(r.allocator);
    switch (result) {
        .not_module => return 0,
        .not_found => |msg| {
            try api.pushString(L, msg);
            return 1;
        },
        .found => |f| {
            if (api.loadFile(L, f.file, "bt") != .ok) {
                const msg = api.toString(L, -1) orelse "syntax error";
                return aux.err(L, "error loading module '{s}' from file '{s}':\n\t{s}", .{ name, f.file, msg });
            }
            try api.pushString(L, f.file);
            return 2;
        },
    }
}

test "components" {
    try std.testing.expect(hasComponent("a/internal/b", "internal"));
    try std.testing.expect(hasComponent("internal", "internal"));
    try std.testing.expect(!hasComponent("internals/x", "internal"));
}

// ---------------------------------------------------------------------------
// Tests on a real directory tree, under the leak-checking test allocator
// ---------------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    environ: std.process.Environ.Map,

    fn init() !Fixture {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(root);
        var environ = std.process.Environ.Map.init(a);
        errdefer environ.deinit();
        const cache = try std.fs.path.join(a, &.{ root, "cache" });
        defer a.free(cache);
        try environ.put("PROLUA_CACHE", cache);
        return .{ .tmp = tmp, .root = root, .environ = environ };
    }

    fn deinit(self: *Fixture) void {
        self.environ.deinit();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, text: []const u8) !void {
        const io = std.testing.io;
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.createDirPath(io, d);
        try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = text });
    }

    fn join(self: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.root, rel });
    }

    /// The graph the tests share: app (main) with a replaced sibling `one`
    /// that has an internal package and its own cached dependency `four`, a
    /// vendored `two`, and a cached `three`
    fn populate(self: *Fixture) !void {
        try self.write("app/module.toml",
            \\schema = 1
            \\module = "example.com/me/app"
            \\
            \\[dependencies]
            \\"example.com/lib/one" = "v0.1.0"
            \\"example.com/lib/three" = "v1.0.0"
            \\
            \\[replacements."example.com/lib/one"]
            \\path = "../one"
            \\
        );
        try self.write("app/src/init.lua", "return 'app'\n");
        try self.write("app/src/util.lua", "return 'util'\n");
        try self.write("app/src/util/deep.lua", "return 'deep'\n");
        try self.write("app/vendor/example.com/lib/two/module.toml", "schema = 1\nmodule = \"example.com/lib/two\"\n");
        try self.write("app/vendor/example.com/lib/two/src/init.lua", "return 'two'\n");
        try self.write("one/module.toml", "schema = 1\nmodule = \"example.com/lib/one\"\n[dependencies]\n\"example.com/lib/four\" = \"v2.0.0\"\n");
        try self.write("one/src/init.lua", "return 'one'\n");
        try self.write("one/src/internal/init.lua", "return 'secret'\n");
        try self.write("cache/modules/example.com/lib/three/v1.0.0/module.toml", "schema = 1\nmodule = \"example.com/lib/three\"\n");
        try self.write("cache/modules/example.com/lib/three/v1.0.0/src/init.lua", "return 'three'\n");
        try self.write("cache/modules/example.com/lib/four/v2.0.0/module.toml", "schema = 1\nmodule = \"example.com/lib/four\"\n");
        try self.write("cache/modules/example.com/lib/four/v2.0.0/src/init.lua", "return 'four'\n");
    }
};

/// A resolver on the fixture's main module; `doc` must outlive it
fn resolverFor(f: *Fixture, doc: *manifest.Document, m: *manifest.Manifest) !Resolver {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const root = try f.join("app");
    defer a.free(root);
    const path = try f.join("app/module.toml");
    defer a.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    defer a.free(text);
    var diag = manifest.Diagnostic{};
    doc.* = try manifest.parse(a, text, &diag);
    m.* = try manifest.Manifest.fromDocument(doc, &diag);
    return Resolver.init(a, io, &f.environ, root, m, root);
}

fn expectFile(f: *Fixture, res: *Resolver.Result, rel: []const u8) !void {
    const want = try f.join(rel);
    defer std.testing.allocator.free(want);
    switch (res.*) {
        .found => |found| try std.testing.expectEqualStrings(want, found.file),
        .not_found => |msg| {
            std.debug.print("expected {s}, got: {s}\n", .{ rel, msg });
            return error.TestExpectedFound;
        },
        .not_module => return error.TestExpectedFound,
    }
}

test "resolve: the main module, a replacement, vendor/, the cache, and a transitive dependency" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.populate();
    var doc: manifest.Document = undefined;
    var m: manifest.Manifest = undefined;
    var r = try resolverFor(&f, &doc, &m);
    defer r.deinit();
    defer doc.deinit();
    const a = std.testing.allocator;

    const cases = [_]struct { path: []const u8, file: []const u8 }{
        .{ .path = "example.com/me/app", .file = "app/src/init.lua" },
        .{ .path = "example.com/me/app/util", .file = "app/src/util.lua" },
        .{ .path = "example.com/me/app/util/deep", .file = "app/src/util/deep.lua" },
        .{ .path = "example.com/lib/one", .file = "one/src/init.lua" },
        .{ .path = "example.com/lib/two", .file = "app/vendor/example.com/lib/two/src/init.lua" },
        .{ .path = "example.com/lib/three", .file = "cache/modules/example.com/lib/three/v1.0.0/src/init.lua" },
    };
    for (cases) |c| {
        var res = try r.resolve(c.path, null);
        defer res.deinit(a);
        try expectFile(&f, &res, c.file);
    }

    // `four` is declared by `one`, not by the main module: found only from inside `one`
    const one_file = try f.join("one/src/init.lua");
    defer a.free(one_file);
    var from_one = try r.resolve("example.com/lib/four", one_file);
    defer from_one.deinit(a);
    try expectFile(&f, &from_one, "cache/modules/example.com/lib/four/v2.0.0/src/init.lua");
    const app_file = try f.join("app/src/init.lua");
    defer a.free(app_file);
    var from_app = try r.resolve("example.com/lib/four", app_file);
    defer from_app.deinit(a);
    try std.testing.expect(from_app == .not_found);
    try std.testing.expect(std.mem.indexOf(u8, from_app.not_found, "no module provides 'example.com/lib/four'") != null);
}

test "resolve: internal packages, plain names, invalid and undeclared paths" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.populate();
    var doc: manifest.Document = undefined;
    var m: manifest.Manifest = undefined;
    var r = try resolverFor(&f, &doc, &m);
    defer r.deinit();
    defer doc.deinit();
    const a = std.testing.allocator;

    const inside = try f.join("one/src/init.lua");
    defer a.free(inside);
    var ok = try r.resolve("example.com/lib/one/internal", inside);
    defer ok.deinit(a);
    try expectFile(&f, &ok, "one/src/internal/init.lua");

    const outside = try f.join("app/src/init.lua");
    defer a.free(outside);
    var refused = try r.resolve("example.com/lib/one/internal", outside);
    defer refused.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, refused.not_found, "is internal to module example.com/lib/one") != null);
    var anonymous = try r.resolve("example.com/lib/one/internal", null);
    defer anonymous.deinit(a);
    try std.testing.expect(anonymous == .not_found);

    var plain = try r.resolve("pl.utils", null);
    defer plain.deinit(a);
    try std.testing.expect(plain == .not_module);
    var bad = try r.resolve("example.com/Bad", null);
    defer bad.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, bad.not_found, "invalid module path"));
    var missing_pkg = try r.resolve("example.com/lib/two/nope", null);
    defer missing_pkg.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, missing_pkg.not_found, "has no package 'nope'") != null);
    var undeclared = try r.resolve("example.com/lib/nine", null);
    defer undeclared.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, undeclared.not_found, "no [replacements] entry, not in vendor/") != null);
}

test "place: how each module is placed" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.populate();
    var doc: manifest.Document = undefined;
    var m: manifest.Manifest = undefined;
    var r = try resolverFor(&f, &doc, &m);
    defer r.deinit();
    defer doc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var notes: std.Io.Writer.Allocating = .init(arena);

    try std.testing.expectEqual(Resolver.How.main, (try r.place(arena, "example.com/me/app", null, &notes)).?.how);
    try std.testing.expectEqual(Resolver.How.replacement_path, (try r.place(arena, "example.com/lib/one", null, &notes)).?.how);
    try std.testing.expectEqual(Resolver.How.vendor, (try r.place(arena, "example.com/lib/two", null, &notes)).?.how);
    const three = (try r.place(arena, "example.com/lib/three", null, &notes)).?;
    try std.testing.expectEqual(Resolver.How.cache, three.how);
    try std.testing.expectEqualStrings("v1.0.0", three.version.?);
    const one_dir = try f.join("one");
    defer std.testing.allocator.free(one_dir);
    try std.testing.expectEqual(Resolver.How.cache_via_requirer, (try r.place(arena, "example.com/lib/four", one_dir, &notes)).?.how);
    try std.testing.expect((try r.place(arena, "example.com/lib/four", null, &notes)) == null);
    try std.testing.expect((try r.place(arena, "example.com/lib/nine", null, &notes)) == null);
}

test "vendor mode: the fingerprint must match, then vendor/ is the only source" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.populate();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const root = try f.join("app");
    defer a.free(root);

    // Read the manifest as the resolver would, to compute the fingerprint it will expect
    var doc: manifest.Document = undefined;
    var m: manifest.Manifest = undefined;
    {
        var r0 = try resolverFor(&f, &doc, &m);
        r0.deinit();
    }
    defer doc.deinit();
    const fp = try integrity.fingerprint(a, io, root, &m);
    defer a.free(fp);

    const stale = "schema = 1\nfingerprint = \"h1:stale\"\n";
    try f.write("app/vendor/modules.toml", stale);
    try std.testing.expectError(error.VendorInconsistent, Resolver.init(a, io, &f.environ, root, &m, root));
    try f.write("app/vendor/modules.toml", "not toml at all [[\n");
    try std.testing.expectError(error.VendorManifestInvalid, Resolver.init(a, io, &f.environ, root, &m, root));

    const good = try std.fmt.allocPrint(a, "schema = 1\nfingerprint = \"{s}\"\n", .{fp});
    defer a.free(good);
    try f.write("app/vendor/modules.toml", good);
    var r = try Resolver.init(a, io, &f.environ, root, &m, root);
    defer r.deinit();
    try std.testing.expect(r.vendor_mode);
    var two = try r.resolve("example.com/lib/two", null);
    defer two.deinit(a);
    try expectFile(&f, &two, "app/vendor/example.com/lib/two/src/init.lua");
    // cached and replaced modules are not consulted in vendor mode
    var three = try r.resolve("example.com/lib/three", null);
    defer three.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, three.not_found, "vendor mode") != null);
    var one = try r.resolve("example.com/lib/one", null);
    defer one.deinit(a);
    try std.testing.expect(one == .not_found);
    // ignoring vendor/ skips the check and the mode
    var r2 = try Resolver.initWith(a, io, &f.environ, root, &m, root, true);
    defer r2.deinit();
    try std.testing.expect(!r2.vendor_mode);
}

test "outside a project every module path fails with the reason" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = std.testing.allocator;
    var r = try Resolver.init(a, std.testing.io, &f.environ, null, null, f.root);
    defer r.deinit();
    var res = try r.resolve("example.com/lib/one", null);
    defer res.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, res.not_found, "not inside a project") != null);
    var plain = try r.resolve("mymod", null);
    defer plain.deinit(a);
    try std.testing.expect(plain == .not_module);
}

test "a file reached through a link out of the module is not a package of it" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.populate();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try f.write("outside/x.lua", "return 'outside'\n");
    f.tmp.dir.symLink(io, "../../outside", "one/src/out", .{}) catch return; // no symlinks here: nothing to test
    var doc: manifest.Document = undefined;
    var m: manifest.Manifest = undefined;
    var r = try resolverFor(&f, &doc, &m);
    defer r.deinit();
    defer doc.deinit();
    var res = try r.resolve("example.com/lib/one/out/x", null);
    defer res.deinit(a);
    try std.testing.expect(res == .not_found);
    try std.testing.expect(std.mem.indexOf(u8, res.not_found, "outside module example.com/lib/one") != null);
    // a link to a file inside the module is fine
    try f.tmp.dir.symLink(io, "init.lua", "one/src/alias.lua", .{});
    var ok = try r.resolve("example.com/lib/one/alias", null);
    defer ok.deinit(a);
    try expectFile(&f, &ok, "one/src/alias.lua");
}
