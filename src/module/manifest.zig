// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `module.toml` (docs/project/package-manager.md §7, §8): the manifest of
//! a module. Zig's standard library has no TOML reader, and the manifest
//! uses a small part of TOML, so this reads exactly that part and rejects
//! everything else with the line it stopped at: comments, bare and quoted
//! keys, `[table]` and `[table."quoted.key"]` headers, basic and literal
//! strings, integers, booleans, and single-line arrays of strings. The
//! subset grows on purpose, not by accident.

const std = @import("std");
const import_path = @import("import_path.zig");

pub const FILE_NAME = "module.toml";

/// Write `data` to `path` by way of a temporary file beside it and a
/// rename, so a reader never sees a half-written file and a failure
/// leaves the old one in place. `WriteError` names the step for the
/// message.
pub fn writeFileAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ path, std.Io.Clock.awake.now(io).nanoseconds });
    defer allocator.free(tmp);
    const cwd = std.Io.Dir.cwd();
    removeStale(io, allocator, path, ".tmp-");
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    errdefer cwd.deleteFile(io, tmp) catch {};
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
}

/// Remove `<path><infix>*` siblings left by an interrupted earlier run
/// (a temporary file, a half-made clone). Best effort: nothing here can
/// fail the operation that follows.
pub fn removeStale(io: std.Io, allocator: std.mem.Allocator, path: []const u8, infix: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const prefix = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, infix }) catch return;
    defer allocator.free(prefix);
    var dir = std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (entry.kind == .directory) {
            dir.deleteTree(io, entry.name) catch {};
        } else {
            dir.deleteFile(io, entry.name) catch {};
        }
    }
}

test "writeFileAtomic replaces the file whole and clears what an interrupted run left" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "module.toml" });
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "module.toml", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "module.toml.tmp-123", .data = "half\n" });
    try writeFileAtomic(io, a, path, "new\n");
    const text = try tmp.dir.readFileAlloc(io, "module.toml", a, .limited(64));
    defer a.free(text);
    try std.testing.expectEqualStrings("new\n", text);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "module.toml.tmp-123", .{}));
    // nothing else is left beside it
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    strings: []const []const u8,
};

/// One `key = value`, under the table whose header preceded it (`table`
/// is empty at the top of the file; a dotted or quoted header is stored
/// with its segments joined by '.', unquoted)
pub const Entry = struct {
    table: []const u8,
    key: []const u8,
    value: Value,
    line: usize,
};

/// Where a read stopped and why
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{ Syntax, OutOfMemory };

