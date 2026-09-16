// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Table Implementation

const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;

const value = @import("value.zig");
const gc_module = @import("gc.zig");
const gc = @import("gc.zig");
const config = @import("config.zig");
const string_module = @import("string.zig");

/// Maximum size for the array part
pub const MAXASIZE: u32 = 1 << 26;

/// Maximum log2 of the hash part size
const MAXHBITS: u8 = 30;

/// Errors produced by table mutation. Explicit because `set`, `rehash`,
/// `resize` and `setInt` call each other recursively, which Zig cannot infer.
pub const TableError = error{ InvalidKey, OutOfMemory };

/// Node in the hash part: value, key and the collision chain as a relative
/// index (`gnext`), 24 bytes like Lua's `Node` now that a value is one word.
pub const Node = extern struct {
    val: value.TValue, // Value (nil = dead entry, key kept for `next`)
    k: value.TValue, // Key (nil = free node; a dead-key marker for a collected key)
    next: i32, // Offset to the next node in the collision chain, 0 = end

    comptime {
        assert(@sizeOf(Node) == 24);
    }

    pub fn init() Node {
        return .{ .val = value.TValue.nil(), .k = value.TValue.nil(), .next = 0 };
    }

    /// The key as a value
    pub inline fn key(self: *const Node) value.TValue {
        return self.k;
    }

    pub inline fn setKey(self: *Node, k: value.TValue) void {
        self.k = k;
    }

    /// Next node in the collision chain, if any
    pub inline fn nextNode(self: *Node) ?*Node {
        if (self.next == 0) return null;
        const off: isize = @as(isize, self.next) * @sizeOf(Node);
        return @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(self))) + off)));
    }

    pub inline fn setNext(self: *Node, n: ?*Node) void {
        const target = n orelse {
            self.next = 0;
            return;
        };
        const diff: isize = @as(isize, @intCast(@intFromPtr(target))) - @as(isize, @intCast(@intFromPtr(self)));
        self.next = @intCast(@divExact(diff, @sizeOf(Node)));
    }

    /// Whether the key is the integer `i`: one word compare for an inline
    /// integer, a value compare for a boxed one
    pub inline fn keyIsInt(self: *const Node, i: i64) bool {
        if (value.TValue.fitsInline(i)) return self.k.bits == value.TValue.integer(i).bits;
        return self.k.isBoxedInt() and self.k.integerValue() == i;
    }

    /// Whether the key is the (interned) string `s`
    pub inline fn keyIsStr(self: *const Node, str: *value.String) bool {
        return self.k.bits == value.TValue.string(str).bits;
    }

    /// Free node (never had a key, or was cleared by a resize)
    pub inline fn isEmpty(self: *const Node) bool {
        return self.k.isNil();
    }

    /// Entry whose value was set to nil
    pub inline fn isDead(self: *const Node) bool {
        return !self.k.isNil() and self.val.isNil();
    }

    pub fn clear(self: *Node) void {
        self.* = init();
    }

    /// Replace a collectable key of a dead entry by an identity-only marker
    /// so the collector may free the key object (lgc.c `clearkey`).
    pub fn clearDeadKey(self: *Node) void {
        assert(self.isDead());
        if (self.k.toGCObject()) |o| self.k = value.TValue.deadKey(o);
    }
};

/// Shared node for tables without a hash part. Never written to.
var dummynode = Node.init();

/// What `array` points at while the array part is empty
var empty_array: [0]value.TValue = .{};

/// Table flags
pub const TableFlags = packed struct(u16) {
    has_weak_keys: bool = false,
    has_weak_values: bool = false,
    has_metamethod: bool = false,
    no_tag_method: u8 = 0, // Bitmap for absent metamethods (cache)
    _pad: u5 = 0,
};

