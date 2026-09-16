// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Mathematical functions (lmathlib.c).
//!
//! Lua 5.4 has two number subtypes, and most of this file exists to keep them
//! apart: `floor`, `ceil`, `modf`, `abs`, `max` and `min` return an integer
//! whenever Lua would, falling back to a float only when the value does not
//! fit. The rest is the `xoshiro256**` generator behind `math.random`.

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const stdio = @import("../utils/stdio.zig");

const PI: f64 = 3.141592653589793238462643383279502884;

/// -2^63 as a float. Exact, and the lower bound of the range of floats that
/// convert to an integer (lua_numbertointeger).
const min_integer_as_float: f64 = @floatFromInt(std.math.minInt(i64));

/// Is `d` inside the range of floats an integer can hold, [-2^63, 2^63)?
/// (lua_numbertointeger)
fn fitsInteger(d: f64) bool {
    return d >= min_integer_as_float and d < -min_integer_as_float;
}

pub fn openMath(L: *state.LuaState) !void {
    try aux.registerLib(L, "math", &mathlib);

    try api.pushNumber(L, PI);
    try api.setField(L, -2, "pi");
    try api.pushNumber(L, std.math.inf(f64));
    try api.setField(L, -2, "huge");
    try api.pushInteger(L, std.math.maxInt(i64));
    try api.setField(L, -2, "maxinteger");
    try api.pushInteger(L, std.math.minInt(i64));
    try api.setField(L, -2, "mininteger");

    // setrandfunc: the generator starts from an unpredictable seed, so a
    // program that never calls randomseed still varies between runs
    try setSeed(L, &rand_state, makeSeed(L), 0);
    api.pop(L, 2); // the two seed components setSeed leaves behind

    api.pop(L, 1); // the library table
}

/// math.abs(x)
fn math_abs(L: *state.LuaState) !i32 {
    if (api.isInteger(L, 1)) {
        var n = api.toInteger(L, 1).?;
        // Wrapping negation: |mininteger| is not representable, and Lua hands
        // back mininteger itself rather than raising (math_abs)
        if (n < 0) n = @bitCast(0 -% @as(u64, @bitCast(n)));
        try api.pushInteger(L, n);
    } else {
        try api.pushNumber(L, @abs(try aux.checkNumber(L, 1)));
    }
    return 1;
}

