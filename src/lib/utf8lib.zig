// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! UTF-8 manipulation (lutf8lib.c).
//!
//! Lua's UTF-8 is deliberately not Zig's: `utf8.char` encodes up to
//! 0x7FFFFFFF using the original six-byte scheme, and every decode has a `lax`
//! mode that accepts surrogates and code points above U+10FFFF. `std.unicode`
//! implements the narrower modern standard, so the codec here is a direct port
//! of `utf8_decode` and `luaO_utf8esc` instead.

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

/// Pattern matching one UTF-8 character, exported as `utf8.charpattern`.
const utf8_pattern = "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";

pub fn openUtf8(L: *state.LuaState) !void {
    try aux.registerLib(L, "utf8", &funcs);
    // `charpattern` is a string, not a function, so it is added after the
    // table is built. Pushing key and value before naming the table keeps the
    // table index valid across the pushes.
    try api.pushString(L, "charpattern");
    try api.pushString(L, utf8_pattern);
    try api.setTable(L, -3);
    api.pop(L, 1);
}

const funcs = [_]aux.Reg{
    .{ .name = "offset", .func = byteOffset },
    .{ .name = "codepoint", .func = codePoint },
    .{ .name = "char", .func = utfChar },
    .{ .name = "len", .func = utfLen },
    .{ .name = "codes", .func = iterCodes },
};

const max_unicode: u32 = 0x10FFFF;
const max_utf: u32 = 0x7FFFFFFF;
const msg_invalid = "invalid UTF-8 code";

fn isCont(c: u8) bool {
    return (c & 0xC0) == 0x80;
}

/// `iscontp` on a byte that may be one past the end. C looks at the string's
/// NUL terminator there, which is never a continuation byte, so the answer is
/// false rather than a bounds error.
fn isContAt(s: []const u8, i: usize) bool {
    return i < s.len and isCont(s[i]);
}

/// `u_posrelat`: a negative position counts back from the end. The result is
/// still 1-based and deliberately unclamped at the top, because the callers
/// distinguish "past the end" from "at the end".
fn posRelat(pos: i64, len: usize) i64 {
    if (pos >= 0) return pos;
    const back: u64 = 0 -% @as(u64, @bitCast(pos));
    if (back > len) return 0;
    return @as(i64, @intCast(len)) + pos + 1;
}

const Decoded = struct {
    code: u32,
    /// Index just past the sequence.
    next: usize,
};

/// Minimum value encodable with each continuation-byte count, so an overlong
/// sequence is rejected. Entry 0 forces a failure for a non-ASCII lead byte
/// that had no continuation bytes at all.
const limits = [6]u32{ 0xFFFFFFFF, 0x80, 0x800, 0x10000, 0x200000, 0x4000000 };

/// `utf8_decode`: the sequence starting at `s[i]`, or null if the bytes are not
/// a valid encoding. `strict` additionally rejects surrogates and values above
/// U+10FFFF; that is exactly what the libraries' `lax` argument turns off.
///
/// `i` must be a valid index into `s`, and `s` must run to the end of the Lua
/// string rather than to the end of the caller's range: a character starting
/// inside the range may well continue past it.
fn decode(s: []const u8, i: usize, strict: bool) ?Decoded {
    var c: u32 = s[i];
    var res: u32 = 0;
    var count: usize = 0;

    if (c < 0x80) {
        res = c;
    } else if (c >= 0xFE) {
        return null; // would need six or more continuation bytes
    } else {
        // The lead byte is shifted left once per continuation byte, so its
        // remaining payload bits end up in the low 7 bits afterwards.
        while (c & 0x40 != 0) {
            count += 1;
            if (i + count >= s.len) return null;
            const cc = s[i + count];
            if (!isCont(cc)) return null;
            res = (res << 6) | (cc & 0x3F);
            c <<= 1;
        }
        res |= (c & 0x7F) << @as(u5, @intCast(count * 5));
        if (res > max_utf or res < limits[count]) return null;
    }

    if (strict and (res > max_unicode or (res >= 0xD800 and res <= 0xDFFF))) return null;
    return .{ .code = res, .next = i + count + 1 };
}

