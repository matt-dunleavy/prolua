// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;

/// Hash seed for consistent hashing across runs
pub const DEFAULT_HASH_SEED: u32 = 5381;

/// Maximum number of characters to hash for long strings (Lua optimization)
pub const MAX_STRING_HASH_LENGTH: usize = 40;

/// Hash step size for long strings (Lua uses this optimization)
pub const STRING_HASH_STEP: usize = 1;

/// Hash function result type
pub const HashResult = u32;

/// String hashing algorithm similar to Lua's implementation
/// Based on a variant of djb2 with Lua's optimizations for long strings
pub fn hashString(bytes: []const u8) HashResult {
    if (bytes.len == 0) return hashStringWithSeed(bytes, @intCast(bytes.len));

    var h: u32 = @intCast(bytes.len); // Initialize with string length (Lua optimization)

    if (bytes.len <= MAX_STRING_HASH_LENGTH) {
        // Hash all characters for short strings
        for (bytes) |c| {
            h = h ^ ((h << 5) +% (h >> 2) +% c);
        }
    } else {
        // For long strings, hash only some characters (Lua optimization)
        const step = @max(1, bytes.len / MAX_STRING_HASH_LENGTH);
        var i: usize = 0;
        while (i < bytes.len) : (i += step) {
            h = h ^ ((h << 5) +% (h >> 2) +% bytes[i]);
        }
    }

    return h;
}

/// String hashing with custom seed
pub fn hashStringWithSeed(bytes: []const u8, seed: u32) HashResult {
    var h = seed;

    if (bytes.len <= MAX_STRING_HASH_LENGTH) {
        // Hash all characters for short strings
        for (bytes) |c| {
            h = h ^ ((h << 5) +% (h >> 2) +% c);
        }
    } else {
        // For long strings, hash only some characters
        const step = @max(1, bytes.len / MAX_STRING_HASH_LENGTH);
        var i: usize = 0;
        while (i < bytes.len) : (i += step) {
            h = h ^ ((h << 5) +% (h >> 2) +% bytes[i]);
        }
    }

    return h;
}

/// DJB2 hash algorithm (Daniel J. Bernstein)
/// Classic and widely used hash function
pub fn djb2Hash(bytes: []const u8) HashResult {
    var h: u32 = DEFAULT_HASH_SEED;
    for (bytes) |c| {
        h = ((h << 5) +% h) +% c; // h * 33 + c
    }
    return h;
}

/// DJB2a hash algorithm (variant with XOR)
pub fn djb2aHash(bytes: []const u8) HashResult {
    var h: u32 = DEFAULT_HASH_SEED;
    for (bytes) |c| {
        h = ((h << 5) +% h) ^ c; // h * 33 ^ c
    }
    return h;
}

/// SDBM hash algorithm
/// Used in some database implementations
pub fn sdbmHash(bytes: []const u8) HashResult {
    var h: u32 = 0;
    for (bytes) |c| {
        h = c +% (h << 6) +% (h << 16) -% h;
    }
    return h;
}

/// FNV-1a hash algorithm (32-bit)
/// Fast and good distribution
pub fn fnv1aHash(bytes: []const u8) HashResult {
    const FNV_OFFSET_BASIS: u32 = 2166136261;
    const FNV_PRIME: u32 = 16777619;

    var h: u32 = FNV_OFFSET_BASIS;
    for (bytes) |c| {
        h ^= c;
        h *%= FNV_PRIME;
    }
    return h;
}

/// CRC32 hash (using polynomial 0xEDB88320)
pub fn crc32Hash(bytes: []const u8) HashResult {
    return @truncate(std.hash.Crc32.hash(bytes));
}

/// Wyhash (fast, high-quality hash)
pub fn wyhash(bytes: []const u8, seed: u64) HashResult {
    return @truncate(std.hash.Wyhash.hash(seed, bytes));
}

