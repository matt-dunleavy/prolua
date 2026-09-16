// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Conversion of Lua numerals to numbers (lobject.c `luaO_str2num`).

const std = @import("std");
const mem = std.mem;
const value = @import("value.zig");

/// Parse a Lua numeral (decimal or hex, integer or float, surrounding spaces
/// allowed), or null when `s_in` is not one
/// The current locale's decimal point (lua_getlocaledecpoint)
const Lconv = extern struct { decimal_point: [*:0]const u8 }; // only the first member is read
extern "c" fn localeconv() *const Lconv;
pub fn localeDecimalPoint() u8 {
    return localeconv().decimal_point[0];
}

/// String to number as luaO_str2num does it, in the current locale
/// (l_str2d): the locale's decimal point is the one `strtod` reads; a
/// string that fails and contains a '.' is tried again with its first '.'
/// replaced by the locale's point. With the "C" locale this is `parseC`.
pub fn parse(s_in: []const u8) ?value.Number {
    const dp = localeDecimalPoint();
    if (dp == '.') return parseC(s_in);
    const L_MAXLENNUM = 200;
    var buf: [L_MAXLENNUM]u8 = undefined;
    if (mem.indexOfScalar(u8, s_in, '.') == null) {
        // First attempt, as strtod sees it: the locale's point is the point
        if (mem.indexOfScalar(u8, s_in, dp) == null) return parseC(s_in);
        if (s_in.len > buf.len) return null;
        for (s_in, 0..) |c, i| buf[i] = if (c == dp) '.' else c;
        return parseC(buf[0..s_in.len]);
    }
    // A '.' stops strtod, so the first attempt fails; the retry replaces the
    // first '.' by the locale's point (every other '.' stays foreign)
    if (s_in.len > buf.len) return null;
    var seen_dot = false;
    for (s_in, 0..) |c, i| {
        if (c == '.') {
            buf[i] = if (seen_dot) dp else '.';
            seen_dot = true;
        } else if (c == dp) {
            buf[i] = '.';
        } else {
            buf[i] = c;
        }
    }
    return parseC(buf[0..s_in.len]);
}

/// String to number with '.' as the decimal point (the "C" locale)
pub fn parseC(s_in: []const u8) ?value.Number {
    const s = mem.trim(u8, s_in, " \t\n\r\x0b\x0c");
    if (s.len == 0) return null;
    var body = s;
    var neg = false;
    if (body[0] == '-' or body[0] == '+') {
        neg = body[0] == '-';
        body = body[1..];
    }
    if (body.len == 0) return null;
    const is_hex = body.len > 1 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X');
    if (is_hex) {
        const digits = body[2..];
        if (digits.len == 0) return null;
        // Hex integer: wraps around modulo 2^64 (l_str2int)
        var all_hex = true;
        var v: u64 = 0;
        for (digits) |c| {
            const d = std.fmt.charToDigit(c, 16) catch {
                all_hex = false;
                break;
            };
            v = v *% 16 +% d;
        }
        if (all_hex) {
            const i: i64 = @bitCast(v);
            return .{ .integer = if (neg) 0 -% i else i };
        }
        // Hex float: only digits, one point, and a binary exponent may appear
        var seen_p = false;
        var seen_dot = false;
        for (digits, 0..) |c, i| {
            switch (c) {
                '0'...'9', 'a'...'f', 'A'...'F' => {},
                '.' => {
                    if (seen_dot or seen_p) return null;
                    seen_dot = true;
                },
                'p', 'P' => {
                    if (seen_p) return null;
                    seen_p = true;
                },
                '+', '-' => {
                    if (i == 0 or (digits[i - 1] != 'p' and digits[i - 1] != 'P')) return null;
                },
                else => return null,
            }
        }
        const f = hexFloat(digits) orelse return null;
        return .{ .float = if (neg) -f else f };
    }
    // Decimal: reject anything std would accept but Lua does not
    var has_dot_or_exp = false;
    for (body, 0..) |c, i| {
        switch (c) {
            '0'...'9' => {},
            '.', 'e', 'E' => has_dot_or_exp = true,
            '+', '-' => {
                if (i == 0 or (body[i - 1] != 'e' and body[i - 1] != 'E')) return null;
            },
            else => return null, // "inf", "nan", "_", ...
        }
    }
    if (!has_dot_or_exp) {
        // l_str2int: accumulate unsigned so that "-9223372036854775808" is
        // the integer minint; anything larger falls through to the float path
        const maxby10: u64 = @as(u64, std.math.maxInt(i64)) / 10;
        const maxlastd: u64 = @as(u64, std.math.maxInt(i64)) % 10;
        var a: u64 = 0;
        var fits = true;
        for (body) |c| {
            const d: u64 = c - '0';
            if (a >= maxby10 and (a > maxby10 or d > maxlastd + @intFromBool(neg))) {
                fits = false;
                break;
            }
            a = a * 10 + d;
        }
        if (fits) {
            const i: i64 = @bitCast(a);
            return .{ .integer = if (neg) 0 -% i else i };
        }
    }
    const f = std.fmt.parseFloat(f64, body) catch return null;
    return .{ .float = if (neg) -f else f };
}

