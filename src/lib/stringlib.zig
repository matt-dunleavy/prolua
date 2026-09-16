// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The string library (lstrlib.c), including Lua's pattern matcher.
//!
//! The matcher is a close port rather than a reimplementation: its behaviour
//! on malformed patterns, empty matches and capture bookkeeping is relied on
//! by real Lua code and is difficult to rediscover from the manual alone.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("../api.zig");
const numeral = @import("../numeral.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const vm = @import("../vm.zig");
const dump_module = @import("../dump.zig");

const MAXCAPTURES = 32;
const L_ESC = '%';
const SPECIALS = "^$*+?.([%-";

/// Recursion limit for `match`, mirroring MAXCCALLS. Without it a pattern such
/// as ("a"):rep(100) matched against "a*a*a*..." can exhaust the native stack.
const MAXCCALLS = 200;

const CAP_UNFINISHED: isize = -1;
const CAP_POSITION: isize = -2;

pub fn openString(L: *state.LuaState) !void {
    const regs = [_]aux.Reg{
        .{ .name = "byte", .func = str_byte },
        .{ .name = "char", .func = str_char },
        .{ .name = "dump", .func = str_dump },
        .{ .name = "find", .func = str_find },
        .{ .name = "format", .func = str_format },
        .{ .name = "gmatch", .func = str_gmatch },
        .{ .name = "gsub", .func = str_gsub },
        .{ .name = "len", .func = str_len },
        .{ .name = "lower", .func = str_lower },
        .{ .name = "match", .func = str_match },
        .{ .name = "rep", .func = str_rep },
        .{ .name = "reverse", .func = str_reverse },
        .{ .name = "sub", .func = str_sub },
        .{ .name = "upper", .func = str_upper },
        .{ .name = "pack", .func = str_pack },
        .{ .name = "packsize", .func = str_packsize },
        .{ .name = "unpack", .func = str_unpack },
    };
    try aux.registerLib(L, "string", &regs);

    // Give every string the library as its metatable's __index, which is what
    // makes ("x"):upper() resolve, and the arithmetic metamethods that make
    // `"10" + 5` coerce (createmetatable / stringmetamethods)
    try aux.newLib(L, &string_metamethods);
    try api.pushValueAt(L, -2); // the string table
    try api.setField(L, -2, "__index");
    try api.setTypeMetatable(L, .string);

    api.pop(L, 1); // the string table itself
}

// Arithmetic on strings.
//
// Since 5.4 the VM no longer coerces strings to numbers itself: `"10" + 5`
// reaches the string metatable's `__add`, which converts both operands and
// performs the operation, or defers to the other operand's metamethod.

const string_metamethods = [_]aux.Reg{
    .{ .name = "__add", .func = arith_add },
    .{ .name = "__sub", .func = arith_sub },
    .{ .name = "__mul", .func = arith_mul },
    .{ .name = "__mod", .func = arith_mod },
    .{ .name = "__pow", .func = arith_pow },
    .{ .name = "__div", .func = arith_div },
    .{ .name = "__idiv", .func = arith_idiv },
    .{ .name = "__unm", .func = arith_unm },
};

/// Push argument `arg` as a number when it is one, or a whole numeral string
/// (tonum). Nothing is pushed when it is neither.
fn toNum(L: *state.LuaState, arg: i32) !bool {
    if (api.type_(L, arg) == .number) {
        try api.pushValueAt(L, arg);
        return true;
    }
    const s = api.toString(L, arg) orelse return false;
    return api.stringToNumber(L, s);
}

/// Neither operand converted: hand over to the second operand's metamethod, or
/// fail the way `lstrlib.c`'s `trymt` does
fn tryMt(L: *state.LuaState, comptime mtname: []const u8) !i32 {
    api.setTop(L, 2) catch {}; // back to the original arguments
    if (api.type_(L, 2) == .string or !(try api.getMetafield(L, 2, mtname))) {
        return aux.err(L, "attempt to {s} a '{s}' with a '{s}'", .{
            mtname[2..],
            api.typeName(L, api.type_(L, -2)),
            api.typeName(L, api.type_(L, -1)),
        });
    }
    try api.insert(L, -3); // the metamethod goes below the arguments
    try api.call(L, 2, 1);
    return 1;
}

fn arith(L: *state.LuaState, op: api.ArithOp, comptime mtname: []const u8) !i32 {
    if ((try toNum(L, 1)) and (try toNum(L, 2))) {
        try api.arith(L, op); // the result replaces the two numbers
        return 1;
    }
    return tryMt(L, mtname);
}

fn arith_add(L: *state.LuaState) !i32 {
    return arith(L, .ADD, "__add");
}
fn arith_sub(L: *state.LuaState) !i32 {
    return arith(L, .SUB, "__sub");
}
fn arith_mul(L: *state.LuaState) !i32 {
    return arith(L, .MUL, "__mul");
}
fn arith_mod(L: *state.LuaState) !i32 {
    return arith(L, .MOD, "__mod");
}
fn arith_pow(L: *state.LuaState) !i32 {
    return arith(L, .POW, "__pow");
}
fn arith_div(L: *state.LuaState) !i32 {
    return arith(L, .DIV, "__div");
}
fn arith_idiv(L: *state.LuaState) !i32 {
    return arith(L, .IDIV, "__idiv");
}
fn arith_unm(L: *state.LuaState) !i32 {
    return arith(L, .UNM, "__unm");
}

// Simple functions

fn str_len(L: *state.LuaState) !i32 {
    const s = try api.checkString(L, 1);
    try api.pushInteger(L, @intCast(s.len));
    return 1;
}

fn str_sub(L: *state.LuaState) !i32 {
    const s = try api.checkString(L, 1);
    const start = aux.strIndex(try api.checkInteger(L, 2), s.len);
    const end = endIndex(try aux.optInteger(L, 3, -1), s.len);

    if (start < end) {
        try api.pushString(L, s[start..end]);
    } else {
        try api.pushString(L, "");
    }
    return 1;
}

/// Exclusive end offset for a Lua range endpoint, which unlike a start
/// position is clamped at both ends rather than wrapping (getendpos)
fn endIndex(pos: i64, len: usize) usize {
    if (pos > @as(i64, @intCast(len))) return len;
    if (pos >= 0) return @intCast(pos);
    const back: u64 = @bitCast(-%pos); // minint-safe
    if (back > len) return 0;
    return len - back + 1;
}

fn str_reverse(L: *state.LuaState) !i32 {
    const s = try api.checkString(L, 1);
    var b = aux.Buffer.init(L);
    defer b.deinit();

    var i = s.len;
    while (i > 0) {
        i -= 1;
        try b.addChar(s[i]);
    }
    try b.pushResult();
    return 1;
}

fn str_lower(L: *state.LuaState) !i32 {
    return mapCase(L, std.ascii.toLower);
}

fn str_upper(L: *state.LuaState) !i32 {
    return mapCase(L, std.ascii.toUpper);
}

fn mapCase(L: *state.LuaState, comptime f: fn (u8) u8) !i32 {
    const s = try api.checkString(L, 1);
    var b = aux.Buffer.init(L);
    defer b.deinit();

    for (s) |c| try b.addChar(f(c));
    try b.pushResult();
    return 1;
}

fn str_rep(L: *state.LuaState) !i32 {
    const s = try api.checkString(L, 1);
    const n = try api.checkInteger(L, 2);
    const sep = try aux.optString(L, 3, "");

    if (n <= 0) {
        try api.pushString(L, "");
        return 1;
    }
    const count: usize = @intCast(n);
    // lstrlib.c limits a string to MAXSIZE (INT_MAX where size_t is wider
    // than int, which it is everywhere Zig runs); the check also guards the
    // multiplication before it can wrap into a small allocation
    const max_size: usize = std.math.maxInt(i32);
    if (s.len + sep.len > max_size / count) {
        return aux.err(L, "resulting string too large", .{});
    }

    var b = aux.Buffer.init(L);
    defer b.deinit();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try b.addString(sep);
        try b.addString(s);
    }
    try b.pushResult();
    return 1;
}

