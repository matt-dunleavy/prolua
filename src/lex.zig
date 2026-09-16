// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");
const numeral = @import("numeral.zig");

pub const TokenType = enum(u8) {
    // Reserved words - must match C implementation order
    kw_and = 0, // and
    kw_break, // break
    kw_do, // do
    kw_else, // else
    kw_elseif, // elseif
    kw_end, // end
    kw_false, // false
    kw_for, // for
    kw_function, // function
    kw_goto, // goto
    kw_if, // if
    kw_in, // in
    kw_local, // local
    kw_nil, // nil
    kw_not, // not
    kw_or, // or
    kw_repeat, // repeat
    kw_return, // return
    kw_then, // then
    kw_true, // true
    kw_until, // until
    kw_while,

    // Multi-character operators
    floor_div, // //
    concat, // ..
    varargs, // ...
    eq_eq, // ==
    greater_eq, // >=
    less_eq, // <=
    not_eq, // ~=
    shift_left, // <<
    shift_right, // >>
    label_delim, // ::

    // Special tokens
    eof,
    number, // TK_FLT in C
    integer, // TK_INT in C
    identifier, // TK_NAME in C
    string, // TK_STRING in C
    unknown, // any other byte, handed to the parser as a one-character token (`unknown_char`)

    // Single-character tokens start at 128 to avoid conflicts
    plus = 128, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    caret, // ^
    hash, // #
    ampersand, // &
    tilde, // ~
    pipe, // |
    less, // <
    greater, // >
    eq, // =
    lparen, // (
    rparen, // )
    lbrace, // {
    rbrace, // }
    lbracket, // [
    rbracket, // ]
    semicolon, // ;
    colon, // :
    comma,
    dot,

    pub const FIRST_RESERVED = @intFromEnum(TokenType.kw_and);
    pub const LAST_RESERVED = @intFromEnum(TokenType.kw_while);
    pub const NUM_RESERVED = LAST_RESERVED - FIRST_RESERVED + 1;
};

// Token string representations - ORDER MUST MATCH TokenType enum
const token_strings = [_][]const u8{
    // Reserved words
    "and",    "break",    "do",     "else",   "elseif", "end",      "false",
    "for",    "function", "goto",   "if",     "in",     "local",    "nil",
    "not",    "or",       "repeat", "return", "then",   "true",     "until",
    "while",
    // Multi-char operators
     "//",       "..",     "...",    "==",     ">=",       "<=",
    "~=",     "<<",       ">>",     "::",
    // Special tokens
        "<eof>",  "<number>", "<integer>",
    "<name>", "<string>",
};

// Comptime verification
comptime {
    const expected_count = @intFromEnum(TokenType.string) + 1;
    if (token_strings.len != expected_count) {
        @compileError("token_strings array size doesn't match TokenType enum");
    }
}

// Semantic information for tokens
pub const SemInfo = union(enum) {
    number: f64, // lua_Number equivalent
    integer: i64, // lua_Integer equivalent
    string: []const u8,
    none: void,
};

// Token structure
pub const Token = struct {
    token_type: TokenType,
    seminfo: SemInfo,
    line: i32,
    column: i32,
};

// Buffer for lexer - optimized for Lua's needs
pub const LexBuffer = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const INITIAL_SIZE = 32; // LUA_MINBUFFER equivalent

    pub fn init(allocator: std.mem.Allocator) !LexBuffer {
        var buf = LexBuffer{
            .buffer = .empty,
            .allocator = allocator,
        };
        try buf.buffer.ensureTotalCapacity(allocator, INITIAL_SIZE);
        return buf;
    }

    pub fn deinit(self: *LexBuffer) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *LexBuffer) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn save(self: *LexBuffer, c: u8) !void {
        try self.buffer.append(self.allocator, c);
    }

    pub fn saveSlice(self: *LexBuffer, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
    }

    pub fn slice(self: *const LexBuffer) []const u8 {
        return self.buffer.items;
    }

    pub fn len(self: *const LexBuffer) usize {
        return self.buffer.items.len;
    }

    pub fn removeLastN(self: *LexBuffer, n: usize) void {
        const current_len = self.buffer.items.len;
        if (n > current_len) {
            self.buffer.clearRetainingCapacity();
        } else {
            self.buffer.shrinkRetainingCapacity(current_len - n);
        }
    }
};

/// Encode `x` (at most 0x7FFFFFFF) at the *end* of `buff`, returning how many
/// bytes were written (luaO_utf8esc)
fn utf8Encode(x_in: u32, buff: *[UTF8BUFFSZ]u8) usize {
    var x = x_in;
    var n: usize = 1;
    if (x < 0x80) {
        buff[UTF8BUFFSZ - 1] = @intCast(x);
    } else {
        var mfb: u32 = 0x3f; // maximum that fits in the first byte
        while (true) {
            buff[UTF8BUFFSZ - n] = @intCast(0x80 | (x & 0x3f));
            n += 1;
            x >>= 6;
            mfb >>= 1;
            if (x <= mfb) break;
        }
        buff[UTF8BUFFSZ - n] = @intCast(((~mfb << 1) | x) & 0xff);
    }
    return n;
}

const EOZ: i32 = -1; // End of input marker (never a byte, so NUL is a character)
const MAX_INT = std.math.maxInt(i32);
const UTF8BUFFSZ = 8; // UTF-8 buffer size
const TAB_SIZE = 8; // Standard tab size