/// Lua table. An `extern struct` so the layout is fixed: the fields a
/// collector traversal and a lookup read (header, metatable, array part,
/// limits, flags, node array) are in the first 56 bytes, the rest after.
/// 80 bytes (Lua's is 56: no `gc` pointer, a 10-byte header).
pub const Table = extern struct {
    header: value.GCObject,
    metatable: ?*Table,
    array: [*]value.TValue, // array part; `asize` slots (`arr()` is the slice)
    asize: u32, // real size of the array part
    // `luaH_getn`'s border hint (ltable.c `alimit`). At most `asize`, and
    // smaller only when the real size is a power of two and the hint is
    // above half of it, the same states the reference's `isrealasize` bit
    // allows
    alimit: u32,
    flags: TableFlags,
    lsizenode: u8, // Log2 of hash size (meaningful only when !dummy)
    dummy: bool, // true when `node` is the shared dummy node
    node: [*]Node, // Hash nodes (or &dummynode)
    lastfree: ?*Node, // Free-node search position (null when exhausted)
    gclist: ?*value.GCObject = null, // link in the gray / grayagain / weak lists
    // The collector that owns the table: its allocator, and boxing for an
    // integer key beyond the inline range
    gc: *gc_module.GarbageCollector,

    comptime {
        assert(@sizeOf(Table) == 80);
        assert(@offsetOf(Table, "node") < 64);
    }

    /// The array part as a slice
    pub inline fn arr(self: *const Table) []value.TValue {
        return self.array[0..self.asize];
    }

    pub fn init(g: *gc_module.GarbageCollector) !*Table {
        const t = try g.allocator.create(Table);
        t.* = .{
            .header = .{
                .next = null,
                .tt = @intFromEnum(value.ValueType.table),
                .marked = 0,
            },
            .metatable = null,
            .array = &empty_array,
            .asize = 0,
            .alimit = 0,
            .node = @ptrCast(&dummynode),
            .lsizenode = 0,
            .lastfree = null,
            .dummy = true,
            .flags = .{},
            .gc = g,
        };
        return t;
    }

    /// Initialize table with size hints
    pub fn initWithSize(g: *gc_module.GarbageCollector, narray: u32, nhash: u32) !*Table {
        const t = try init(g);
        errdefer t.deinit();

        if (narray > 0 or nhash > 0) {
            try t.resize(narray, nhash);
        }

        return t;
    }

    /// Deinitialize table (frees its parts and the struct itself)
    pub fn deinit(self: *Table) void {
        const allocator = self.gc.allocator;
        if (self.asize > 0) {
            allocator.free(self.arr());
        }
        if (!self.dummy) {
            allocator.free(self.node[0..self.hashSize()]);
        }
        allocator.destroy(self);
    }

    /// Number of nodes in the hash part (0 for the dummy node)
    pub fn hashSize(self: *const Table) u32 {
        return if (self.dummy) 0 else @as(u32, 1) << @intCast(self.lsizenode);
    }

    /// Slice over the hash nodes
    pub fn nodes(self: *const Table) []Node {
        return self.node[0..self.hashSize()];
    }

    // ---------------------------------------------------------------------
    // Lookup
    // ---------------------------------------------------------------------

    /// Get value by key (raw access, no metamethods)
    pub fn get(self: *Table, key: value.TValue) value.TValue {
        // The two common key kinds first, without the type switch
        if (key.isInlineInt()) return self.getIntKey(key.inlineInt());
        if (key.isString()) {
            const s = key.stringValue();
            if (s.isShort()) return self.getShortStr(s);
            return self.getGeneric(key);
        }
        switch (key.tag()) {
            .nil => return value.TValue.nil(),
            .number => {
                if (key.numberValue() == .integer) return self.getIntKey(key.integerValue());
                const f = key.floatValue();
                if (floatToIntKey(f)) |i| return self.getIntKey(i);
                if (math.isNan(f)) return value.TValue.nil();
                return self.getGeneric(key);
            },
            .string => {
                const s = key.stringValue();
                if (s.isShort()) return self.getShortStr(s);
                return self.getGeneric(key);
            },
            else => return self.getGeneric(key),
        }
    }

    /// Get value by integer key (optimized)
    pub fn getInt(self: *Table, key: i64) value.TValue {
        return self.getIntKey(key);
    }

    /// An integer key in the array part was addressed beyond the border
    /// hint: "probably '#t' is here now" (luaH_getint). `key` is in the
    /// array part.
    pub inline fn touchLimit(self: *Table, key: i64) void {
        if (key > self.alimit) self.alimit = @intCast(key);
    }

    /// Get value by any integer key
    pub fn getIntKey(self: *Table, key: i64) value.TValue {
        if (key > 0 and key <= @as(i64, @intCast(self.asize))) {
            self.touchLimit(key);
            return self.arr()[@intCast(key - 1)];
        }
        if (self.dummy) return value.TValue.nil();
        var n: ?*Node = self.mainPositionInt(key);
        while (n) |node| : (n = node.nextNode()) {
            if (node.keyIsInt(key)) return node.val;
        }
        return value.TValue.nil();
    }

    // ---------------------------------------------------------------------
    // Store probes (luaH_get as luaV_fastset uses it): the value slot of the
    // entry a key already has, nil-valued or not, or null when the key is
    // absent. A non-nil slot is stored into in place with no key
    // normalisation, no `__newindex` check and no key barrier; a nil or
    // absent one goes to `vm.finishSet`, which reuses this probe instead of
    // searching again (the reference does one search per store, not three).
    // ---------------------------------------------------------------------

    /// Slot of an existing entry for any key, or null when absent
    pub fn findSlot(self: *Table, key: value.TValue) ?*value.TValue {
        if (key.isInteger()) return self.findIntSlot(key.integerValue());
        if (key.isString() and key.stringValue().isShort()) return self.findShortStrSlot(key.stringValue());
        const k = self.normalizeKey(key) catch return null;
        if (k.isInteger()) return self.findIntSlot(k.integerValue());
        const node = self.findNode(k, false) orelse return null;
        return &node.val;
    }

    /// Slot of an existing entry for an integer key, or null when absent
    pub fn findIntSlot(self: *Table, key: i64) ?*value.TValue {
        if (key > 0 and key <= @as(i64, @intCast(self.asize))) {
            self.touchLimit(key);
            return &self.arr()[@intCast(key - 1)];
        }
        if (self.dummy) return null;
        var n: ?*Node = self.mainPositionInt(key);
        while (n) |node| : (n = node.nextNode()) {
            if (node.keyIsInt(key)) return &node.val;
        }
        return null;
    }

    /// Slot of an existing entry for a short string key, or null when absent
    pub fn findShortStrSlot(self: *Table, key: *value.String) ?*value.TValue {
        if (self.dummy) return null;
        var n: ?*Node = self.hashPow2(key.hash);
        while (n) |node| : (n = node.nextNode()) {
            if (node.keyIsStr(key)) return &node.val;
        }
        return null;
    }

    /// Insert a key that a store probe found absent (luaH_finishset's
    /// `luaH_newkey` case): no second search. A nil value inserts nothing.
    pub fn setAbsent(self: *Table, key: value.TValue, val: value.TValue) TableError!void {
        const k = try self.normalizeKey(key);
        if (k.tag() == .string) self.flags.no_tag_method = 0; // invalidateTMcache
        if (val.isNil()) return;
        if (k.isInteger()) {
            // The probe ran on the raw key; a float key that normalises to an
            // array index lands here
            const i = k.integerValue();
            if (i > 0 and i <= @as(i64, @intCast(self.asize))) {
                self.touchLimit(i);
                self.arr()[@intCast(i - 1)] = val;
                return;
            }
        }
        try self.newKey(k, val);
    }

    /// Get value by short (interned) string key: pointer comparison only
    pub fn getShortStr(self: *const Table, key: *value.String) value.TValue {
        if (self.dummy) return value.TValue.nil();
        var n: ?*Node = self.hashPow2(key.hash);
        while (n) |node| : (n = node.nextNode()) {
            if (node.keyIsStr(key)) return node.val;
        }
        return value.TValue.nil();
    }

    /// Generic lookup (key already normalised, not nil, not NaN)
    fn getGeneric(self: *const Table, key: value.TValue) value.TValue {
        const node = self.findNode(key, false) orelse return value.TValue.nil();
        return node.val;
    }

    /// Find the node holding `key`, if any. With `deadok`, a node whose key
    /// was collected (a dead-key marker) matches a collectable key with the
    /// same address; only `next` may use that (ltable.c `getgeneric`).
    fn findNode(self: *const Table, key: value.TValue, deadok: bool) ?*Node {
        if (self.dummy) return null;
        var n: ?*Node = self.mainPosition(key);
        while (n) |node| : (n = node.nextNode()) {
            if (equalKey(node.key(), key, deadok)) return node;
        }
        return null;
    }

    // ---------------------------------------------------------------------
    // Insertion
    // ---------------------------------------------------------------------

    /// Set value by key (raw, no metamethods). A nil value removes the entry.
    pub fn set(self: *Table, key: value.TValue, val: value.TValue) TableError!void {
        const k = try self.normalizeKey(key);
        // A string key may be a metamethod name: forget which ones were
        // known to be absent (invalidateTMcache). The in-place fast set in
        // the VM skips this because it only overwrites non-nil entries,
        // which can never have been recorded as absent.
        if (k.tag() == .string) self.flags.no_tag_method = 0;

        // Array part fast path
        if (k.isInteger()) {
            const i = k.integerValue();
            if (i > 0 and i <= @as(i64, @intCast(self.asize))) {
                self.touchLimit(i);
                self.arr()[@intCast(i - 1)] = val;
                return;
            }
        }

        // Existing hash entry (possibly dead, but still holding its key):
        // just update the value
        if (self.findNode(k, false)) |node| {
            node.val = val;
            return;
        }

        // Do not insert nil values
        if (val.isNil()) return;

        try self.newKey(k, val);
    }

    /// An integer key as a value, boxed beyond the inline range
    fn intKey(self: *const Table, i: i64) TableError!value.TValue {
        if (value.TValue.fitsInline(i)) return value.TValue.integer(i);
        return value.TValue.boxedInteger(self.gc.newBoxedInt(i) catch return error.OutOfMemory);
    }

    /// The key as it is stored: a float with an integer value becomes that
    /// integer (boxed if large); nil and NaN are invalid keys
    pub fn normalizeKey(self: *const Table, key: value.TValue) TableError!value.TValue {
        if (key.isNumber()) {
            switch (key.numberValue()) {
                .integer => return key,
                .float => |f| {
                    if (floatToIntKey(f)) |i| return self.intKey(i);
                    if (math.isNan(f)) return error.InvalidKey;
                    return key;
                },
            }
        }
        if (key.isNil()) return error.InvalidKey;
        return key;
    }

    /// Set value by integer key (optimized). Keys outside the array part,
    /// including zero and negatives, fall through to the hash part.
    pub fn setInt(self: *Table, key: i64, val: value.TValue) TableError!void {
        if (key > 0 and key <= @as(i64, @intCast(self.asize))) {
            self.touchLimit(key);
            self.arr()[@intCast(key - 1)] = val;
            return;
        }
        try self.set(try self.intKey(key), val);
    }

    /// Insert a new key (luaH_newkey). `key` is normalised and absent.
    fn newKey(self: *Table, key: value.TValue, val: value.TValue) TableError!void {
        if (self.dummy) {
            try self.rehash(key);
            return self.set(key, val);
        }

        var mp = self.mainPosition(key);
        if (mp.isDead()) {
            // A removed entry in the main position is reused in place; its
            // chain link stays valid because the node keeps its position.
            mp.setKey(key);
            mp.val = val;
            return;
        }
        if (!mp.isEmpty()) {
            // Main position is taken: get a free place
            const f = self.getFreePos() orelse {
                try self.rehash(key); // grow table
                return self.set(key, val); // insert key into grown table
            };

            // Is the colliding node in its own main position?
            const othern_start = self.mainPosition(mp.key());
            if (othern_start != mp) {
                // No: move the colliding node into the free position and
                // put the new key in its main position.
                var othern = othern_start;
                while (othern.nextNode() != mp) {
                    othern = othern.nextNode().?;
                }
                othern.setNext(f); // rechain to point to `f`
                const mp_next = mp.nextNode();
                f.* = mp.*; // copy colliding node into free position
                f.setNext(mp_next); // the copied link was relative to `mp`
                mp.next = 0;
                mp.val = value.TValue.nil();
            } else {
                // Yes: the new key goes into the free position, chained
                // right after the main position.
                f.setNext(mp.nextNode());
                mp.setNext(f);
                mp = f;
            }
        }

        mp.setKey(key);
        mp.val = val;
    }

    /// Find a free node, searching downwards from `lastfree`
    fn getFreePos(self: *Table) ?*Node {
        while (self.lastfree) |lf| {
            if (@intFromPtr(lf) <= @intFromPtr(self.node)) break;
            const prev: *Node = @ptrFromInt(@intFromPtr(lf) - @sizeOf(Node));
            self.lastfree = prev;
            if (prev.isEmpty()) return prev;
        }
        self.lastfree = null;
        return null;
    }

    // ---------------------------------------------------------------------
    // Hashing
    // ---------------------------------------------------------------------

    fn hashPow2(self: *const Table, h: u32) *Node {
        return &self.node[h & (self.hashSize() - 1)];
    }

    /// Hash modulo an odd number, to spread keys that are multiples of 2^k
    fn hashMod(self: *const Table, h: u64) *Node {
        const size = self.hashSize();
        return &self.node[@intCast(h % ((size - 1) | 1))];
    }

    fn mainPositionInt(self: *const Table, i: i64) *Node {
        return self.hashMod(@as(u64, @bitCast(i)));
    }

    /// Main position of a (normalised, non-nil) key
    fn mainPosition(self: *const Table, key: value.TValue) *Node {
        return switch (key.tag()) {
            .number => switch (key.numberValue()) {
                .integer => |i| self.mainPositionInt(i),
                .float => |f| self.hashMod(hashFloat(f)),
            },
            .string => self.hashPow2(key.stringValue().hashOf()),
            .boolean => self.hashPow2(if (key.booleanValue()) 1 else 0),
            .light_userdata => self.hashMod(@intFromPtr(key.asLightUserdata().?) >> 3),
            .table => self.hashMod(@intFromPtr(key.tableValue()) >> 3),
            .userdata => self.hashMod(@intFromPtr(key.userdataValue()) >> 3),
            .thread => self.hashMod(@intFromPtr(key.threadValue()) >> 3),
            .function => switch (key.functionValue()) {
                .closure => |c| self.hashMod(@intFromPtr(c) >> 3),
                .cclosure => |c| self.hashMod(@intFromPtr(c) >> 3),
                .native_fn => |f| self.hashMod(@intFromPtr(f) >> 3),
            },
            .deadkey => self.hashMod(@intFromPtr(key.deadKeyObject()) >> 3),
            .nil, .lclosure, .cclosure, .proto, .upvalue, .boxint => unreachable,
        };
    }

    // ---------------------------------------------------------------------
    // Rehash
    // ---------------------------------------------------------------------

    const Counts = struct {
        nums: [MAXHBITS + 2]u32 = [_]u32{0} ** (MAXHBITS + 2), // nums[i] = keys in (2^(i-1), 2^i]
        na: u32 = 0, // integer keys that could live in an array
        total: u32 = 0, // all keys
    };

    fn countInt(key: i64, c: *Counts) void {
        if (key > 0 and key <= MAXASIZE) {
            c.nums[ceillog2(@intCast(key))] += 1;
            c.na += 1;
        }
    }

    fn countKey(key: value.TValue, c: *Counts) void {
        c.total += 1;
        if (key.isInteger()) countInt(key.integerValue(), c);
    }

    /// Compute the optimal array size: the largest n (power of 2) such that
    /// more than half of the slots 1..n would be in use.
    fn computeSizes(c: *const Counts, na_out: *u32) u32 {
        var a: u32 = 0; // keys <= 2^i
        var na: u32 = 0; // keys that will go to the array part
        var optimal: u32 = 0;
        var twotoi: u32 = 1;
        var i: usize = 0;
        while (i < c.nums.len and twotoi > 0 and (twotoi / 2) < c.na) : (i += 1) {
            a += c.nums[i];
            if (a > twotoi / 2) {
                optimal = twotoi;
                na = a;
            }
            twotoi *%= 2;
        }
        na_out.* = na;
        return optimal;
    }

    /// Resize the table to fit its current keys plus `extra_key`
    fn rehash(self: *Table, extra_key: value.TValue) TableError!void {
        var c = Counts{};

        // Array part
        for (self.arr(), 1..) |v, i| {
            if (!v.isNil()) {
                countInt(@intCast(i), &c);
                c.total += 1;
            }
        }

        // Hash part (live entries only)
        for (self.nodes()) |*n| {
            if (!n.isEmpty() and !n.isDead()) countKey(n.key(), &c);
        }

        // The key being inserted
        countKey(extra_key, &c);

        var na: u32 = 0;
        const asize = computeSizes(&c, &na);
        const hsize = c.total - na;
        try self.resize(asize, hsize);
    }

    /// Resize the array part to `nasize` slots and the hash part to at least
    /// `nhsize` nodes (rounded up to a power of two), reinserting every entry.
    pub fn resize(self: *Table, nasize: u32, nhsize: u32) TableError!void {
        const allocator = self.gc.allocator;
        const oldarray = self.arr();
        const oldnodes = self.nodes();
        const olddummy = self.dummy;

        // New array part (copy the overlapping prefix)
        var newarray: []value.TValue = &empty_array;
        if (nasize > 0) {
            newarray = try allocator.alloc(value.TValue, nasize);
            const keep = @min(oldarray.len, nasize);
            @memcpy(newarray[0..keep], oldarray[0..keep]);
            @memset(newarray[keep..], value.TValue.nil());
        }
        errdefer if (nasize > 0) allocator.free(newarray);

        // New hash part
        if (nhsize == 0) {
            self.node = @ptrCast(&dummynode);
            self.lsizenode = 0;
            self.lastfree = null;
            self.dummy = true;
        } else {
            const lsize: u8 = ceillog2(nhsize);
            if (lsize > MAXHBITS) return error.OutOfMemory;
            const size = @as(usize, 1) << @intCast(lsize);
            const nn = try allocator.alloc(Node, size);
            for (nn) |*n| n.* = Node.init();
            self.node = nn.ptr;
            self.lsizenode = lsize;
            self.lastfree = @ptrFromInt(@intFromPtr(nn.ptr) + size * @sizeOf(Node)); // one past the end
            self.dummy = false;
        }

        self.array = newarray.ptr;
        self.asize = nasize;
        self.alimit = nasize;

        // Reinsert array slots that no longer fit into the hash part
        if (oldarray.len > nasize) {
            for (oldarray[nasize..], nasize + 1..) |v, i| {
                if (!v.isNil()) try self.set(value.TValue.integer(@intCast(i)), v);
            }
        }

        // Reinsert live entries from the old hash part
        for (oldnodes) |*n| {
            if (!n.isEmpty() and !n.isDead()) try self.set(n.key(), n.val);
        }

        // Free old parts
        if (oldarray.len > 0) allocator.free(oldarray);
        if (!olddummy) allocator.free(oldnodes);
    }

    // ---------------------------------------------------------------------
    // Length and iteration
    // ---------------------------------------------------------------------

    /// A border of the table (the `#` operator without metamethods):
    /// some n such that t[n] is non-nil and t[n+1] is nil (or 0). This is
    /// `luaH_getn`, including which border it picks on a table with holes
    /// and how it moves the `alimit` hint, so `#t` matches the reference
    /// byte for byte. `ispow2realasize` is `isPow2(array.len)` here, and
    /// `limitequalsasize` is `alimit == array.len`.
    pub fn arrayLen(self: *Table) u32 {
        const asize: u32 = @intCast(self.asize);
        var limit = self.alimit;
        if (limit > 0 and self.arr()[limit - 1].isNil()) {
            // (1) there must be a border before `limit`
            if (limit >= 2 and !self.arr()[limit - 2].isNil()) {
                // `limit - 1` is a border; can it be a new limit?
                if (isPow2(asize) and !isPow2(limit - 1)) self.alimit = limit - 1;
                return limit - 1;
            } else {
                // must search for a border in [0, limit]
                const boundary = binSearch(self.arr(), 0, limit);
                // can this border represent the real size of the array?
                if (isPow2(asize) and boundary > asize / 2) self.alimit = boundary;
                return boundary;
            }
        }
        // `limit` is zero or present in the table
        if (limit != asize) {
            // (2) `limit` > 0 and the array has more elements after it
            if (self.arr()[limit].isNil()) return limit; // `limit + 1` is empty
            // else, try the last element in the array
            limit = asize;
            if (self.arr()[limit - 1].isNil()) {
                // there must be a border in the array after the old limit,
                // and it must be a valid new limit
                const boundary = binSearch(self.arr(), self.alimit, limit);
                self.alimit = boundary;
                return boundary;
            }
            // else, the new limit is present in the table; check the hash part
        }
        // (3) `limit` is the last element and either is zero or present
        if (self.dummy or self.getIntKey(@as(i64, limit) + 1).isNil()) return limit;
        return self.hashSearch(limit);
    }

    /// Binary search for a border in array[i..j]: array[i-1] is non-nil
    /// (or i == 0) and array[j-1] is nil (ltable.c binsearch)
    fn binSearch(array: []const value.TValue, lo: u32, hi: u32) u32 {
        var i = lo;
        var j = hi;
        while (j - i > 1) {
            const m = (i + j) / 2;
            if (array[m - 1].isNil()) j = m else i = m;
        }
        return i;
    }

    inline fn isPow2(x: u32) bool {
        return (x & (x -% 1)) == 0;
    }

    /// Unbound search for a border in the hash part, starting after `j`
    /// where t[j] is non-nil (or j == 0).
    fn hashSearch(self: *Table, start: u32) u32 {
        var i: u64 = start;
        var j: u64 = @as(u64, start) + 1;
        // Find i, j with t[i] non-nil and t[j] nil
        while (!self.getIntKey(@intCast(j)).isNil()) {
            i = j;
            if (j > math.maxInt(i64) / 2) {
                // Table was built to defeat this search: fall back to linear
                var k: u64 = 1;
                while (!self.getIntKey(@intCast(k)).isNil()) k += 1;
                return @intCast(@min(k - 1, math.maxInt(u32)));
            }
            j *= 2;
        }
        // Binary search between them
        while (j - i > 1) {
            const m = (i + j) / 2;
            if (self.getIntKey(@intCast(m)).isNil()) j = m else i = m;
        }
        return @intCast(@min(i, math.maxInt(u32)));
    }

    /// Advance `key` to the next key with a non-nil value; returns false at the
    /// end. A nil key starts the traversal. Returns false too for a key that is
    /// not in the table (Lua raises "invalid key to 'next'").
    pub fn next(self: *const Table, key: *value.TValue) bool {
        return self.nextPair(key) != null;
    }

    /// Like `next`, but also returns the value of the found entry
    pub fn nextPair(self: *const Table, key: *value.TValue) ?value.TValue {
        const alen: usize = self.asize;
        var i: usize = self.findIndex(key.*) orelse return null;

        // Array part
        while (i < alen) : (i += 1) {
            if (!self.arr()[i].isNil()) {
                key.* = value.TValue.integer(@intCast(i + 1));
                return self.arr()[i];
            }
        }

        // Hash part
        i -= alen;
        const hnodes = self.nodes();
        while (i < hnodes.len) : (i += 1) {
            const n = &hnodes[i];
            if (!n.isEmpty() and !n.isDead()) {
                key.* = n.key();
                return n.val;
            }
        }

        return null;
    }

    /// Traversal index right after `key`: 0 for nil, array slots first, then
    /// hash nodes (alen + node index + 1).
    pub fn findIndex(self: *const Table, key: value.TValue) ?usize {
        if (key.isNil()) return 0;
        const k = self.normalizeKey(key) catch return null;
        if (k.isInteger()) {
            const i = k.integerValue();
            if (i > 0 and i <= @as(i64, @intCast(self.asize))) return @intCast(i);
        }
        const node = self.findNode(k, true) orelse return null;
        const idx = (@intFromPtr(node) - @intFromPtr(self.node)) / @sizeOf(Node);
        return self.asize + idx + 1;
    }

    // ---------------------------------------------------------------------
    // Metatable and weakness
    // ---------------------------------------------------------------------

    /// Check if table is weak
    pub fn isWeak(self: *const Table) bool {
        return self.flags.has_weak_keys or self.flags.has_weak_values;
    }

    /// Set the metatable. Weak-mode flags are refreshed by `updateWeakFlags`,
    /// which needs the interned "__mode" string from the global state.
    pub fn setMetatable(self: *Table, mt: ?*Table) void {
        self.metatable = mt;
        self.flags.has_metamethod = mt != null;
        self.flags.no_tag_method = 0;
        if (mt == null) {
            self.flags.has_weak_keys = false;
            self.flags.has_weak_values = false;
        }
    }

    /// Recompute the weak-key / weak-value flags from `metatable.__mode`
    pub fn updateWeakFlags(self: *Table, mode_key: *value.String) void {
        self.flags.has_weak_keys = false;
        self.flags.has_weak_values = false;
        const mt = self.metatable orelse return;
        const mode = mt.getShortStr(mode_key);
        if (mode.asString()) |s| {
            const str = s.slice();
            self.flags.has_weak_keys = mem.indexOfScalar(u8, str, 'k') != null;
            self.flags.has_weak_values = mem.indexOfScalar(u8, str, 'v') != null;
        }
    }
};