/// The manifest as read: every entry, in file order. Strings are copies
/// owned by `arena`.
pub const Document = struct {
    entries: []const Entry,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn get(self: *const Document, table: []const u8, key: []const u8) ?Value {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.table, table) and std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn getString(self: *const Document, table: []const u8, key: []const u8) ?[]const u8 {
        const v = self.get(table, key) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn getInteger(self: *const Document, table: []const u8, key: []const u8) ?i64 {
        const v = self.get(table, key) orelse return null;
        return if (v == .integer) v.integer else null;
    }
};

/// `vMAJOR.MINOR.PATCH[-pre][+build]`: the form every version in a
/// manifest, a sum and a tag takes
pub fn isVersion(v: []const u8) bool {
    if (v.len < 2 or v.len > 64 or v[0] != 'v') return false;
    _ = std.SemanticVersion.parse(v[1..]) catch return false;
    return true;
}

/// One `"module path" = "version"` line of `[dependencies]` or
/// `[indirectDependencies]`
pub const Dependency = struct {
    module: []const u8,
    version: []const u8,
};

/// One `[replacements."module path"]` table: a local `path`, or another
/// `module` at a `version`
pub const Replacement = struct {
    module: []const u8,
    path: ?[]const u8 = null,
    target_module: ?[]const u8 = null,
    target_version: ?[]const u8 = null,
};

/// The manifest's fields, checked; slices live in the document's arena
pub const Manifest = struct {
    schema: i64,
    module: []const u8,
    version: ?[]const u8,
    prolua: ?[]const u8,
    dependencies: []const Dependency = &.{},
    indirect: []const Dependency = &.{},
    replacements: []const Replacement = &.{},

    /// The version `[dependencies]` or `[indirectDependencies]` gives `module`
    pub fn dependencyVersion(self: *const Manifest, module: []const u8) ?[]const u8 {
        for (self.dependencies) |d| if (std.mem.eql(u8, d.module, module)) return d.version;
        for (self.indirect) |d| if (std.mem.eql(u8, d.module, module)) return d.version;
        return null;
    }

    pub fn replacement(self: *const Manifest, module: []const u8) ?Replacement {
        for (self.replacements) |r| if (std.mem.eql(u8, r.module, module)) return r;
        return null;
    }

    fn readDependencies(doc: *Document, table: []const u8, diag: *Diagnostic) error{ Invalid, OutOfMemory }![]const Dependency {
        const alloc = doc.arena.allocator();
        var list: std.ArrayList(Dependency) = .empty;
        for (doc.entries) |e| {
            if (!std.mem.eql(u8, e.table, table)) continue;
            if (e.value != .string) {
                diag.* = .{ .line = e.line, .message = "a dependency's value must be its version, a string" };
                return error.Invalid;
            }
            if (!isVersion(e.value.string)) {
                diag.* = .{ .line = e.line, .message = "a dependency's version is vMAJOR.MINOR.PATCH, as in \"v1.0.0\"" };
                return error.Invalid;
            }
            // A key becomes a directory under the cache and vendor/: only a
            // valid module path may (no "..", no odd bytes), and only a
            // namespace path can be fetched
            if (!import_path.isNamespace(e.key)) {
                diag.* = .{ .line = e.line, .message = "a dependency is a module path whose first component is a host, as in github.com/matt-dunleavy/json" };
                return error.Invalid;
            }
            import_path.validate(e.key) catch |err| {
                diag.* = .{ .line = e.line, .message = import_path.describe(err) };
                return error.Invalid;
            };
            try list.append(alloc, .{ .module = e.key, .version = e.value.string });
        }
        return list.toOwnedSlice(alloc);
    }

    fn readReplacements(doc: *Document, diag: *Diagnostic) error{ Invalid, OutOfMemory }![]const Replacement {
        const alloc = doc.arena.allocator();
        const prefix = "replacements.";
        var list: std.ArrayList(Replacement) = .empty;
        for (doc.entries) |e| {
            if (!std.mem.startsWith(u8, e.table, prefix)) continue;
            const module = e.table[prefix.len..];
            if (e.value != .string) {
                diag.* = .{ .line = e.line, .message = "a replacement's fields are strings" };
                return error.Invalid;
            }
            import_path.validate(module) catch |err| {
                diag.* = .{ .line = e.line, .message = import_path.describe(err) };
                return error.Invalid;
            };
            var slot: ?*Replacement = null;
            for (list.items) |*r| if (std.mem.eql(u8, r.module, module)) {
                slot = r;
            };
            if (slot == null) {
                try list.append(alloc, .{ .module = module });
                slot = &list.items[list.items.len - 1];
            }
            const r = slot.?;
            if (std.mem.eql(u8, e.key, "path")) {
                r.path = e.value.string;
            } else if (std.mem.eql(u8, e.key, "module")) {
                r.target_module = e.value.string;
            } else if (std.mem.eql(u8, e.key, "version")) {
                r.target_version = e.value.string;
            } else {
                diag.* = .{ .line = e.line, .message = "a replacement has 'path', or 'module' and 'version'" };
                return error.Invalid;
            }
        }
        for (list.items) |r| {
            if (r.path == null and (r.target_module == null or r.target_version == null)) {
                diag.* = .{ .line = 0, .message = "a replacement needs 'path', or 'module' and 'version'" };
                return error.Invalid;
            }
            if (r.target_version) |v| if (!isVersion(v)) {
                diag.* = .{ .line = 0, .message = "a replacement's version is vMAJOR.MINOR.PATCH" };
                return error.Invalid;
            };
            if (r.target_module) |t| import_path.validate(t) catch |err| {
                diag.* = .{ .line = 0, .message = import_path.describe(err) };
                return error.Invalid;
            };
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn fromDocument(doc: *Document, diag: *Diagnostic) error{ Invalid, OutOfMemory }!Manifest {
        const schema = doc.getInteger("", "schema") orelse {
            diag.* = .{ .line = 0, .message = "missing 'schema = 1'" };
            return error.Invalid;
        };
        if (schema != 1) {
            diag.* = .{ .line = 0, .message = "unsupported schema (this prolua reads schema 1)" };
            return error.Invalid;
        }
        const module = doc.getString("", "module") orelse {
            if (doc.get("", "module")) |_| {
                diag.* = .{ .line = 0, .message = "'module' must be a string" };
            } else {
                diag.* = .{ .line = 0, .message = "missing 'module = \"...\"'" };
            }
            return error.Invalid;
        };
        import_path.validate(module) catch |err| {
            diag.* = .{ .line = 0, .message = import_path.describe(err) };
            return error.Invalid;
        };
        return .{
            .schema = schema,
            .module = module,
            .version = doc.getString("", "version"),
            .prolua = doc.getString("", "prolua"),
            .dependencies = try readDependencies(doc, "dependencies", diag),
            .indirect = try readDependencies(doc, "indirectDependencies", diag),
            .replacements = try readReplacements(doc, diag),
        };
    }
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    line: usize = 1,
    alloc: std.mem.Allocator,
    diag: *Diagnostic,

    fn fail(self: *Parser, message: []const u8) ParseError {
        self.diag.* = .{ .line = self.line, .message = message };
        return error.Syntax;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn skipBlanks(self: *Parser) void {
        while (self.peek()) |c| : (self.pos += 1) {
            if (c != ' ' and c != '\t') break;
        }
    }

    /// The rest of a line must be blank or a comment
    fn endOfLine(self: *Parser) ParseError!void {
        self.skipBlanks();
        if (self.peek()) |c| {
            if (c == '#') {
                while (self.peek()) |d| : (self.pos += 1) {
                    if (d == '\n') break;
                }
            } else if (c != '\n' and c != '\r') {
                return self.fail("unexpected text after the value");
            }
        }
        if (self.peek() == @as(?u8, '\r')) self.pos += 1;
        if (self.peek() == @as(?u8, '\n')) {
            self.pos += 1;
            self.line += 1;
        }
    }

    fn isBareKeyChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    /// A bare key, or a quoted one (basic or literal string)
    fn key(self: *Parser) ParseError![]const u8 {
        const c = self.peek() orelse return self.fail("expected a key");
        if (c == '"' or c == '\'') return self.string();
        const start = self.pos;
        while (self.peek()) |d| : (self.pos += 1) {
            if (!isBareKeyChar(d)) break;
        }
        if (self.pos == start) return self.fail("expected a key");
        return self.text[start..self.pos];
    }

    /// A basic ("...", with \\ \" \n \t \r escapes) or literal ('...') string
    fn string(self: *Parser) ParseError![]const u8 {
        const quote = self.peek().?;
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated string");
            if (c == '\n') return self.fail("unterminated string");
            self.pos += 1;
            if (c == quote) break;
            if (c == '\\' and quote == '"') {
                const e = self.peek() orelse return self.fail("unterminated string");
                self.pos += 1;
                const decoded: u8 = switch (e) {
                    '\\' => '\\',
                    '"' => '"',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => return self.fail("unsupported escape in string (\\\\, \\\", \\n, \\t, \\r are read)"),
                };
                try out.append(self.alloc, decoded);
            } else {
                try out.append(self.alloc, c);
            }
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn value(self: *Parser) ParseError!Value {
        const c = self.peek() orelse return self.fail("expected a value");
        if (c == '"' or c == '\'') return .{ .string = try self.string() };
        if (c == '[') {
            self.pos += 1;
            var items: std.ArrayList([]const u8) = .empty;
            while (true) {
                self.skipBlanks();
                const d = self.peek() orelse return self.fail("unterminated array");
                if (d == ']') {
                    self.pos += 1;
                    break;
                }
                if (d != '"' and d != '\'') return self.fail("only arrays of strings are read");
                try items.append(self.alloc, try self.string());
                self.skipBlanks();
                const e = self.peek() orelse return self.fail("unterminated array");
                if (e == ',') {
                    self.pos += 1;
                } else if (e != ']') {
                    return self.fail("expected ',' or ']' in array");
                }
            }
            return .{ .strings = try items.toOwnedSlice(self.alloc) };
        }
        if (std.mem.startsWith(u8, self.text[self.pos..], "true")) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        if (std.mem.startsWith(u8, self.text[self.pos..], "false")) {
            self.pos += 5;
            return .{ .boolean = false };
        }
        if (c == '-' or c == '+' or std.ascii.isDigit(c)) {
            const start = self.pos;
            self.pos += 1;
            while (self.peek()) |d| : (self.pos += 1) {
                if (!std.ascii.isDigit(d) and d != '_') break;
            }
            var digits: std.ArrayList(u8) = .empty;
            for (self.text[start..self.pos]) |d| {
                if (d != '_') try digits.append(self.alloc, d);
            }
            const n = std.fmt.parseInt(i64, digits.items, 10) catch return self.fail("bad integer");
            return .{ .integer = n };
        }
        return self.fail("unsupported value (strings, integers, booleans and arrays of strings are read)");
    }

    /// `[a.b."c.d"]` → "a.b.c.d"
    fn header(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // '['
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            self.skipBlanks();
            const part = try self.key();
            try out.appendSlice(self.alloc, part);
            self.skipBlanks();
            const c = self.peek() orelse return self.fail("unterminated table header");
            self.pos += 1;
            if (c == ']') break;
            if (c != '.') return self.fail("expected '.' or ']' in table header");
            try out.append(self.alloc, '.');
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn parse(self: *Parser) ParseError![]const Entry {
        var entries: std.ArrayList(Entry) = .empty;
        var table: []const u8 = "";
        // `[[name]]`: the n-th occurrence opens the table "name[n]", from 0
        var array_counts: std.StringHashMapUnmanaged(usize) = .empty;
        while (self.pos < self.text.len) {
            self.skipBlanks();
            const c = self.peek() orelse break;
            if (c == '\n' or c == '\r' or c == '#') {
                try self.endOfLine();
                continue;
            }
            if (c == '[') {
                if (self.text.len > self.pos + 1 and self.text[self.pos + 1] == '[') {
                    self.pos += 1;
                    const name = try self.header();
                    if (self.peek() != @as(?u8, ']')) return self.fail("expected ']]' to close the array header");
                    self.pos += 1;
                    const n = array_counts.get(name) orelse 0;
                    try array_counts.put(self.alloc, name, n + 1);
                    table = try std.fmt.allocPrint(self.alloc, "{s}[{d}]", .{ name, n });
                    try self.endOfLine();
                    continue;
                }
                table = try self.header();
                try self.endOfLine();
                continue;
            }
            const line = self.line;
            const k = try self.key();
            self.skipBlanks();
            if (self.peek() != @as(?u8, '=')) return self.fail("expected '=' after the key");
            self.pos += 1;
            self.skipBlanks();
            const v = try self.value();
            try entries.append(self.alloc, .{ .table = table, .key = k, .value = v, .line = line });
            try self.endOfLine();
        }
        return entries.toOwnedSlice(self.alloc);
    }
};

/// Read a manifest's text. On `error.Syntax`, `diag` says where.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var p = Parser{ .text = text, .alloc = arena.allocator(), .diag = diag };
    const entries = try p.parse();
    return .{ .entries = entries, .arena = arena };
}

/// The manifest `init` writes
pub fn write(writer: anytype, module: []const u8, version: []const u8, prolua_min: []const u8) !void {
    try writer.print(
        \\schema = 1
        \\module = "{s}"
        \\version = "{s}"
        \\prolua = ">={s}"
        \\
    , .{ module, version, prolua_min });
}

// ---------------------------------------------------------------------------
// Editing: `add` changes one entry and leaves the rest of the file as written
// ---------------------------------------------------------------------------

/// The table a header line opens, in the same joined form the parser
/// uses (`[replacements."a.b/c"]` is `replacements.a.b/c`), or null
fn headerTable(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 2 or t[0] != '[' or t[t.len - 1] != ']') return null;
    return t[1 .. t.len - 1];
}

/// Whether a header's table equals `table` once quotes are removed from its segments
fn headerNames(header: []const u8, table: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < header.len and j < table.len) {
        if (header[i] == '"') {
            i += 1;
            continue;
        }
        if (header[i] != table[j]) return false;
        i += 1;
        j += 1;
    }
    while (i < header.len and header[i] == '"') i += 1;
    return i == header.len and j == table.len;
}

/// The key of a `key = value` line, unquoted, or null
fn lineKey(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#' or t[0] == '[') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    var key = std.mem.trim(u8, t[0..eq], " \t");
    if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"') key = key[1 .. key.len - 1];
    return key;
}

const Lines = std.ArrayList([]const u8);

fn splitLines(allocator: std.mem.Allocator, text: []const u8) !Lines {
    var lines: Lines = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(allocator, l);
    // a trailing newline yields an empty last element: drop it so joining restores the file
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return lines;
}

/// Lines are joined with the ending the file used: CRLF when its first
/// line ends in '\r', so an edited Windows-style manifest stays one
fn joinLines(allocator: std.mem.Allocator, lines: *const Lines) ![]u8 {
    const crlf = lines.items.len > 0 and std.mem.endsWith(u8, lines.items[0], "\r");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (lines.items) |l| {
        const bare = std.mem.trimEnd(u8, l, "\r");
        try out.writer.writeAll(bare);
        try out.writer.writeAll(if (crlf) "\r\n" else "\n");
    }
    return allocator.dupe(u8, out.written());
}

/// The line range [start, end) of the entries under the header for
/// `table`, and the header's index; null when the table is absent
fn tableRange(lines: *const Lines, table: []const u8) ?struct { header: usize, start: usize, end: usize } {
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const h = headerTable(lines.items[i]) orelse continue;
        if (!headerNames(h, table)) continue;
        var end = i + 1;
        while (end < lines.items.len and headerTable(lines.items[end]) == null) end += 1;
        return .{ .header = i, .start = i + 1, .end = end };
    }
    return null;
}

/// Set `key = value` in `table`: replace the existing line, or add one
/// after the table's last entry, or add the table at the end
fn setEntry(allocator: std.mem.Allocator, lines: *Lines, table: []const u8, header_text: []const u8, key: []const u8, entry: []const u8) !void {
    if (tableRange(lines, table)) |r| {
        var i = r.start;
        while (i < r.end) : (i += 1) {
            const k = lineKey(lines.items[i]) orelse continue;
            if (std.mem.eql(u8, k, key)) {
                lines.items[i] = entry;
                return;
            }
        }
        // after the last non-blank line of the table
        var at = r.end;
        while (at > r.start and std.mem.trim(u8, lines.items[at - 1], " \t\r").len == 0) at -= 1;
        try lines.insert(allocator, at, entry);
        return;
    }
    if (lines.items.len > 0 and std.mem.trim(u8, lines.items[lines.items.len - 1], " \t\r").len != 0) try lines.append(allocator, "");
    try lines.append(allocator, header_text);
    try lines.append(allocator, entry);
}

/// `text` with `"module" = "version"` set in `[dependencies]`
pub fn setDependency(allocator: std.mem.Allocator, text: []const u8, module: []const u8, version: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines = try splitLines(arena, text);
    const entry = try std.fmt.allocPrint(arena, "\"{s}\" = \"{s}\"", .{ module, version });
    try setEntry(arena, &lines, "dependencies", "[dependencies]", module, entry);
    return joinLines(allocator, &lines);
}

/// `text` with `[replacements."module"]` set to `path = "path"`, any
/// `module`/`version` target of that table removed
pub fn setReplacementPath(allocator: std.mem.Allocator, text: []const u8, module: []const u8, path: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines = try splitLines(arena, text);
    const table = try std.fmt.allocPrint(arena, "replacements.{s}", .{module});
    const header = try std.fmt.allocPrint(arena, "[replacements.\"{s}\"]", .{module});
    const entry = try std.fmt.allocPrint(arena, "path = \"{s}\"", .{path});
    if (tableRange(&lines, table)) |r| {
        var i = r.start;
        while (i < r.end) {
            const k = lineKey(lines.items[i]);
            if (k != null and (std.mem.eql(u8, k.?, "module") or std.mem.eql(u8, k.?, "version"))) {
                _ = lines.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }
    try setEntry(arena, &lines, table, header, "path", entry);
    return joinLines(allocator, &lines);
}

/// `text` with `[indirectDependencies]` holding exactly `entries` (sorted
/// by module): rewritten where it is, added at the end when absent,
/// removed when there are none
pub fn setIndirectDependencies(allocator: std.mem.Allocator, text: []const u8, entries: []const Dependency) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines = try splitLines(arena, text);
    const sorted = try arena.dupe(Dependency, entries);
    std.mem.sort(Dependency, sorted, {}, struct {
        fn lt(_: void, a: Dependency, b: Dependency) bool {
            return std.mem.lessThan(u8, a.module, b.module);
        }
    }.lt);
    var fresh: Lines = .empty;
    for (sorted) |d| try fresh.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" = \"{s}\"", .{ d.module, d.version }));

    if (tableRange(&lines, "indirectDependencies")) |r| {
        if (entries.len == 0) {
            // the header, its entries, and the blank lines that separated it from what follows
            var end = r.end;
            var start = r.header;
            while (start > 0 and std.mem.trim(u8, lines.items[start - 1], " \t\r").len == 0) start -= 1;
            if (start == 0) {
                while (end < lines.items.len and std.mem.trim(u8, lines.items[end], " \t\r").len == 0) end += 1;
            }
            try lines.replaceRange(arena, start, end - start, &.{});
            return joinLines(allocator, &lines);
        }
        // the entries in place; a blank line before a following table stays
        var end = r.end;
        while (end > r.start and std.mem.trim(u8, lines.items[end - 1], " \t\r").len == 0) end -= 1;
        try lines.replaceRange(arena, r.start, end - r.start, fresh.items);
        return joinLines(allocator, &lines);
    }
    if (entries.len == 0) return joinLines(allocator, &lines);
    if (lines.items.len > 0 and std.mem.trim(u8, lines.items[lines.items.len - 1], " \t\r").len != 0) try lines.append(arena, "");
    try lines.append(arena, "[indirectDependencies]");
    try lines.appendSlice(arena, fresh.items);
    return joinLines(allocator, &lines);
}

/// `text` without `module` in `[dependencies]`; the table goes when it
/// empties. False when the module was not there.
pub fn removeDependency(allocator: std.mem.Allocator, text: []const u8, module: []const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines = try splitLines(arena, text);
    const r = tableRange(&lines, "dependencies") orelse return null;
    var i = r.start;
    var removed = false;
    while (i < r.end) : (i += 1) {
        const k = lineKey(lines.items[i]) orelse continue;
        if (std.mem.eql(u8, k, module)) {
            _ = lines.orderedRemove(i);
            removed = true;
            break;
        }
    }
    if (!removed) return null;
    // an emptied table: drop the header and the blank lines around it
    var has_entry = false;
    var j = r.start;
    while (j < r.end - 1) : (j += 1) has_entry = has_entry or lineKey(lines.items[j]) != null;
    if (!has_entry) {
        var end = r.end - 1;
        var start = r.header;
        while (start > 0 and std.mem.trim(u8, lines.items[start - 1], " \t\r").len == 0) start -= 1;
        if (start == 0) {
            while (end < lines.items.len and std.mem.trim(u8, lines.items[end], " \t\r").len == 0) end += 1;
        }
        try lines.replaceRange(arena, start, end - start, &.{});
    }
    return try joinLines(allocator, &lines);
}

test "removeDependency drops the line, then the table" {
    const a = std.testing.allocator;
    const t0 = "schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/a\" = \"v1.0.0\"\n\"example.com/lib/b\" = \"v2.0.0\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n";
    const t1 = (try removeDependency(a, t0, "example.com/lib/a")).?;
    defer a.free(t1);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/b\" = \"v2.0.0\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n", t1);
    const t2 = (try removeDependency(a, t1, "example.com/lib/b")).?;
    defer a.free(t2);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n", t2);
    try std.testing.expect((try removeDependency(a, t2, "example.com/lib/b")) == null);
}