// Main lexer state
pub const LexState = struct {
    current: i32, // current character, or EOZ
    linenumber: i32, // input line counter
    lastline: i32, // line of last token consumed
    column: i32, // current column counter
    lastcolumn: i32, // column of last token consumed
    tokencolumn: i32, // column where current token started
    t: Token, // current token
    lookahead: Token, // lookahead token
    source: []const u8, // input source
    source_name: []const u8, // source name for error messages
    pos: usize, // current position in source
    buff: LexBuffer, // buffer for tokens
    allocator: std.mem.Allocator,

    // The last error, in Lua's wording (llex.c lexerror): `err_msg` is the
    // text and `err_near` says what follows "near" in the full message
    err_msg: []const u8 = "",
    err_near: ErrNear = .none,
    err_char: u8 = 0,
    unknown_char: u8 = 0, // the byte of the last `.unknown` token
    err_buf: [96]u8 = undefined,

    pub const ErrNear = enum { none, buffer, eof, char };

    // Error handling
    pub const Error = error{
        UnfinishedString,
        UnfinishedLongString,
        UnfinishedLongComment,
        MalformedNumber,
        DecimalEscapeTooLarge,
        InvalidEscapeSequence,
        InvalidLongStringDelimiter,
        HexadecimalDigitExpected,
        MissingBrace,
        UTF8ValueTooLarge,
        UnexpectedCharacter,
        ChunkHasTooManyLines,
        LexicalElementTooLong,
        OutOfMemory,
    };

    pub fn init(source: []const u8, source_name: []const u8, allocator: std.mem.Allocator) !LexState {
        var lexstate = LexState{
            .current = 0,
            .linenumber = 1,
            .lastline = 1,
            .column = 0, // Will be incremented to 1 by nextChar()
            .lastcolumn = 1,
            .tokencolumn = 1,
            .t = Token{ .token_type = .eof, .seminfo = .none, .line = 1, .column = 1 },
            .lookahead = Token{ .token_type = .eof, .seminfo = .none, .line = 1, .column = 1 },
            .source = source,
            .source_name = source_name,
            .pos = 0,
            .buff = try LexBuffer.init(allocator),
            .allocator = allocator,
        };

        // Read first character
        lexstate.nextChar();
        return lexstate;
    }

    /// Record `msg` as the reason for the error being returned
    fn fail(self: *LexState, comptime err: Error, msg: []const u8, near: ErrNear) Error {
        self.err_msg = msg;
        self.err_near = near;
        return err;
    }

    /// Like `fail`, for messages that need formatting
    fn failFmt(self: *LexState, comptime err: Error, comptime fmt: []const u8, args: anytype, near: ErrNear) Error {
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch fmt;
        return self.fail(err, msg, near);
    }

    /// An escape-sequence error: the offending character is added to the
    /// buffer first so the message shows it (esccheck)
    fn failEsc(self: *LexState, comptime err: Error, msg: []const u8) Error {
        if (self.current != EOZ) self.saveAndNext() catch {};
        return self.fail(err, msg, .buffer);
    }

    /// What a C "%s" shows of a buffer: the bytes before the first NUL
    pub fn cString(s: []const u8) []const u8 {
        return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
    }

    /// The full message for the last error, "msg near 'token'" (lexerror)
    pub fn errorMessage(self: *const LexState, buf: []u8) []const u8 {
        return switch (self.err_near) {
            .none => self.err_msg,
            .eof => std.fmt.bufPrint(buf, "{s} near <eof>", .{self.err_msg}) catch self.err_msg,
            // the reference prints the buffer with "%s", so it stops at a NUL
            .buffer => std.fmt.bufPrint(buf, "{s} near '{s}'", .{ self.err_msg, cString(self.buff.slice()) }) catch self.err_msg,
            .char => if (std.ascii.isPrint(self.err_char))
                std.fmt.bufPrint(buf, "{s} near '{c}'", .{ self.err_msg, self.err_char }) catch self.err_msg
            else
                std.fmt.bufPrint(buf, "{s} near '<\\{d}>'", .{ self.err_msg, self.err_char }) catch self.err_msg,
        };
    }

    pub fn deinit(self: *LexState) void {
        // Free any remaining allocated memory in tokens
        self.freeSemInfo(&self.t.seminfo);
        self.freeSemInfo(&self.lookahead.seminfo);
        self.buff.deinit();
    }

    // Read next character from input
    fn nextChar(self: *LexState) void {
        if (self.pos >= self.source.len) {
            self.current = EOZ;
        } else {
            self.current = self.source[self.pos];

            // Handle column advancement based on character type
            if (self.current == '\t') {
                // A tab occupies the columns up to the next tab stop, so the
                // character after it lands on that stop (column 9, 17, ...).
                self.column = (@divTrunc(self.column, TAB_SIZE) + 1) * TAB_SIZE;
            } else if (self.current & 0x80 != 0) {
                // This is a potential UTF-8 multibyte character
                // Check if this is a continuation byte (10xxxxxx)
                if (self.current & 0xC0 == 0x80) {
                    // Continuation byte - don't advance column
                    // This maintains the column position from the start byte
                } else {
                    // Start of a UTF-8 sequence - advance column
                    self.column += 1;
                }
            } else {
                // Regular ASCII character
                self.column += 1;
            }

            self.pos += 1;
        }
    }

    // Save current character and read next
    fn saveAndNext(self: *LexState) !void {
        std.debug.assert(self.current != EOZ);
        try self.buff.save(@intCast(self.current));
        self.nextChar();
    }

    // Check if current char is newline
    fn currIsNewline(self: *const LexState) bool {
        return self.current == '\n' or self.current == '\r';
    }

    // Increment line number and handle different newline sequences
    fn incLineNumber(self: *LexState) !void {
        const old = self.current;
        std.debug.assert(self.currIsNewline());
        // Reset the column before reading the first character of the new line,
        // so that character is reported at column 1.
        self.column = 0;
        self.nextChar(); // skip '\n' or '\r'
        if (self.currIsNewline() and self.current != old) {
            self.column = 0;
            self.nextChar(); // skip '\n\r' or '\r\n'
        }
        self.linenumber += 1;
        if (self.linenumber >= MAX_INT) {
            return self.fail(error.ChunkHasTooManyLines, "chunk has too many lines", .none);
        }
    }

    // Check if next character matches and consume it
    fn checkNext1(self: *LexState, c: u8) bool {
        if (self.current == c) {
            self.nextChar();
            return true;
        }
        return false;
    }

    // Check if current char is in set and save it
    fn checkNext2(self: *LexState, set: []const u8) !bool {
        std.debug.assert(set.len == 2);
        if (self.current == set[0] or self.current == set[1]) {
            try self.saveAndNext();
            return true;
        }
        return false;
    }

    // Character classification functions
    fn isDigit(c: i32) bool {
        return c >= '0' and c <= '9';
    }

    fn isXDigit(c: i32) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isAlpha(c: i32) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isAlnum(c: i32) bool {
        return isAlpha(c) or isDigit(c);
    }

    fn isLAlpha(c: i32) bool {
        return isAlpha(c) or c == '_';
    }

    fn isLAlnum(c: i32) bool {
        return isAlnum(c) or c == '_';
    }

    fn isSpace(c: i32) bool {
        return c == ' ' or c == 12 or c == '\t' or c == 11; // 12=form feed, 11=vertical tab
    }

    // Convert hex character to value
    fn hexValue(c: i32) u8 {
        if (c >= '0' and c <= '9') return @intCast(c - '0');
        if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
        if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
        return 0;
    }

    // Read a sequence '[=*[' or ']=*]'
    fn skipSep(self: *LexState) !usize {
        var count: usize = 0;
        const s = self.current;
        std.debug.assert(s == '[' or s == ']');
        try self.saveAndNext();
        while (self.current == '=') {
            try self.saveAndNext();
            count += 1;
        }
        return if (self.current == s) count + 2 else if (count == 0) 1 else 0;
    }

    // Read long string or long comment
    fn readLongString(self: *LexState, seminfo: ?*SemInfo, sep: usize) !void {
        const start_line = self.linenumber;
        try self.saveAndNext(); // skip 2nd '['
        if (self.currIsNewline()) { // string starts with a newline?
            try self.incLineNumber(); // skip it
        }

        while (true) {
            switch (self.current) {
                EOZ => {
                    if (seminfo != null) {
                        return self.failFmt(error.UnfinishedLongString, "unfinished long string (starting at line {d})", .{start_line}, .eof);
                    }
                    return self.failFmt(error.UnfinishedLongComment, "unfinished long comment (starting at line {d})", .{start_line}, .eof);
                },
                ']' => {
                    if (try self.skipSep() == sep) {
                        try self.saveAndNext(); // skip 2nd ']'
                        break;
                    }
                },
                '\n', '\r' => {
                    try self.buff.save('\n');
                    try self.incLineNumber();
                    if (seminfo == null) self.buff.reset(); // avoid wasting space
                },
                else => {
                    if (seminfo != null) {
                        try self.saveAndNext();
                    } else {
                        self.nextChar();
                    }
                },
            }
        }

        if (seminfo) |si| {
            const content = self.buff.slice();
            if (content.len >= 2 * sep) {
                const str_content = content[sep .. content.len - sep];
                const owned_str = try self.allocator.dupe(u8, str_content);
                si.* = .{ .string = owned_str };
            } else {
                si.* = .{ .string = "" };
            }
        }
    }

    // Get hexadecimal digit
    fn getHexa(self: *LexState) !u8 {
        try self.saveAndNext();
        if (!isXDigit(self.current)) {
            return self.failEsc(error.HexadecimalDigitExpected, "hexadecimal digit expected");
        }
        return hexValue(self.current);
    }

    // Read hexadecimal escape sequence
    fn readHexaEsc(self: *LexState) !u8 {
        const r = (try self.getHexa() << 4) + try self.getHexa();
        self.buff.removeLastN(2); // remove saved chars from buffer
        return r;
    }

    // Read UTF-8 escape sequence
    fn readUtf8Esc(self: *LexState) !u32 {
        var r: u32 = 0;
        var i: usize = 4; // chars to be removed: '\', 'u', '{', and first digit
        try self.saveAndNext(); // skip 'u'
        if (self.current != '{') {
            return self.failEsc(error.MissingBrace, "missing '{'");
        }
        r = try self.getHexa(); // must have at least one digit
        while (true) {
            try self.saveAndNext();
            if (!isXDigit(self.current)) break;
            i += 1;
            if (r > 0x7FFFFFFF >> 4) {
                return self.failEsc(error.UTF8ValueTooLarge, "UTF-8 value too large");
            }
            r = (r << 4) + hexValue(self.current);
        }
        if (self.current != '}') {
            return self.failEsc(error.MissingBrace, "missing '}'");
        }
        self.nextChar(); // skip '}'
        self.buff.removeLastN(i); // remove saved chars from buffer
        return r;
    }

    // Convert UTF-8 code point to bytes. Lua accepts values up to 2^31-1
    // and encodes them with the original (up to six byte) scheme, beyond
    // what standard UTF-8 allows (luaO_utf8esc).
    fn utf8Esc(self: *LexState) !void {
        const r = try self.readUtf8Esc();
        var buff: [UTF8BUFFSZ]u8 = undefined;
        const n = utf8Encode(r, &buff);
        try self.buff.saveSlice(buff[UTF8BUFFSZ - n ..]);
    }

    // Read decimal escape sequence
    fn readDecEsc(self: *LexState) !u8 {
        var r: u16 = 0;
        var i: u8 = 0;
        while (i < 3 and isDigit(self.current)) : (i += 1) {
            r = 10 * r + @as(u16, @intCast(self.current - '0'));
            try self.saveAndNext();
        }
        if (r > 255) {
            return self.failEsc(error.DecimalEscapeTooLarge, "decimal escape too large");
        }
        self.buff.removeLastN(i); // remove read digits from buffer
        return @intCast(r);
    }

    // Read string literal
    fn readString(self: *LexState, delimiter: u8) !void {
        try self.saveAndNext(); // keep delimiter for error messages

        while (self.current != delimiter) {
            switch (self.current) {
                EOZ => return self.fail(error.UnfinishedString, "unfinished string", .eof),
                '\n', '\r' => return self.fail(error.UnfinishedString, "unfinished string", .buffer),
                '\\' => { // escape sequences
                    try self.saveAndNext(); // keep '\' for error messages
                    var c: u8 = undefined;
                    switch (self.current) {
                        'a' => c = '\x07', // bell
                        'b' => c = '\x08', // backspace
                        'f' => c = '\x0C', // form feed
                        'n' => c = '\n',
                        'r' => c = '\r',
                        't' => c = '\t',
                        'v' => c = '\x0B', // vertical tab
                        'x' => {
                            c = try self.readHexaEsc();
                            self.nextChar();
                            self.buff.removeLastN(1); // remove '\'
                            try self.buff.save(c);
                            continue;
                        },
                        'u' => {
                            try self.utf8Esc();
                            continue;
                        },
                        '\n', '\r' => {
                            try self.incLineNumber();
                            c = '\n';
                            self.buff.removeLastN(1); // remove '\'
                            try self.buff.save(c);
                            continue;
                        },
                        '\\', '"', '\'' => c = @intCast(self.current),
                        EOZ => continue, // will raise error next loop
                        'z' => { // zap following span of spaces
                            self.buff.removeLastN(1); // remove '\'
                            self.nextChar(); // skip the 'z'
                            while (isSpace(self.current) or self.currIsNewline()) {
                                if (self.currIsNewline()) {
                                    try self.incLineNumber();
                                } else {
                                    self.nextChar();
                                }
                            }
                            continue;
                        },
                        else => {
                            if (isDigit(self.current)) {
                                c = try self.readDecEsc();
                                self.buff.removeLastN(1); // remove '\'
                                try self.buff.save(c);
                                continue;
                            } else {
                                return self.failEsc(error.InvalidEscapeSequence, "invalid escape sequence");
                            }
                        },
                    }
                    self.nextChar();
                    self.buff.removeLastN(1); // remove '\'
                    try self.buff.save(c);
                },
                else => try self.saveAndNext(),
            }
        }

        try self.saveAndNext(); // skip delimiter

        // Create string without delimiters
        const full_str = self.buff.slice();
        if (full_str.len >= 2) {
            const str_content = full_str[1 .. full_str.len - 1];
            const owned_str = try self.allocator.dupe(u8, str_content);
            self.t.seminfo = .{ .string = owned_str };
        } else {
            self.t.seminfo = .{ .string = "" };
        }
    }

    // Read a number (integer or float)
    fn readNumeral(self: *LexState) !TokenType {
        const first = self.current;
        std.debug.assert(isDigit(self.current));
        try self.saveAndNext();

        var expo: []const u8 = "Ee";
        if (first == '0' and try self.checkNext2("xX")) { // hexadecimal?
            expo = "Pp";
        }

        while (true) {
            if (try self.checkNext2(expo)) { // exponent mark?
                _ = try self.checkNext2("-+"); // optional exponent sign
            } else if (isXDigit(self.current) or self.current == '.') {
                try self.saveAndNext();
            } else {
                break;
            }
        }

        if (isLAlnum(self.current)) { // numeral touching a letter?
            try self.saveAndNext(); // force an error
        }

        // The same conversion `tonumber` uses, so the two cannot disagree
        const n = numeral.parse(self.buff.slice()) orelse
            return self.fail(error.MalformedNumber, "malformed number", .buffer);
        switch (n) {
            .integer => |i| {
                self.t.seminfo = .{ .integer = i };
                return .integer;
            },
            .float => |f| {
                self.t.seminfo = .{ .number = f };
                return .number;
            },
        }
    }

    // Main lexing function
    fn llex(self: *LexState) !TokenType {
        self.buff.reset();

        while (true) {
            switch (self.current) {
                '\n', '\r' => { // line breaks
                    try self.incLineNumber();
                },
                ' ', 12, '\t', 11 => { // spaces (12=form feed, 11=vertical tab)
                    self.nextChar();
                },
                '-' => { // '-' or '--' (comment)
                    // Save token position before consuming character
                    self.tokencolumn = self.column;
                    self.nextChar();
                    if (self.current != '-') return .minus;
                    // else is a comment
                    self.nextChar();
                    if (self.current == '[') { // long comment?
                        const sep = try self.skipSep();
                        self.buff.reset(); // 'skipSep' may dirty the buffer
                        if (sep >= 2) {
                            try self.readLongString(null, sep); // skip long comment
                            self.buff.reset(); // previous call may dirty the buff
                            continue;
                        }
                    }
                    // else short comment
                    while (!self.currIsNewline() and self.current != EOZ) {
                        self.nextChar();
                    }
                },
                '[' => { // long string or simply '['
                    self.tokencolumn = self.column;
                    const sep = try self.skipSep();
                    if (sep >= 2) {
                        try self.readLongString(&self.t.seminfo, sep);
                        return .string;
                    } else if (sep == 0) { // '[=...' missing second bracket?
                        return self.fail(error.InvalidLongStringDelimiter, "invalid long string delimiter", .buffer);
                    }
                    return .lbracket;
                },
                '=' => {
                    self.tokencolumn = self.column;
                    self.nextChar();
                    self.t.seminfo = .none;
                    if (self.checkNext1('=')) return .eq_eq;
                    return .eq;
                },
                '<' => {
                    self.tokencolumn = self.column;
                    self.nextChar();
                    self.t.seminfo = .none;
                    if (self.checkNext1('=')) return .less_eq;
                    if (self.checkNext1('<')) return .shift_left;
                    return .less;
                },
                '>' => {
                    self.tokencolumn = self.column;
                    self.nextChar();
                    self.t.seminfo = .none;
                    if (self.checkNext1('=')) return .greater_eq;
                    if (self.checkNext1('>')) return .shift_right;
                    return .greater;
                },
                '/' => {
                    self.tokencolumn = self.column;
                    self.nextChar();
                    self.t.seminfo = .none;
                    if (self.checkNext1('/')) return .floor_div;
                    return .slash;
                },
                '~' => {
                    self.tokencolumn = self.column;
                    self.nextChar();
                    self.t.seminfo = .none;
                    if (self.checkNext1('=')) return .not_eq;
                    return .tilde;
                },
                ':' => {
                    self.tokencolumn = self.column;
                    self.nextChar();
                    self.t.seminfo = .none;
                    if (self.checkNext1(':')) return .label_delim;
                    return .colon;
                },
                '"', '\'' => { // short literal strings
                    self.tokencolumn = self.column;
                    try self.readString(@intCast(self.current));
                    return .string;
                },
                '.' => { // '.', '..', '...', or number
                    self.tokencolumn = self.column;
                    try self.saveAndNext();
                    if (self.checkNext1('.')) {
                        self.t.seminfo = .none;
                        if (self.checkNext1('.')) {
                            return .varargs; // '...'
                        } else {
                            return .concat; // '..'
                        }
                    } else if (!isDigit(self.current)) {
                        self.t.seminfo = .none;
                        return .dot;
                    } else {
                        return try self.readNumeral();
                    }
                },
                '0'...'9' => {
                    self.tokencolumn = self.column;
                    return try self.readNumeral();
                },
                EOZ => {
                    // End of input sits one column past the last character.
                    self.tokencolumn = self.column + 1;
                    self.t.seminfo = .none;
                    return .eof;
                },
                else => {
                    if (isLAlpha(self.current)) { // identifier or reserved word?
                        self.tokencolumn = self.column;
                        while (isLAlnum(self.current)) {
                            try self.saveAndNext();
                        }

                        const str = self.buff.slice();

                        // Check if it's a reserved word
                        if (lookupKeyword(str)) |token| {
                            self.t.seminfo = .none;
                            return token;
                        } else {
                            // It's an identifier
                            const owned_str = try self.allocator.dupe(u8, str);
                            self.t.seminfo = .{ .string = owned_str };
                            return .identifier;
                        }
                    } else { // single-char tokens
                        self.tokencolumn = self.column;
                        const c = self.current;
                        self.nextChar();
                        self.t.seminfo = .none;
                        return switch (c) {
                            '+' => .plus,
                            '*' => .star,
                            '%' => .percent,
                            '^' => .caret,
                            '#' => .hash,
                            '&' => .ampersand,
                            '|' => .pipe,
                            '(' => .lparen,
                            ')' => .rparen,
                            '{' => .lbrace,
                            '}' => .rbrace,
                            ']' => .rbracket,
                            ';' => .semicolon,
                            ',' => .comma,
                            else => {
                                // Lua hands any other byte to the parser as a
                                // one-character token, and the parser reports
                                // it with the message its context calls for
                                // ("syntax error", "')' expected", ...)
                                self.unknown_char = @intCast(c);
                                self.t.seminfo = .none;
                                return .unknown;
                            },
                        };
                    }
                },
            }
        }
    }

    // Get next token
    pub fn next(self: *LexState) !void {
        self.lastline = self.linenumber;
        self.lastcolumn = self.tokencolumn;
        if (self.lookahead.token_type != .eof) { // is there a look-ahead token?
            // Free any existing seminfo in current token before overwriting
            self.freeSemInfo(&self.t.seminfo);
            self.t = self.lookahead; // use this one
            self.lookahead.token_type = .eof; // and discharge it
            self.lookahead.seminfo = .none; // memory ownership transferred to self.t
            self.lookahead.line = 1;
            self.lookahead.column = 1;
        } else {
            // Free any existing seminfo before getting new token
            self.freeSemInfo(&self.t.seminfo);
            self.t.seminfo = .none;
            self.t.token_type = try self.llex(); // read next token
            self.t.line = self.linenumber;
            self.t.column = self.tokencolumn;
        }
    }

    // Look ahead one token
    pub fn lookAhead(self: *LexState) !TokenType {
        std.debug.assert(self.lookahead.token_type == .eof);
        self.lookahead.token_type = try self.llex();
        self.lookahead.line = self.linenumber;
        self.lookahead.column = self.tokencolumn;
        return self.lookahead.token_type;
    }

    // Get current token type
    pub fn getCurrentToken(self: *const LexState) TokenType {
        return self.t.token_type;
    }

    // Get current token semantic info
    pub fn getCurrentSeminfo(self: *const LexState) SemInfo {
        return self.t.seminfo;
    }

    // Get current line number
    pub fn getCurrentLine(self: *const LexState) i32 {
        return self.linenumber;
    }

    // Get current token column
    pub fn getCurrentColumn(self: *const LexState) i32 {
        return self.t.column;
    }

    // Get last token line
    pub fn getLastLine(self: *const LexState) i32 {
        return self.lastline;
    }

    // Get last token column
    pub fn getLastColumn(self: *const LexState) i32 {
        return self.lastcolumn;
    }

    // Helper to free semantic info
    pub fn freeSemInfo(self: *LexState, seminfo: *SemInfo) void {
        switch (seminfo.*) {
            .string => |s| {
                if (s.len > 0) {
                    self.allocator.free(s);
                }
            },
            else => {},
        }
        seminfo.* = .none;
    }
};

