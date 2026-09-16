// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Table manipulation library (ltablib.c).

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const table = @import("../table.zig");
const vm = @import("../vm.zig");

const table_funcs = [_]aux.Reg{
    .{ .name = "concat", .func = tconcat },
    .{ .name = "insert", .func = tinsert },
    .{ .name = "move", .func = tmove },
    .{ .name = "pack", .func = tpack },
    .{ .name = "remove", .func = tremove },
    .{ .name = "sort", .func = tsort },
    .{ .name = "unpack", .func = tunpack },
};

pub fn openTable(L: *state.LuaState) !void {
    try aux.registerLib(L, "table", &table_funcs);
    api.pop(L, 1);
}

// Shared helpers

/// Operations an argument must provide to stand in for a table (checktab)
const TAB_R: u32 = 1;
const TAB_W: u32 = 2;
const TAB_L: u32 = 4;
const TAB_RW: u32 = TAB_R | TAB_W;

/// Is `key` present in the raw table at `idx`?
fn hasRawField(L: *state.LuaState, idx: i32, key: []const u8) !bool {
    const t = api.absIndex(L, idx);
    try api.pushString(L, key);
    try api.rawGet(L, t);
    const found = !api.isNil(L, -1);
    api.pop(L, 1);
    return found;
}

/// Check that the argument at `arg` either is a table or has a metatable
/// supplying every operation in `what` (checktab).
fn checkTab(L: *state.LuaState, arg: i32, what: u32) !void {
    const tp = api.type_(L, arg);
    if (tp == .table) return;
    if (api.getMetatable(L, arg)) {
        // Every requested operation must be supplied by the metatable. A
        // string passes the '__index' test, since the string library is its
        // metatable's index, but has no '__len', which is what makes
        // table.concat reject one.
        const ok = ((what & TAB_R) == 0 or try hasRawField(L, -1, "__index")) and
            ((what & TAB_W) == 0 or try hasRawField(L, -1, "__newindex")) and
            ((what & TAB_L) == 0 or try hasRawField(L, -1, "__len"));
        api.pop(L, 1);
        if (ok) return;
    }
    return aux.typeError(L, arg, "table");
}

/// Length of the object at `idx`, honouring `__len` (luaL_len)
fn objLen(L: *state.LuaState, idx: i32) !i64 {
    try api.length(L, idx);
    const n = api.toInteger(L, -1) orelse
        return aux.err(L, "object length is not an integer", .{});
    api.pop(L, 1);
    return n;
}

/// Length of a table argument after checking it supports `what` (aux_getn)
fn auxGetN(L: *state.LuaState, idx: i32, what: u32) !i64 {
    try checkTab(L, idx, what | TAB_L);
    return objLen(L, idx);
}

// table.insert / table.remove

/// The table at argument 1 when it has no metatable and its array part
/// holds every index up to `upto`: the case the library can work on
/// directly instead of through `lua_geti` / `lua_seti`
fn rawArray(L: *state.LuaState, upto: i64) ?*table.Table {
    const t = api.toTable(L, 1) orelse return null;
    if (t.metatable != null or upto < 0 or upto > @as(i64, @intCast(t.asize))) return null;
    return t;
}

/// table.insert(t, [pos,] v)
fn tinsert(L: *state.LuaState) anyerror!i32 {
    // Lua leaves the wrap-around of `#t + 1` to the unsigned bounds test below
    const e = (try auxGetN(L, 1, TAB_RW)) +% 1; // first empty slot
    var pos: i64 = undefined;
    switch (api.getTop(L)) {
        2 => pos = e,
        3 => {
            pos = try aux.checkInteger(L, 2);
            // One unsigned comparison rejects both pos < 1 and pos > e
            const upos: u64 = @bitCast(pos);
            try aux.argCheck(L, upos -% 1 < @as(u64, @bitCast(e)), 2, "position out of bounds");
            if (rawArray(L, e)) |t| {
                // Elements pos .. e-1 all sit in the array part: shift them
                // up in place (they were already in the table, so no barrier)
                const p: usize = @intCast(pos - 1);
                const end: usize = @intCast(e - 1);
                std.mem.copyBackwards(value.TValue, t.arr()[p + 1 .. end + 1], t.arr()[p..end]);
                t.touchLimit(e); // the reference's lua_seti(t, e) moves the border hint
            } else {
                var i = e;
                while (i > pos) : (i -= 1) {
                    try api.getI(L, 1, i - 1);
                    try api.setI(L, 1, i);
                }
            }
        },
        else => return aux.err(L, "wrong number of arguments to 'insert'", .{}),
    }
    try api.setI(L, 1, pos);
    return 0;
}