/// Hash a pointer address (for table keys)
pub fn hashPointer(ptr: *const anyopaque) HashResult {
    const addr = @intFromPtr(ptr);
    // Drop lower bits (usually 0 due to alignment) and mix
    const shifted = addr >> 3;
    return @truncate(shifted ^ (shifted >> 16));
}

/// Hash an integer value
pub fn hashInteger(value: i64) HashResult {
    const uval = @as(u64, @bitCast(value));
    // Mix high and low bits
    return @truncate(uval ^ (uval >> 32));
}

/// Hash a floating-point value
pub fn hashFloat(value: f64) HashResult {
    // Handle special cases
    if (math.isNan(value)) return 0;
    if (value == 0.0) return 0; // Treat -0.0 and +0.0 the same

    const bits = @as(u64, @bitCast(value));
    return @truncate(bits ^ (bits >> 32));
}

/// Hash a boolean value
pub fn hashBoolean(value: bool) HashResult {
    return if (value) 1 else 0;
}

/// Combine two hash values
pub fn combineHashes(h1: HashResult, h2: HashResult) HashResult {
    // Based on boost::hash_combine
    return h1 ^ (h2 +% 0x9e3779b9 +% (h1 << 6) +% (h1 >> 2));
}

/// Hash function context for incremental hashing
pub const HashContext = struct {
    state: u32,
    algorithm: Algorithm,

    pub const Algorithm = enum {
        lua_string,
        djb2,
        djb2a,
        sdbm,
        fnv1a,
    };

    /// Initialize hash context
    pub fn init(algorithm: Algorithm) HashContext {
        const seed = switch (algorithm) {
            .lua_string => 0,
            .djb2, .djb2a => DEFAULT_HASH_SEED,
            .sdbm => 0,
            .fnv1a => 2166136261,
        };

        return HashContext{
            .state = seed,
            .algorithm = algorithm,
        };
    }

    /// Update hash with new bytes
    pub fn update(self: *HashContext, bytes: []const u8) void {
        switch (self.algorithm) {
            .lua_string => {
                for (bytes) |c| {
                    self.state = self.state ^ ((self.state << 5) +% (self.state >> 2) +% c);
                }
            },
            .djb2 => {
                for (bytes) |c| {
                    self.state = ((self.state << 5) +% self.state) +% c;
                }
            },
            .djb2a => {
                for (bytes) |c| {
                    self.state = ((self.state << 5) +% self.state) ^ c;
                }
            },
            .sdbm => {
                for (bytes) |c| {
                    self.state = c +% (self.state << 6) +% (self.state << 16) -% self.state;
                }
            },
            .fnv1a => {
                const FNV_PRIME: u32 = 16777619;
                for (bytes) |c| {
                    self.state ^= c;
                    self.state *%= FNV_PRIME;
                }
            },
        }
    }

    /// Finalize and get hash result
    pub fn final(self: *const HashContext) HashResult {
        return self.state;
    }

    /// Reset context to initial state
    pub fn reset(self: *HashContext) void {
        self.* = init(self.algorithm);
    }
};

/// Hash table utilities
pub const TableHash = struct {
    /// Calculate hash table size (power of 2)
    pub fn calculateSize(min_size: usize) usize {
        if (min_size == 0) return 1;
        return @as(usize, 1) << @intCast(math.log2_int_ceil(u64, min_size));
    }

    /// Get hash table index from hash value
    pub fn getIndex(hash: HashResult, table_size: usize) usize {
        assert(math.isPowerOfTwo(table_size));
        return @as(usize, hash) & (table_size - 1);
    }

    /// Probe sequence for open addressing (linear probing)
    pub fn linearProbe(start_index: usize, step: usize, table_size: usize) usize {
        return (start_index + step) % table_size;
    }

    /// Probe sequence for open addressing (quadratic probing)
    pub fn quadraticProbe(start_index: usize, step: usize, table_size: usize) usize {
        return (start_index + step * step) % table_size;
    }

    /// Double hashing probe
    pub fn doubleHashProbe(start_index: usize, hash2: HashResult, step: usize, table_size: usize) usize {
        const step_size = 1 + (@as(usize, hash2) % (table_size - 1));
        return (start_index + step * step_size) % table_size;
    }
};