// Standalone functions

// Keyword lookup - optimized with perfect hash or binary search
pub fn lookupKeyword(str: []const u8) ?TokenType {
    // Only search in the reserved word range
    for (0..TokenType.NUM_RESERVED) |i| {
        if (std.mem.eql(u8, str, token_strings[i])) {
            return @enumFromInt(TokenType.FIRST_RESERVED + i);
        }
    }
    return null;
}

// Get string representation of token
pub fn tokenToString(token: TokenType) []const u8 {
    if (token == .unknown) return "?"; // the parser prints the byte itself
    const index = @intFromEnum(token);
    if (index < token_strings.len) {
        return token_strings[index];
    }

    // Handle single-character tokens
    return switch (token) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .caret => "^",
        .hash => "#",
        .ampersand => "&",
        .tilde => "~",
        .pipe => "|",
        .less => "<",
        .greater => ">",
        .eq => "=",
        .lparen => "(",
        .rparen => ")",
        .lbrace => "{",
        .rbrace => "}",
        .lbracket => "[",
        .rbracket => "]",
        .semicolon => ";",
        .colon => ":",
        .comma => ",",
        .dot => ".",
        else => "<unknown>",
    };
}

// Check if a token is a reserved word
pub fn isReserved(token: TokenType) bool {
    const val = @intFromEnum(token);
    return val >= TokenType.FIRST_RESERVED and val <= TokenType.LAST_RESERVED;
}

