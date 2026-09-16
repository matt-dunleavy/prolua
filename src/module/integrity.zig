// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.
//! Integrity (docs/project/package-manager.md §52.2): the hash of a module's
//! tree and the `module.sum` file that records one per module version.
//!
//! The hash is `h1:` and the standard base64 of SHA-256 over the lines
//! `<sha256 of the file, hex>  <path>\n`, one per regular file, paths
//! relative to the module root with `/`, sorted, `.git` excluded: Go's
//! dirhash `H1`, so the same tree has the same hash under both.

const std = @import("std");
const import_path = @import("import_path.zig");
const manifest = @import("manifest.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// A symbolic link met while walking a module tree: a link to a regular
/// file is that file (its content is what is hashed and copied), anything
/// else is refused, since a module's files must all lie inside it
pub const LinkError = error{ LinkToDirectory, DanglingLink };

/// Check that the link at `path` in `dir` leads to a regular file
pub fn linkTarget(dir: std.Io.Dir, io: std.Io, path: []const u8) LinkError!void {
    const st = dir.statFile(io, path, .{}) catch return error.DanglingLink;
    if (st.kind != .file) return error.LinkToDirectory;
}

/// The path a tree walk failed on, for the message
pub var bad_link: [std.fs.max_path_bytes]u8 = undefined;
pub var bad_link_len: usize = 0;

pub fn noteLink(path: []const u8) void {
    const n = @min(path.len, bad_link.len);
    @memcpy(bad_link[0..n], path[0..n]);
    bad_link_len = n;
}

/// `h1:...` for the tree at `dir`; the caller frees it. A link to a
/// directory or to nothing is `error.LinkToDirectory` / `DanglingLink`
/// with `bad_link` set.
pub fn hashTree(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.basename, ".git")) {
            walker.leave(io);
            continue;
        }
        if (entry.kind == .sym_link) {
            linkTarget(dir, io, entry.path) catch |err| {
                noteLink(entry.path);
                return err;
            };
        } else if (entry.kind != .file) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var summary = Sha256.init(.{});
    for (paths.items) |p| {
        const content = try dir.readFileAlloc(io, p, arena, .unlimited);
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(content, &digest, .{});
        var line: std.Io.Writer.Allocating = .init(arena);
        try line.writer.print("{x}  {s}\n", .{ digest, p });
        summary.update(line.written());
    }
    var out: [Sha256.digest_length]u8 = undefined;
    summary.final(&out);
    const enc = std.base64.standard.Encoder;
    var b64: [enc.calcSize(Sha256.digest_length)]u8 = undefined;
    _ = enc.encode(&b64, &out);
    return std.fmt.allocPrint(allocator, "h1:{s}", .{b64});
}

/// `h1:` over arbitrary text: the same encoding as a tree hash
pub fn hashText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &out, .{});
    const enc = std.base64.standard.Encoder;
    var b64: [enc.calcSize(Sha256.digest_length)]u8 = undefined;
    _ = enc.encode(&b64, &out);
    return std.fmt.allocPrint(allocator, "h1:{s}", .{b64});
}

/// The fingerprint `vendor/modules.toml` records (§42): what the main
/// manifest declares (dependencies, indirect dependencies, replacements,
/// in canonical form, so comments and layout do not count) and the whole
/// of `module.sum`
pub fn fingerprint(allocator: std.mem.Allocator, io: std.Io, root: []const u8, m: anytype) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (m.dependencies) |d| try text.writer.print("dep {s} {s}\n", .{ d.module, d.version });
    for (m.indirect) |d| try text.writer.print("indirect {s} {s}\n", .{ d.module, d.version });
    for (m.replacements) |r| try text.writer.print("replace {s} {s} {s} {s}\n", .{ r.module, r.path orelse "-", r.target_module orelse "-", r.target_version orelse "-" });
    const sum_path = try std.fs.path.join(allocator, &.{ root, FILE_NAME });
    defer allocator.free(sum_path);
    const sum_text = std.Io.Dir.cwd().readFileAlloc(io, sum_path, allocator, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(sum_text);
    try text.writer.writeAll("sum\n");
    try text.writer.writeAll(sum_text);
    return hashText(allocator, text.written());
}

pub const VENDOR_DIR = "vendor";
pub const VENDOR_FILE = "modules.toml";

pub const FILE_NAME = "module.sum";

pub const Entry = struct {
    module: []const u8,
    version: []const u8,
    hash: []const u8,
};