/// Consistent hashing utilities
pub const ConsistentHash = struct {
    /// Simple consistent hash ring position
    pub fn getRingPosition(key: []const u8, ring_size: u32) u32 {
        return hashString(key) % ring_size;
    }

    /// Jump consistent hash (Google's algorithm)
    pub fn jumpConsistentHash(key: u64, num_buckets: u32) u32 {
        var k = key;
        var b: i32 = -1;
        var j: i32 = 0;

        while (j < num_buckets) {
            b = j;
            k = k *% 2862933555777941757 +% 1;
            j = @intFromFloat(@as(f64, @floatFromInt(b + 1)) * (@as(f64, @floatFromInt(@as(i64, 1) << 31)) / @as(f64, @floatFromInt((k >> 33) + 1))));
        }

        return @intCast(b);
    }
};

/// Hash quality testing utilities
pub const HashTesting = struct {
    /// Calculate collision count for a set of strings
    pub fn countCollisions(strings: []const []const u8, hash_fn: *const fn ([]const u8) HashResult) usize {
        var seen = std.AutoHashMap(HashResult, void).init(std.testing.allocator);
        defer seen.deinit();

        var collisions: usize = 0;
        for (strings) |str| {
            const hash = hash_fn(str);
            if (seen.contains(hash)) {
                collisions += 1;
            } else {
                seen.put(hash, {}) catch unreachable;
            }
        }

        return collisions;
    }

    /// Calculate distribution quality (chi-squared test approximation)
    pub fn calculateDistribution(hashes: []const HashResult, num_buckets: usize) f64 {
        var buckets: std.ArrayList(usize) = .empty;
        defer buckets.deinit(std.testing.allocator);
        buckets.resize(std.testing.allocator, num_buckets) catch unreachable;

        for (buckets.items) |*bucket| {
            bucket.* = 0;
        }

        for (hashes) |hash| {
            const bucket_idx = @as(usize, hash) % num_buckets;
            buckets.items[bucket_idx] += 1;
        }

        const expected = @as(f64, @floatFromInt(hashes.len)) / @as(f64, @floatFromInt(num_buckets));
        var chi_squared: f64 = 0.0;

        for (buckets.items) |count| {
            const diff = @as(f64, @floatFromInt(count)) - expected;
            chi_squared += (diff * diff) / expected;
        }

        return chi_squared;
    }
};

// Tests
test "string hashing consistency" {
    const test_strings = [_][]const u8{
        "",
        "a",
        "hello",
        "hello world",
        "The quick brown fox jumps over the lazy dog",
        "a" ** 100, // Long string
    };

    for (test_strings) |str| {
        const hash1 = hashString(str);
        const hash2 = hashString(str);
        try std.testing.expectEqual(hash1, hash2);
    }
}

test "different strings produce different hashes" {
    const hash1 = hashString("hello");
    const hash2 = hashString("world");
    const hash3 = hashString("hello world");

    try std.testing.expect(hash1 != hash2);
    try std.testing.expect(hash1 != hash3);
    try std.testing.expect(hash2 != hash3);
}

test "hash algorithms comparison" {
    const test_string = "The quick brown fox jumps over the lazy dog";

    const lua_hash = hashString(test_string);
    const djb2_hash = djb2Hash(test_string);
    const djb2a_hash = djb2aHash(test_string);
    const sdbm_hash = sdbmHash(test_string);
    const fnv1a_hash = fnv1aHash(test_string);

    // All should be different (very likely)
    const hashes = [_]HashResult{ lua_hash, djb2_hash, djb2a_hash, sdbm_hash, fnv1a_hash };
    for (hashes, 0..) |h1, i| {
        for (hashes[i + 1 ..]) |h2| {
            try std.testing.expect(h1 != h2);
        }
    }
}