test "setIndirectDependencies replaces the table and removes it when empty" {
    const a = std.testing.allocator;
    const t0 = "schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/a\" = \"v1.0.0\"\n\n[indirectDependencies]\n\"example.com/lib/z\" = \"v0.1.0\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n";
    const t1 = try setIndirectDependencies(a, t0, &.{ .{ .module = "example.com/lib/y", .version = "v2.0.0" }, .{ .module = "example.com/lib/b", .version = "v1.5.0" } });
    defer a.free(t1);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/a\" = \"v1.0.0\"\n\n[indirectDependencies]\n\"example.com/lib/b\" = \"v1.5.0\"\n\"example.com/lib/y\" = \"v2.0.0\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n", t1);
    const t2 = try setIndirectDependencies(a, t1, &.{});
    defer a.free(t2);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/a\" = \"v1.0.0\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n", t2);
}

test "module paths in a manifest are validated: no traversal, no plain names as dependencies" {
    const a = std.testing.allocator;
    const cases = [_]struct { text: []const u8, line: usize, word: []const u8 }{
        .{ .text = "schema = 1\nmodule = \"example.com/me/app\"\n[dependencies]\n\"example.com/lib/../../x\" = \"v1.0.0\"\n", .line = 4, .word = "may only contain" },
        .{ .text = "schema = 1\nmodule = \"example.com/me/app\"\n[dependencies]\n\"mymod\" = \"v1.0.0\"\n", .line = 4, .word = "first component is a host" },
        .{ .text = "schema = 1\nmodule = \"../escape\"\n", .line = 0, .word = "may only contain" },
        .{ .text = "schema = 1\nmodule = \"example.com/me/app\"\n[replacements.\"example.com/lib/a\"]\nmodule = \"../x\"\nversion = \"v1.0.0\"\n", .line = 0, .word = "may only contain" },
        .{ .text = "schema = 1\nmodule = \"example.com/me/app\"\n[replacements.\"bad name\"]\npath = \"../x\"\n", .line = 4, .word = "may only contain" },
    };
    for (cases) |c| {
        var diag = Diagnostic{};
        var doc = try parse(a, c.text, &diag);
        defer doc.deinit();
        try std.testing.expectError(error.Invalid, Manifest.fromDocument(&doc, &diag));
        try std.testing.expectEqual(c.line, diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, c.word) != null);
    }
}