/// table.remove(t [, pos])
fn tremove(L: *state.LuaState) anyerror!i32 {
    const size = try auxGetN(L, 1, TAB_RW);
    var pos = try aux.optInteger(L, 2, size);
    if (pos != size) { // an explicit `#t` needs no check, and `#t + 1` is legal
        const upos: u64 = @bitCast(pos);
        try aux.argCheck(L, upos -% 1 <= @as(u64, @bitCast(size)), 2, "position out of bounds");
    }
    if (pos >= 1 and pos <= size) {
        if (rawArray(L, size)) |t| {
            const p: usize = @intCast(pos - 1);
            const last: usize = @intCast(size - 1);
            try api.pushValue(L, t.arr()[p]); // the result (pos <= #t: no hint change)
            std.mem.copyForwards(value.TValue, t.arr()[p..last], t.arr()[p + 1 .. last + 1]);
            t.arr()[last] = value.TValue.nil();
            return 1;
        }
    }
    try api.getI(L, 1, pos); // the result, left on the stack
    while (pos < size) : (pos += 1) {
        try api.getI(L, 1, pos + 1);
        try api.setI(L, 1, pos);
    }
    try api.pushNil(L);
    try api.setI(L, 1, pos);
    return 1;
}

// table.move

/// table.move(a1, f, e, t [, a2])
fn tmove(L: *state.LuaState) anyerror!i32 {
    const f = try aux.checkInteger(L, 2);
    const e = try aux.checkInteger(L, 3);
    const t = try aux.checkInteger(L, 4);
    const tt: i32 = if (!aux.isNoneOrNil(L, 5)) 5 else 1;
    try checkTab(L, 1, TAB_R);
    try checkTab(L, tt, TAB_W);
    if (e >= f) { // otherwise there is nothing to move
        // `f > 0` short-circuits the sum that would itself overflow
        try aux.argCheck(L, f > 0 or e < std.math.maxInt(i64) + f, 3, "too many elements to move");
        const n = e - f + 1;
        try aux.argCheck(L, t <= std.math.maxInt(i64) - n + 1, 4, "destination wrap around");
        // Ascending order rehashes better, and is safe unless the ranges
        // overlap with the destination inside the source
        if (t > e or t <= f or (tt != 1 and !(try api.compare(L, 1, tt, .EQ)))) {
            var i: i64 = 0;
            while (i < n) : (i += 1) {
                try api.getI(L, 1, f + i);
                try api.setI(L, tt, t + i);
            }
        } else {
            var i: i64 = n - 1;
            while (i >= 0) : (i -= 1) {
                try api.getI(L, 1, f + i);
                try api.setI(L, tt, t + i);
            }
        }
    }
    try api.pushValueAt(L, tt);
    return 1;
}

// table.concat

fn addField(L: *state.LuaState, b: *aux.Buffer, i: i64) !void {
    try api.getI(L, 1, i);
    if (!api.isString(L, -1) and !api.isNumber(L, -1))
        return aux.err(L, "invalid value ({s}) at index {d} in table for 'concat'", .{
            api.typeName(L, api.type_(L, -1)), i,
        });
    try b.addValue(-1);
    api.pop(L, 1);
}

/// table.concat(t [, sep [, i [, j]]])
fn tconcat(L: *state.LuaState) anyerror!i32 {
    var last = try auxGetN(L, 1, TAB_R);
    const sep = try aux.optString(L, 2, "");
    var i = try aux.optInteger(L, 3, 1);
    last = try aux.optInteger(L, 4, last);

    var b = aux.Buffer.init(L);
    defer b.deinit();
    if (api.toTable(L, 1)) |t| {
        // Plain table with the whole range in its array part: read the
        // values directly instead of through `lua_geti` (the usual case)
        if (t.metatable == null and i >= 1 and last <= @as(i64, @intCast(t.asize))) {
            t.touchLimit(last); // as the reference's lua_geti(t, last) would
            while (i <= last) : (i += 1) {
                const v = t.arr()[@intCast(i - 1)];
                if (v.isString()) {
                    try b.addString(v.stringValue().slice());
                } else if (v.isNumber()) {
                    var buf: [64]u8 = undefined;
                    try b.addString(vm.numberToStringBuf(&buf, v.numberValue()));
                } else {
                    return aux.err(L, "invalid value ({s}) at index {d} in table for 'concat'", .{ api.typeName(L, v.tag()), i });
                }
                if (i < last) try b.addString(sep);
            }
            try b.pushResult();
            return 1;
        }
    }
    while (i < last) : (i += 1) {
        try addField(L, &b, i);
        try b.addString(sep);
    }
    if (i == last) try addField(L, &b, i); // no trailing separator
    try b.pushResult();
    return 1;
}

