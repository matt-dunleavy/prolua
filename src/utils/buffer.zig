// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

/// Initial buffer size (matches Lua's LUA_MINBUFFER)
pub const INITIAL_BUFFER_SIZE = 32;

/// Buffer growth factor
pub const GROWTH_FACTOR = 2;

/// Maximum buffer size to prevent excessive memory usage
pub const MAX_BUFFER_SIZE = 1024 * 1024 * 100; // 100MB

/// String buffer for efficient string building and concatenation
pub const StringBuffer = struct {
    data: []u8,
    len: usize,
    capacity: usize,
    allocator: mem.Allocator,

    /// Initialize a new string buffer
    pub fn init(allocator: mem.Allocator) !StringBuffer {
        const data = try allocator.alloc(u8, INITIAL_BUFFER_SIZE);
        return StringBuffer{
            .data = data,
            .len = 0,
            .capacity = INITIAL_BUFFER_SIZE,
            .allocator = allocator,
        };
    }

    /// Initialize with a specific initial capacity
    pub fn initWithCapacity(allocator: mem.Allocator, capacity: usize) !StringBuffer {
        const actual_capacity = @max(capacity, INITIAL_BUFFER_SIZE);
        const data = try allocator.alloc(u8, actual_capacity);
        return StringBuffer{
            .data = data,
            .len = 0,
            .capacity = actual_capacity,
            .allocator = allocator,
        };
    }

    /// Initialize from an existing string
    pub fn initFromString(allocator: mem.Allocator, str: []const u8) !StringBuffer {
        const capacity = @max(str.len * 2, INITIAL_BUFFER_SIZE);
        var buffer = try initWithCapacity(allocator, capacity);
        try buffer.appendSlice(str);
        return buffer;
    }

    /// Deinitialize the buffer
    pub fn deinit(self: *StringBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// Get the current content as a slice
    pub fn slice(self: *const StringBuffer) []const u8 {
        return self.data[0..self.len];
    }

    /// Get the current length
    pub fn length(self: *const StringBuffer) usize {
        return self.len;
    }

    /// Get the current capacity
    pub fn getCapacity(self: *const StringBuffer) usize {
        return self.capacity;
    }

    /// Check if the buffer is empty
    pub fn isEmpty(self: *const StringBuffer) bool {
        return self.len == 0;
    }

    /// Clear the buffer contents (keep capacity)
    pub fn clear(self: *StringBuffer) void {
        self.len = 0;
    }

    /// Reset the buffer to initial state
    pub fn reset(self: *StringBuffer) !void {
        self.clear();
        if (self.capacity > INITIAL_BUFFER_SIZE) {
            self.allocator.free(self.data);
            self.data = try self.allocator.alloc(u8, INITIAL_BUFFER_SIZE);
            self.capacity = INITIAL_BUFFER_SIZE;
        }
    }

    /// Ensure the buffer has at least the specified capacity
    pub fn ensureCapacity(self: *StringBuffer, min_capacity: usize) !void {
        if (self.capacity >= min_capacity) return;

        var new_capacity = self.capacity;
        while (new_capacity < min_capacity) {
            new_capacity *= GROWTH_FACTOR;
            if (new_capacity > MAX_BUFFER_SIZE) {
                return error.BufferTooLarge;
            }
        }

        const new_data = try self.allocator.realloc(self.data, new_capacity);
        self.data = new_data;
        self.capacity = new_capacity;
    }

    /// Ensure space for at least n more bytes
    pub fn ensureSpace(self: *StringBuffer, n: usize) !void {
        try self.ensureCapacity(self.len + n);
    }

    /// Append a single byte
    pub fn append(self: *StringBuffer, byte: u8) !void {
        try self.ensureSpace(1);
        self.data[self.len] = byte;
        self.len += 1;
    }

    /// Append a slice of bytes
    pub fn appendSlice(self: *StringBuffer, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.ensureSpace(bytes.len);
        @memcpy(self.data[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Append a null-terminated string
    pub fn appendCString(self: *StringBuffer, cstr: [*:0]const u8) !void {
        const len = mem.len(cstr);
        try self.appendSlice(cstr[0..len]);
    }

    /// Append a formatted string
    pub fn appendFormat(self: *StringBuffer, comptime fmt: []const u8, args: anytype) !void {
        // Estimate required space (this is a heuristic)
        const estimated_size = fmt.len + 64;
        try self.ensureSpace(estimated_size);

        // Try to format directly into the buffer
        const remaining = self.data[self.len..];
        if (std.fmt.bufPrint(remaining, fmt, args)) |result| {
            self.len += result.len;
        } else |err| switch (err) {
            error.NoSpaceLeft => {
                // Fallback: allocate a temporary buffer
                const temp = try std.fmt.allocPrint(self.allocator, fmt, args);
                defer self.allocator.free(temp);
                try self.appendSlice(temp);
            },
        }
    }

    /// Append multiple strings efficiently
    pub fn appendMany(self: *StringBuffer, strings: []const []const u8) !void {
        // Calculate total length first
        var total_len: usize = 0;
        for (strings) |str| {
            total_len += str.len;
        }

        if (total_len == 0) return;
        try self.ensureSpace(total_len);

        // Copy all strings
        for (strings) |str| {
            if (str.len > 0) {
                @memcpy(self.data[self.len .. self.len + str.len], str);
                self.len += str.len;
            }
        }
    }

    /// Append with a separator between elements
    pub fn appendJoin(self: *StringBuffer, strings: []const []const u8, separator: []const u8) !void {
        if (strings.len == 0) return;

        // Calculate total length
        var total_len: usize = 0;
        for (strings, 0..) |str, i| {
            total_len += str.len;
            if (i > 0) total_len += separator.len;
        }

        try self.ensureSpace(total_len);

        // Copy strings with separators
        for (strings, 0..) |str, i| {
            if (i > 0 and separator.len > 0) {
                @memcpy(self.data[self.len .. self.len + separator.len], separator);
                self.len += separator.len;
            }
            if (str.len > 0) {
                @memcpy(self.data[self.len .. self.len + str.len], str);
                self.len += str.len;
            }
        }
    }

    /// Insert bytes at a specific position
    pub fn insert(self: *StringBuffer, pos: usize, bytes: []const u8) !void {
        if (pos > self.len) return error.IndexOutOfBounds;
        if (bytes.len == 0) return;

        try self.ensureSpace(bytes.len);

        // Move existing data to make room
        if (pos < self.len) {
            const src = self.data[pos..self.len];
            const dst = self.data[pos + bytes.len .. self.len + bytes.len];
            std.mem.copyBackwards(u8, dst, src);
        }

        // Insert new data
        @memcpy(self.data[pos .. pos + bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Remove a range of bytes
    pub fn remove(self: *StringBuffer, start: usize, end: usize) !void {
        if (start >= self.len or end > self.len or start > end) {
            return error.IndexOutOfBounds;
        }

        const remove_len = end - start;
        if (remove_len == 0) return;

        // Move remaining data forward
        if (end < self.len) {
            const src = self.data[end..self.len];
            const dst = self.data[start .. self.len - remove_len];
            std.mem.copyForwards(u8, dst, src); // ranges overlap
        }

        self.len -= remove_len;
    }

    /// Truncate to a specific length
    pub fn truncate(self: *StringBuffer, new_len: usize) void {
        if (new_len < self.len) {
            self.len = new_len;
        }
    }

    /// Convert the buffer to an owned string
    pub fn toOwnedSlice(self: *StringBuffer) ![]u8 {
        const result = try self.allocator.alloc(u8, self.len);
        @memcpy(result, self.data[0..self.len]);
        return result;
    }

    /// Convert the buffer to an owned string and reset the buffer
    pub fn toOwnedSliceAndReset(self: *StringBuffer) ![]u8 {
        const result = try self.toOwnedSlice();
        try self.reset();
        return result;
    }

    /// Clone the buffer
    pub fn clone(self: *const StringBuffer) !StringBuffer {
        var new_buffer = try initWithCapacity(self.allocator, self.capacity);
        try new_buffer.appendSlice(self.slice());
        return new_buffer;
    }

    /// Shrink the buffer to fit its content
    pub fn shrinkToFit(self: *StringBuffer) !void {
        if (self.len == 0) {
            try self.reset();
            return;
        }

        if (self.capacity > self.len) {
            const new_capacity = @max(self.len, INITIAL_BUFFER_SIZE);
            const new_data = try self.allocator.realloc(self.data, new_capacity);
            self.data = new_data;
            self.capacity = new_capacity;
        }
    }

    /// Get a byte at a specific position
    pub fn at(self: *const StringBuffer, index: usize) !u8 {
        if (index >= self.len) return error.IndexOutOfBounds;
        return self.data[index];
    }

    /// Set a byte at a specific position
    pub fn set(self: *StringBuffer, index: usize, byte: u8) !void {
        if (index >= self.len) return error.IndexOutOfBounds;
        self.data[index] = byte;
    }

    /// Find the first occurrence of a byte
    pub fn indexOf(self: *const StringBuffer, byte: u8) ?usize {
        return mem.indexOfScalar(u8, self.slice(), byte);
    }

    /// Find the last occurrence of a byte
    pub fn lastIndexOf(self: *const StringBuffer, byte: u8) ?usize {
        return mem.lastIndexOfScalar(u8, self.slice(), byte);
    }

    /// Check if the buffer starts with a prefix
    pub fn startsWith(self: *const StringBuffer, prefix: []const u8) bool {
        return mem.startsWith(u8, self.slice(), prefix);
    }

    /// Check if the buffer ends with a suffix
    pub fn endsWith(self: *const StringBuffer, suffix: []const u8) bool {
        return mem.endsWith(u8, self.slice(), suffix);
    }

    /// Replace all occurrences of a pattern with a replacement
    pub fn replace(self: *StringBuffer, pattern: []const u8, replacement: []const u8) !void {
        if (pattern.len == 0) return;

        var new_buffer = init(self.allocator) catch return;
        defer new_buffer.deinit();

        var pos: usize = 0;
        const content = self.slice();

        while (pos < content.len) {
            if (mem.startsWith(u8, content[pos..], pattern)) {
                try new_buffer.appendSlice(replacement);
                pos += pattern.len;
            } else {
                try new_buffer.append(content[pos]);
                pos += 1;
            }
        }

        // Replace current buffer content
        self.clear();
        try self.appendSlice(new_buffer.slice());
    }
};

/// Specialized buffer for Lua table.concat operations
pub const ConcatBuffer = struct {
    buffer: StringBuffer,

    pub fn init(allocator: mem.Allocator) !ConcatBuffer {
        return ConcatBuffer{
            .buffer = try StringBuffer.init(allocator),
        };
    }

    pub fn deinit(self: *ConcatBuffer) void {
        self.buffer.deinit();
    }

    /// Concatenate array elements with optional separator
    pub fn concatArray(self: *ConcatBuffer, strings: []const []const u8, separator: ?[]const u8) ![]u8 {
        self.buffer.clear();

        if (strings.len == 0) {
            return try self.buffer.toOwnedSlice();
        }

        if (separator) |sep| {
            try self.buffer.appendJoin(strings, sep);
        } else {
            try self.buffer.appendMany(strings);
        }

        return try self.buffer.toOwnedSlice();
    }

    /// Concatenate with range specification (for table.concat with i, j parameters)
    pub fn concatRange(self: *ConcatBuffer, strings: []const []const u8, start: usize, end: usize, separator: ?[]const u8) ![]u8 {
        if (start > end or start >= strings.len) {
            return try self.buffer.allocator.alloc(u8, 0);
        }

        const actual_end = @min(end + 1, strings.len);
        const range = strings[start..actual_end];
        return try self.concatArray(range, separator);
    }
};

// Tests
test "StringBuffer basic operations" {
    var buffer = try StringBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    // Test empty buffer
    try std.testing.expect(buffer.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buffer.length());

    // Test append
    try buffer.append('H');
    try buffer.appendSlice("ello");
    try std.testing.expectEqualSlices(u8, "Hello", buffer.slice());
    try std.testing.expect(!buffer.isEmpty());
    try std.testing.expectEqual(@as(usize, 5), buffer.length());

    // Test clear
    buffer.clear();
    try std.testing.expect(buffer.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buffer.length());
}

test "StringBuffer growth" {
    var buffer = try StringBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    // Fill buffer beyond initial capacity
    const long_string = "a" ** 100;
    try buffer.appendSlice(long_string);
    try std.testing.expectEqual(@as(usize, 100), buffer.length());
    try std.testing.expectEqualSlices(u8, long_string, buffer.slice());
}

test "StringBuffer format" {
    var buffer = try StringBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.appendFormat("Hello, {s}! You have {} messages.", .{ "World", 42 });
    try std.testing.expectEqualSlices(u8, "Hello, World! You have 42 messages.", buffer.slice());
}

test "StringBuffer join" {
    var buffer = try StringBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    const strings = [_][]const u8{ "apple", "banana", "cherry" };
    try buffer.appendJoin(&strings, ", ");
    try std.testing.expectEqualSlices(u8, "apple, banana, cherry", buffer.slice());
}

test "StringBuffer insert and remove" {
    var buffer = try StringBuffer.initFromString(std.testing.allocator, "HelloWorld");
    defer buffer.deinit();

    // Insert
    try buffer.insert(5, ", ");
    try std.testing.expectEqualSlices(u8, "Hello, World", buffer.slice());

    // Remove
    try buffer.remove(5, 7); // Remove ", "
    try std.testing.expectEqualSlices(u8, "HelloWorld", buffer.slice());
}

test "ConcatBuffer operations" {
    var concat_buffer = try ConcatBuffer.init(std.testing.allocator);
    defer concat_buffer.deinit();

    const strings = [_][]const u8{ "one", "two", "three" };

    // Test without separator
    const result1 = try concat_buffer.concatArray(&strings, null);
    defer std.testing.allocator.free(result1);
    try std.testing.expectEqualSlices(u8, "onetwothree", result1);

    // Test with separator
    const result2 = try concat_buffer.concatArray(&strings, "-");
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualSlices(u8, "one-two-three", result2);

    // Test range
    const result3 = try concat_buffer.concatRange(&strings, 1, 2, "|");
    defer std.testing.allocator.free(result3);
    try std.testing.expectEqualSlices(u8, "two|three", result3);
}

test "StringBuffer utilities" {
    var buffer = try StringBuffer.initFromString(std.testing.allocator, "Hello, World!");
    defer buffer.deinit();

    // Test indexOf
    try std.testing.expectEqual(@as(?usize, 7), buffer.indexOf('W'));
    try std.testing.expectEqual(@as(?usize, null), buffer.indexOf('x'));

    // Test startsWith/endsWith
    try std.testing.expect(buffer.startsWith("Hello"));
    try std.testing.expect(buffer.endsWith("World!"));
    try std.testing.expect(!buffer.startsWith("Hi"));

    // Test at/set
    try std.testing.expectEqual(@as(u8, 'H'), try buffer.at(0));
    try buffer.set(0, 'h');
    try std.testing.expectEqual(@as(u8, 'h'), try buffer.at(0));
}