fn str_byte(L: *state.LuaState) !i32 {
    const s = try api.checkString(L, 1);
    const pi = try aux.optInteger(L, 2, 1);
    const start = aux.strIndex(pi, s.len);
    const end = endIndex(try aux.optInteger(L, 3, pi), s.len);

    if (start >= end) return 0;
    const n = end - start;
    if (!api.checkStack(L, @intCast(n))) return aux.err(L, "string slice too long", .{});

    for (s[start..end]) |c| try api.pushInteger(L, c);
    return @intCast(n);
}

fn str_char(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    var b = aux.Buffer.init(L);
    defer b.deinit();

    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        const c = try api.checkInteger(L, i);
        try aux.argCheck(L, c >= 0 and c <= 255, i, "value out of range");
        try b.addChar(@intCast(c));
    }
    try b.pushResult();
    return 1;
}

/// string.dump(function [, strip])
fn str_dump(L: *state.LuaState) !i32 {
    const strip = api.toBoolean(L, 2);
    try api.checkType(L, 1, .function);
    api.setTop(L, 1) catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(L.allocator);
    api.dump(L, dump_module.appendWriter, @ptrCast(&out), strip) catch |err| switch (err) {
        error.NotLuaFunction => return aux.err(L, "unable to dump given function", .{}),
        else => return err,
    };
    try api.pushString(L, out.items);
    return 1;
}

// Pattern matching (lstrlib.c's MatchState and friends)

const Capture = struct {
    init: usize,
    len: isize,
};