// table.pack / table.unpack

/// table.pack(...)
fn tpack(L: *state.LuaState) anyerror!i32 {
    const n = api.getTop(L);
    try api.createTable(L, n, 1);
    try api.insert(L, 1); // the result table, below the values
    var i = n;
    while (i >= 1) : (i -= 1) try api.setI(L, 1, i);
    try api.pushInteger(L, n);
    try api.setField(L, 1, "n"); // the count, so trailing nils survive
    return 1;
}

/// table.unpack(t [, i [, j]])
fn tunpack(L: *state.LuaState) anyerror!i32 {
    const len = try auxGetN(L, 1, TAB_R);
    var i = try aux.optInteger(L, 2, 1);
    const e = if (aux.isNoneOrNil(L, 3)) len else try aux.checkInteger(L, 3);
    if (i > e) return 0; // empty range

    // Unsigned so that a range spanning the whole integer type is caught here
    // rather than overflowing the count
    var n: u64 = @as(u64, @bitCast(e)) -% @as(u64, @bitCast(i)); // count - 1
    if (n >= @as(u64, std.math.maxInt(i32)))
        return aux.err(L, "too many results to unpack", .{});
    n += 1;
    if (!api.checkStack(L, @intCast(n)))
        return aux.err(L, "too many results to unpack", .{});

    if (i >= 1) {
        if (rawArray(L, e)) |t| {
            var idx: usize = @intCast(i - 1);
            const stop: usize = @intCast(e);
            t.touchLimit(e); // as the reference's lua_geti(t, e) would
            while (idx < stop) : (idx += 1) try api.pushValue(L, t.arr()[idx]);
            return @intCast(n);
        }
    }
    while (i < e) : (i += 1) try api.getI(L, 1, i); // i .. e-1, so i + 1 cannot overflow
    try api.getI(L, 1, e);
    return @intCast(n);
}

// table.sort
//
// Quicksort after 'Algorithms in MODULA-3', Robert Sedgewick; Addison-Wesley,
// 1993, ported from ltablib.c. The array indices are the C code's `IdxT`, kept
// as a 32-bit unsigned type because `tsort` refuses arrays that do not fit.

/// Arrays larger than this may use a randomized pivot
const RANLIMIT: u32 = 100;

/// Store the two values on top of the stack into `t[i]` and `t[j]` (set2)
fn set2(L: *state.LuaState, i: u32, j: u32) anyerror!void {
    try api.setI(L, 1, i);
    try api.setI(L, 1, j);
}

/// Is the value at `a` less than the one at `b` under the sort's order?
/// (sort_comp)
fn sortComp(L: *state.LuaState, a: i32, b: i32) anyerror!bool {
    if (api.isNil(L, 2)) return api.compare(L, a, b, .LT);
    try api.pushValueAt(L, 2);
    try api.pushValueAt(L, a - 1); // -1 compensates for the function
    try api.pushValueAt(L, b - 2); // -2 for the function and 'a'
    try api.call(L, 2, 1);
    const res = api.toBoolean(L, -1);
    api.pop(L, 1);
    return res;
}

/// Partition around the pivot on top of the stack.
///
/// Precondition `a[lo] <= P == a[up-1] <= a[up]`, so only `lo+1 .. up-2` has
/// to be partitioned; the sentinels at both ends are what let the scan loops
/// run without a bounds test on every step. A comparison function that is not
/// a strict order breaks that guarantee, so each loop carries the one check
/// that catches it before the scan leaves the array.
fn partition(L: *state.LuaState, lo: u32, up: u32) anyerror!u32 {
    var i = lo; // incremented before first use
    var j = up - 1; // decremented before first use
    // Invariant: a[lo .. i] <= P <= a[j .. up]
    while (true) {
        while (true) { // ++i while a[i] < P
            i += 1;
            try api.getI(L, 1, i);
            if (!(try sortComp(L, -1, -2))) break;
            if (i == up - 1) // a[up - 1] < P, but P *is* a[up - 1]
                return aux.err(L, "invalid order function for sorting", .{});
            api.pop(L, 1);
        }
        // Now a[i] >= P and a[lo .. i-1] < P  (a)
        while (true) { // --j while P < a[j]
            j -= 1;
            try api.getI(L, 1, j);
            if (!(try sortComp(L, -3, -1))) break;
            if (j < i) // a[j] > P with j <= i - 1 contradicts (a)
                return aux.err(L, "invalid order function for sorting", .{});
            api.pop(L, 1);
        }
        // Now a[j] <= P and a[j+1 .. up] >= P
        if (j < i) { // nothing left out of place
            api.pop(L, 1); // a[j]
            try set2(L, up - 1, i); // put the pivot at its final position
            return i;
        }
        try set2(L, i, j);
    }
}