// Test helper functions
test "lexer initialization" {
    const allocator = std.testing.allocator;
    const source = "local x = 42";
    var lexer = try LexState.init(source, "test", allocator);
    defer lexer.deinit();

    try std.testing.expect(lexer.linenumber == 1);
    try std.testing.expect(lexer.current == 'l');
}

test "keyword lookup" {
    try std.testing.expect(lookupKeyword("local") == .kw_local);
    try std.testing.expect(lookupKeyword("for") == .kw_for);
    try std.testing.expect(lookupKeyword("notakeyword") == null);
}

test "token string representation" {
    try std.testing.expectEqualStrings("local", tokenToString(.kw_local));
    try std.testing.expectEqualStrings("+", tokenToString(.plus));
    try std.testing.expectEqualStrings("==", tokenToString(.eq_eq));
}

// Helper function to test token sequence
fn expectTokenSequence(source: []const u8, expected: []const TokenType) !void {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init(source, "test", allocator);
    defer lexer.deinit();

    for (expected) |expected_token| {
        try lexer.next();
        try std.testing.expectEqual(expected_token, lexer.getCurrentToken());
        // Clean up any allocated memory
        lexer.freeSemInfo(&lexer.t.seminfo);
    }

    // Verify EOF at the end
    try lexer.next();
    try std.testing.expectEqual(TokenType.eof, lexer.getCurrentToken());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Helper to test a single token with semantic info
fn expectToken(source: []const u8, expected_type: TokenType, expected_sem: ?SemInfo) !void {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init(source, "test", allocator);
    defer lexer.deinit();

    try lexer.next();
    try std.testing.expectEqual(expected_type, lexer.getCurrentToken());

    if (expected_sem) |sem| {
        switch (sem) {
            .number => |n| {
                const actual = lexer.getCurrentSeminfo();
                try std.testing.expectEqual(n, actual.number);
            },
            .integer => |i| {
                const actual = lexer.getCurrentSeminfo();
                try std.testing.expectEqual(i, actual.integer);
            },
            .string => |s| {
                const actual = lexer.getCurrentSeminfo();
                try std.testing.expectEqualStrings(s, actual.string);
            },
            .none => {},
        }
    }

    // Clean up any allocated memory
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Test all keywords
test "all keywords" {
    const keywords = [_]struct { text: []const u8, token: TokenType }{
        .{ .text = "and", .token = .kw_and },
        .{ .text = "break", .token = .kw_break },
        .{ .text = "do", .token = .kw_do },
        .{ .text = "else", .token = .kw_else },
        .{ .text = "elseif", .token = .kw_elseif },
        .{ .text = "end", .token = .kw_end },
        .{ .text = "false", .token = .kw_false },
        .{ .text = "for", .token = .kw_for },
        .{ .text = "function", .token = .kw_function },
        .{ .text = "goto", .token = .kw_goto },
        .{ .text = "if", .token = .kw_if },
        .{ .text = "in", .token = .kw_in },
        .{ .text = "local", .token = .kw_local },
        .{ .text = "nil", .token = .kw_nil },
        .{ .text = "not", .token = .kw_not },
        .{ .text = "or", .token = .kw_or },
        .{ .text = "repeat", .token = .kw_repeat },
        .{ .text = "return", .token = .kw_return },
        .{ .text = "then", .token = .kw_then },
        .{ .text = "true", .token = .kw_true },
        .{ .text = "until", .token = .kw_until },
        .{ .text = "while", .token = .kw_while },
    };

    for (keywords) |kw| {
        try expectToken(kw.text, kw.token, null);
    }
}

// Test all operators
test "operators" {
    const operators = [_]struct { text: []const u8, token: TokenType }{
        // Multi-character operators
        .{ .text = "//", .token = .floor_div },
        .{ .text = "..", .token = .concat },
        .{ .text = "...", .token = .varargs },
        .{ .text = "==", .token = .eq_eq },
        .{ .text = ">=", .token = .greater_eq },
        .{ .text = "<=", .token = .less_eq },
        .{ .text = "~=", .token = .not_eq },
        .{ .text = "<<", .token = .shift_left },
        .{ .text = ">>", .token = .shift_right },
        .{ .text = "::", .token = .label_delim },
        // Single-character operators
        .{ .text = "+", .token = .plus },
        .{ .text = "-", .token = .minus },
        .{ .text = "*", .token = .star },
        .{ .text = "/", .token = .slash },
        .{ .text = "%", .token = .percent },
        .{ .text = "^", .token = .caret },
        .{ .text = "#", .token = .hash },
        .{ .text = "&", .token = .ampersand },
        .{ .text = "~", .token = .tilde },
        .{ .text = "|", .token = .pipe },
        .{ .text = "<", .token = .less },
        .{ .text = ">", .token = .greater },
        .{ .text = "=", .token = .eq },
        .{ .text = "(", .token = .lparen },
        .{ .text = ")", .token = .rparen },
        .{ .text = "{", .token = .lbrace },
        .{ .text = "}", .token = .rbrace },
        .{ .text = "[", .token = .lbracket },
        .{ .text = "]", .token = .rbracket },
        .{ .text = ";", .token = .semicolon },
        .{ .text = ":", .token = .colon },
        .{ .text = ",", .token = .comma },
        .{ .text = ".", .token = .dot },
    };

    for (operators) |op| {
        try expectToken(op.text, op.token, null);
    }
}

// Test identifiers
test "identifiers" {
    try expectToken("hello", .identifier, .{ .string = "hello" });
    try expectToken("_test", .identifier, .{ .string = "_test" });
    try expectToken("test123", .identifier, .{ .string = "test123" });
    try expectToken("_123", .identifier, .{ .string = "_123" });
    try expectToken("camelCase", .identifier, .{ .string = "camelCase" });
    try expectToken("snake_case", .identifier, .{ .string = "snake_case" });
}

// Test integers
test "integer literals" {
    try expectToken("42", .integer, .{ .integer = 42 });
    try expectToken("0", .integer, .{ .integer = 0 });
    try expectToken("123456789", .integer, .{ .integer = 123456789 });
    try expectToken("0x1F", .integer, .{ .integer = 31 });
    try expectToken("0X1f", .integer, .{ .integer = 31 });
    try expectToken("0xff", .integer, .{ .integer = 255 });
    try expectToken("0xDEADBEEF", .integer, .{ .integer = 0xDEADBEEF });
}

// Test floating point numbers
test "floating point literals" {
    try expectToken("3.14", .number, .{ .number = 3.14 });
    try expectToken("0.5", .number, .{ .number = 0.5 });
    try expectToken(".5", .number, .{ .number = 0.5 });
    try expectToken("1e10", .number, .{ .number = 1e10 });
    try expectToken("1.5e-4", .number, .{ .number = 1.5e-4 });
    try expectToken("1E10", .number, .{ .number = 1e10 });
    try expectToken("1.5E-4", .number, .{ .number = 1.5e-4 });
}

// Test simple strings
test "simple string literals" {
    try expectToken("\"hello\"", .string, .{ .string = "hello" });
    try expectToken("'world'", .string, .{ .string = "world" });
    try expectToken("\"\"", .string, .{ .string = "" });
    try expectToken("''", .string, .{ .string = "" });
    try expectToken("\"hello world\"", .string, .{ .string = "hello world" });
}

// Test string escape sequences
test "string escape sequences" {
    try expectToken("\"\\n\"", .string, .{ .string = "\n" });
    try expectToken("\"\\r\"", .string, .{ .string = "\r" });
    try expectToken("\"\\t\"", .string, .{ .string = "\t" });
    try expectToken("\"\\\\\"", .string, .{ .string = "\\" });
    try expectToken("\"\\\"\"", .string, .{ .string = "\"" });
    try expectToken("'\\''", .string, .{ .string = "'" });
    try expectToken("\"\\a\"", .string, .{ .string = "\x07" });
    try expectToken("\"\\b\"", .string, .{ .string = "\x08" });
    try expectToken("\"\\f\"", .string, .{ .string = "\x0C" });
    try expectToken("\"\\v\"", .string, .{ .string = "\x0B" });
}

// Test hexadecimal escape sequences
test "hex escape sequences" {
    try expectToken("\"\\x41\"", .string, .{ .string = "A" });
    try expectToken("\"\\x42\\x43\"", .string, .{ .string = "BC" });
    try expectToken("\"\\xff\"", .string, .{ .string = "\xff" });
}

// Test decimal escape sequences
test "decimal escape sequences" {
    try expectToken("\"\\65\"", .string, .{ .string = "A" });
    try expectToken("\"\\065\"", .string, .{ .string = "A" });
    try expectToken("\"\\0\"", .string, .{ .string = "\x00" });
    try expectToken("\"\\255\"", .string, .{ .string = "\xff" });
}

// Test UTF-8 escape sequences
test "utf8 escape sequences" {
    try expectToken("\"\\u{41}\"", .string, .{ .string = "A" });
    try expectToken("\"\\u{1F600}\"", .string, .{ .string = "😀" });
    try expectToken("\"\\u{20AC}\"", .string, .{ .string = "€" });
}

// Test z escape (whitespace zapping)
test "z escape sequence" {
    try expectToken("\"hello\\z   world\"", .string, .{ .string = "helloworld" });
    try expectToken("\"line1\\z\n   line2\"", .string, .{ .string = "line1line2" });
}

// Test short comments
test "short comments" {
    try expectTokenSequence("-- comment\nlocal", &[_]TokenType{.kw_local});
    try expectTokenSequence("local -- comment", &[_]TokenType{.kw_local});
    try expectTokenSequence("--comment", &[_]TokenType{});
}

// Test long comments
test "long comments" {
    try expectTokenSequence("--[[comment]]local", &[_]TokenType{.kw_local});
    try expectTokenSequence("--[[ multi\nline\ncomment ]]local", &[_]TokenType{.kw_local});
    try expectTokenSequence("--[=[ comment ]=]local", &[_]TokenType{.kw_local});
    try expectTokenSequence("--[==[ comment ]==]local", &[_]TokenType{.kw_local});
}

// Test long strings
test "long strings" {
    try expectToken("[[hello]]", .string, .{ .string = "hello" });
    try expectToken("[[\nhello\n]]", .string, .{ .string = "hello\n" });
    try expectToken("[=[ hello ]=]", .string, .{ .string = " hello " });
    try expectToken("[==[ [[hello]] ]==]", .string, .{ .string = " [[hello]] " });
}

// Test complex token sequences
test "complex expressions" {
    try expectTokenSequence("local x = 42 + 3.14", &[_]TokenType{ .kw_local, .identifier, .eq, .integer, .plus, .number });

    try expectTokenSequence("function foo(a, b) return a + b end", &[_]TokenType{ .kw_function, .identifier, .lparen, .identifier, .comma, .identifier, .rparen, .kw_return, .identifier, .plus, .identifier, .kw_end });

    try expectTokenSequence("if x > 0 then print(x) end", &[_]TokenType{ .kw_if, .identifier, .greater, .integer, .kw_then, .identifier, .lparen, .identifier, .rparen, .kw_end });
}

// Test line number tracking
test "line number tracking" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("line1\nline2\nline3", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentLine());
    try lexer.next(); // identifier "line1"
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentLine());
    lexer.freeSemInfo(&lexer.t.seminfo);

    try lexer.next(); // identifier "line2"
    try std.testing.expectEqual(@as(i32, 2), lexer.getCurrentLine());
    lexer.freeSemInfo(&lexer.t.seminfo);

    try lexer.next(); // identifier "line3"
    try std.testing.expectEqual(@as(i32, 3), lexer.getCurrentLine());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Test look-ahead
test "look ahead" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("local x", "test", allocator);
    defer lexer.deinit();

    try lexer.next();
    try std.testing.expectEqual(TokenType.kw_local, lexer.getCurrentToken());

    const lookahead = try lexer.lookAhead();
    try std.testing.expectEqual(TokenType.identifier, lookahead);
    try std.testing.expectEqual(TokenType.kw_local, lexer.getCurrentToken()); // current unchanged

    // Clean up lookahead seminfo
    lexer.freeSemInfo(&lexer.lookahead.seminfo);

    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Test error cases
test "error: unfinished string" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"unterminated", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.UnfinishedString, lexer.next());
}