const MatchState = struct {
    L: *state.LuaState,
    src: []const u8,
    pat: []const u8,
    level: u32 = 0,
    matchdepth: i32 = MAXCCALLS,
    capture: [MAXCAPTURES]Capture = undefined,

    /// Matching can fail with a Lua error (malformed pattern, too complex) or
    /// an allocation failure while pushing captures
    const Error = anyerror;

    fn reprep(self: *MatchState) void {
        self.matchdepth = MAXCCALLS;
        self.level = 0;
    }

    fn fail(self: *MatchState, comptime fmt: []const u8, args: anytype) Error {
        return aux.err(self.L, fmt, args);
    }

    /// Index of the capture the next ')' closes (capture_to_close)
    fn captureToClose(self: *MatchState) Error!u32 {
        var level = self.level;
        while (level > 0) {
            level -= 1;
            if (self.capture[level].len == CAP_UNFINISHED) return level;
        }
        return self.fail("invalid pattern capture", .{});
    }

    fn checkCapture(self: *MatchState, c: u8) Error!u32 {
        const l = @as(i32, c) - '1';
        if (l < 0 or l >= self.level or self.capture[@intCast(l)].len == CAP_UNFINISHED) {
            return self.fail("invalid capture index %{d}", .{l + 1});
        }
        return @intCast(l);
    }

    /// Offset just past the character class starting at `p` (classend)
    fn classEnd(self: *MatchState, p: usize) Error!usize {
        var i = p;
        const c = self.pat[i];
        i += 1;
        switch (c) {
            L_ESC => {
                if (i == self.pat.len) return self.fail("malformed pattern (ends with '%')", .{});
                return i + 1;
            },
            '[' => {
                if (i < self.pat.len and self.pat[i] == '^') i += 1;
                // The character right after '[' is always consumed before
                // looking for the closing bracket, which is what lets "[]]"
                // treat its first ']' as a literal
                while (true) {
                    if (i >= self.pat.len) return self.fail("malformed pattern (missing ']')", .{});
                    const cc = self.pat[i];
                    i += 1;
                    if (cc == L_ESC and i < self.pat.len) i += 1;
                    if (i < self.pat.len and self.pat[i] == ']') break;
                }
                return i + 1;
            },
            else => return i,
        }
    }

    fn singleMatch(self: *MatchState, s: usize, p: usize, ep: usize) bool {
        if (s >= self.src.len) return false;
        const c = self.src[s];
        return switch (self.pat[p]) {
            '.' => true,
            L_ESC => matchClass(c, self.pat[p + 1]),
            '[' => self.matchBracketClass(c, p, ep - 1),
            else => self.pat[p] == c,
        };
    }

    fn matchBracketClass(self: *MatchState, c: u8, pstart: usize, ec: usize) bool {
        var sig = true;
        var p = pstart;
        if (self.pat[p + 1] == '^') {
            sig = false;
            p += 1;
        }
        p += 1;
        while (p < ec) : (p += 1) {
            if (self.pat[p] == L_ESC) {
                p += 1;
                if (matchClass(c, self.pat[p])) return sig;
            } else if (p + 2 < ec and self.pat[p + 1] == '-') {
                if (self.pat[p] <= c and c <= self.pat[p + 2]) return sig;
                p += 2;
            } else if (self.pat[p] == c) return sig;
        }
        return !sig;
    }

    fn matchBalance(self: *MatchState, s: usize, p: usize) Error!?usize {
        if (p >= self.pat.len - 1) {
            return self.fail("malformed pattern (missing arguments to '%b')", .{});
        }
        if (s >= self.src.len or self.src[s] != self.pat[p]) return null;

        const b = self.pat[p];
        const e = self.pat[p + 1];
        var cont: i32 = 1;
        var i = s + 1;
        while (i < self.src.len) : (i += 1) {
            if (self.src[i] == e) {
                cont -= 1;
                if (cont == 0) return i + 1;
            } else if (self.src[i] == b) cont += 1;
        }
        return null;
    }

    fn maxExpand(self: *MatchState, s: usize, p: usize, ep: usize) Error!?usize {
        var i: usize = 0;
        while (self.singleMatch(s + i, p, ep)) i += 1;
        while (true) {
            if (try self.match(s + i, ep + 1)) |res| return res;
            if (i == 0) return null;
            i -= 1;
        }
    }

    fn minExpand(self: *MatchState, sstart: usize, p: usize, ep: usize) Error!?usize {
        var s = sstart;
        while (true) {
            if (try self.match(s, ep + 1)) |res| return res;
            if (self.singleMatch(s, p, ep)) s += 1 else return null;
        }
    }

    fn startCapture(self: *MatchState, s: usize, p: usize, what: isize) Error!?usize {
        if (self.level >= MAXCAPTURES) return self.fail("too many captures", .{});
        self.capture[self.level] = .{ .init = s, .len = what };
        self.level += 1;
        const res = try self.match(s, p);
        if (res == null) self.level -= 1; // undo capture
        return res;
    }

    fn endCapture(self: *MatchState, s: usize, p: usize) Error!?usize {
        const l = try self.captureToClose();
        self.capture[l].len = @intCast(s - self.capture[l].init);
        const res = try self.match(s, p);
        if (res == null) self.capture[l].len = CAP_UNFINISHED;
        return res;
    }

    fn matchCapture(self: *MatchState, s: usize, c: u8) Error!?usize {
        const l = try self.checkCapture(c);
        const len: usize = @intCast(self.capture[l].len);
        const init = self.capture[l].init;
        if (self.src.len - s >= len and
            std.mem.eql(u8, self.src[init .. init + len], self.src[s .. s + len]))
        {
            return s + len;
        }
        return null;
    }

    /// Match `pat[p..]` against `src[s..]`, returning the end offset of the
    /// match. The C original uses `goto init` for tail recursion; the loop
    /// here plays the same role.
    fn match(self: *MatchState, s_in: usize, p_in: usize) Error!?usize {
        self.matchdepth -= 1;
        if (self.matchdepth == 0) return self.fail("pattern too complex", .{});
        defer self.matchdepth += 1;

        var s = s_in;
        var p = p_in;
        while (p != self.pat.len) {
            switch (self.pat[p]) {
                '(' => {
                    if (p + 1 < self.pat.len and self.pat[p + 1] == ')') {
                        return self.startCapture(s, p + 2, CAP_POSITION);
                    }
                    return self.startCapture(s, p + 1, CAP_UNFINISHED);
                },
                ')' => return self.endCapture(s, p + 1),
                '$' => {
                    if (p + 1 == self.pat.len) {
                        return if (s == self.src.len) s else null;
                    }
                    // Not the last character, so it is an ordinary '$'
                    switch (try self.matchDefault(&s, &p)) {
                        .done => |r| return r,
                        .again => continue,
                    }
                },
                L_ESC => {
                    if (p + 1 < self.pat.len) {
                        switch (self.pat[p + 1]) {
                            'b' => {
                                const res = try self.matchBalance(s, p + 2);
                                if (res) |r| {
                                    s = r;
                                    p += 4;
                                    continue;
                                }
                                return null;
                            },
                            'f' => {
                                p += 2;
                                if (p >= self.pat.len or self.pat[p] != '[') {
                                    return self.fail("missing '[' after '%f' in pattern", .{});
                                }
                                const ep = try self.classEnd(p);
                                const previous: u8 = if (s == 0) 0 else self.src[s - 1];
                                const current: u8 = if (s < self.src.len) self.src[s] else 0;
                                if (!self.matchBracketClass(previous, p, ep - 1) and
                                    self.matchBracketClass(current, p, ep - 1))
                                {
                                    p = ep;
                                    continue;
                                }
                                return null;
                            },
                            '0'...'9' => {
                                const res = try self.matchCapture(s, self.pat[p + 1]);
                                if (res) |r| {
                                    s = r;
                                    p += 2;
                                    continue;
                                }
                                return null;
                            },
                            else => {},
                        }
                    }
                    switch (try self.matchDefault(&s, &p)) {
                        .done => |r| return r,
                        .again => continue,
                    }
                },
                else => {
                    switch (try self.matchDefault(&s, &p)) {
                        .done => |r| return r,
                        .again => continue,
                    }
                },
            }
        }
        return s;
    }

    /// Outcome of one `dflt` step: either the match resolves here, or `s`/`p`
    /// were advanced and the caller should keep looping. The C original
    /// expresses the second case with `goto init`.
    const Step = union(enum) {
        done: ?usize,
        again,
    };

    /// The `dflt` label of the C `match`: one pattern class plus its optional
    /// `*` / `+` / `-` / `?` suffix
    fn matchDefault(self: *MatchState, s: *usize, p: *usize) Error!Step {
        const ep = try self.classEnd(p.*);
        const suffix: u8 = if (ep < self.pat.len) self.pat[ep] else 0;

        if (!self.singleMatch(s.*, p.*, ep)) {
            // Suffixes that accept zero repetitions can skip the class
            if (suffix == '*' or suffix == '?' or suffix == '-') {
                p.* = ep + 1;
                return .again;
            }
            return .{ .done = null };
        }

        switch (suffix) {
            '?' => {
                if (try self.match(s.* + 1, ep + 1)) |res| return .{ .done = res };
                p.* = ep + 1;
                return .again;
            },
            '+' => return .{ .done = try self.maxExpand(s.* + 1, p.*, ep) },
            '*' => return .{ .done = try self.maxExpand(s.*, p.*, ep) },
            '-' => return .{ .done = try self.minExpand(s.*, p.*, ep) },
            else => {
                s.* += 1;
                p.* = ep;
                return .again;
            },
        }
    }

    /// Push capture `i`, or the whole match when there are no captures
    /// (push_onecapture). Returns false when a position capture was pushed.
    fn pushOneCapture(self: *MatchState, i: u32, s: usize, e: usize) Error!void {
        if (i >= self.level) {
            if (i != 0) return self.fail("invalid capture index %{d}", .{i + 1});
            try api.pushString(self.L, self.src[s..e]);
            return;
        }
        const l = self.capture[i].len;
        if (l == CAP_UNFINISHED) return self.fail("unfinished capture", .{});
        if (l == CAP_POSITION) {
            try api.pushInteger(self.L, @intCast(self.capture[i].init + 1));
            return;
        }
        const init = self.capture[i].init;
        try api.pushString(self.L, self.src[init .. init + @as(usize, @intCast(l))]);
    }

    /// Push every capture, or the whole match when the pattern had none
    fn pushCaptures(self: *MatchState, s: ?usize, e: usize) Error!i32 {
        const nlevels: u32 = if (self.level == 0 and s != null) 1 else self.level;
        if (!api.checkStack(self.L, @intCast(nlevels))) {
            return self.fail("too many captures", .{});
        }
        var i: u32 = 0;
        while (i < nlevels) : (i += 1) {
            try self.pushOneCapture(i, s orelse 0, e);
        }
        return @intCast(nlevels);
    }
};