/// An element in the middle half of [lo,up], perturbed by `rnd` (choosePivot)
fn choosePivot(lo: u32, up: u32, rnd: u32) u32 {
    const r4 = (up - lo) / 4;
    return (rnd ^ lo ^ up) % (r4 * 2) + (lo + r4);
}

/// A fresh pivot perturbation (l_randomizePivot).
///
/// Only reached when a partition came out badly lopsided, where any value that
/// varies between runs is enough to stop the next pass repeating it.
fn randomizePivot(L: *state.LuaState, rnd: u32) u32 {
    var r = rnd ^ @as(u32, @truncate(@intFromPtr(L) >> 4)) ^ 0x9e3779b9;
    r ^= r << 13;
    r ^= r >> 17;
    r ^= r << 5;
    return if (r == 0) 1 else r; // 0 means "do not randomize"
}

fn auxsort(L: *state.LuaState, lo_start: u32, up_start: u32, rnd_start: u32) anyerror!void {
    var lo = lo_start;
    var up = up_start;
    var rnd = rnd_start;
    while (lo < up) { // loop in place of the tail recursion
        // Order a[lo], a[p] and a[up] so the outer two become the sentinels
        try api.getI(L, 1, lo);
        try api.getI(L, 1, up);
        if (try sortComp(L, -1, -2)) try set2(L, lo, up) else api.pop(L, 2);
        if (up - lo == 1) return; // two elements, now sorted

        var p = if (up - lo < RANLIMIT or rnd == 0)
            (lo + up) / 2 // the middle is a good pivot for a small interval
        else
            choosePivot(lo, up, rnd);

        try api.getI(L, 1, p);
        try api.getI(L, 1, lo);
        if (try sortComp(L, -2, -1)) {
            try set2(L, p, lo);
        } else {
            api.pop(L, 1); // a[lo]
            try api.getI(L, 1, up);
            if (try sortComp(L, -1, -2)) try set2(L, p, up) else api.pop(L, 2);
        }
        if (up - lo == 2) return; // three elements, now sorted

        try api.getI(L, 1, p); // the pivot
        try api.pushValueAt(L, -1); // a second copy, left for `partition`
        try api.getI(L, 1, up - 1);
        try set2(L, p, up - 1); // park the pivot at up - 1
        p = try partition(L, lo, up);

        // Recur into the smaller half and iterate on the larger one, which
        // bounds the recursion depth at O(log n)
        const n = blk: {
            if (p - lo < up - p) {
                try auxsort(L, lo, p - 1, rnd);
                const size = p - lo;
                lo = p + 1;
                break :blk size;
            } else {
                try auxsort(L, p + 1, up, rnd);
                const size = up - p;
                up = p - 1;
                break :blk size;
            }
        };
        if ((up - lo) / 128 > n) rnd = randomizePivot(L, rnd);
    }
}

// The same algorithm over the array part of a plain table (no metatable,
// every element in the array part), which is what `table.sort` is nearly
// always given: elements are read and swapped in place instead of through
// `lua_geti` / `lua_seti`. The comparator (or an `__lt` metamethod of an
// element) may run arbitrary Lua that resizes the table, so the array is
// re-validated after every call; a table that shrank below the range is
// reported like a broken order function, which is the closest the
// reference gets (it would compare the nils it then reads).

/// `a < b` under the sort's order, for the raw sort
fn rawLess(L: *state.LuaState, t: *table.Table, n: u32, a: value.TValue, b: value.TValue, has_comp: bool) anyerror!bool {
    var res: bool = undefined;
    if (!has_comp) {
        if (a.isInteger() and b.isInteger()) return a.integerValue() < b.integerValue();
        res = try vm.lessThan(L, a, b); // numbers, strings, or `__lt`
    } else {
        try api.pushValueAt(L, 2);
        try api.pushValue(L, a);
        try api.pushValue(L, b);
        try api.call(L, 2, 1);
        res = api.toBoolean(L, -1);
        api.pop(L, 1);
    }
    if (t.asize < n) return aux.err(L, "invalid order function for sorting", .{});
    return res;
}