/// math.sin(x)
fn math_sin(L: *state.LuaState) !i32 {
    try api.pushNumber(L, @sin(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.cos(x)
fn math_cos(L: *state.LuaState) !i32 {
    try api.pushNumber(L, @cos(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.tan(x)
fn math_tan(L: *state.LuaState) !i32 {
    try api.pushNumber(L, @tan(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.asin(x)
fn math_asin(L: *state.LuaState) !i32 {
    try api.pushNumber(L, std.math.asin(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.acos(x)
fn math_acos(L: *state.LuaState) !i32 {
    try api.pushNumber(L, std.math.acos(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.atan(y [, x])
fn math_atan(L: *state.LuaState) !i32 {
    const y = try aux.checkNumber(L, 1);
    const x = try aux.optNumber(L, 2, 1.0);
    try api.pushNumber(L, std.math.atan2(y, x));
    return 1;
}

/// math.tointeger(x)
fn math_tointeger(L: *state.LuaState) !i32 {
    if (api.toInteger(L, 1)) |n| {
        try api.pushInteger(L, n);
    } else {
        try aux.checkAny(L, 1);
        try api.pushNil(L); // luaL_pushfail: not convertible to an integer
    }
    return 1;
}

/// Push `d` as an integer when it has an exact integer representation, and as
/// a float otherwise (pushnumint / lua_numbertointeger)
fn pushNumInt(L: *state.LuaState, d: f64) !void {
    if (fitsInteger(d)) {
        try api.pushInteger(L, @intFromFloat(d));
    } else {
        try api.pushNumber(L, d);
    }
}

/// math.floor(x)
fn math_floor(L: *state.LuaState) !i32 {
    if (api.isInteger(L, 1)) {
        try api.setTop(L, 1); // an integer is its own floor
    } else {
        try pushNumInt(L, @floor(try aux.checkNumber(L, 1)));
    }
    return 1;
}

/// math.ceil(x)
fn math_ceil(L: *state.LuaState) !i32 {
    if (api.isInteger(L, 1)) {
        try api.setTop(L, 1); // an integer is its own ceiling
    } else {
        try pushNumInt(L, @ceil(try aux.checkNumber(L, 1)));
    }
    return 1;
}

/// math.fmod(x, y)
fn math_fmod(L: *state.LuaState) !i32 {
    if (api.isInteger(L, 1) and api.isInteger(L, 2)) {
        const d = api.toInteger(L, 2).?;
        if (@as(u64, @bitCast(d)) +% 1 <= 1) { // d is -1 or 0
            try aux.argCheck(L, d != 0, 2, "zero");
            try api.pushInteger(L, 0); // avoids the overflow of mininteger % -1
        } else {
            try api.pushInteger(L, @rem(api.toInteger(L, 1).?, d));
        }
    } else {
        const x = try aux.checkNumber(L, 1);
        const y = try aux.checkNumber(L, 2);
        try api.pushNumber(L, @rem(x, y));
    }
    return 1;
}

/// math.modf(x)
fn math_modf(L: *state.LuaState) !i32 {
    if (api.isInteger(L, 1)) {
        try api.setTop(L, 1); // the number is its own integer part
        try api.pushNumber(L, 0.0); // and has no fractional part
    } else {
        const n = try aux.checkNumber(L, 1);
        const ip = if (n < 0) @ceil(n) else @floor(n); // rounds toward zero
        try pushNumInt(L, ip);
        // The test is for ±inf, where the subtraction would give NaN
        try api.pushNumber(L, if (n == ip) 0.0 else n - ip);
    }
    return 2;
}

/// math.sqrt(x)
fn math_sqrt(L: *state.LuaState) !i32 {
    try api.pushNumber(L, @sqrt(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.ult(m, n)
fn math_ult(L: *state.LuaState) !i32 {
    const a: u64 = @bitCast(try aux.checkInteger(L, 1));
    const b: u64 = @bitCast(try aux.checkInteger(L, 2));
    try api.pushBoolean(L, a < b);
    return 1;
}

/// math.log(x [, base])
fn math_log(L: *state.LuaState) !i32 {
    const x = try aux.checkNumber(L, 1);
    var res: f64 = undefined;
    if (aux.isNoneOrNil(L, 2)) {
        res = @log(x);
    } else {
        const base = try aux.checkNumber(L, 2);
        // Bases 2 and 10 get the dedicated routines: log(8)/log(2) is not
        // exactly 3, log2(8) is
        if (base == 2.0) {
            res = @log2(x);
        } else if (base == 10.0) {
            res = @log10(x);
        } else {
            res = @log(x) / @log(base);
        }
    }
    try api.pushNumber(L, res);
    return 1;
}

/// math.exp(x)
fn math_exp(L: *state.LuaState) !i32 {
    try api.pushNumber(L, @exp(try aux.checkNumber(L, 1)));
    return 1;
}

/// math.deg(x)
fn math_deg(L: *state.LuaState) !i32 {
    try api.pushNumber(L, (try aux.checkNumber(L, 1)) * (180.0 / PI));
    return 1;
}

/// math.rad(x)
fn math_rad(L: *state.LuaState) !i32 {
    try api.pushNumber(L, (try aux.checkNumber(L, 1)) * (PI / 180.0));
    return 1;
}

// `frexp` and `ldexp` are unconditional in the lmathlib.c this follows, though
// a stock 5.4 build only exposes them under LUA_COMPAT_MATHLIB.

/// math.min(x, ···)
fn math_min(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    try aux.argCheck(L, n >= 1, 1, "value expected");
    var imin: i32 = 1;
    var i: i32 = 2;
    while (i <= n) : (i += 1) {
        if (try api.compare(L, i, imin, .LT)) imin = i;
    }
    // Copying the winning argument is what preserves its subtype
    try api.pushValueAt(L, imin);
    return 1;
}

/// math.max(x, ···)
fn math_max(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    try aux.argCheck(L, n >= 1, 1, "value expected");
    var imax: i32 = 1;
    var i: i32 = 2;
    while (i <= n) : (i += 1) {
        if (try api.compare(L, imax, i, .LT)) imax = i;
    }
    try api.pushValueAt(L, imax);
    return 1;
}

/// math.type(x)
fn math_type(L: *state.LuaState) !i32 {
    if (api.type_(L, 1) == .number) {
        try api.pushString(L, if (api.isInteger(L, 1)) "integer" else "float");
    } else {
        try aux.checkAny(L, 1);
        try api.pushNil(L); // luaL_pushfail: nil, not the string "nil"
    }
    return 1;
}

// Pseudo-random number generator, xoshiro256**.
//
// Lua keeps the generator state in a userdata upvalue shared by `random` and
// `randomseed`. Native functions here cannot carry upvalues (there is no
// `pushCClosure` in api.zig), so the state lives at file scope instead and is
// shared by every LuaState in the process.

var rand_state: [4]u64 = .{ 0, 0, 0, 0 };

/// Number of binary digits in the mantissa of a float (FIGS)
const FIGS = std.math.floatMantissaBits(f64) + 1;

/// The (64 - FIGS) low bits of a random word have to be thrown out
const shift64_FIG = 64 - FIGS;

/// 2^-FIGS
const scaleFIG: f64 = 0.5 / @as(f64, @floatFromInt(@as(u64, 1) << (FIGS - 1)));

fn nextRand(s: *[4]u64) u64 {
    const state0 = s[0];
    const state1 = s[1];
    const state2 = s[2] ^ state0;
    const state3 = s[3] ^ state1;
    const res = std.math.rotl(u64, state1 *% 5, 7) *% 9;
    s[0] = state0 ^ state3;
    s[1] = state1 ^ state2;
    s[2] = state2 ^ (state1 << 17);
    s[3] = std.math.rotl(u64, state3, 45);
    return res;
}

/// Take the high FIGS bits of a random word as a float in [0,1) (I2d).
///
/// C routes this through a signed integer to please old compilers and then
/// corrects for a negative result; with FIGS = 53 the shifted value always
/// fits in a positive i64, so the correction is dead code here.
fn I2d(x: u64) f64 {
    return @as(f64, @floatFromInt(x >> shift64_FIG)) * scaleFIG;
}

/// The smallest Mersenne number not smaller than `n`.
///
/// This is `project`'s loop with the doubling shift unrolled: each step
/// spreads the '1' bits further right until everything below the highest set
/// bit is set.
fn mersenneAtLeast(n: u64) u64 {
    var lim = n;
    inline for (.{ 1, 2, 4, 8, 16, 32 }) |sh| lim |= lim >> sh;
    return lim;
}

/// Project `ran` into [0, n] without bias (project).
///
/// A plain modulo would favour the low end of the interval unless its size is
/// a power of two, so instead the value is masked down to the enclosing
/// Mersenne number and redrawn until it lands inside [0, n].
fn project(ran: u64, n: u64, s: *[4]u64) u64 {
    const lim = mersenneAtLeast(n);
    var r = ran & lim;
    while (r > n) r = nextRand(s) & lim;
    return r;
}

/// math.random([m [, n]])
fn math_random(L: *state.LuaState) !i32 {
    var low: i64 = undefined;
    var up: i64 = undefined;
    const rv = nextRand(&rand_state);
    switch (api.getTop(L)) {
        0 => {
            try api.pushNumber(L, I2d(rv)); // float between 0 and 1
            return 1;
        },
        1 => {
            low = 1;
            up = try aux.checkInteger(L, 1);
            if (up == 0) { // a single 0: every bit is random
                try api.pushInteger(L, @bitCast(rv));
                return 1;
            }
        },
        2 => {
            low = try aux.checkInteger(L, 1);
            up = try aux.checkInteger(L, 2);
        },
        else => return aux.err(L, "wrong number of arguments", .{}),
    }
    try aux.argCheck(L, low <= up, 1, "interval is empty");
    // The interval can be wider than the signed range (math.random(mininteger,
    // maxinteger)), so the projection is done in unsigned arithmetic
    const ulow: u64 = @bitCast(low);
    const p = project(rv, @as(u64, @bitCast(up)) -% ulow, &rand_state);
    try api.pushInteger(L, @bitCast(p +% ulow));
    return 1;
}

/// Reset the generator and leave the two seed components on the stack, which
/// is what `math.randomseed` returns in 5.4 (setseed)
fn setSeed(L: *state.LuaState, s: *[4]u64, n1: u64, n2: u64) !void {
    s[0] = n1;
    s[1] = 0xff; // avoid a zero state
    s[2] = n2;
    s[3] = 0;
    for (0..16) |_| _ = nextRand(s); // discard, to spread the seed
    try api.pushInteger(L, @bitCast(n1));
    try api.pushInteger(L, @bitCast(n2));
}

/// A seed that differs between runs (luaL_makeseed).
///
/// The clock alone is not enough, since two processes can start within the
/// same tick, so addresses that ASLR moves around are mixed in as well.
fn makeSeed(L: *state.LuaState) u64 {
    const now = std.Io.Timestamp.now(stdio.io(), .real);
    var local: u8 = 0;
    var h: u64 = @truncate(@as(u96, @bitCast(now.nanoseconds)));
    h = mixSeed(h ^ @intFromPtr(L));
    h = mixSeed(h ^ @intFromPtr(&local));
    return h;
}

/// splitmix64's finalizer, used to stir the seed material together
fn mixSeed(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// math.randomseed([x [, y]])
fn math_randomseed(L: *state.LuaState) !i32 {
    var n1: u64 = undefined;
    var n2: u64 = undefined;
    if (api.getTop(L) == 0) {
        n1 = makeSeed(L);
        n2 = nextRand(&rand_state); // in case the seed is not that random
    } else {
        n1 = @bitCast(try aux.checkInteger(L, 1));
        n2 = @bitCast(try aux.optInteger(L, 2, 0));
    }
    try setSeed(L, &rand_state, n1, n2);
    return 2; // return the seeds
}

const mathlib = [_]aux.Reg{
    .{ .name = "abs", .func = math_abs },
    .{ .name = "acos", .func = math_acos },
    .{ .name = "asin", .func = math_asin },
    .{ .name = "atan", .func = math_atan },
    .{ .name = "ceil", .func = math_ceil },
    .{ .name = "cos", .func = math_cos },
    .{ .name = "deg", .func = math_deg },
    .{ .name = "exp", .func = math_exp },
    .{ .name = "tointeger", .func = math_tointeger },
    .{ .name = "floor", .func = math_floor },
    .{ .name = "fmod", .func = math_fmod },
    .{ .name = "ult", .func = math_ult },
    .{ .name = "log", .func = math_log },
    .{ .name = "max", .func = math_max },
    .{ .name = "min", .func = math_min },
    .{ .name = "modf", .func = math_modf },
    .{ .name = "rad", .func = math_rad },
    .{ .name = "random", .func = math_random },
    .{ .name = "randomseed", .func = math_randomseed },
    .{ .name = "sin", .func = math_sin },
    .{ .name = "sqrt", .func = math_sqrt },
    .{ .name = "tan", .func = math_tan },
    .{ .name = "type", .func = math_type },
};

// Tests
//
// Only the pieces that need no LuaState. Everything observable from Lua,
// including the integer/float subtypes, is covered by the behavioural script
// in mathtest.lua, which the reference interpreter also passes.

test "nextRand reproduces the xoshiro256** sequence" {
    // Seeded as `math.randomseed(42, 0)` does, then compared against the
    // values Lua 5.4 prints for math.random(0)
    var s: [4]u64 = .{ 42, 0xff, 0, 0 };
    for (0..16) |_| _ = nextRand(&s);
    try std.testing.expectEqual(@as(u64, 0xee49b4f7660276e5), nextRand(&s));
    try std.testing.expectEqual(@as(u64, 0x73a81c109b785431), nextRand(&s));
    try std.testing.expectEqual(@as(u64, 0x8c00881aa3bfbd4b), nextRand(&s));
}

test "I2d lands in [0,1)" {
    try std.testing.expectEqual(@as(f64, 0.0), I2d(0));
    try std.testing.expectEqual(@as(f64, 0.5), I2d(1 << 63));
    const max = I2d(std.math.maxInt(u64));
    try std.testing.expect(max < 1.0);
    // The largest representable result is 1 - 2^-53
    try std.testing.expectEqual(@as(f64, 1.0) - scaleFIG, max);
}

test "mersenneAtLeast covers the interval" {
    try std.testing.expectEqual(@as(u64, 0), mersenneAtLeast(0));
    try std.testing.expectEqual(@as(u64, 1), mersenneAtLeast(1));
    try std.testing.expectEqual(@as(u64, 3), mersenneAtLeast(2));
    try std.testing.expectEqual(@as(u64, 7), mersenneAtLeast(5));
    try std.testing.expectEqual(@as(u64, 0xffff), mersenneAtLeast(0x8000));
    try std.testing.expectEqual(std.math.maxInt(u64), mersenneAtLeast(std.math.maxInt(u64)));
}

test "project stays inside the interval" {
    var s: [4]u64 = .{ 1, 0xff, 2, 0 };
    for (0..16) |_| _ = nextRand(&s);
    for (0..64) |_| {
        const r = project(nextRand(&s), 9, &s);
        try std.testing.expect(r <= 9);
    }
}

test "fitsInteger matches lua_numbertointeger" {
    try std.testing.expect(fitsInteger(0.0));
    try std.testing.expect(fitsInteger(-1.0));
    // The bounds: -2^63 converts, 2^63 does not, and the float just below it does
    try std.testing.expect(fitsInteger(min_integer_as_float));
    try std.testing.expect(!fitsInteger(-min_integer_as_float));
    try std.testing.expect(fitsInteger(9223372036854774784.0));
    try std.testing.expect(!fitsInteger(std.math.inf(f64)));
    try std.testing.expect(!fitsInteger(-std.math.inf(f64)));
    try std.testing.expect(!fitsInteger(std.math.nan(f64)));
}