test "error: unfinished long string" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("[[unterminated", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.UnfinishedLongString, lexer.next());
}

test "error: unfinished long comment" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("--[[unterminated", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.UnfinishedLongComment, lexer.next());
}

test "error: malformed number" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("0xGG", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.MalformedNumber, lexer.next());
}

test "error: decimal escape too large" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"\\256\"", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.DecimalEscapeTooLarge, lexer.next());
}

test "error: invalid escape sequence" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"\\q\"", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.InvalidEscapeSequence, lexer.next());
}

test "error: hex digit expected" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"\\xGG\"", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.HexadecimalDigitExpected, lexer.next());
}

test "error: missing brace in utf8" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"\\u41\"", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.MissingBrace, lexer.next());
}

test "error: utf8 value too large" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"\\u{FFFFFFFF}\"", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.UTF8ValueTooLarge, lexer.next());
}

test "unknown character becomes a one-character token" {
    // as in llex.c, which returns the byte itself; the parser reports it
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("@", "test", allocator);
    defer lexer.deinit();

    try lexer.next();
    try std.testing.expectEqual(TokenType.unknown, lexer.t.token_type);
    try std.testing.expectEqual(@as(u8, '@'), lexer.unknown_char);
}

test "error: invalid long string delimiter" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("[=", "test", allocator);
    defer lexer.deinit();

    try std.testing.expectError(LexState.Error.InvalidLongStringDelimiter, lexer.next());
}