fn matchClass(c: u8, cl: u8) bool {
    const res = switch (std.ascii.toLower(cl)) {
        'a' => std.ascii.isAlphabetic(c),
        'c' => std.ascii.isControl(c),
        'd' => std.ascii.isDigit(c),
        'g' => c > 32 and c < 127,
        'l' => std.ascii.isLower(c),
        'p' => (c > 32 and c < 127) and !std.ascii.isAlphanumeric(c),
        's' => std.ascii.isWhitespace(c),
        'u' => std.ascii.isUpper(c),
        'w' => std.ascii.isAlphanumeric(c),
        'x' => std.ascii.isHex(c),
        'z' => c == 0, // deprecated, still accepted
        else => return cl == c,
    };
    return if (std.ascii.isLower(cl)) res else !res;
}

/// Does the pattern contain no special characters, so a plain search is enough?
fn noSpecials(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, SPECIALS) == null;
}

fn str_find(L: *state.LuaState) !i32 {
    return findAux(L, true);
}

fn str_match(L: *state.LuaState) !i32 {
    return findAux(L, false);
}

fn findAux(L: *state.LuaState, find: bool) !i32 {
    const s = try api.checkString(L, 1);
    const p = try api.checkString(L, 2);
    const init = aux.strStart(try aux.optInteger(L, 3, 1), s.len);

    if (init > s.len) { // start after the end: cannot find anything
        try api.pushNil(L);
        return 1;
    }

    if (find and (api.toBoolean(L, 4) or noSpecials(p))) {
        if (std.mem.indexOf(u8, s[init..], p)) |off| {
            try api.pushInteger(L, @intCast(init + off + 1));
            try api.pushInteger(L, @intCast(init + off + p.len));
            return 2;
        }
        try api.pushNil(L);
        return 1;
    }

    const anchor = p.len > 0 and p[0] == '^';
    const pat = if (anchor) p[1..] else p;

    var ms = MatchState{ .L = L, .src = s, .pat = pat };
    var s1 = init;
    while (true) {
        ms.reprep();
        if (try ms.match(s1, 0)) |e| {
            if (find) {
                try api.pushInteger(L, @intCast(s1 + 1));
                try api.pushInteger(L, @intCast(e));
                return (try ms.pushCaptures(null, 0)) + 2;
            }
            return ms.pushCaptures(s1, e);
        }
        if (s1 >= s.len or anchor) break;
        s1 += 1;
    }

    try api.pushNil(L);
    return 1;
}

// gmatch keeps its position between calls in the upvalues of a C closure:
// 1 = subject, 2 = pattern, 3 = current offset, 4 = end of the last match
// (or -1 when there has been none). Keeping the strings there also keeps
// them alive for the collector, which is why the C version does the same.
const GM_SRC = 1;
const GM_PAT = 2;
const GM_POS = 3;
const GM_LAST = 4;

fn str_gmatch(L: *state.LuaState) !i32 {
    const s = try api.checkString(L, 1);
    _ = try api.checkString(L, 2);
    const init = aux.strStart(try aux.optInteger(L, 3, 1), s.len);

    try api.pushValueAt(L, 1);
    try api.pushValueAt(L, 2);
    try api.pushInteger(L, @intCast(@min(init, s.len + 1)));
    try api.pushInteger(L, -1);
    try api.pushCClosure(L, gmatchAux, 4);
    return 1;
}

fn gmatchAux(L: *state.LuaState) !i32 {
    const s = api.toString(L, api.upvalueIndex(GM_SRC)).?;
    const p = api.toString(L, api.upvalueIndex(GM_PAT)).?;
    const pos: usize = @intCast(api.toInteger(L, api.upvalueIndex(GM_POS)).?);
    const last = api.toInteger(L, api.upvalueIndex(GM_LAST)).?;

    var ms = MatchState{ .L = L, .src = s, .pat = p };
    var src = pos;
    while (src <= s.len) : (src += 1) {
        ms.reprep();
        if (try ms.match(src, 0)) |e| {
            // Refusing a match that ends where the last one did is what stops
            // an empty-matching pattern from spinning forever
            if (@as(i64, @intCast(e)) == last) continue;

            try api.pushInteger(L, @intCast(e));
            try api.replace(L, api.upvalueIndex(GM_POS));
            try api.pushInteger(L, @intCast(e));
            try api.replace(L, api.upvalueIndex(GM_LAST));
            return ms.pushCaptures(src, e);
        }
    }
    return 0;
}

fn str_gsub(L: *state.LuaState) !i32 {
    const src = try api.checkString(L, 1);
    const p = try api.checkString(L, 2);
    const tr = api.type_(L, 3);
    const max_s = try aux.optInteger(L, 4, @as(i64, @intCast(src.len)) + 1);

    if (tr != .number and tr != .string and tr != .function and tr != .table) {
        return aux.typeError(L, 3, "string/function/table");
    }

    const anchor = p.len > 0 and p[0] == '^';
    const pat = if (anchor) p[1..] else p;

    var b = aux.Buffer.init(L);
    defer b.deinit();

    var ms = MatchState{ .L = L, .src = src, .pat = pat };
    var s: usize = 0;
    var last: i64 = -1;
    var n: i64 = 0;
    var changed = false;

    while (n < max_s) {
        ms.reprep();
        const matched = try ms.match(s, 0);
        if (matched != null and @as(i64, @intCast(matched.?)) != last) {
            const e = matched.?;
            n += 1;
            changed = (try addValue(L, &ms, &b, s, e, tr)) or changed;
            s = e;
            last = @intCast(e);
        } else if (s < src.len) {
            try b.addChar(src[s]);
            s += 1;
        } else break;
        if (anchor) break;
    }

    if (!changed) {
        try api.pushValueAt(L, 1);
    } else {
        try b.addString(src[s..]);
        try b.pushResult();
    }
    try api.pushInteger(L, n);
    return 2;
}

/// Append the replacement for one match; returns whether it changed the text
fn addValue(
    L: *state.LuaState,
    ms: *MatchState,
    b: *aux.Buffer,
    s: usize,
    e: usize,
    tr: value.ValueType,
) !bool {
    switch (tr) {
        .function => {
            try api.pushValueAt(L, 3);
            const n = try ms.pushCaptures(s, e);
            try api.call(L, n, 1);
        },
        .table => {
            try ms.pushOneCapture(0, s, e);
            try api.getTable(L, 3);
        },
        else => {
            try addReplacementString(L, ms, b, s, e);
            return true;
        },
    }

    // A function or table yielding nil/false leaves the original text alone
    if (!api.toBoolean(L, -1)) {
        api.pop(L, 1);
        try b.addString(ms.src[s..e]);
        return false;
    }
    if (!api.isString(L, -1)) {
        return aux.err(L, "invalid replacement value (a {s})", .{api.typeName(L, api.type_(L, -1))});
    }
    try b.addValue(-1);
    api.pop(L, 1);
    return true;
}