/// `luaO_utf8esc`: encode `x` (up to 0x7FFFFFFF) into `buf`, returning the
/// bytes written. The encoding runs backwards from the end of the buffer
/// because the length is only known once the continuation bytes are done.
fn encode(buf: *[8]u8, x: u32) []const u8 {
    var n: usize = 1;
    if (x < 0x80) {
        buf[buf.len - 1] = @intCast(x);
    } else {
        var mfb: u32 = 0x3F; // most that still fits in the lead byte
        var v = x;
        while (true) {
            buf[buf.len - n] = @intCast(0x80 | (v & 0x3F));
            n += 1;
            v >>= 6;
            mfb >>= 1; // one less bit available in the lead byte
            if (v <= mfb) break;
        }
        buf[buf.len - n] = @truncate((~mfb << 1) | v);
    }
    return buf[buf.len - n ..];
}

/// utf8.len(s [, i [, j [, lax]]]) -- characters starting in [i, j], or
/// `nil, position` at the first byte that is not valid there
fn utfLen(L: *state.LuaState) !i32 {
    const s = try aux.checkString(L, 1);
    const len = s.len;
    var posi = posRelat(try aux.optInteger(L, 2, 1), len);
    var posj = posRelat(try aux.optInteger(L, 3, -1), len);
    const lax = api.toBoolean(L, 4);

    try aux.argCheck(L, 1 <= posi and posi - 1 <= @as(i64, @intCast(len)), 2, "initial position out of bounds");
    posi -= 1;
    try aux.argCheck(L, posj - 1 < @as(i64, @intCast(len)), 3, "final position out of bounds");
    posj -= 1;

    var n: i64 = 0;
    var i: usize = @intCast(posi);
    while (@as(i64, @intCast(i)) <= posj) {
        const d = decode(s, i, !lax) orelse {
            try api.pushNil(L); // luaL_pushfail
            try api.pushInteger(L, @as(i64, @intCast(i)) + 1);
            return 2;
        };
        i = d.next;
        n += 1;
    }
    try api.pushInteger(L, n);
    return 1;
}

/// utf8.codepoint(s [, i [, j [, lax]]]) -- every code point starting in [i, j]
fn codePoint(L: *state.LuaState) !i32 {
    const s = try aux.checkString(L, 1);
    const len: i64 = @intCast(s.len);
    const posi = posRelat(try aux.optInteger(L, 2, 1), s.len);
    const pose = posRelat(try aux.optInteger(L, 3, posi), s.len);
    const lax = api.toBoolean(L, 4);

    try aux.argCheck(L, posi >= 1, 2, "out of bounds");
    try aux.argCheck(L, pose <= len, 3, "out of bounds");
    if (posi > pose) return 0; // empty interval

    // One result per byte is the upper bound; refuse a range that could not be
    // returned even in principle.
    if (pose - posi >= std.math.maxInt(i32)) {
        return aux.err(L, "string slice too long", .{});
    }
    if (!api.checkStack(L, @intCast(pose - posi + 1))) {
        return aux.err(L, "string slice too long", .{});
    }

    var n: i32 = 0;
    const se: usize = @intCast(pose);
    var i: usize = @intCast(posi - 1);
    while (i < se) {
        const d = decode(s, i, !lax) orelse return aux.err(L, msg_invalid, .{});
        try api.pushInteger(L, d.code);
        n += 1;
        i = d.next;
    }
    return n;
}

/// `pushutfchar`: encode one integer argument, rejecting anything Lua's
/// extended UTF-8 cannot represent. A negative argument wraps to a huge
/// unsigned value and so fails the same check, as it does in C.
fn addUtfChar(L: *state.LuaState, b: *aux.Buffer, arg: i32) !void {
    const code: u64 = @bitCast(try aux.checkInteger(L, arg));
    try aux.argCheck(L, code <= max_utf, arg, "value out of range");
    var buf: [8]u8 = undefined;
    try b.addString(encode(&buf, @intCast(code)));
}

/// utf8.char(...) -- the arguments encoded and concatenated
fn utfChar(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    var b = aux.Buffer.init(L);
    defer b.deinit();

    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        try addUtfChar(L, &b, i);
    }
    try b.pushResult();
    return 1;
}