// Test edge cases
test "edge case: dots" {
    try expectTokenSequence(".", &[_]TokenType{.dot});
    try expectTokenSequence("..", &[_]TokenType{.concat});
    try expectTokenSequence("...", &[_]TokenType{.varargs});
    try expectTokenSequence("....a", &[_]TokenType{ .varargs, .dot, .identifier });
}

test "edge case: newline handling" {
    // Test different newline types
    const allocator = std.testing.allocator;

    // LF
    var lexer1 = try LexState.init("a\nb", "test", allocator);
    defer lexer1.deinit();
    try lexer1.next();
    try std.testing.expectEqual(@as(i32, 1), lexer1.getCurrentLine());
    lexer1.freeSemInfo(&lexer1.t.seminfo);
    try lexer1.next();
    try std.testing.expectEqual(@as(i32, 2), lexer1.getCurrentLine());
    lexer1.freeSemInfo(&lexer1.t.seminfo);

    // CR
    var lexer2 = try LexState.init("a\rb", "test", allocator);
    defer lexer2.deinit();
    try lexer2.next();
    try std.testing.expectEqual(@as(i32, 1), lexer2.getCurrentLine());
    lexer2.freeSemInfo(&lexer2.t.seminfo);
    try lexer2.next();
    try std.testing.expectEqual(@as(i32, 2), lexer2.getCurrentLine());
    lexer2.freeSemInfo(&lexer2.t.seminfo);

    // CRLF
    var lexer3 = try LexState.init("a\r\nb", "test", allocator);
    defer lexer3.deinit();
    try lexer3.next();
    try std.testing.expectEqual(@as(i32, 1), lexer3.getCurrentLine());
    lexer3.freeSemInfo(&lexer3.t.seminfo);
    try lexer3.next();
    try std.testing.expectEqual(@as(i32, 2), lexer3.getCurrentLine());
    lexer3.freeSemInfo(&lexer3.t.seminfo);
}

