// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! String Implementation
//!
//! This module implements Lua strings with interning, hashing, and
//! efficient memory management. Strings in Lua are immutable and
//! interned for fast comparison and memory efficiency.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;

const value = @import("value.zig");
const gc = @import("gc.zig");
const config = @import("config.zig");

/// Maximum string length
pub const MAX_STR_LEN = math.maxInt(usize) - @sizeOf(String);

/// Short string threshold (strings <= this are always interned)
pub const LUAI_MAXSHORTLEN = 40;

/// String hash seed
pub const STRING_SEED = 0x9e3779b9;

/// `shrlen` of a long string (Lua's TString.shrlen sentinel)
const LONG_MARK: u8 = 0xFF;

/// String structure, laid out as Lua's TString: 32 bytes of header, then the
/// bytes and a NUL in the same allocation. Short strings (interned, at most
/// LUAI_MAXSHORTLEN bytes) keep their length in a byte and use `u.hnext`
/// for the intern chain; long strings keep their length in `u.lnglen` and
/// are never chained.
pub const String = struct {
    header: value.GCObject,
    hash: u32, // short strings: always valid; long strings: once `extra` is set (luaS_hashlongstr)
    shrlen: u8, // length of a short string, LONG_MARK for a long one
    extra: u8, // short strings: reserved-word flag; long strings: "hash is valid"
    u: extern union {
        lnglen: usize, // length of a long string
        hnext: ?*String, // chain in the intern table (kept apart from `header.next`, the GC list)
    },

    comptime {
        std.debug.assert(@sizeOf(String) == 32);
    }

    pub inline fn isShort(self: *const String) bool {
        return self.shrlen != LONG_MARK;
    }

    /// String length
    pub inline fn len(self: *const String) usize {
        return if (self.shrlen != LONG_MARK) self.shrlen else self.u.lnglen;
    }

    /// Get string data as slice
    pub inline fn slice(self: *const String) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return (base + @sizeOf(String))[0..self.len()];
    }

    /// The hash, computing it on first use for a long string. Short strings
    /// are hashed when interned; long strings only when used as table keys.
    pub fn hashOf(self: *String) u32 {
        if (!self.isShort() and self.extra == 0) {
            self.hash = hashString(self.slice(), STRING_SEED);
            self.extra = 1;
        }
        return self.hash;
    }

    /// Check if string is reserved word
    pub fn isReserved(self: *const String) bool {
        return self.isShort() and self.extra != 0;
    }

    /// Compare strings
    pub fn equals(self: *const String, other: *const String) bool {
        return self == other; // Interned strings can be compared by pointer
    }

    /// Get string size in memory
    pub fn sizeOf(n: usize) usize {
        return @sizeOf(String) + n + 1; // +1 for null terminator
    }
};