/// A hexadecimal float (digits, optional point, optional binary exponent),
/// correctly rounded like C99 `strtod`, which is what the reference uses:
/// the mantissa is gathered exactly into 64 bits, further digits only shift
/// the exponent and set a sticky bit, and one round-to-nearest-even makes
/// the double. (Accumulating in a double, as `std.fmt.parseFloat` does for
/// long mantissas, rounds at every digit and drifts.)
fn hexFloat(digits: []const u8) ?f64 {
    var m: u64 = 0;
    var exp: i32 = 0; // binary exponent of `m`
    var sticky = false;
    var any = false;
    var i: usize = 0;
    var after_dot = false;
    while (i < digits.len) : (i += 1) {
        const c = digits[i];
        if (c == '.') {
            after_dot = true;
            continue;
        }
        if (c == 'p' or c == 'P') break;
        const d: u64 = std.fmt.charToDigit(c, 16) catch return null;
        any = true;
        if (m >> 60 == 0) { // room for four more bits
            m = m * 16 + d;
            if (after_dot) exp -= 4;
        } else {
            if (!after_dot) exp += 4; // the digit is a factor of 16 we cannot hold
            if (d != 0) sticky = true;
        }
    }
    if (!any) return null;
    if (i < digits.len) { // binary exponent
        i += 1;
        var eneg = false;
        if (i < digits.len and (digits[i] == '+' or digits[i] == '-')) {
            eneg = digits[i] == '-';
            i += 1;
        }
        if (i >= digits.len) return null;
        var e: i32 = 0;
        while (i < digits.len) : (i += 1) {
            const c = digits[i];
            if (c < '0' or c > '9') return null;
            if (e < 100000) e = e * 10 + @as(i32, c - '0'); // saturate: already an overflow
        }
        exp += if (eneg) -e else e;
    }
    if (m == 0) return 0.0;
    // Normalise to 64 significant bits, keep 53, round to nearest even
    const lz: u6 = @intCast(@clz(m));
    m <<= lz;
    exp -= @as(i32, lz);
    var keep: u64 = m >> 11;
    const rem: u64 = m & 0x7ff;
    const half: u64 = 0x400;
    if (rem > half or (rem == half and (sticky or (keep & 1) == 1))) {
        keep += 1;
        if (keep == (@as(u64, 1) << 53)) { // rounding carried into a new bit
            keep >>= 1;
            exp += 1;
        }
    }
    // keep * 2^(exp + 11), with overflow to inf and underflow to 0 as strtod
    const e2 = exp + 11;
    if (e2 > 1100) return std.math.inf(f64);
    if (e2 < -1200) return 0.0;
    return std.math.ldexp(@as(f64, @floatFromInt(keep)), e2);
}

test "numeral.parse follows luaO_str2num" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 42), parse("42").?.integer);
    try t.expectEqual(@as(i64, -1), parse("0xffffffffffffffff").?.integer);
    try t.expectEqual(@as(i64, 31), parse(" 0x1F ").?.integer);
    try t.expectEqual(@as(f64, 16.0), parse("0x1p4").?.float);
    try t.expectEqual(@as(f64, 1.5), parse("0x1.8").?.float);
    try t.expectEqual(@as(f64, 100.0), parse("1e2").?.float);
    try t.expectEqual(@as(f64, 9223372036854775808.0), parse("9223372036854775808").?.float);
    try t.expectEqual(@as(i64, std.math.minInt(i64)), parse("-9223372036854775808").?.integer);
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), parse("9223372036854775807").?.integer);
    try t.expectEqual(@as(f64, -9223372036854775809.0), parse("-9223372036854775809").?.float);
    try t.expectEqual(@as(?value.Number, null), parse("0b101"));
    try t.expectEqual(@as(?value.Number, null), parse("1_000"));
    try t.expectEqual(@as(?value.Number, null), parse("inf"));
    try t.expectEqual(@as(?value.Number, null), parse("nan"));
    try t.expectEqual(@as(?value.Number, null), parse("3x"));
    try t.expectEqual(@as(?value.Number, null), parse("1..2"));
    try t.expectEqual(@as(?value.Number, null), parse("0x"));
    try t.expectEqual(@as(?value.Number, null), parse("1e"));
    try t.expectEqual(@as(?value.Number, null), parse(""));
}