// Helper functions

/// A float with an integral value that fits an integer, as that integer
fn floatToIntKey(f: f64) ?i64 {
    if (@floor(f) != f) return null;
    if (f < -9223372036854775808.0 or f >= 9223372036854775808.0) return null;
    return @intFromFloat(f);
}

/// Normalise a key: floats with integral values become integers; nil and NaN
/// are invalid keys.
fn hashFloat(f: f64) u64 {
    // Mix the bit pattern; +0.0 and -0.0 compare equal so hash them alike
    const bits: u64 = @bitCast(if (f == 0.0) @as(f64, 0.0) else f);
    return (bits ^ (bits >> 32)) *% 0x9E3779B97F4A7C15;
}

/// Compare a node key `k1` with a lookup key `k2` (raw equality; integers
/// and floats never mix because keys are normalised before they reach the
/// hash part). A dead key (node key whose object was collected) matches a
/// collectable key only by address and only when `deadok`, which lets `next`
/// continue past removed entries. Any other lookup must not match it: the
/// address may since have been reused by an object of another type, whose
/// main position is a different node.
fn equalKey(k1: value.TValue, k2: value.TValue, deadok: bool) bool {
    if (k1.tag() == .deadkey) {
        if (!deadok) return false;
        return if (k2.toGCObject()) |o| o == k1.deadKeyObject() else false;
    }
    if (k1.tag() != k2.tag()) return false;
    return switch (k1.tag()) {
        .nil => true,
        .number => switch (k1.numberValue()) {
            .integer => |a| k2.numberValue() == .integer and k2.integerValue() == a,
            .float => |a| k2.numberValue() == .float and k2.floatValue() == a,
        },
        .string => k1.stringValue() == k2.stringValue() or
            (!k1.stringValue().isShort() and mem.eql(u8, k1.stringValue().slice(), k2.stringValue().slice())),
        else => k1.rawEqual(k2),
    };
}