test "edge case: whitespace" {
    // Test various whitespace characters
    try expectTokenSequence("a b", &[_]TokenType{ .identifier, .identifier });
    try expectTokenSequence("a\tb", &[_]TokenType{ .identifier, .identifier });
    try expectTokenSequence("a\x0Bb", &[_]TokenType{ .identifier, .identifier }); // vertical tab
    try expectTokenSequence("a\x0Cb", &[_]TokenType{ .identifier, .identifier }); // form feed
}

test "edge case: empty input" {
    try expectTokenSequence("", &[_]TokenType{});
}

test "edge case: long separator matching" {
    // Test that separators must match
    try expectToken("[==[ hello ]==]", .string, .{ .string = " hello " });
    // Mismatched separators should not close the string
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("[==[ hello ]=]", "test", allocator);
    defer lexer.deinit();
    try std.testing.expectError(LexState.Error.UnfinishedLongString, lexer.next());
}

test "column tracking" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("local x = 42 + y", "test", allocator);
    defer lexer.deinit();

    // "local" starts at column 1
    try lexer.next();
    try std.testing.expectEqual(TokenType.kw_local, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentColumn());

    // "x" starts at column 7
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 7), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "=" starts at column 9
    try lexer.next();
    try std.testing.expectEqual(TokenType.eq, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 9), lexer.getCurrentColumn());

    // "42" starts at column 11
    try lexer.next();
    try std.testing.expectEqual(TokenType.integer, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 11), lexer.getCurrentColumn());

    // "+" starts at column 14
    try lexer.next();
    try std.testing.expectEqual(TokenType.plus, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 14), lexer.getCurrentColumn());

    // "y" starts at column 16
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 16), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