/// utf8.offset(s, n [, i]) -- where the n-th character counting from `i`
/// starts; `n == 0` reports the start of the character containing `i`
fn byteOffset(L: *state.LuaState) !i32 {
    const s = try aux.checkString(L, 1);
    const len: i64 = @intCast(s.len);
    var n = try aux.checkInteger(L, 2);

    // Counting forwards starts at the front, counting backwards at the end.
    const default_pos: i64 = if (n >= 0) 1 else len + 1;
    var posi = posRelat(try aux.optInteger(L, 3, default_pos), s.len);
    try aux.argCheck(L, 1 <= posi and posi - 1 <= len, 3, "position out of bounds");
    posi -= 1;

    if (n == 0) {
        // Walk back to the start of the sequence `posi` is inside.
        while (posi > 0 and isContAt(s, @intCast(posi))) posi -= 1;
    } else {
        if (isContAt(s, @intCast(posi))) {
            return aux.err(L, "initial position is a continuation byte", .{});
        }
        if (n < 0) {
            while (n < 0 and posi > 0) {
                posi -= 1;
                while (posi > 0 and isContAt(s, @intCast(posi))) posi -= 1;
                n += 1;
            }
        } else {
            n -= 1; // the character at `posi` is the first one
            while (n > 0 and posi < len) {
                posi += 1;
                while (isContAt(s, @intCast(posi))) posi += 1;
                n -= 1;
            }
        }
    }

    if (n != 0) { // ran off the end before finding it
        try api.pushNil(L); // luaL_pushfail
        return 1;
    }

    // 5.4 reports only where the character starts. (5.5 added a second result
    // giving where it ends; this interpreter targets 5.4.)
    try api.pushInteger(L, posi + 1);
    return 1;
}

/// `iter_aux`: advance past the character at the previous position and decode
/// the next one. Upvalue-free, like the C original: the state is the string
/// and the previous index, passed as arguments by the `for` loop.
fn iterAux(L: *state.LuaState, strict: bool) !i32 {
    const s = try aux.checkString(L, 1);
    const len: u64 = s.len;
    // An unsigned read makes a negative control variable compare as huge and
    // simply end the loop.
    var n: u64 = @bitCast(api.toInteger(L, 2) orelse 0);

    if (n < len) {
        while (isContAt(s, @intCast(n))) n += 1;
    }
    if (n >= len) return 0; // no more code points

    const d = decode(s, @intCast(n), strict) orelse return aux.err(L, msg_invalid, .{});
    // A trailing continuation byte means the sequence was not self-contained.
    if (isContAt(s, d.next)) return aux.err(L, msg_invalid, .{});

    try api.pushInteger(L, @intCast(n + 1));
    try api.pushInteger(L, d.code);
    return 2;
}

fn iterAuxStrict(L: *state.LuaState) !i32 {
    return iterAux(L, true);
}

fn iterAuxLax(L: *state.LuaState) !i32 {
    return iterAux(L, false);
}

/// utf8.codes(s [, lax]) -- iterator over position, code point pairs
fn iterCodes(L: *state.LuaState) !i32 {
    const lax = api.toBoolean(L, 2);
    const s = try aux.checkString(L, 1);
    try aux.argCheck(L, !isContAt(s, 0), 1, msg_invalid);

    try api.pushCFunction(L, if (lax) iterAuxLax else iterAuxStrict);
    try api.pushValueAt(L, 1);
    try api.pushInteger(L, 0);
    return 3;
}

// === Tests ===
//
// The codec is pure, so it is checked directly here; the library functions
// themselves are exercised by utf8test.lua.

const testing = std.testing;

fn expectEncode(code: u32, expected: []const u8) !void {
    var buf: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, expected, encode(&buf, code));
}

test "utf8lib.encode matches the standard sequences" {
    try expectEncode(0x00, "\x00");
    try expectEncode('A', "A");
    try expectEncode(0x7F, "\x7F");
    try expectEncode(0x80, "\xC2\x80");
    try expectEncode(0xE9, "\xC3\xA9"); // e-acute
    try expectEncode(0x7FF, "\xDF\xBF");
    try expectEncode(0x800, "\xE0\xA0\x80");
    try expectEncode(0x20AC, "\xE2\x82\xAC"); // euro sign
    try expectEncode(0xFFFF, "\xEF\xBF\xBF");
    try expectEncode(0x10000, "\xF0\x90\x80\x80");
    try expectEncode(0x1F600, "\xF0\x9F\x98\x80"); // grinning face
    try expectEncode(0x10FFFF, "\xF4\x8F\xBF\xBF");
}