/// Ceiling of log2(x) for x >= 1
fn ceillog2(x: u32) u8 {
    if (x <= 1) return 0;
    return @intCast(32 - @clz(x - 1));
}

// Tests

test "table basic operations" {
    const allocator = std.testing.allocator;

    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();
    const t = try Table.init(&g);
    defer t.deinit();

    try t.set(value.TValue.integer(1), value.TValue.integer(10));
    try t.set(value.TValue.integer(2), value.TValue.integer(20));
    try t.set(value.TValue.integer(3), value.TValue.integer(30));

    try std.testing.expect(t.get(value.TValue.integer(1)).asInteger().? == 10);
    try std.testing.expect(t.get(value.TValue.integer(2)).asInteger().? == 20);
    try std.testing.expect(t.get(value.TValue.integer(3)).asInteger().? == 30);
    try std.testing.expect(t.get(value.TValue.integer(99)).isNil());
    try std.testing.expect(t.get(value.TValue.nil()).isNil());

    // Removing and re-adding
    try t.set(value.TValue.integer(2), value.TValue.nil());
    try std.testing.expect(t.get(value.TValue.integer(2)).isNil());
    try t.set(value.TValue.integer(2), value.TValue.integer(22));
    try std.testing.expect(t.get(value.TValue.integer(2)).asInteger().? == 22);

    // nil and NaN keys are rejected on write and miss on read
    try std.testing.expectError(error.InvalidKey, t.set(value.TValue.nil(), value.TValue.integer(1)));
    try std.testing.expectError(error.InvalidKey, t.set(value.TValue.float(math.nan(f64)), value.TValue.integer(1)));
    try std.testing.expect(t.get(value.TValue.float(math.nan(f64))).isNil());
}