/// `module.sum`: one `<module> <version> <hash>` line per module version,
/// sorted by module then version, rewritten whole
pub const Sum = struct {
    entries: std.ArrayList(Entry) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Sum {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Sum) void {
        self.arena.deinit();
    }

    /// The line a malformed `module.sum` failed on, for the message
    pub var bad_line: usize = 0;

    /// Read `<root>/module.sum`; a missing file is an empty sum. A line
    /// that is not `<module> <version> h1:<hash>` is `error.BadSumLine`
    /// with `bad_line` set: the file is hand-editable, so say where.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Sum {
        var sum = init(allocator);
        errdefer sum.deinit();
        const a = sum.arena.allocator();
        const path = try std.fs.path.join(a, &.{ root, FILE_NAME });
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 24)) catch |err| switch (err) {
            error.FileNotFound => return sum,
            else => return err,
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            bad_line = line_no;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const m = fields.next() orelse return error.BadSumLine;
            const v = fields.next() orelse return error.BadSumLine;
            const h = fields.next() orelse return error.BadSumLine;
            if (fields.next() != null) return error.BadSumLine;
            if (!std.mem.startsWith(u8, h, "h1:")) return error.BadSumLine;
            // the module and version become a path under the cache
            import_path.validate(m) catch return error.BadSumLine;
            if (!manifest.isVersion(v)) return error.BadSumLine;
            try sum.entries.append(a, .{ .module = m, .version = v, .hash = h });
        }
        bad_line = 0;
        return sum;
    }

    pub fn get(self: *const Sum, module: []const u8, version: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.module, module) and std.mem.eql(u8, e.version, version)) return e.hash;
        }
        return null;
    }

    /// Record `hash` for `module@version`, replacing any earlier entry
    pub fn set(self: *Sum, module: []const u8, version: []const u8, hash: []const u8) !void {
        const a = self.arena.allocator();
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.module, module) and std.mem.eql(u8, e.version, version)) {
                e.hash = try a.dupe(u8, hash);
                return;
            }
        }
        try self.entries.append(a, .{ .module = try a.dupe(u8, module), .version = try a.dupe(u8, version), .hash = try a.dupe(u8, hash) });
    }

    /// Drop every entry not in `keep` (module, version pairs): the sum
    /// records the selected versions and nothing else
    pub fn retain(self: *Sum, keep: []const [2][]const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            var found = false;
            for (keep) |k| found = found or (std.mem.eql(u8, k[0], e.module) and std.mem.eql(u8, k[1], e.version));
            if (found) {
                i += 1;
            } else {
                _ = self.entries.orderedRemove(i);
            }
        }
    }

    fn lessThan(_: void, x: Entry, y: Entry) bool {
        const c = std.mem.order(u8, x.module, y.module);
        if (c != .eq) return c == .lt;
        return std.mem.lessThan(u8, x.version, y.version);
    }

    /// The file's text, sorted ("" for an empty sum)
    pub fn render(self: *Sum, allocator: std.mem.Allocator) ![]u8 {
        std.mem.sort(Entry, self.entries.items, {}, lessThan);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        for (self.entries.items) |e| try out.writer.print("{s} {s} {s}\n", .{ e.module, e.version, e.hash });
        return allocator.dupe(u8, out.written());
    }

    /// Whether writing would change `<root>/module.sum`
    pub fn differsFromFile(self: *Sum, io: std.Io, root: []const u8) !bool {
        const a = self.arena.allocator();
        const path = try std.fs.path.join(a, &.{ root, FILE_NAME });
        const now = try self.render(a);
        const on_disk = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 24)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        return !std.mem.eql(u8, now, on_disk);
    }

    /// Write `<root>/module.sum`, sorted; an empty sum removes the file
    pub fn store(self: *Sum, io: std.Io, root: []const u8) !void {
        const a = self.arena.allocator();
        const path = try std.fs.path.join(a, &.{ root, FILE_NAME });
        if (self.entries.items.len == 0) {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            return;
        }
        const text = try self.render(a);
        try manifest.writeFileAtomic(io, a, path, text);
    }
};

test "sum entries" {
    var sum = Sum.init(std.testing.allocator);
    defer sum.deinit();
    try sum.set("example.com/b", "v1.0.0", "h1:bbb");
    try sum.set("example.com/a", "v2.0.0", "h1:aaa");
    try sum.set("example.com/b", "v1.0.0", "h1:ccc");
    try std.testing.expectEqualStrings("h1:ccc", sum.get("example.com/b", "v1.0.0").?);
    try std.testing.expect(sum.get("example.com/b", "v1.0.1") == null);
    try std.testing.expectEqual(@as(usize, 2), sum.entries.items.len);
    sum.retain(&.{.{ "example.com/a", "v2.0.0" }});
    try std.testing.expectEqual(@as(usize, 1), sum.entries.items.len);
    try std.testing.expect(sum.get("example.com/b", "v1.0.0") == null);
}

test "hashTree: a link to a file is its content; a link to a directory is refused" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, "m/src");
    try tmp.dir.createDirPath(io, "n/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "m/module.toml", .data = "schema = 1\nmodule = \"example.com/m\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/src/real.lua", .data = "return 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "n/module.toml", .data = "schema = 1\nmodule = \"example.com/m\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "n/src/real.lua", .data = "return 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "n/src/init.lua", .data = "return 1\n" });
    tmp.dir.symLink(io, "real.lua", "m/src/init.lua", .{}) catch return; // no symlinks here: nothing to test
    const m = try std.fs.path.join(a, &.{ root, "m" });
    defer a.free(m);
    const n = try std.fs.path.join(a, &.{ root, "n" });
    defer a.free(n);
    const hm = try hashTree(a, io, m);
    defer a.free(hm);
    const hn = try hashTree(a, io, n);
    defer a.free(hn);
    try std.testing.expectEqualStrings(hn, hm);
    try tmp.dir.symLink(io, "..", "m/src/up", .{});
    try std.testing.expectError(error.LinkToDirectory, hashTree(a, io, m));
    try std.testing.expectEqualStrings("src/up", bad_link[0..bad_link_len]);
    try tmp.dir.deleteFile(io, "m/src/up");
    try tmp.dir.symLink(io, "nowhere", "m/src/gone", .{});
    try std.testing.expectError(error.DanglingLink, hashTree(a, io, m));
}