test "a dependency with a malformed version is rejected with its line" {
    const text = "schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/a\" = \"1.0\"\n";
    var diag = Diagnostic{};
    var doc = try parse(std.testing.allocator, text, &diag);
    defer doc.deinit();
    try std.testing.expectError(error.Invalid, Manifest.fromDocument(&doc, &diag));
    try std.testing.expectEqual(@as(usize, 5), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "vMAJOR.MINOR.PATCH") != null);
}

test "a CRLF manifest reads, and edits keep its line endings" {
    const a = std.testing.allocator;
    const text = "schema = 1\r\nmodule = \"example.com/me/app\"\r\n\r\n[dependencies]\r\n\"example.com/lib/a\" = \"v1.0.0\"\r\n";
    var diag = Diagnostic{};
    var doc = try parse(a, text, &diag);
    defer doc.deinit();
    const m = try Manifest.fromDocument(&doc, &diag);
    try std.testing.expectEqualStrings("v1.0.0", m.dependencyVersion("example.com/lib/a").?);
    const edited = try setDependency(a, text, "example.com/lib/b", "v2.0.0");
    defer a.free(edited);
    try std.testing.expectEqualStrings("schema = 1\r\nmodule = \"example.com/me/app\"\r\n\r\n[dependencies]\r\n\"example.com/lib/a\" = \"v1.0.0\"\r\n\"example.com/lib/b\" = \"v2.0.0\"\r\n", edited);
    try std.testing.expect(std.mem.indexOf(u8, edited, "\n\"example.com/lib/b\"") == null or std.mem.indexOf(u8, edited, "\r\n\"example.com/lib/b\"") != null);
}