test "table array optimization" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    const t = try Table.init(&g);
    defer t.deinit();

    // Sequential integer keys migrate to the array part on rehash
    var i: u32 = 1;
    while (i <= 10) : (i += 1) {
        try t.setInt(i, value.TValue.integer(@intCast(i * 10)));
    }

    try std.testing.expect(t.asize >= 8);
    try std.testing.expect(t.alimit == t.asize);

    i = 1;
    while (i <= 10) : (i += 1) {
        const v = t.getInt(i);
        try std.testing.expect(v.asInteger().? == i * 10);
    }
    try std.testing.expectEqual(@as(u32, 10), t.arrayLen());
}

test "table hash part" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    const t = try Table.init(&g);
    defer t.deinit();

    // String keys (interned short strings compare by pointer)
    const k1 = try g.newString("alpha");
    const k2 = try g.newString("beta");
    try t.set(value.TValue.string(k1), value.TValue.integer(100));
    try t.set(value.TValue.string(k2), value.TValue.integer(200));
    try std.testing.expect(t.get(value.TValue.string(k1)).asInteger().? == 100);
    try std.testing.expect(t.get(value.TValue.string(k2)).asInteger().? == 200);

    // Many colliding-ish keys force relocation and rehash
    var i: i64 = 1;
    while (i <= 64) : (i += 1) {
        try t.set(value.TValue.integer(i * 1000), value.TValue.integer(i));
    }
    i = 1;
    while (i <= 64) : (i += 1) {
        try std.testing.expect(t.get(value.TValue.integer(i * 1000)).asInteger().? == i);
    }
    try std.testing.expect(t.get(value.TValue.string(k1)).asInteger().? == 100);

    // Boolean and float keys
    try t.set(value.TValue.boolean(true), value.TValue.integer(1));
    try t.set(value.TValue.float(2.5), value.TValue.integer(25));
    try std.testing.expect(t.get(value.TValue.boolean(true)).asInteger().? == 1);
    try std.testing.expect(t.get(value.TValue.float(2.5)).asInteger().? == 25);
    try std.testing.expect(t.get(value.TValue.boolean(false)).isNil());
}