test "hash context incremental hashing" {
    const test_string = "hello world";

    // Hash all at once
    const direct_hash = djb2Hash(test_string);

    // Hash incrementally
    var ctx = HashContext.init(.djb2);
    ctx.update("hello");
    ctx.update(" ");
    ctx.update("world");
    const incremental_hash = ctx.final();

    try std.testing.expectEqual(direct_hash, incremental_hash);
}

test "numeric hashing" {
    // Test integer hashing
    const int_hash1 = hashInteger(42);
    const int_hash2 = hashInteger(42);
    const int_hash3 = hashInteger(43);

    try std.testing.expectEqual(int_hash1, int_hash2);
    try std.testing.expect(int_hash1 != int_hash3);

    // Test float hashing
    const float_hash1 = hashFloat(3.14159);
    const float_hash2 = hashFloat(3.14159);
    const float_hash3 = hashFloat(2.71828);

    try std.testing.expectEqual(float_hash1, float_hash2);
    try std.testing.expect(float_hash1 != float_hash3);

    // Test special float values
    const nan_hash1 = hashFloat(math.nan(f64));
    const nan_hash2 = hashFloat(math.nan(f64));
    try std.testing.expectEqual(nan_hash1, nan_hash2);

    const zero_hash1 = hashFloat(0.0);
    const zero_hash2 = hashFloat(-0.0);
    try std.testing.expectEqual(zero_hash1, zero_hash2);
}

test "hash combination" {
    const hash1: HashResult = 0x12345678;
    const hash2: HashResult = 0x87654321;

    const combined1 = combineHashes(hash1, hash2);
    const combined2 = combineHashes(hash2, hash1);

    // Order should matter
    try std.testing.expect(combined1 != combined2);

    // Combining with itself should be different
    const self_combined = combineHashes(hash1, hash1);
    try std.testing.expect(self_combined != hash1);
}

test "table hash utilities" {
    // Test size calculation
    try std.testing.expectEqual(@as(usize, 1), TableHash.calculateSize(0));
    try std.testing.expectEqual(@as(usize, 1), TableHash.calculateSize(1));
    try std.testing.expectEqual(@as(usize, 2), TableHash.calculateSize(2));
    try std.testing.expectEqual(@as(usize, 4), TableHash.calculateSize(3));
    try std.testing.expectEqual(@as(usize, 8), TableHash.calculateSize(5));
    try std.testing.expectEqual(@as(usize, 16), TableHash.calculateSize(16));

    // Test index calculation
    const table_size = 16;
    for (0..100) |i| {
        const hash: HashResult = @intCast(i);
        const index = TableHash.getIndex(hash, table_size);
        try std.testing.expect(index < table_size);
    }
}

test "consistent hashing" {
    const test_keys = [_][]const u8{ "key1", "key2", "key3", "key4", "key5" };
    const ring_size = 100;

    // Test ring positions
    for (test_keys) |key| {
        const pos1 = ConsistentHash.getRingPosition(key, ring_size);
        const pos2 = ConsistentHash.getRingPosition(key, ring_size);
        try std.testing.expectEqual(pos1, pos2);
        try std.testing.expect(pos1 < ring_size);
    }

    // Test jump consistent hash
    for (test_keys) |key| {
        const hash_val = hashString(key);
        const bucket1 = ConsistentHash.jumpConsistentHash(hash_val, 10);
        const bucket2 = ConsistentHash.jumpConsistentHash(hash_val, 10);
        try std.testing.expectEqual(bucket1, bucket2);
        try std.testing.expect(bucket1 < 10);
    }
}

test "long string optimization" {
    // Create a very long string
    const long_string = "a" ** 1000;

    // Should still hash quickly and consistently
    const hash1 = hashString(long_string);
    const hash2 = hashString(long_string);
    try std.testing.expectEqual(hash1, hash2);

    // Different long strings should have different hashes
    const long_string2 = "b" ** 1000;
    const hash3 = hashString(long_string2);
    try std.testing.expect(hash1 != hash3);
}