test "the reader survives mutations of a valid manifest" {
    // Deterministic byte-level mutations of the specification's example:
    // every result either reads or is rejected with a line inside the
    // text; nothing crashes or hangs, and a document that reads round-trips
    // through the editors without breaking
    const a = std.testing.allocator;
    const base =
        \\schema = 1
        \\module = "example.com/matt/myapp"
        \\version = "v0.4.0"
        \\prolua = ">=0.5.0"
        \\
        \\[dependencies]
        \\"example.com/lib/http" = "v1.7.2"
        \\"example.net/database/sqlite" = "v0.9.3"
        \\
        \\[indirectDependencies]
        \\"example.com/lib/uri" = "v1.1.0"
        \\
        \\[replacements."example.com/lib/http"]
        \\path = "../http"
        \\
        \\[[modules]]
        \\module = "x.example/y"
        \\excludes = ["a.example/b@v1.0.0", 'c']
        \\
    ;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const alphabet = "\"'[]=.#\n\r\\ \t/@-_x0";
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        @memcpy(buf[0..base.len], base);
        var len = base.len;
        const edits = 1 + random.uintLessThan(usize, 4);
        var e: usize = 0;
        while (e < edits) : (e += 1) {
            const at = random.uintLessThan(usize, len);
            switch (random.uintLessThan(u8, 3)) {
                0 => buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)],
                1 => if (len > 1) {
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                else => if (len < buf.len) {
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                    len += 1;
                },
            }
        }
        const text = buf[0..len];
        var diag = Diagnostic{};
        var doc = parse(a, text, &diag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Syntax => {
                const line_count = std.mem.count(u8, text, "\n") + 1;
                try std.testing.expect(diag.line >= 1 and diag.line <= line_count);
                continue;
            },
        };
        defer doc.deinit();
        _ = Manifest.fromDocument(&doc, &diag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Invalid => continue,
        };
        const edited = try setDependency(a, text, "example.com/lib/zz", "v9.9.9");
        defer a.free(edited);
        var diag2 = Diagnostic{};
        var doc2 = parse(a, edited, &diag2) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Syntax => {
                std.debug.print("edit broke a readable manifest:\n{s}\n---\n{s}\n", .{ text, edited });
                return error.TestUnexpectedResult;
            },
        };
        defer doc2.deinit();
    }
}