test "table float keys normalise to integers" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();
    const t = try Table.init(&g);
    defer t.deinit();

    try t.set(value.TValue.float(1.0), value.TValue.integer(11));
    try t.set(value.TValue.integer(2), value.TValue.integer(22));
    try std.testing.expect(t.get(value.TValue.integer(1)).asInteger().? == 11);
    try std.testing.expect(t.get(value.TValue.float(2.0)).asInteger().? == 22);
    try std.testing.expect(t.get(value.TValue.float(-0.0)).isNil());
    try t.set(value.TValue.float(0.0), value.TValue.integer(0));
    try std.testing.expect(t.get(value.TValue.integer(0)).asInteger().? == 0);
}

test "table iteration" {
    const allocator = std.testing.allocator;

    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();
    const t = try Table.init(&g);
    defer t.deinit();

    try t.set(value.TValue.integer(1), value.TValue.integer(10));
    try t.set(value.TValue.integer(2), value.TValue.integer(20));
    try t.set(value.TValue.integer(3), value.TValue.integer(30));
    const ks = try g.newString("x");
    try t.set(value.TValue.string(ks), value.TValue.integer(40));
    try t.set(value.TValue.integer(100), value.TValue.integer(50));
    try t.set(value.TValue.integer(2), value.TValue.nil()); // removed entry is skipped

    var key = value.TValue.nil();
    var count: u32 = 0;
    var sum: i64 = 0;
    while (t.nextPair(&key)) |v| {
        count += 1;
        sum += v.asInteger().?;
    }
    try std.testing.expectEqual(@as(u32, 4), count);
    try std.testing.expectEqual(@as(i64, 130), sum);

    // Unknown key: traversal cannot continue
    var bogus = value.TValue.integer(12345);
    try std.testing.expect(!t.next(&bogus));
}