test "hashTree: deterministic, sensitive to content and names, blind to .git" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, "m/src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "m/module.toml", .data = "schema = 1\nmodule = \"example.com/m\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/src/init.lua", .data = "return 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "m/src/sub/x.lua", .data = "return 2\n" });
    const dir = try std.fs.path.join(a, &.{ root, "m" });
    defer a.free(dir);

    const h1 = try hashTree(a, io, dir);
    defer a.free(h1);
    try std.testing.expect(std.mem.startsWith(u8, h1, "h1:"));
    const h1_again = try hashTree(a, io, dir);
    defer a.free(h1_again);
    try std.testing.expectEqualStrings(h1, h1_again);

    // .git is not part of the tree
    try tmp.dir.createDirPath(io, "m/.git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = "m/.git/HEAD", .data = "ref: refs/heads/main\n" });
    const h_git = try hashTree(a, io, dir);
    defer a.free(h_git);
    try std.testing.expectEqualStrings(h1, h_git);

    // a byte changes the hash; so does a name
    try tmp.dir.writeFile(io, .{ .sub_path = "m/src/init.lua", .data = "return 3\n" });
    const h_changed = try hashTree(a, io, dir);
    defer a.free(h_changed);
    try std.testing.expect(!std.mem.eql(u8, h1, h_changed));
    try tmp.dir.writeFile(io, .{ .sub_path = "m/src/init.lua", .data = "return 1\n" });
    try tmp.dir.rename("m/src/sub/x.lua", tmp.dir, "m/src/sub/y.lua", io);
    const h_renamed = try hashTree(a, io, dir);
    defer a.free(h_renamed);
    try std.testing.expect(!std.mem.eql(u8, h1, h_renamed));
}

test "Sum: load, store, retain and the frozen comparison on disk" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    var empty = try Sum.load(a, io, root);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.items.len);
    try std.testing.expect(!try empty.differsFromFile(io, root));

    try empty.set("example.com/b", "v1.0.0", "h1:bbb");
    try empty.set("example.com/a", "v2.0.0", "h1:aaa");
    try std.testing.expect(try empty.differsFromFile(io, root));
    try empty.store(io, root);
    try std.testing.expect(!try empty.differsFromFile(io, root));

    var loaded = try Sum.load(a, io, root);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try std.testing.expectEqualStrings("example.com/a", loaded.entries.items[0].module); // sorted on store
    try std.testing.expectEqualStrings("h1:bbb", loaded.get("example.com/b", "v1.0.0").?);

    loaded.retain(&.{});
    try loaded.store(io, root);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, FILE_NAME, .{}));

    try tmp.dir.writeFile(io, .{ .sub_path = FILE_NAME, .data = "example.com/x v1.0.0\n" });
    try std.testing.expectError(error.BadSumLine, Sum.load(a, io, root));
    try tmp.dir.writeFile(io, .{ .sub_path = FILE_NAME, .data = "example.com/../x v1.0.0 h1:aaa\n" });
    try std.testing.expectError(error.BadSumLine, Sum.load(a, io, root));
    try tmp.dir.writeFile(io, .{ .sub_path = FILE_NAME, .data = "example.com/x 1.0 h1:aaa\n" });
    try std.testing.expectError(error.BadSumLine, Sum.load(a, io, root));
}

test "Sum.load survives mutations of a valid file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const base = "example.com/lib/one v0.1.0 h1:R77N7i7rM3STRUNnPTUcwud7Z3CQBqeunMoxoCrRhwo=\nexample.com/lib/two v0.4.0 h1:o0K9Bqd/ZOvPh2Yul+tLiDZ5sFBMnTuEDWV/Z/2gHa4=\n";
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const alphabet = " \n\r\th:1=/.v0x";
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 800) : (i += 1) {
        @memcpy(buf[0..base.len], base);
        var len = base.len;
        var e: usize = 0;
        while (e < 3) : (e += 1) {
            const at = random.uintLessThan(usize, len);
            if (random.boolean()) {
                buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
            } else if (len > 1) {
                std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                len -= 1;
            }
        }
        try tmp.dir.writeFile(io, .{ .sub_path = FILE_NAME, .data = buf[0..len] });
        var sum = Sum.load(a, io, root) catch |err| switch (err) {
            error.BadSumLine => {
                try std.testing.expect(Sum.bad_line >= 1);
                continue;
            },
            else => return err,
        };
        defer sum.deinit();
        for (sum.entries.items) |entry| try std.testing.expect(std.mem.startsWith(u8, entry.hash, "h1:"));
    }
}