test "setDependency adds a table, a line, and replaces a line" {
    const a = std.testing.allocator;
    const t0 = "schema = 1\nmodule = \"example.com/me/app\"\n";
    const t1 = try setDependency(a, t0, "example.com/lib/http", "v1.0.0");
    defer a.free(t1);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/http\" = \"v1.0.0\"\n", t1);
    const t2 = try setDependency(a, t1, "example.com/lib/json", "v2.0.0");
    defer a.free(t2);
    const t3 = try setDependency(a, t2, "example.com/lib/http", "v1.1.0");
    defer a.free(t3);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[dependencies]\n\"example.com/lib/http\" = \"v1.1.0\"\n\"example.com/lib/json\" = \"v2.0.0\"\n", t3);
    var diag = Diagnostic{};
    var doc = try parse(a, t3, &diag);
    defer doc.deinit();
    const m = try Manifest.fromDocument(&doc, &diag);
    try std.testing.expectEqualStrings("v1.1.0", m.dependencyVersion("example.com/lib/http").?);
}

test "setDependency keeps comments and later tables in place" {
    const a = std.testing.allocator;
    const t0 =
        \\schema = 1
        \\module = "example.com/me/app"
        \\
        \\[dependencies]
        \\# pinned on purpose
        \\"example.com/lib/a" = "v1.0.0"
        \\
        \\[replacements."example.com/lib/a"]
        \\path = "../a"
        \\
    ;
    const t1 = try setDependency(a, t0, "example.com/lib/b", "v3.0.0");
    defer a.free(t1);
    try std.testing.expectEqualStrings(
        \\schema = 1
        \\module = "example.com/me/app"
        \\
        \\[dependencies]
        \\# pinned on purpose
        \\"example.com/lib/a" = "v1.0.0"
        \\"example.com/lib/b" = "v3.0.0"
        \\
        \\[replacements."example.com/lib/a"]
        \\path = "../a"
        \\
    , t1);
}