test "table array length" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    const t = try Table.init(&g);
    defer t.deinit();

    try std.testing.expect(t.arrayLen() == 0);

    try t.set(value.TValue.integer(1), value.TValue.integer(1));
    try t.set(value.TValue.integer(2), value.TValue.integer(2));
    try t.set(value.TValue.integer(3), value.TValue.integer(3));
    try std.testing.expectEqual(@as(u32, 3), t.arrayLen());

    // Border continues into the hash part when the array is full
    try t.set(value.TValue.integer(5), value.TValue.integer(5));
    try t.set(value.TValue.integer(4), value.TValue.integer(4));
    try std.testing.expectEqual(@as(u32, 5), t.arrayLen());

    // A hole gives a border on either side
    try t.set(value.TValue.integer(3), value.TValue.nil());
    const n = t.arrayLen();
    try std.testing.expect(n == 2 or n == 5);
}

test "table weak flags" {
    const allocator = std.testing.allocator;
    var g = gc.GarbageCollector.init(allocator);
    defer g.deinit();

    const t = try Table.init(&g);
    defer t.deinit();
    const mt = try Table.init(&g);
    defer mt.deinit();

    const mode_key = try g.newString("__mode");
    const kv = try g.newString("kv");
    try mt.set(value.TValue.string(mode_key), value.TValue.string(kv));

    t.setMetatable(mt);
    try std.testing.expect(!t.isWeak());
    t.updateWeakFlags(mode_key);
    try std.testing.expect(t.flags.has_weak_keys and t.flags.has_weak_values);

    t.setMetatable(null);
    try std.testing.expect(!t.isWeak());
}