test "utf8lib.encode uses Lua's extended range above U+10FFFF" {
    // Five- and six-byte forms, which modern UTF-8 dropped but Lua keeps.
    try expectEncode(0x200000, "\xF8\x88\x80\x80\x80");
    try expectEncode(0x4000000, "\xFC\x84\x80\x80\x80\x80");
    try expectEncode(max_utf, "\xFD\xBF\xBF\xBF\xBF\xBF");
}

test "utf8lib.decode round-trips every encodable code point" {
    const samples = [_]u32{
        0,      'A',      0x7F,     0x80,      0xE9,    0x7FF,
        0x800,  0x20AC,   0xFFFF,   0x10000,   0x1F600, 0x10FFFF,
        0xD800, 0x110000, 0x200000, 0x4000000, max_utf,
    };
    for (samples) |code| {
        var buf: [8]u8 = undefined;
        const bytes = encode(&buf, code);
        // Surrogates and out-of-range values only decode in lax mode, which is
        // the whole point of the flag.
        const d = decode(bytes, 0, false).?;
        try testing.expectEqual(code, d.code);
        try testing.expectEqual(bytes.len, d.next);
    }
}

test "utf8lib.decode rejects malformed sequences" {
    // Continuation byte with nothing to continue.
    try testing.expect(decode("\x80", 0, true) == null);
    try testing.expect(decode("\xBF", 0, true) == null);
    // Lead byte whose continuation bytes are missing or truncated.
    try testing.expect(decode("\xC3", 0, true) == null);
    try testing.expect(decode("\xE2\x82", 0, true) == null);
    try testing.expect(decode("\xC3Z", 0, true) == null);
    // Six or more continuation bytes.
    try testing.expect(decode("\xFE\x80\x80\x80\x80\x80", 0, true) == null);
    try testing.expect(decode("\xFF", 0, true) == null);
    // Overlong encodings of values that fit in fewer bytes.
    try testing.expect(decode("\xC0\x80", 0, true) == null);
    try testing.expect(decode("\xC1\xBF", 0, true) == null);
    try testing.expect(decode("\xE0\x80\x80", 0, true) == null);
    try testing.expect(decode("\xF0\x80\x80\x80", 0, true) == null);
}

test "utf8lib.decode strict mode rejects surrogates and oversized values" {
    const surrogate = "\xED\xA0\x80"; // U+D800
    try testing.expect(decode(surrogate, 0, true) == null);
    try testing.expectEqual(@as(u32, 0xD800), decode(surrogate, 0, false).?.code);

    const too_big = "\xF4\x90\x80\x80"; // U+110000
    try testing.expect(decode(too_big, 0, true) == null);
    try testing.expectEqual(@as(u32, 0x110000), decode(too_big, 0, false).?.code);

    try testing.expect(decode("\xF4\x8F\xBF\xBF", 0, true) != null); // U+10FFFF is fine
}

test "utf8lib.decode reads past a caller's range but not past the string" {
    // "h" then a two-byte character: decoding at index 1 needs byte 2, which is
    // why callers pass the whole string and only compare positions.
    const s = "h\xC3\xA9!";
    const d = decode(s, 1, true).?;
    try testing.expectEqual(@as(u32, 0xE9), d.code);
    try testing.expectEqual(@as(usize, 3), d.next);
    // The same lead byte with the string ending after it fails instead.
    try testing.expect(decode(s[0..2], 1, true) == null);
}

test "utf8lib.posRelat maps negative positions from the end" {
    try testing.expectEqual(@as(i64, 1), posRelat(1, 5));
    try testing.expectEqual(@as(i64, 5), posRelat(-1, 5));
    try testing.expectEqual(@as(i64, 1), posRelat(-5, 5));
    try testing.expectEqual(@as(i64, 0), posRelat(-6, 5)); // further back than the string
    try testing.expectEqual(@as(i64, 0), posRelat(0, 5));
    try testing.expectEqual(@as(i64, 99), posRelat(99, 5)); // not clamped at the top
    try testing.expectEqual(@as(i64, 0), posRelat(std.math.minInt(i64), 5));
}