test "setReplacementPath adds, then rewrites a module-form replacement" {
    const a = std.testing.allocator;
    const t0 = "schema = 1\nmodule = \"example.com/me/app\"\n\n[replacements.\"example.com/lib/a\"]\nmodule = \"fork.example.com/a\"\nversion = \"v1.0.0\"\n";
    const t1 = try setReplacementPath(a, t0, "example.com/lib/a", "../a");
    defer a.free(t1);
    try std.testing.expectEqualStrings("schema = 1\nmodule = \"example.com/me/app\"\n\n[replacements.\"example.com/lib/a\"]\npath = \"../a\"\n", t1);
    const t2 = try setReplacementPath(a, t1, "example.com/lib/b", "/abs/b");
    defer a.free(t2);
    try std.testing.expect(std.mem.endsWith(u8, t2, "[replacements.\"example.com/lib/b\"]\npath = \"/abs/b\"\n"));
    var diag = Diagnostic{};
    var doc = try parse(a, t2, &diag);
    defer doc.deinit();
    const m = try Manifest.fromDocument(&doc, &diag);
    try std.testing.expectEqualStrings("../a", m.replacement("example.com/lib/a").?.path.?);
    try std.testing.expectEqualStrings("/abs/b", m.replacement("example.com/lib/b").?.path.?);
}