/// String table for interning
pub const StringTable = struct {
    const MIN_SIZE = 128;

    hash: []?*String,
    nuse: u32, // Number of elements
    size: u32, // Size of hash array
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !StringTable {
        const hash = try allocator.alloc(?*String, MIN_SIZE);
        @memset(hash, null);

        return StringTable{
            .hash = hash,
            .nuse = 0,
            .size = MIN_SIZE,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringTable) void {
        self.allocator.free(self.hash);
    }

    /// Find string in table (the probe of internshrstr): hash, then length,
    /// then the bytes
    pub fn find(self: *StringTable, data: []const u8, hash: u32) ?*String {
        const idx = hash & (self.size - 1);
        var curr = self.hash[idx];
        while (curr) |s| {
            if (s.hash == hash and s.shrlen == data.len and mem.eql(u8, s.slice(), data)) {
                return s;
            }
            curr = s.u.hnext;
        }
        return null;
    }

    /// Insert string into table
    pub fn insert(self: *StringTable, s: *String) !void {
        // Check if resize needed
        if (self.nuse >= self.size and self.size <= math.maxInt(u32) / 2) {
            try self.resize(self.size * 2);
        }

        const idx = s.hash & (self.size - 1);
        s.u.hnext = self.hash[idx];
        self.hash[idx] = s;
        self.nuse += 1;
    }

    /// Remove string from table
    pub fn remove(self: *StringTable, s: *String) void {
        const idx = s.hash & (self.size - 1);
        var prev: *?*String = &self.hash[idx];
        var curr = prev.*;

        while (curr) |current| {
            if (current == s) {
                prev.* = current.u.hnext;
                current.u.hnext = null;
                self.nuse -= 1;
                break;
            }
            prev = &current.u.hnext;
            curr = current.u.hnext;
        }
    }

    /// Resize hash table
    fn resize(self: *StringTable, newsize: u32) !void {
        const oldhash = self.hash;
        const oldsize = self.size;

        // Allocate new hash array
        const newhash = try self.allocator.alloc(?*String, newsize);
        @memset(newhash, null);

        self.hash = newhash;
        self.size = newsize;

        // Rehash all strings
        for (oldhash[0..oldsize]) |head| {
            var p = head;
            while (p) |s| {
                const next = s.u.hnext;
                const idx = s.hash & (newsize - 1);
                s.u.hnext = self.hash[idx];
                self.hash[idx] = s;
                p = next;
            }
        }

        self.allocator.free(oldhash);
    }

    /// Shrink table if too sparse
    pub fn shrink(self: *StringTable) !void {
        const optimal = self.nuse * 4; // 25% load factor
        if (self.size > MIN_SIZE and self.size > optimal) {
            const newsize = @max(MIN_SIZE, std.math.ceilPowerOfTwo(u32, optimal) catch self.size);
            if (newsize < self.size) {
                try self.resize(newsize);
            }
        }
    }
};

/// Hash function for strings
pub fn hashString(data: []const u8, seed: u32) u32 {
    if (data.len == 0) return seed;

    // Use FNV-1a hash for good distribution
    var h: u32 = seed;
    for (data) |byte| {
        h ^= byte;
        h *%= 0x01000193; // FNV prime
    }

    // Mix final hash
    h ^= @truncate(data.len);
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;

    return h;
}

/// Allocate a string object with its bytes stored inline after the header.
/// The object is not linked to any GC list or intern table; see `StringPool`.
pub fn createString(allocator: std.mem.Allocator, data: []const u8, hash: u32) !*String {
    if (data.len > MAX_STR_LEN) {
        return error.StringTooLong;
    }

    const size = String.sizeOf(data.len);
    const mem_ptr = try allocator.alignedAlloc(u8, .of(String), size);

    const s = @as(*String, @ptrCast(@alignCast(mem_ptr.ptr)));
    const data_ptr = mem_ptr.ptr + @sizeOf(String); // the bytes follow the struct

    s.* = .{
        .header = .{
            .next = null,
            .tt = @intFromEnum(value.ValueType.string),
            .marked = 0, // Will be set by GC
        },
        .hash = hash,
        .shrlen = if (data.len <= LUAI_MAXSHORTLEN) @intCast(data.len) else LONG_MARK,
        .extra = 0, // short: not a reserved word; long: not hashed yet
        .u = if (data.len <= LUAI_MAXSHORTLEN) .{ .hnext = null } else .{ .lnglen = data.len },
    };

    // Copy string data
    @memcpy(data_ptr[0..data.len], data);
    data_ptr[data.len] = 0; // Null terminate

    return s;
}

/// Free a string created by `createString` (the inline block, with its alignment).
pub fn freeString(allocator: std.mem.Allocator, s: *String) void {
    const block: [*]align(@alignOf(String)) u8 = @ptrCast(s);
    allocator.free(block[0..String.sizeOf(s.len())]);
}

/// String pool for global string management
pub const StringPool = struct {
    table: StringTable,
    gc: *gc.GarbageCollector,
    reserved_words: std.StringHashMap(*String),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, g: *gc.GarbageCollector) !StringPool {
        return StringPool{
            .table = try StringTable.init(allocator),
            .gc = g,
            .reserved_words = std.StringHashMap(*String).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringPool) void {
        self.reserved_words.deinit();
        self.table.deinit();
    }

    /// Intern a string
    pub fn intern(self: *StringPool, data: []const u8) !*String {
        const hash = hashString(data, STRING_SEED);

        // Try to find existing string
        if (self.table.find(data, hash)) |s| {
            // Dead (white of the cycle being swept) but not collected yet:
            // resurrect it, as internshrstr does, or the sweep frees a
            // string that is referenced again
            if (gc.isDead(self.gc, &s.header)) gc.changeWhite(&s.header);
            return s;
        }

        // Create new string using GC allocator
        const s = try self.createStringWithGC(data, hash);

        // Only intern short strings
        if (s.isShort()) {
            try self.table.insert(s);
        }

        return s;
    }

    /// Create a string (may not be interned)
    pub fn create(self: *StringPool, data: []const u8) !*String {
        // Short strings are always interned
        if (data.len <= LUAI_MAXSHORTLEN) {
            return self.intern(data);
        }

        // Long strings are not interned, and are hashed only if used as keys
        return self.createStringWithGC(data, 0);
    }

    /// Create a string and hand its ownership to the garbage collector
    fn createStringWithGC(self: *StringPool, data: []const u8, hash: u32) !*String {
        const s = try createString(self.allocator, data, hash);
        self.gc.linkObject(&s.header, String.sizeOf(data.len));
        return s;
    }

    /// Intern a reserved word
    pub fn internReserved(self: *StringPool, word: []const u8) !*String {
        const s = try self.intern(word);
        s.extra = 1;
        try self.reserved_words.put(word, s);
        return s;
    }

    /// Get reserved word
    pub fn getReserved(self: *StringPool, word: []const u8) ?*String {
        return self.reserved_words.get(word);
    }

    /// Force collection of dead strings
    pub fn collect(self: *StringPool) !void {
        // This is called during GC sweep phase
        // The GC will call remove() for each dead string

        // Shrink table if needed
        try self.table.shrink();
    }

    /// Remove dead string from pool
    pub fn remove(self: *StringPool, s: *String) void {
        if (s.isShort()) {
            self.table.remove(s);
        }
        // Long strings are not in the table, so nothing to do
    }

    /// Get statistics for debugging
    pub fn stats(self: *const StringPool) StringStats {
        return .{
            .total_strings = self.table.nuse,
            .table_size = self.table.size,
            .load_factor = @as(f32, @floatFromInt(self.table.nuse)) / @as(f32, @floatFromInt(self.table.size)),
        };
    }
};

/// String pool statistics
pub const StringStats = struct {
    total_strings: u32,
    table_size: u32,
    load_factor: f32,
};

/// Concatenate strings
pub fn concat(pool: *StringPool, strings: []const *String) !*String {
    // Calculate total length
    var total: usize = 0;
    for (strings) |s| {
        total += s.len();
    }

    if (total > MAX_STR_LEN) {
        return error.StringTooLong;
    }

    // Allocate buffer
    const buffer = try pool.allocator.alloc(u8, total);
    defer pool.allocator.free(buffer);

    // Copy strings
    var pos: usize = 0;
    for (strings) |s| {
        @memcpy(buffer[pos .. pos + s.len()], s.slice());
        pos += s.len();
    }

    // Create result (will be interned if short)
    return pool.create(buffer);
}

/// Compare strings lexicographically
pub fn compare(s1: *const String, s2: *const String) std.math.Order {
    return mem.order(u8, s1.slice(), s2.slice());
}

/// Format string for debugging
pub fn format(s: *const String, writer: anytype) !void {
    try writer.writeByte('"');
    // Escape special characters
    for (s.slice()) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0...31, 127 => try writer.print("\\{d:0>3}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// Reserved words
pub const reserved_words = [_][]const u8{
    "and",   "break",  "do",     "else",     "elseif",
    "end",   "false",  "for",    "function", "goto",
    "if",    "in",     "local",  "nil",      "not",
    "or",    "repeat", "return", "then",     "true",
    "until", "while",
};

/// Initialize reserved words in string pool
pub fn initReservedWords(pool: *StringPool) !void {
    for (reserved_words) |word| {
        _ = try pool.internReserved(word);
    }
}

// Tests

test "string creation and interning" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    var pool = try StringPool.init(allocator, &g);
    defer pool.deinit();

    // Test short string interning
    const s1 = try pool.intern("hello");
    const s2 = try pool.intern("hello");
    try std.testing.expect(s1 == s2);
    try std.testing.expect(s1.isShort());

    // Test long string
    const long = "a" ** 100;
    const s3 = try pool.create(long);
    try std.testing.expect(!s3.isShort());
    try std.testing.expect(s3.len() == 100);
}

test "string hashing" {
    const h1 = hashString("hello", STRING_SEED);
    const h2 = hashString("hello", STRING_SEED);
    const h3 = hashString("world", STRING_SEED);

    try std.testing.expect(h1 == h2);
    try std.testing.expect(h1 != h3);
}

test "reserved words" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    var pool = try StringPool.init(allocator, &g);
    defer pool.deinit();

    try initReservedWords(&pool);

    // Check reserved words are marked
    const s = pool.getReserved("while").?;
    try std.testing.expect(s.isReserved());

    // Check non-reserved word
    const s2 = try pool.intern("hello");
    try std.testing.expect(!s2.isReserved());
}

test "string concatenation" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    var pool = try StringPool.init(allocator, &g);
    defer pool.deinit();

    const s1 = try pool.intern("hello");
    const s2 = try pool.intern(" ");
    const s3 = try pool.intern("world");

    const result = try concat(&pool, &[_]*String{ s1, s2, s3 });
    try std.testing.expectEqualStrings("hello world", result.slice());
}

test "string table operations" {
    const allocator = std.testing.allocator;
    var table = try StringTable.init(allocator);
    defer table.deinit();

    // Create and insert strings
    const s1 = try createString(allocator, "test1", hashString("test1", STRING_SEED));
    defer freeString(allocator, s1);

    try table.insert(s1);
    try std.testing.expect(table.nuse == 1);

    // Find string
    const found = table.find("test1", s1.hash);
    try std.testing.expect(found != null);
    try std.testing.expect(found.? == s1);

    // Remove string
    table.remove(s1);
    try std.testing.expect(table.nuse == 0);
    try std.testing.expect(table.find("test1", s1.hash) == null);
}

test "string pool statistics" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    var pool = try StringPool.init(allocator, &g);
    defer pool.deinit();

    // Add some strings
    _ = try pool.intern("one");
    _ = try pool.intern("two");
    _ = try pool.intern("three");

    const stats = pool.stats();
    try std.testing.expect(stats.total_strings == 3);
    try std.testing.expect(stats.table_size >= 128);
    try std.testing.expect(stats.load_factor > 0 and stats.load_factor < 1);
}