/// Expand `%0`-`%9` and `%%` in a string replacement (add_s)
fn addReplacementString(
    L: *state.LuaState,
    ms: *MatchState,
    b: *aux.Buffer,
    s: usize,
    e: usize,
) !void {
    const news = (try api.toStringCoerce(L, 3)).?;
    var i: usize = 0;
    while (i < news.len) {
        const c = news[i];
        if (c != L_ESC) {
            try b.addChar(c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= news.len) return aux.err(L, "invalid use of '%' in replacement string", .{});
        const d = news[i];
        if (d == L_ESC) {
            try b.addChar(L_ESC);
        } else if (d == '0') {
            try b.addString(ms.src[s..e]);
        } else if (std.ascii.isDigit(d)) {
            try ms.pushOneCapture(d - '1', s, e);
            try b.addValue(-1);
            api.pop(L, 1);
        } else {
            return aux.err(L, "invalid use of '%' in replacement string", .{});
        }
        i += 1;
    }
}

// string.format (str_format)

/// Lua formats numbers by handing the directive to the C library, so `%g`
/// rounding, `%a` output and the exponent width all match the platform exactly.
/// We link libc already, so do the same rather than reimplementing printf.
extern "c" fn snprintf(noalias buf: [*]u8, size: usize, noalias fmt: [*:0]const u8, ...) c_int;

/// Longest directive we accept, matching Lua's MAX_FORMAT budget
const MAX_FORMAT = 32;

fn str_format(L: *state.LuaState) !i32 {
    const fmt = try api.checkString(L, 1);
    const top = api.getTop(L);

    var b = aux.Buffer.init(L);
    defer b.deinit();

    var arg: i32 = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try b.addChar(fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            try b.addChar('%');
            i += 1;
            continue;
        }

        // The argument is claimed before the specification is read, so a
        // missing one is reported first (str_format's `++arg > top`)
        arg += 1;
        if (arg > top) return aux.argError(L, arg, "no value");

        // Span flags, width and precision ('0' is included as a flag) up to
        // the conversion character; each conversion validates its own part
        // of it afterwards (getformat)
        const spec_start = i;
        while (i < fmt.len and std.mem.indexOfScalar(u8, "-+#0 123456789.", fmt[i]) != null) i += 1;
        // The format still needs room for '%', a length modifier and NUL
        if (i - spec_start + 1 >= MAX_FORMAT - 10) return aux.err(L, "invalid format (too long)", .{});
        const spec = fmt[spec_start..i];
        if (i >= fmt.len) return aux.err(L, "invalid conversion '%{s}' to 'format'", .{spec});
        const conv = fmt[i];
        i += 1;

        try formatOne(L, &b, conv, spec, arg);
    }

    try b.pushResult();
    return 1;
}

// The flags each conversion accepts (L_FMTFLAGS*)
const FLAGS_F = "-+#0 "; // floats
const FLAGS_X = "-#0"; // hexadecimal and octal
const FLAGS_I = "-+0 "; // signed integers
const FLAGS_U = "-0"; // unsigned integers
const FLAGS_C = "-"; // characters, pointers and strings