test "the specification's example manifest" {
    const text =
        \\schema = 1
        \\module = "example.com/matt/myapp"
        \\version = "v0.4.0"
        \\prolua = ">=0.5.0"
        \\
        \\[dependencies]
        \\"example.com/lib/http" = "v1.7.2"
        \\"example.com/lib/json" = "v1.4.0"   # trailing comment
        \\
        \\[indirectDependencies]
        \\"example.com/lib/uri" = "v1.1.0"
        \\
        \\[replacements."example.com/lib/http"]
        \\path = "../http"
        \\
        \\excludes = ["example.com/lib/http@v1.7.1", 'x']
        \\flag = true
        \\
    ;
    var diag = Diagnostic{};
    var doc = try parse(std.testing.allocator, text, &diag);
    defer doc.deinit();
    const m = try Manifest.fromDocument(&doc, &diag);
    try std.testing.expectEqualStrings("example.com/matt/myapp", m.module);
    try std.testing.expectEqualStrings("v0.4.0", m.version.?);
    try std.testing.expectEqualStrings("v1.7.2", doc.getString("dependencies", "example.com/lib/http").?);
    try std.testing.expectEqualStrings("v1.4.0", doc.getString("dependencies", "example.com/lib/json").?);
    try std.testing.expectEqualStrings("../http", doc.getString("replacements.example.com/lib/http", "path").?);
    const ex = doc.get("replacements.example.com/lib/http", "excludes").?.strings;
    try std.testing.expectEqual(@as(usize, 2), ex.len);
    try std.testing.expectEqualStrings("x", ex[1]);
    try std.testing.expect(doc.get("replacements.example.com/lib/http", "flag").?.boolean);
}

test "arrays of tables" {
    const text =
        \\schema = 1
        \\
        \\[[modules]]
        \\module = "a.example/x"
        \\version = "v1.0.0"
        \\
        \\[[modules]]
        \\module = "b.example/y"
        \\version = "v2.0.0"
        \\
    ;
    var diag = Diagnostic{};
    var doc = try parse(std.testing.allocator, text, &diag);
    defer doc.deinit();
    try std.testing.expectEqualStrings("a.example/x", doc.getString("modules[0]", "module").?);
    try std.testing.expectEqualStrings("v2.0.0", doc.getString("modules[1]", "version").?);
    try std.testing.expect(doc.get("modules[2]", "module") == null);
}

test "rejected input names its line" {
    const cases = [_]struct { text: []const u8, line: usize }{
        .{ .text = "schema = 1\nmodule = 3.5\n", .line = 2 },
        .{ .text = "schema = 1\n[deps\n", .line = 2 },
        .{ .text = "x = \"unterminated\n", .line = 1 },
        .{ .text = "\n\nkey\n", .line = 3 },
        .{ .text = "a = [1, 2]\n", .line = 1 },
        .{ .text = "[[modules]\n", .line = 1 },
        .{ .text = "a = 1 b = 2\n", .line = 1 },
    };
    for (cases) |c| {
        var diag = Diagnostic{};
        try std.testing.expectError(error.Syntax, parse(std.testing.allocator, c.text, &diag));
        try std.testing.expectEqual(c.line, diag.line);
    }
}

test "write then read" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, "github.com/matt-dunleavy/http", "v0.1.0", "0.2.7");
    var diag = Diagnostic{};
    var doc = try parse(std.testing.allocator, aw.written(), &diag);
    defer doc.deinit();
    const m = try Manifest.fromDocument(&doc, &diag);
    try std.testing.expectEqualStrings("github.com/matt-dunleavy/http", m.module);
    try std.testing.expectEqualStrings(">=0.2.7", m.prolua.?);
    try std.testing.expectEqual(@as(i64, 1), m.schema);
}

test "dependencies and replacements" {
    const text =
        \\schema = 1
        \\module = "example.com/me/app"
        \\
        \\[dependencies]
        \\"example.com/lib/http" = "v1.7.2"
        \\"example.com/lib/json" = "v1.4.0"
        \\
        \\[indirectDependencies]
        \\"example.com/lib/uri" = "v1.1.0"
        \\
        \\[replacements."example.com/lib/http"]
        \\path = "../http"
        \\
        \\[replacements."example.com/lib/json"]
        \\module = "fork.example.com/json"
        \\version = "v1.4.1"
        \\
    ;
    var diag = Diagnostic{};
    var doc = try parse(std.testing.allocator, text, &diag);
    defer doc.deinit();
    const m = try Manifest.fromDocument(&doc, &diag);
    try std.testing.expectEqual(@as(usize, 2), m.dependencies.len);
    try std.testing.expectEqualStrings("v1.7.2", m.dependencyVersion("example.com/lib/http").?);
    try std.testing.expectEqualStrings("v1.1.0", m.dependencyVersion("example.com/lib/uri").?);
    try std.testing.expect(m.dependencyVersion("example.com/lib/none") == null);
    try std.testing.expectEqualStrings("../http", m.replacement("example.com/lib/http").?.path.?);
    const fork = m.replacement("example.com/lib/json").?;
    try std.testing.expectEqualStrings("fork.example.com/json", fork.target_module.?);
    try std.testing.expectEqualStrings("v1.4.1", fork.target_version.?);
    try std.testing.expect(m.replacement("example.com/lib/uri") == null);
}

test "a replacement without a target is rejected" {
    const text =
        \\schema = 1
        \\module = "example.com/me/app"
        \\[replacements."example.com/lib/http"]
        \\version = "v1"
        \\
    ;
    var diag = Diagnostic{};
    var doc = try parse(std.testing.allocator, text, &diag);
    defer doc.deinit();
    try std.testing.expectError(error.Invalid, Manifest.fromDocument(&doc, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "needs 'path'") != null);
}