// Stores write back the copies that were read *before* the comparison,
// exactly as `set2` stores the stack copies in the reference: a comparator
// that modifies the table sees the same sequence of values either way.

/// `partition` over the array part; `pivot` is a copy of `a[up - 1]`
fn partitionRaw(L: *state.LuaState, t: *table.Table, n: u32, lo: u32, up: u32, pivot: value.TValue, has_comp: bool) anyerror!u32 {
    var i = lo;
    var j = up - 1;
    while (true) {
        var vi: value.TValue = undefined;
        while (true) { // ++i while a[i] < P
            i += 1;
            vi = t.arr()[i - 1];
            if (!(try rawLess(L, t, n, vi, pivot, has_comp))) break;
            if (i == up - 1) return aux.err(L, "invalid order function for sorting", .{});
        }
        var vj: value.TValue = undefined;
        while (true) { // --j while P < a[j]
            j -= 1;
            vj = t.arr()[j - 1];
            if (!(try rawLess(L, t, n, pivot, vj, has_comp))) break;
            if (j < i) return aux.err(L, "invalid order function for sorting", .{});
        }
        if (j < i) {
            t.arr()[up - 2] = vi; // set2(up - 1, i): the pivot goes to its final place
            t.arr()[i - 1] = pivot;
            return i;
        }
        t.arr()[i - 1] = vj; // set2(i, j)
        t.arr()[j - 1] = vi;
    }
}

fn auxsortRaw(L: *state.LuaState, t: *table.Table, n: u32, lo_start: u32, up_start: u32, rnd_start: u32, has_comp: bool) anyerror!void {
    var lo = lo_start;
    var up = up_start;
    var rnd = rnd_start;
    while (lo < up) {
        // Order a[lo], a[p] and a[up] so the outer two become the sentinels
        const vlo = t.arr()[lo - 1];
        const vup = t.arr()[up - 1];
        if (try rawLess(L, t, n, vup, vlo, has_comp)) { // set2(lo, up)
            t.arr()[lo - 1] = vup;
            t.arr()[up - 1] = vlo;
        }
        if (up - lo == 1) return;

        var p = if (up - lo < RANLIMIT or rnd == 0) (lo + up) / 2 else choosePivot(lo, up, rnd);

        const vp = t.arr()[p - 1];
        const vlo2 = t.arr()[lo - 1];
        if (try rawLess(L, t, n, vp, vlo2, has_comp)) { // set2(p, lo)
            t.arr()[p - 1] = vlo2;
            t.arr()[lo - 1] = vp;
        } else {
            const vup2 = t.arr()[up - 1];
            if (try rawLess(L, t, n, vup2, vp, has_comp)) { // set2(p, up)
                t.arr()[p - 1] = vup2;
                t.arr()[up - 1] = vp;
            }
        }
        if (up - lo == 2) return;

        const pivot = t.arr()[p - 1];
        const vup1 = t.arr()[up - 2];
        t.arr()[p - 1] = vup1; // set2(p, up - 1): park the pivot at up - 1
        t.arr()[up - 2] = pivot;
        p = try partitionRaw(L, t, n, lo, up, pivot, has_comp);

        const size = blk: {
            if (p - lo < up - p) {
                try auxsortRaw(L, t, n, lo, p - 1, rnd, has_comp);
                const size = p - lo;
                lo = p + 1;
                break :blk size;
            } else {
                try auxsortRaw(L, t, n, p + 1, up, rnd, has_comp);
                const size = up - p;
                up = p - 1;
                break :blk size;
            }
        };
        if ((up - lo) / 128 > size) rnd = randomizePivot(L, rnd);
    }
}

/// table.sort(t [, comp])
fn tsort(L: *state.LuaState) anyerror!i32 {
    const n = try auxGetN(L, 1, TAB_RW);
    if (n > 1) {
        try aux.argCheck(L, n < std.math.maxInt(i32), 1, "array too big");
        const has_comp = !aux.isNoneOrNil(L, 2);
        if (has_comp) try api.checkType(L, 2, .function);
        try api.setTop(L, 2); // sortComp reads argument 2 whether or not it was given
        if (api.toTable(L, 1)) |t| {
            if (t.metatable == null and t.asize >= n) {
                try auxsortRaw(L, t, @intCast(n), 1, @intCast(n), 0, has_comp);
                return 0;
            }
        }
        try auxsort(L, 1, @intCast(n), 0);
    }
    return 0;
}