/// Skip up to two digits (get2digits)
fn skip2Digits(s: []const u8, start: usize) usize {
    var i = start;
    if (i < s.len and std.ascii.isDigit(s[i])) {
        i += 1;
        if (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    return i;
}

/// Check a conversion specification (checkformat): only `flags`, a width of
/// at most two digits not starting with '0', and, where allowed, a
/// precision of at most two digits
fn checkFormat(L: *state.LuaState, spec: []const u8, conv: u8, flags: []const u8, precision: bool) !void {
    var i: usize = 0;
    while (i < spec.len and std.mem.indexOfScalar(u8, flags, spec[i]) != null) i += 1; // skip flags
    if (i < spec.len and spec[i] != '0') { // a width cannot start with '0'
        i = skip2Digits(spec, i); // skip width
        if (i < spec.len and spec[i] == '.' and precision) {
            i = skip2Digits(spec, i + 1); // skip precision
        }
    }
    if (i != spec.len) return aux.err(L, "invalid conversion specification: '%{s}{c}'", .{ spec, conv });
}

fn formatOne(
    L: *state.LuaState,
    b: *aux.Buffer,
    conv: u8,
    spec: []const u8,
    arg: i32,
) !void {
    var out: [512]u8 = undefined;
    var form: [MAX_FORMAT]u8 = undefined;

    switch (conv) {
        'd', 'i' => {
            try checkFormat(L, spec, conv, FLAGS_I, true);
            const n = try api.checkInteger(L, arg);
            const f = try cSpec(&form, spec, "ll", conv);
            try b.addString(cFormat(&out, f, n));
        },
        'u', 'o', 'x', 'X' => {
            try checkFormat(L, spec, conv, if (conv == 'u') FLAGS_U else FLAGS_X, true);
            const n = try api.checkInteger(L, arg);
            const f = try cSpec(&form, spec, "ll", conv);
            try b.addString(cFormat(&out, f, @as(u64, @bitCast(n))));
        },
        'c' => {
            try checkFormat(L, spec, conv, FLAGS_C, false);
            const n = try api.checkInteger(L, arg);
            const f = try cSpec(&form, spec, "", conv);
            try b.addString(cFormat(&out, f, @as(c_int, @truncate(n))));
        },
        'f', 'e', 'E', 'g', 'G', 'a', 'A' => { // no 'F': useless and not in C89
            try checkFormat(L, spec, conv, FLAGS_F, true);
            const n = try api.checkNumber(L, arg);
            const f = try cSpec(&form, spec, "", conv);
            try b.addString(cFormat(&out, f, n));
        },
        's' => {
            const s = try tostringArg(L, arg);
            if (spec.len == 0) { // no modifiers: keep the entire string
                try b.addString(s);
                return;
            }
            try checkFormat(L, spec, conv, FLAGS_C, true);
            // snprintf stops at a NUL, so the string may not contain one
            if (std.mem.indexOfScalar(u8, s, 0) != null) return api.argError(L, arg, "string contains zeros");
            if (std.mem.indexOfScalar(u8, spec, '.') == null and s.len >= 100) {
                // No precision and the string is too long to be formatted
                try b.addString(s);
                return;
            }
            const f = try cSpec(&form, spec, "", 's');
            // snprintf needs a terminated string for %s
            var tmp: [512]u8 = undefined;
            const cut = @min(s.len, tmp.len - 1);
            @memcpy(tmp[0..cut], s[0..cut]);
            tmp[cut] = 0;
            try b.addString(cFormat(&out, f, @as([*:0]const u8, @ptrCast(&tmp))));
        },
        'p' => {
            try checkFormat(L, spec, conv, FLAGS_C, false);
            const f = try cSpec(&form, spec, "", 'p');
            if (api.toPointer(L, arg)) |p| {
                try b.addString(cFormat(&out, f, p));
            } else {
                // Avoid calling printf with a null pointer: format the text
                // "(null)" as a string instead, as lstrlib.c does
                const fs = try cSpec(&form, spec, "", 's');
                try b.addString(cFormat(&out, fs, @as([*:0]const u8, "(null)")));
            }
        },
        'q' => {
            if (spec.len != 0) {
                return aux.err(L, "specifier '%q' cannot have modifiers", .{});
            }
            try addQuoted(L, b, arg);
        },
        else => {
            // The reference prints the specification as a C string: a NUL
            // conversion character ends it
            var formbuf: [MAX_FORMAT]u8 = undefined;
            @memcpy(formbuf[0..spec.len], spec);
            formbuf[spec.len] = conv;
            return aux.err(L, "invalid conversion '%{s}' to 'format'", .{cString(formbuf[0 .. spec.len + 1])});
        },
    }
}

/// Rebuild the directive as a NUL-terminated C format string, inserting the
/// length modifier an integer conversion needs (addlenmod)
fn cSpec(buf: []u8, spec: []const u8, lenmod: []const u8, conv: u8) ![:0]const u8 {
    var n: usize = 0;
    buf[n] = '%';
    n += 1;
    @memcpy(buf[n .. n + spec.len], spec);
    n += spec.len;
    @memcpy(buf[n .. n + lenmod.len], lenmod);
    n += lenmod.len;
    buf[n] = conv;
    n += 1;
    buf[n] = 0;
    return buf[0..n :0];
}

fn cFormat(out: []u8, form: [:0]const u8, arg: anytype) []const u8 {
    const n = snprintf(out.ptr, out.len, form.ptr, arg);
    if (n < 0) return "";
    return out[0..@min(@as(usize, @intCast(n)), out.len - 1)];
}

/// The value at `arg` as a string, honouring `__tostring` (luaL_tolstring)
fn tostringArg(L: *state.LuaState, arg: i32) ![]const u8 {
    return aux.toLString(L, arg);
}

/// %q: emit a literal the lexer can read back (addliteral / addquoted)
fn addQuoted(L: *state.LuaState, b: *aux.Buffer, arg: i32) !void {
    switch (api.type_(L, arg)) {
        .string => {
            const s = api.toString(L, arg).?;
            try b.addChar('"');
            for (s, 0..) |c, i| {
                switch (c) {
                    // A newline is escaped as a backslash followed by a real
                    // newline, which is what the lexer reads back (addquoted)
                    '"', '\\', '\n' => {
                        try b.addChar('\\');
                        try b.addChar(c);
                    },
                    else => {
                        if (c == 0 or std.ascii.isControl(c)) {
                            // A decimal escape, padded to three digits when a
                            // digit follows so the lexer does not absorb it
                            const digit_follows = i + 1 < s.len and std.ascii.isDigit(s[i + 1]);
                            if (digit_follows) try b.addFmt("\\{d:0>3}", .{c}) else try b.addFmt("\\{d}", .{c});
                        } else {
                            try b.addChar(c);
                        }
                    },
                }
            }
            try b.addChar('"');
        },
        .number => {
            if (api.isInteger(L, arg)) {
                const n = api.toInteger(L, arg).?;
                if (n == std.math.minInt(i64)) {
                    // The corner case: written in decimal it would read back
                    // as a float, so use hexadecimal
                    try b.addFmt("0x{x}", .{@as(u64, @bitCast(n))});
                } else {
                    try b.addFmt("{d}", .{n});
                }
            } else {
                // A float must round-trip exactly, so use C's hex notation
                // (quotefloat)
                const n = api.toNumber(L, arg).?;
                if (std.math.isInf(n)) {
                    try b.addString(if (n < 0) "-1e9999" else "1e9999");
                } else if (std.math.isNan(n)) {
                    try b.addString("(0/0)");
                } else {
                    var out: [64]u8 = undefined;
                    const hex = cFormat(&out, "%a", n);
                    // quotefloat: the literal must use '.' whatever the locale's point
                    const dp = numeral.localeDecimalPoint();
                    if (dp != '.') {
                        if (std.mem.indexOfScalar(u8, hex, dp)) |i| out[i] = '.';
                    }
                    try b.addString(hex);
                }
            }
        },
        .nil => try b.addString("nil"),
        .boolean => try b.addString(if (api.toBoolean(L, arg)) "true" else "false"),
        else => return aux.err(L, "value has no literal form", .{}),
    }
}

// PACK / UNPACK
//
// Port of lstrlib.c's pack/unpack. The format language, alignment, overflow
// checks and error strings have to match the reference: tpack.lua finds
// substrings in the messages and compares packed bytes.

const MAXINTSIZE = 16;
const NB = 8;
const MC: u8 = 0xFF;
const SZINT = @sizeOf(i64);
const PACKPAD: u8 = 0x00;
/// Match this system's Lua: packsize rejects a result above INT_MAX.
const PACK_MAXSIZE: usize = std.math.maxInt(i32);

const native_little = builtin.cpu.arch.endian() == .little;

/// Native max alignment: offsetof(struct { char c; union { LUAI_MAXALIGN } u }, u)
const NativeAlign = extern struct {
    c: u8,
    u: extern union {
        n: f64,
        s: ?*anyopaque,
        i: i64,
        l: c_long,
    },
};
const native_maxalign: i32 = @intCast(@offsetOf(NativeAlign, "u"));

const Header = struct {
    L: *state.LuaState,
    islittle: bool,
    maxalign: i32,
};

const KOption = enum {
    int,
    uint,
    float,
    number,
    double,
    char,
    string,
    zstr,
    padding,
    paddalign,
    nop,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn getnum(fmt: []const u8, i: *usize, df: i32) i32 {
    if (i.* >= fmt.len or !isDigit(fmt[i.*])) return df;
    var a: i32 = 0;
    const lim = @divTrunc(std.math.maxInt(i32) - 9, 10);
    while (i.* < fmt.len and isDigit(fmt[i.*]) and a <= lim) {
        a = a * 10 + @as(i32, fmt[i.*] - '0');
        i.* += 1;
    }
    return a;
}

fn getnumlimit(h: *Header, fmt: []const u8, i: *usize, df: i32) !i32 {
    const sz = getnum(fmt, i, df);
    if (sz > MAXINTSIZE or sz <= 0)
        return aux.err(h.L, "integral size ({d}) out of limits [1,{d}]", .{ sz, MAXINTSIZE });
    return sz;
}

fn getoption(h: *Header, fmt: []const u8, i: *usize, size: *i32) !KOption {
    size.* = 0;
    const opt = fmt[i.*];
    i.* += 1;
    switch (opt) {
        'b' => {
            size.* = 1;
            return .int;
        },
        'B' => {
            size.* = 1;
            return .uint;
        },
        'h' => {
            size.* = @sizeOf(c_short);
            return .int;
        },
        'H' => {
            size.* = @sizeOf(c_short);
            return .uint;
        },
        'l' => {
            size.* = @sizeOf(c_long);
            return .int;
        },
        'L' => {
            size.* = @sizeOf(c_long);
            return .uint;
        },
        'j' => {
            size.* = SZINT;
            return .int;
        },
        'J' => {
            size.* = SZINT;
            return .uint;
        },
        'T' => {
            size.* = @sizeOf(usize);
            return .uint;
        },
        'f' => {
            size.* = @sizeOf(f32);
            return .float;
        },
        'n' => {
            size.* = @sizeOf(f64);
            return .number;
        },
        'd' => {
            size.* = @sizeOf(f64);
            return .double;
        },
        'i' => {
            size.* = try getnumlimit(h, fmt, i, @sizeOf(c_int));
            return .int;
        },
        'I' => {
            size.* = try getnumlimit(h, fmt, i, @sizeOf(c_int));
            return .uint;
        },
        's' => {
            size.* = try getnumlimit(h, fmt, i, @sizeOf(usize));
            return .string;
        },
        'c' => {
            size.* = getnum(fmt, i, -1);
            if (size.* == -1) return aux.err(h.L, "missing size for format option 'c'", .{});
            return .char;
        },
        'z' => return .zstr,
        'x' => {
            size.* = 1;
            return .padding;
        },
        'X' => return .paddalign,
        ' ' => {},
        '<' => {
            h.islittle = true;
        },
        '>' => {
            h.islittle = false;
        },
        '=' => {
            h.islittle = native_little;
        },
        '!' => {
            h.maxalign = try getnumlimit(h, fmt, i, native_maxalign);
        },
        else => return aux.err(h.L, "invalid format option '{c}'", .{opt}),
    }
    return .nop;
}

fn getdetails(h: *Header, totalsize: usize, fmt: []const u8, i: *usize, psize: *i32, ntoalign: *i32) !KOption {
    const opt = try getoption(h, fmt, i, psize);
    var al = psize.*;
    if (opt == .paddalign) {
        if (i.* >= fmt.len) return api.argError(h.L, 1, "invalid next option for option 'X'");
        const next = try getoption(h, fmt, i, &al);
        if (next == .char or al == 0)
            return api.argError(h.L, 1, "invalid next option for option 'X'");
    }
    if (al <= 1 or opt == .char) {
        ntoalign.* = 0;
    } else {
        if (al > h.maxalign) al = h.maxalign;
        if (al & (al - 1) != 0)
            return api.argError(h.L, 1, "format asks for alignment not power of 2");
        const mask: usize = @intCast(al - 1);
        ntoalign.* = @intCast((@as(usize, @intCast(al)) - (totalsize & mask)) & mask);
    }
    return opt;
}

fn packint(b: *aux.Buffer, n: u64, islittle: bool, size: i32, neg: bool) !void {
    const sz: usize = @intCast(size);
    var buf: [MAXINTSIZE]u8 = undefined;
    var val = n;
    buf[if (islittle) @as(usize, 0) else sz - 1] = @truncate(val);
    var i: usize = 1;
    while (i < sz) : (i += 1) {
        val >>= NB;
        buf[if (islittle) i else sz - 1 - i] = @truncate(val);
    }
    if (neg and sz > SZINT) {
        i = SZINT;
        while (i < sz) : (i += 1) {
            buf[if (islittle) i else sz - 1 - i] = MC;
        }
    }
    try b.addString(buf[0..sz]);
}

fn copyWithEndian(dest: []u8, src: []const u8, islittle: bool) void {
    if (islittle == native_little) {
        @memcpy(dest, src);
    } else {
        for (src, 0..) |c, i| dest[dest.len - 1 - i] = c;
    }
}

/// The part of a string before its first NUL: what the reference's C
/// string loops see of a pack format
fn cString(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

fn str_pack(L: *state.LuaState) !i32 {
    const fmt = cString(try api.checkString(L, 1)); // the reference reads the format as a C string
    // str_pack pushes a nil "to separate arguments from string buffer", so
    // the first missing argument reads as nil in its message
    try api.pushNil(L);
    var h = Header{ .L = L, .islittle = native_little, .maxalign = 1 };
    var b = aux.Buffer.init(L);
    defer b.deinit();
    var totalsize: usize = 0;
    var arg: i32 = 1;
    var fi: usize = 0;
    while (fi < fmt.len) {
        var size: i32 = 0;
        var ntoalign: i32 = 0;
        const opt = try getdetails(&h, totalsize, fmt, &fi, &size, &ntoalign);
        totalsize += @as(usize, @intCast(ntoalign)) + @as(usize, @intCast(size));
        while (ntoalign > 0) : (ntoalign -= 1) try b.addChar(PACKPAD);
        arg += 1;
        switch (opt) {
            .int => {
                const n = try api.checkInteger(L, arg);
                if (size < SZINT) {
                    const lim: i64 = @as(i64, 1) << @intCast(size * NB - 1);
                    try aux.argCheck(L, -lim <= n and n < lim, arg, "integer overflow");
                }
                try packint(&b, @bitCast(n), h.islittle, size, n < 0);
            },
            .uint => {
                const n = try api.checkInteger(L, arg);
                if (size < SZINT) {
                    const lim: u64 = @as(u64, 1) << @intCast(size * NB);
                    try aux.argCheck(L, @as(u64, @bitCast(n)) < lim, arg, "unsigned overflow");
                }
                try packint(&b, @bitCast(n), h.islittle, size, false);
            },
            .float => {
                const f: f32 = @floatCast(try api.checkNumber(L, arg));
                var out: [@sizeOf(f32)]u8 = undefined;
                copyWithEndian(&out, std.mem.asBytes(&f), h.islittle);
                try b.addString(&out);
            },
            .number, .double => {
                const f: f64 = try api.checkNumber(L, arg);
                var out: [@sizeOf(f64)]u8 = undefined;
                copyWithEndian(&out, std.mem.asBytes(&f), h.islittle);
                try b.addString(&out);
            },
            .char => {
                const s = try api.checkString(L, arg);
                const want: usize = @intCast(size);
                try aux.argCheck(L, s.len <= want, arg, "string longer than given size");
                try b.addString(s);
                var pad = s.len;
                while (pad < want) : (pad += 1) try b.addChar(PACKPAD);
            },
            .string => {
                const s = try api.checkString(L, arg);
                const usz: usize = @intCast(size);
                if (usz < @sizeOf(usize)) {
                    const lim: usize = @as(usize, 1) << @intCast(size * NB);
                    try aux.argCheck(L, s.len < lim, arg, "string length does not fit in given size");
                }
                try packint(&b, s.len, h.islittle, size, false);
                try b.addString(s);
                totalsize += s.len;
            },
            .zstr => {
                const s = try api.checkString(L, arg);
                try aux.argCheck(L, std.mem.indexOfScalar(u8, s, 0) == null, arg, "string contains zeros");
                try b.addString(s);
                try b.addChar(0);
                totalsize += s.len + 1;
            },
            .padding => try b.addChar(PACKPAD),
            .paddalign, .nop => {},
        }
        switch (opt) {
            .padding, .paddalign, .nop => arg -= 1,
            else => {},
        }
    }
    try b.pushResult();
    return 1;
}

fn str_packsize(L: *state.LuaState) !i32 {
    const fmt = cString(try api.checkString(L, 1)); // the reference reads the format as a C string
    var h = Header{ .L = L, .islittle = native_little, .maxalign = 1 };
    var totalsize: usize = 0;
    var fi: usize = 0;
    while (fi < fmt.len) {
        var size: i32 = 0;
        var ntoalign: i32 = 0;
        const opt = try getdetails(&h, totalsize, fmt, &fi, &size, &ntoalign);
        try aux.argCheck(L, opt != .string and opt != .zstr, 1, "variable-length format");
        const used: usize = @as(usize, @intCast(size)) + @as(usize, @intCast(ntoalign));
        try aux.argCheck(L, used <= PACK_MAXSIZE and totalsize <= PACK_MAXSIZE - used, 1, "format result too large");
        totalsize += used;
    }
    try api.pushInteger(L, @intCast(totalsize));
    return 1;
}

fn unpackint(L: *state.LuaState, str: []const u8, islittle: bool, size: i32, issigned: bool) !i64 {
    const sz: usize = @intCast(size);
    var res: u64 = 0;
    const limit: usize = if (sz <= SZINT) sz else SZINT;
    var i: isize = @intCast(limit - 1);
    while (i >= 0) : (i -= 1) {
        const idx: usize = if (islittle) @intCast(i) else sz - 1 - @as(usize, @intCast(i));
        res <<= NB;
        res |= str[idx];
    }
    if (sz < SZINT) {
        if (issigned) {
            const mask: u64 = @as(u64, 1) << @intCast(size * NB - 1);
            res = (res ^ mask) -% mask;
        }
    } else if (sz > SZINT) {
        const extra: u8 = if (!issigned or @as(i64, @bitCast(res)) >= 0) 0 else MC;
        var j: usize = limit;
        while (j < sz) : (j += 1) {
            const idx: usize = if (islittle) j else sz - 1 - j;
            if (str[idx] != extra)
                return aux.err(L, "{d}-byte integer does not fit into Lua Integer", .{size});
        }
    }
    return @bitCast(res);
}

fn str_unpack(L: *state.LuaState) !i32 {
    const fmt = cString(try api.checkString(L, 1)); // the reference reads the format as a C string
    const data = try api.checkString(L, 2);
    var pos: usize = aux.strStart(try aux.optInteger(L, 3, 1), data.len);
    try aux.argCheck(L, pos <= data.len, 3, "initial position out of string");
    var h = Header{ .L = L, .islittle = native_little, .maxalign = 1 };
    var n: i32 = 0;
    var fi: usize = 0;
    while (fi < fmt.len) {
        var size: i32 = 0;
        var ntoalign: i32 = 0;
        const opt = try getdetails(&h, pos, fmt, &fi, &size, &ntoalign);
        const need: usize = @as(usize, @intCast(ntoalign)) + @as(usize, @intCast(size));
        try aux.argCheck(L, need <= data.len - pos, 2, "data string too short");
        pos += @intCast(ntoalign);
        if (!api.checkStack(L, 2)) return aux.err(L, "stack overflow (too many results)", .{});
        n += 1;
        switch (opt) {
            .int, .uint => {
                try api.pushInteger(L, try unpackint(L, data[pos..], h.islittle, size, opt == .int));
            },
            .float => {
                var f: f32 = undefined;
                copyWithEndian(std.mem.asBytes(&f), data[pos..][0..@sizeOf(f32)], h.islittle);
                try api.pushNumber(L, f);
            },
            .number, .double => {
                var f: f64 = undefined;
                copyWithEndian(std.mem.asBytes(&f), data[pos..][0..@sizeOf(f64)], h.islittle);
                try api.pushNumber(L, f);
            },
            .char => {
                const sz: usize = @intCast(size);
                try api.pushString(L, data[pos..][0..sz]);
            },
            .string => {
                // The length is read as a size_t in the reference: a negative
                // value wraps to a huge one and fails the check below
                const len: u64 = @bitCast(try unpackint(L, data[pos..], h.islittle, size, false));
                try aux.argCheck(L, len <= data.len - pos - @as(usize, @intCast(size)), 2, "data string too short");
                try api.pushString(L, data[pos + @as(usize, @intCast(size)) ..][0..len]);
                pos += len;
            },
            .zstr => {
                const rest = data[pos..];
                const len = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
                try aux.argCheck(L, pos + len < data.len, 2, "unfinished string for format 'z'");
                try api.pushString(L, rest[0..len]);
                pos += len + 1;
            },
            .paddalign, .padding, .nop => n -= 1,
        }
        pos += @intCast(size);
    }
    try api.pushInteger(L, @intCast(pos + 1));
    return n + 1;
}

test "matchClass covers the documented classes" {
    try std.testing.expect(matchClass('a', 'a')); // %a letter
    try std.testing.expect(!matchClass('1', 'a'));
    try std.testing.expect(matchClass('1', 'd')); // %d digit
    try std.testing.expect(matchClass(' ', 's')); // %s space
    try std.testing.expect(matchClass('_', 'p')); // %p punctuation
    try std.testing.expect(matchClass('f', 'x')); // %x hex digit
    // An uppercase class is the complement of its lowercase form
    try std.testing.expect(matchClass('1', 'A'));
    try std.testing.expect(!matchClass('a', 'A'));
    // An unknown class matches itself literally
    try std.testing.expect(matchClass('%', '%'));
}

test "noSpecials distinguishes plain patterns" {
    try std.testing.expect(noSpecials("hello"));
    try std.testing.expect(!noSpecials("h.llo"));
    try std.testing.expect(!noSpecials("^h"));
    try std.testing.expect(!noSpecials("a%d"));
}

test "endIndex clamps range endpoints" {
    try std.testing.expectEqual(@as(usize, 5), endIndex(5, 5));
    try std.testing.expectEqual(@as(usize, 5), endIndex(99, 5));
    try std.testing.expectEqual(@as(usize, 5), endIndex(-1, 5));
    try std.testing.expectEqual(@as(usize, 0), endIndex(-99, 5));
}