test "column tracking with newlines" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("a = 1\n  b = 2", "test", allocator);
    defer lexer.deinit();

    // "a" at line 1, column 1
    try lexer.next();
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentLine());
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    try lexer.next(); // =
    try lexer.next(); // 1

    // "b" at line 2, column 3 (after 2 spaces)
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 2), lexer.getCurrentLine());
    try std.testing.expectEqual(@as(i32, 3), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Test reserved word detection
test "reserved words vs identifiers" {
    try expectToken("andd", .identifier, .{ .string = "andd" });
    try expectToken("_and", .identifier, .{ .string = "_and" });
    try expectToken("and_", .identifier, .{ .string = "and_" });
    try expectToken("AND", .identifier, .{ .string = "AND" }); // Lua is case-sensitive
}

// Test isReserved function
test "isReserved function" {
    try std.testing.expect(isReserved(.kw_and));
    try std.testing.expect(isReserved(.kw_local));
    try std.testing.expect(isReserved(.kw_while));
    try std.testing.expect(!isReserved(.identifier));
    try std.testing.expect(!isReserved(.plus));
    try std.testing.expect(!isReserved(.eof));
}

// Test tab column tracking
test "column tracking with tabs" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("a\tb\t\tc", "test", allocator);
    defer lexer.deinit();

    // "a" at column 1
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "b" at column 9 (next tab stop after column 1)
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 9), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "c" at column 25 (two tab stops: 9->17->25)
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 25), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Test UTF-8 column tracking
test "column tracking with UTF-8" {
    const allocator = std.testing.allocator;

    // Test with emoji and other multibyte characters
    var lexer = try LexState.init("a = \"😀\" + b", "test", allocator);
    defer lexer.deinit();

    // "a" at column 1
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "=" at column 3
    try lexer.next();
    try std.testing.expectEqual(TokenType.eq, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 3), lexer.getCurrentColumn());

    // String at column 5 (the emoji counts as 1 column visually)
    try lexer.next();
    try std.testing.expectEqual(TokenType.string, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 5), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "+" at column 9 (5 + opening quote + emoji + closing quote + space)
    try lexer.next();
    try std.testing.expectEqual(TokenType.plus, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 9), lexer.getCurrentColumn());

    // "b" at column 11
    try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 11), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Test mixed tabs and UTF-8. Lua identifiers are ASCII-only, so the non-ASCII
// text lives inside string literals; each multibyte character counts as one column.
test "column tracking with mixed tabs and UTF-8" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("\"€\"\t\"→\"\t\"你好\"", "test", allocator);
    defer lexer.deinit();

    // "€" string at column 1
    try lexer.next();
    try std.testing.expectEqual(TokenType.string, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 1), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "→" string at column 9 (next tab stop after columns 1-3)
    try lexer.next();
    try std.testing.expectEqual(TokenType.string, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 9), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "你好" string at column 17 (next tab stop after columns 9-11)
    try lexer.next();
    try std.testing.expectEqual(TokenType.string, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 17), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);
}

// Non-ASCII bytes outside strings and comments are rejected, as in Lua 5.4
test "non-ASCII identifier is not a name" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("€ = 1", "test", allocator);
    defer lexer.deinit();
    try lexer.next();
    try std.testing.expectEqual(TokenType.unknown, lexer.t.token_type); // the first byte of the UTF-8 sequence
    try std.testing.expectEqual(@as(u8, 0xE2), lexer.unknown_char);
}

// Test column tracking in strings with escape sequences
test "column tracking in strings with escapes" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("x = \"\\n\\t\" + y", "test", allocator);
    defer lexer.deinit();

    try lexer.next(); // x
    lexer.freeSemInfo(&lexer.t.seminfo);
    try lexer.next(); // =

    // String starts at column 5
    try lexer.next();
    try std.testing.expectEqual(TokenType.string, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 5), lexer.getCurrentColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    // "+" at column 12: string literal "\n\t" occupies columns 5-10, then a space
    try lexer.next();
    try std.testing.expectEqual(TokenType.plus, lexer.getCurrentToken());
    try std.testing.expectEqual(@as(i32, 12), lexer.getCurrentColumn());
}

// Test getLastColumn
test "getLastColumn tracking" {
    const allocator = std.testing.allocator;
    var lexer = try LexState.init("abc + def", "test", allocator);
    defer lexer.deinit();

    // Initially lastcolumn is 1
    try std.testing.expectEqual(@as(i32, 1), lexer.getLastColumn());

    try lexer.next(); // abc
    try std.testing.expectEqual(@as(i32, 1), lexer.getLastColumn());
    lexer.freeSemInfo(&lexer.t.seminfo);

    try lexer.next(); // +
    try std.testing.expectEqual(@as(i32, 1), lexer.getLastColumn()); // last token was at column 1

    try lexer.next(); // def
    try std.testing.expectEqual(@as(i32, 5), lexer.getLastColumn()); // last token was at column 5
    lexer.freeSemInfo(&lexer.t.seminfo);
}
