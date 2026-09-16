// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Standard I/O library (liolib.c).
//!
//! A file handle is a full userdata holding an `LStream`, sharing one
//! metatable kept in the registry under `FILEHANDLE_KEY`. Zig 0.16 has no
//! `FILE*` equivalent, so `LStream` carries the buffering, the logical file
//! position and the read/write capabilities that C's stdio would own.
//!
//! Positional reads and writes are preferred over `std.Io.File.Reader` and
//! `.Writer` because a Lua handle must read and write through a single shared
//! position (`"r+"`, `"a+"`), and must be able to seek at any point; the two
//! stream helpers each own a private buffer and cursor and cannot be combined
//! on one file without corrupting each other. Streams that cannot seek (the
//! standard handles, pipes) fall back to `readStreaming`/`writeStreamingAll`.

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const vm = @import("../vm.zig");
const stdio = @import("../utils/stdio.zig");
const oslib = @import("oslib.zig");

const REGISTRY = api.REGISTRY_INDEX;

const FILEHANDLE_KEY = "FILE*";
const IO_INPUT = "_IO_input";
const IO_OUTPUT = "_IO_output";

/// Size of both the read and the write buffer carried by every handle
/// (LUAL_BUFFERSIZE).
const BUF_SIZE = 4096;

/// Maximum length of a numeral accepted by the `"n"` format (L_MAXLENNUM)
const MAX_LEN_NUM = 200;

/// Upper bound on formats passed to `lines`, kept under the 255 upvalues a
/// `CClosure` can hold once the three control upvalues are counted
/// (MAXARGLINE).
const MAX_ARG_LINE = 250;

const Buffering = enum(u8) { none, full, line };

/// The state behind a Lua file handle (luaL_Stream).
///
/// Lives in the userdata payload, which `gc.newUserdata` allocates as a plain
/// `[]u8`, so every access goes through an `align(1)` pointer.
const LStream = struct {
    file: std.Io.File,
    open: bool,
    /// The three standard handles are borrowed from the process: closing them
    /// would take `print` and the REPL down with them, so `close` refuses
    /// (io_noclose) and the collector leaves them alone.
    std_stream: bool,
    readable: bool,
    writable: bool,
    /// `"a"`/`"a+"`: every write is repositioned to the end first, since
    /// `std.Io` has no O_APPEND equivalent in its open options.
    append: bool,
    /// Cleared the first time a positional operation reports `Unseekable`, so
    /// pipes and terminals degrade to streaming instead of failing.
    seekable: bool,
    /// Logical position, i.e. what `seek` reports: the offset of the next byte
    /// the program will see, not of the next byte the kernel will hand over.
    pos: u64,
    rstart: u32,
    rend: u32,
    wlen: u32,
    wcap: u32,
    buffering: Buffering,
    /// Name of the last failed `std.Io` operation, standing in for `errno`
    /// plus `ferror`; cleared when an entry point starts a new operation.
    last_error: ?[]const u8,
    /// Set by `io.popen`: the child at the other end of the pipe, waited for
    /// on close, and the `Io` instance that spawned it.
    child: ?std.process.Child,
    spawner: ?*std.Io.Threaded,
    rbuf: [BUF_SIZE]u8,
    wbuf: [BUF_SIZE]u8,
};

const StreamPtr = *align(1) LStream;

// ---------------------------------------------------------------------------
// Errors reported the Lua way
// ---------------------------------------------------------------------------

/// Best-effort `errno` for a Zig error name, so the third result of a failed
/// file operation stays useful to scripts that compare against known codes.
fn errnoFor(name: []const u8) i64 {
    const table = .{
        .{ "FileNotFound", 2 },
        .{ "AccessDenied", 13 },
        .{ "PermissionDenied", 13 },
        .{ "IsDir", 21 },
        .{ "NotDir", 20 },
        .{ "PathAlreadyExists", 17 },
        .{ "NoSpaceLeft", 28 },
        .{ "DiskQuota", 122 },
        .{ "BrokenPipe", 32 },
        .{ "Unseekable", 29 },
        .{ "FileTooBig", 27 },
        .{ "FileBusy", 26 },
        .{ "DeviceBusy", 16 },
        .{ "SystemResources", 12 },
        .{ "NameTooLong", 36 },
        .{ "SymLinkLoop", 40 },
        .{ "ProcessFdQuotaExceeded", 24 },
        .{ "SystemFdQuotaExceeded", 23 },
        .{ "ReadOnlyFileSystem", 30 },
        .{ "NotOpenForReading", 9 },
        .{ "NotOpenForWriting", 9 },
        .{ "InputOutput", 5 },
        .{ "WouldBlock", 11 },
        .{ "EndOfStream", 0 },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return -1;
}

/// Push `nil, message, errno` (luaL_fileresult on failure)
fn pushFileResult(L: *state.LuaState, errname: []const u8, fname: ?[]const u8) !i32 {
    try api.pushNil(L);

    const code = errnoFor(errname);
    // Report the system's own wording ("No such file or directory") rather
    // than Zig's error name, which is what scripts and users expect to see
    const text: []const u8 = if (code != 0) std.mem.span(strerror(@intCast(code))) else errname;

    var buf: [512]u8 = undefined;
    const msg = if (fname) |f|
        std.fmt.bufPrint(&buf, "{s}: {s}", .{ f, text }) catch text
    else
        text;
    try api.pushString(L, msg);
    try api.pushInteger(L, code);
    return 3;
}

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

/// Push the result of an operation that recorded its failure on the handle
fn pushStreamResult(L: *state.LuaState, s: StreamPtr) !i32 {
    if (s.last_error) |e| {
        s.last_error = null;
        return pushFileResult(L, e, null);
    }
    try api.pushBoolean(L, true);
    return 1;
}

// ---------------------------------------------------------------------------
// Handle identity and lifetime
// ---------------------------------------------------------------------------

/// The handle at `idx`, or null if it is not one (luaL_testudata).
fn testStream(L: *state.LuaState, idx: i32) ?StreamPtr {
    if (!api.getMetatable(L, idx)) return null;
    _ = api.getField(L, REGISTRY, FILEHANDLE_KEY) catch {
        api.pop(L, 1);
        return null;
    };
    const same = api.rawEqual(L, -1, -2);
    api.pop(L, 2);
    if (!same) return null;
    const p = api.toUserdata(L, idx) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The handle at `idx`, raising if the argument is not one (luaL_checkudata)
fn checkStream(L: *state.LuaState, idx: i32) !StreamPtr {
    return testStream(L, idx) orelse aux.typeError(L, idx, FILEHANDLE_KEY);
}

/// The handle at `idx`, raising if it has been closed (tofile).
///
/// Using a closed handle is one of the few io errors Lua raises rather than
/// reports, because the alternative is reading from a stale descriptor.
fn toFile(L: *state.LuaState, idx: i32) !StreamPtr {
    const s = try checkStream(L, idx);
    if (!s.open) return aux.err(L, "attempt to use a closed file", .{});
    return s;
}

/// Push a fresh handle, closed, with the shared metatable already installed.
///
/// Created closed first so a failure between here and the open leaves a handle
/// the collector can safely finalize (newprefile).
fn newStream(L: *state.LuaState) !StreamPtr {
    const raw = try api.newUserdata(L, @sizeOf(LStream), 0);
    const s: StreamPtr = @ptrCast(raw);
    s.* = .{
        .file = undefined,
        .open = false,
        .std_stream = false,
        .readable = false,
        .writable = false,
        .append = false,
        .seekable = false,
        .pos = 0,
        .rstart = 0,
        .rend = 0,
        .wlen = 0,
        .wcap = BUF_SIZE,
        .buffering = .full,
        .last_error = null,
        .child = null,
        .spawner = null,
        .rbuf = undefined,
        .wbuf = undefined,
    };
    _ = try api.getField(L, REGISTRY, FILEHANDLE_KEY);
    _ = try api.setMetatable(L, -2);
    return s;
}

/// Flush the pending writes of every open handle, as C's `exit` flushes
/// every stdio stream: `os.exit` calls this so a script that wrote to a file
/// and exited without closing it loses nothing, as under the reference.
/// Every handle has `__gc`, so every live one is on the collector's `finobj`
/// or `tobefnz` list; the handle metatable tells them from other userdata.
pub fn flushAll(L: *state.LuaState) void {
    _ = api.getField(L, REGISTRY, FILEHANDLE_KEY) catch return;
    defer api.pop(L, 1);
    const meta = (L.top - 1)[0].asTable() orelse return;
    const g = &L.l_G.gc;
    const io = stdio.io();
    for ([_]?*value.GCObject{ g.finobj, g.tobefnz }) |head| {
        var o = head;
        while (o) |obj| : (o = obj.next) {
            if (obj.tt != @intFromEnum(value.ValueType.userdata)) continue;
            const u: *value.Userdata = @fieldParentPtr("header", obj);
            if (u.metatable != meta) continue;
            const s: StreamPtr = @ptrCast(u.data);
            if (s.open and s.writable) _ = flushWrites(s, io);
        }
    }
}

// ---------------------------------------------------------------------------
// Low-level stream operations
// ---------------------------------------------------------------------------

/// Read into `dest` at the logical position without advancing it. Returns 0 at
/// end of stream; a failure is recorded on the handle and also reported as 0,
/// the way C code checks `ferror` after a short `fread`.
fn rawRead(s: StreamPtr, io: std.Io, dest: []u8) usize {
    if (dest.len == 0) return 0;
    if (s.seekable) {
        if (s.file.readPositional(io, &.{dest}, s.pos)) |n| {
            return n;
        } else |e| switch (e) {
            error.Unseekable => s.seekable = false,
            else => {
                s.last_error = @errorName(e);
                return 0;
            },
        }
    }
    return s.file.readStreaming(io, &.{dest}) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => {
            s.last_error = @errorName(e);
            return 0;
        },
    };
}

fn rawWrite(s: StreamPtr, io: std.Io, bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    if (s.seekable) {
        if (s.append) {
            s.pos = s.file.length(io) catch |e| blk: {
                if (e == error.Unseekable) {
                    s.seekable = false;
                    break :blk s.pos;
                }
                s.last_error = @errorName(e);
                return false;
            };
        }
    }
    if (s.seekable) {
        if (s.file.writePositionalAll(io, bytes, s.pos)) |_| {
            s.pos += bytes.len;
            return true;
        } else |e| switch (e) {
            error.Unseekable => s.seekable = false,
            else => {
                s.last_error = @errorName(e);
                return false;
            },
        }
    }
    s.file.writeStreamingAll(io, bytes) catch |e| {
        s.last_error = @errorName(e);
        return false;
    };
    return true;
}

fn flushWrites(s: StreamPtr, io: std.Io) bool {
    if (s.wlen == 0) return true;
    const pending = s.wbuf[0..s.wlen];
    s.wlen = 0;
    return rawWrite(s, io, pending);
}

/// Drop buffered read-ahead. `pos` counts only consumed bytes, so nothing else
/// has to be adjusted.
fn discardReadAhead(s: StreamPtr) void {
    s.rstart = 0;
    s.rend = 0;
}

fn writeBytes(s: StreamPtr, io: std.Io, bytes: []const u8) bool {
    discardReadAhead(s);
    if (s.buffering == .none) return rawWrite(s, io, bytes);

    var rest = bytes;
    while (rest.len > 0) {
        const space: usize = s.wcap - s.wlen;
        if (space == 0) {
            if (!flushWrites(s, io)) return false;
            continue;
        }
        const take = @min(space, rest.len);
        const at: usize = s.wlen;
        @memcpy(s.wbuf[at..][0..take], rest[0..take]);
        s.wlen += @intCast(take);
        rest = rest[take..];
    }
    if (s.buffering == .line and std.mem.indexOfScalar(u8, bytes, '\n') != null) {
        return flushWrites(s, io);
    }
    return true;
}

/// Fill `dest` with up to `dest.len` bytes; 0 means end of stream or error
fn readSome(s: StreamPtr, io: std.Io, dest: []u8) usize {
    if (dest.len == 0) return 0;
    if (!flushWrites(s, io)) return 0;

    const buffered: usize = s.rend - s.rstart;
    if (buffered > 0) {
        const n = @min(dest.len, buffered);
        const at: usize = s.rstart;
        @memcpy(dest[0..n], s.rbuf[at..][0..n]);
        s.rstart += @intCast(n);
        s.pos += n;
        return n;
    }
    if (dest.len >= BUF_SIZE) {
        const n = rawRead(s, io, dest);
        s.pos += n;
        return n;
    }
    const n = rawRead(s, io, s.rbuf[0..]);
    if (n == 0) return 0;
    s.rstart = 0;
    s.rend = @intCast(n);
    const take = @min(dest.len, n);
    @memcpy(dest[0..take], s.rbuf[0..take]);
    s.rstart = @intCast(take);
    s.pos += take;
    return take;
}

fn readByte(s: StreamPtr, io: std.Io) ?u8 {
    var one: [1]u8 = undefined;
    if (readSome(s, io, one[0..]) == 0) return null;
    return one[0];
}

/// Push the byte just returned by `readByte` back (ungetc).
///
/// Only ever called immediately after a successful `readByte`, which
/// guarantees the byte is still sitting in the read buffer.
fn unreadByte(s: StreamPtr) void {
    if (s.rstart == 0) return;
    s.rstart -= 1;
    s.pos -= 1;
}

fn closeStream(s: StreamPtr, io: std.Io) bool {
    if (!s.open) return true;
    const flushed = flushWrites(s, io);
    s.open = false;
    discardReadAhead(s);
    if (s.std_stream) return flushed;
    s.file.close(io);
    return flushed;
}

// ---------------------------------------------------------------------------
// Opening files
// ---------------------------------------------------------------------------

const OpenMode = struct {
    base: u8,
    plus: bool,
};

/// Check `mode` against `[rwa]%+?b*` and split it (l_checkmode)
fn parseMode(mode: []const u8) ?OpenMode {
    if (mode.len == 0) return null;
    var i: usize = 0;
    const base = mode[i];
    if (base != 'r' and base != 'w' and base != 'a') return null;
    i += 1;
    var plus = false;
    if (i < mode.len and mode[i] == '+') {
        plus = true;
        i += 1;
    }
    // The only accepted extension is 'b'; POSIX has no separate text mode, so
    // it is parsed and ignored (L_MODEEXT).
    while (i < mode.len) : (i += 1) {
        if (mode[i] != 'b') return null;
    }
    return .{ .base = base, .plus = plus };
}

fn openInto(s: StreamPtr, path: []const u8, m: OpenMode) !void {
    const io = stdio.io();
    const dir = std.Io.Dir.cwd();
    const file = switch (m.base) {
        'r' => try dir.openFile(io, path, .{
            .mode = if (m.plus) .read_write else .read_only,
            .allow_directory = false,
        }),
        'w' => try dir.createFile(io, path, .{ .read = m.plus, .truncate = true }),
        else => try dir.createFile(io, path, .{ .read = m.plus, .truncate = false }),
    };
    s.file = file;
    s.open = true;
    s.seekable = true;
    s.readable = m.base == 'r' or m.plus;
    s.writable = m.base != 'r' or m.plus;
    s.append = m.base == 'a';
    s.pos = if (m.base == 'a') file.length(io) catch 0 else 0;
}

/// Open `fname` or raise, leaving the handle on the stack (opencheck)
fn openCheck(L: *state.LuaState, fname: []const u8, comptime mode: []const u8) !void {
    const m = comptime parseMode(mode).?;
    const s = try newStream(L);
    openInto(s, fname, m) catch |e| {
        return aux.err(L, "cannot open file '{s}' ({s})", .{ fname, @errorName(e) });
    };
}

// ---------------------------------------------------------------------------
// Default input and output
// ---------------------------------------------------------------------------

/// Push the registry's default handle and return it (getiofile)
fn getIoFile(L: *state.LuaState, comptime key: []const u8, comptime what: []const u8) !StreamPtr {
    _ = try api.getField(L, REGISTRY, key);
    const s = testStream(L, -1) orelse {
        return aux.err(L, "default {s} file is not a file handle", .{what});
    };
    if (!s.open) return aux.err(L, "default {s} file is closed", .{what});
    return s;
}

fn gIoFile(L: *state.LuaState, comptime key: []const u8, comptime mode: []const u8) !i32 {
    if (!aux.isNoneOrNil(L, 1)) {
        if (api.toString(L, 1)) |fname| {
            try openCheck(L, fname, mode);
        } else {
            _ = try toFile(L, 1); // check that it is a valid file handle
            try api.pushValueAt(L, 1);
        }
        try api.setField(L, REGISTRY, key);
    }
    _ = try api.getField(L, REGISTRY, key);
    return 1;
}

// ---------------------------------------------------------------------------
// Reading (g_read and friends)
// ---------------------------------------------------------------------------

fn readLine(L: *state.LuaState, s: StreamPtr, io: std.Io, chop: bool) !bool {
    var b = aux.Buffer.init(L);
    defer b.deinit();

    var saw_newline = false;
    while (readByte(s, io)) |c| {
        if (c == '\n') {
            saw_newline = true;
            break;
        }
        try b.addChar(c);
    }
    if (!chop and saw_newline) try b.addChar('\n');
    const got = b.items().len;
    try b.pushResult();
    return saw_newline or got > 0;
}

fn readAll(L: *state.LuaState, s: StreamPtr, io: std.Io) !void {
    var b = aux.Buffer.init(L);
    defer b.deinit();

    var chunk: [BUF_SIZE]u8 = undefined;
    while (true) {
        const n = readSome(s, io, chunk[0..]);
        if (n == 0) break;
        try b.addString(chunk[0..n]);
    }
    try b.pushResult();
}

fn readChars(L: *state.LuaState, s: StreamPtr, io: std.Io, want: usize) !bool {
    var b = aux.Buffer.init(L);
    defer b.deinit();

    var chunk: [BUF_SIZE]u8 = undefined;
    var remaining = want;
    while (remaining > 0) {
        const n = readSome(s, io, chunk[0..@min(remaining, chunk.len)]);
        if (n == 0) break;
        try b.addString(chunk[0..n]);
        remaining -= n;
    }
    const got = b.items().len;
    try b.pushResult();
    return got > 0;
}

/// A zero-length read: push `""` and report whether anything is left (test_eof)
fn testEof(L: *state.LuaState, s: StreamPtr, io: std.Io) !bool {
    const c = readByte(s, io);
    if (c != null) unreadByte(s);
    try api.pushString(L, "");
    return c != null;
}

/// One-character lookahead over the stream while scanning a numeral (RN)
const NumScanner = struct {
    s: StreamPtr,
    io: std.Io,
    c: ?u8,
    n: usize,
    buf: [MAX_LEN_NUM + 1]u8,

    fn nextc(r: *NumScanner) bool {
        if (r.n >= MAX_LEN_NUM) {
            r.n = 0; // invalidate the result rather than truncate it
            return false;
        }
        r.buf[r.n] = r.c orelse return false;
        r.n += 1;
        r.c = readByte(r.s, r.io);
        return true;
    }

    fn accept(r: *NumScanner, set: []const u8) bool {
        const c = r.c orelse return false;
        if (c == set[0] or c == set[1]) return r.nextc();
        return false;
    }

    fn digits(r: *NumScanner, hex: bool) usize {
        var count: usize = 0;
        while (r.c) |c| {
            const ok = if (hex) std.ascii.isHex(c) else std.ascii.isDigit(c);
            if (!ok or !r.nextc()) break;
            count += 1;
        }
        return count;
    }
};

fn readNumber(L: *state.LuaState, s: StreamPtr, io: std.Io) !bool {
    var r = NumScanner{ .s = s, .io = io, .c = null, .n = 0, .buf = undefined };

    while (true) {
        r.c = readByte(s, io);
        const c = r.c orelse break;
        if (!std.ascii.isWhitespace(c)) break;
    }

    var hex = false;
    var count: usize = 0;
    _ = r.accept("-+");
    if (r.accept("00")) {
        if (r.accept("xX")) hex = true else count = 1;
    }
    count += r.digits(hex);
    if (r.accept("..")) count += r.digits(hex);
    if (count > 0 and r.accept(if (hex) "pP" else "eE")) {
        _ = r.accept("-+");
        _ = r.digits(false);
    }
    if (r.c != null) unreadByte(s);

    if (r.n > 0 and api.stringToNumber(L, r.buf[0..r.n])) return true;
    try api.pushNil(L); // a result for g_read to replace with the fail value
    return false;
}

/// Read every requested format, pushing one result each (g_read).
///
/// `first` is the stack index of the first format; results are counted from
/// the top, so anything already on the stack below them is left alone.
fn gRead(L: *state.LuaState, s: StreamPtr, first: i32) !i32 {
    const io = stdio.io();
    s.last_error = null;
    _ = flushWrites(s, io);
    // Checked here rather than left to the kernel so the message is the same
    // on every platform, and so `io.stdout:read()` fails without a syscall.
    if (!s.readable) return pushFileResult(L, "NotOpenForReading", null);

    var nargs = api.getTop(L) - 1;
    var n = first;
    var success = true;

    if (nargs == 0) {
        success = try readLine(L, s, io, true);
        n = first + 1;
    } else {
        while (nargs > 0 and success) : ({
            nargs -= 1;
            n += 1;
        }) {
            if (api.type_(L, n) == .number) {
                const count = try aux.checkInteger(L, n);
                if (count < 0) return aux.argError(L, n, "invalid format");
                success = if (count == 0)
                    try testEof(L, s, io)
                else
                    try readChars(L, s, io, @intCast(count));
            } else {
                var f = try aux.checkString(L, n);
                if (f.len > 0 and f[0] == '*') f = f[1..]; // 5.1 compatibility
                if (f.len == 0) return aux.argError(L, n, "invalid format");
                switch (f[0]) {
                    'n' => success = try readNumber(L, s, io),
                    'l' => success = try readLine(L, s, io, true),
                    'L' => success = try readLine(L, s, io, false),
                    'a' => {
                        try readAll(L, s, io);
                        success = true; // reading nothing still yields ""
                    },
                    else => return aux.argError(L, n, "invalid format"),
                }
            }
        }
    }

    if (s.last_error) |e| {
        s.last_error = null;
        return pushFileResult(L, e, null);
    }
    if (!success) {
        api.pop(L, 1);
        try api.pushNil(L);
    }
    return n - first;
}

// ---------------------------------------------------------------------------
// Writing (g_write)
// ---------------------------------------------------------------------------

fn gWrite(L: *state.LuaState, s: StreamPtr, arg_start: i32) !i32 {
    const io = stdio.io();
    s.last_error = null;
    if (!s.writable) {
        const nres = try pushFileResult(L, "NotOpenForWriting", null);
        try api.pushInteger(L, 0); // bytes written before the failure
        return nres + 1;
    }

    const top = api.getTop(L);
    var arg = arg_start;
    var total: i64 = 0;
    while (arg < top) : (arg += 1) {
        var numbuf: [64]u8 = undefined;
        const bytes = if (api.type_(L, arg) == .number) blk: {
            const num: value.Number = if (api.isInteger(L, arg))
                .{ .integer = api.toInteger(L, arg).? }
            else
                .{ .float = api.toNumber(L, arg).? };
            break :blk vm.numberToStringBuf(&numbuf, num);
        } else try aux.checkString(L, arg);

        if (!writeBytes(s, io, bytes)) {
            const e = s.last_error orelse "InputOutput";
            s.last_error = null;
            const nres = try pushFileResult(L, e, null);
            try api.pushInteger(L, total);
            return nres + 1;
        }
        total += @intCast(bytes.len);
    }
    return 1; // the handle is already the value on top
}

// ---------------------------------------------------------------------------
// C closures for `lines`
// ---------------------------------------------------------------------------

/// Build the iterator closure over the handle at index 1 (aux_lines).
///
/// Upvalues: 1 the handle, 2 the format count, 3 whether the iterator owns the
/// handle, 4.. the formats.
fn auxLines(L: *state.LuaState, toclose: bool) !void {
    const nformats = api.getTop(L) - 1;
    try aux.argCheck(L, nformats <= MAX_ARG_LINE, MAX_ARG_LINE + 2, "too many arguments");

    try api.pushValueAt(L, 1);
    try api.pushInteger(L, nformats);
    try api.pushBoolean(L, toclose);
    var i: i32 = 2;
    while (i <= nformats + 1) : (i += 1) try api.pushValueAt(L, i);

    try api.pushCClosure(L, ioReadline, @intCast(3 + nformats));
}

fn ioReadline(L: *state.LuaState) !i32 {
    const s = testStream(L, api.upvalueIndex(1)) orelse {
        return aux.err(L, "file is already closed", .{});
    };
    if (!s.open) return aux.err(L, "file is already closed", .{});
    const nformats: i32 = @intCast(api.toInteger(L, api.upvalueIndex(2)) orelse 0);

    // The generic for passes state and control; drop them and rebuild the
    // argument list g_read expects.
    try api.setTop(L, 1);
    var i: i32 = 1;
    while (i <= nformats) : (i += 1) try api.pushValueAt(L, api.upvalueIndex(3 + i));

    const nres = try gRead(L, s, 2);
    if (api.toBoolean(L, -nres)) return nres;

    if (nres > 1) { // read failed with an error message rather than at EOF
        const msg = api.toString(L, -nres + 1) orelse "read error";
        try api.pushString(L, msg);
        return api.error_(L);
    }
    if (api.toBoolean(L, api.upvalueIndex(3))) {
        _ = closeStream(s, stdio.io());
    }
    return 0;
}

// ---------------------------------------------------------------------------
// io functions
// ---------------------------------------------------------------------------

fn ioOpen(L: *state.LuaState) !i32 {
    const filename = try aux.checkString(L, 1);
    const mode = try aux.optString(L, 2, "r");
    const m = parseMode(mode) orelse return aux.argError(L, 2, "invalid mode");

    const s = try newStream(L);
    openInto(s, filename, m) catch |e| {
        return pushFileResult(L, @errorName(e), filename);
    };
    return 1;
}

/// io.popen(prog [, mode])
/// Runs `prog` through the shell with one end of a pipe as its stdout
/// (mode "r") or stdin (mode "w"). Closing the handle waits for the child
/// and reports its exit the way `os.execute` does (l_pclose /
/// luaL_execresult).
fn ioPopen(L: *state.LuaState) !i32 {
    const cmd = try aux.checkString(L, 1);
    const mode = try aux.optString(L, 2, "r");
    const reading = std.mem.eql(u8, mode, "r");
    try aux.argCheck(L, reading or std.mem.eql(u8, mode, "w"), 2, "invalid mode");
    const s = try newStream(L);

    // As in `os.execute`, the shared `Io` cannot spawn (failing allocator, no
    // environment), so the pipe gets its own instance, kept until close.
    const spawner = try L.allocator.create(std.Io.Threaded);
    spawner.* = .init(L.allocator, .{ .environ = oslib.processEnviron() });
    const io = spawner.io();
    const argv = [_][]const u8{ oslib.shell_argv0, oslib.shell_flag, cmd };
    const child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = if (reading) .inherit else .pipe,
        .stdout = if (reading) .pipe else .inherit,
    }) catch |err| {
        spawner.deinit();
        L.allocator.destroy(spawner);
        return pushFileResult(L, @errorName(err), cmd);
    };
    s.file = if (reading) child.stdout.? else child.stdin.?;
    s.child = child;
    s.spawner = spawner;
    s.open = true;
    s.readable = reading;
    s.writable = !reading;
    s.seekable = false;
    return 1;
}

/// Close this end of a `popen` pipe and wait for the child (l_pclose). The
/// pipe is closed first so a child blocked on it can finish.
fn reapChild(allocator: std.mem.Allocator, s: StreamPtr) std.process.Child.WaitError!std.process.Child.Term {
    const spawner = s.spawner.?;
    const io = spawner.io();
    var child = s.child.?;
    _ = closeStream(s, io); // closes the pipe end, which is the child's `stdout`/`stdin` field
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    const term = child.wait(io);
    s.child = null;
    s.spawner = null;
    spawner.deinit();
    allocator.destroy(spawner);
    return term;
}

fn ioTmpfile(L: *state.LuaState) !i32 {
    const io = stdio.io();
    const s = try newStream(L);
    const dir = std.Io.Dir.cwd();

    var namebuf: [128]u8 = undefined;
    var attempt: u32 = 0;
    while (attempt < 128) : (attempt += 1) {
        tmp_counter +%= 1;
        const path = std.fmt.bufPrint(&namebuf, "{s}/prolua_tmp_{x}", .{ tmpDir(), tmp_counter }) catch
            return pushFileResult(L, "NameTooLong", null);
        const file = dir.createFile(io, path, .{
            .read = true,
            .truncate = true,
            .exclusive = true,
        }) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return pushFileResult(L, @errorName(e), null),
        };
        // Unlinking while the descriptor is open reproduces C `tmpfile()`: the
        // contents stay reachable and vanish when the last handle closes.
        dir.deleteFile(io, path) catch {};
        s.file = file;
        s.open = true;
        s.seekable = true;
        s.readable = true;
        s.writable = true;
        return 1;
    }
    return pushFileResult(L, "PathAlreadyExists", null);
}

var tmp_counter: u32 = 0;

/// Zig 0.16 dropped `std.posix.getenv`, and reading `TMPDIR` through
/// `std.process` needs an allocator this call site does not have, so the
/// conventional directory is used directly.
fn tmpDir() []const u8 {
    return if (@import("builtin").os.tag == .windows) "." else "/tmp";
}

fn ioClose(L: *state.LuaState) !i32 {
    if (api.getTop(L) == 0) _ = try api.getField(L, REGISTRY, IO_OUTPUT);
    return fClose(L);
}

fn ioFlush(L: *state.LuaState) !i32 {
    const s = try getIoFile(L, IO_OUTPUT, "output");
    s.last_error = null;
    _ = flushWrites(s, stdio.io());
    return pushStreamResult(L, s);
}

fn ioInput(L: *state.LuaState) !i32 {
    return gIoFile(L, IO_INPUT, "r");
}

fn ioOutput(L: *state.LuaState) !i32 {
    return gIoFile(L, IO_OUTPUT, "w");
}

fn ioRead(L: *state.LuaState) !i32 {
    const s = try getIoFile(L, IO_INPUT, "input");
    return gRead(L, s, 1);
}

fn ioWrite(L: *state.LuaState) !i32 {
    const s = try getIoFile(L, IO_OUTPUT, "output");
    return gWrite(L, s, 1);
}

fn ioLines(L: *state.LuaState) !i32 {
    if (api.getTop(L) == 0) try api.pushNil(L); // ensure index 1 exists

    var toclose = false;
    if (api.isNil(L, 1)) {
        _ = try getIoFile(L, IO_INPUT, "input");
        try api.replace(L, 1);
    } else {
        const fname = try aux.checkString(L, 1);
        try openCheck(L, fname, "r");
        try api.replace(L, 1);
        toclose = true;
    }
    _ = try toFile(L, 1);

    try auxLines(L, toclose);
    if (!toclose) return 1;

    // state, control, and the handle as the generic for's to-be-closed value
    try api.pushNil(L);
    try api.pushNil(L);
    try api.pushValueAt(L, 1);
    return 4;
}

fn ioType(L: *state.LuaState) !i32 {
    try aux.checkAny(L, 1);
    const s = testStream(L, 1) orelse {
        try api.pushNil(L);
        return 1;
    };
    try api.pushString(L, if (s.open) "file" else "closed file");
    return 1;
}

// ---------------------------------------------------------------------------
// File handle methods
// ---------------------------------------------------------------------------

fn fRead(L: *state.LuaState) !i32 {
    const s = try toFile(L, 1);
    return gRead(L, s, 2);
}

fn fWrite(L: *state.LuaState) !i32 {
    const s = try toFile(L, 1);
    try api.pushValueAt(L, 1); // the handle is the successful result
    return gWrite(L, s, 2);
}

fn fLines(L: *state.LuaState) !i32 {
    _ = try toFile(L, 1);
    try auxLines(L, false);
    return 1;
}

fn fSeek(L: *state.LuaState) !i32 {
    const s = try toFile(L, 1);
    const io = stdio.io();
    const op = try aux.checkOption(L, 2, "cur", &.{ "set", "cur", "end" });
    const offset = try aux.optInteger(L, 3, 0);

    s.last_error = null;
    if (!flushWrites(s, io)) return pushStreamResult(L, s);
    if (!s.seekable) return pushFileResult(L, "Unseekable", null);
    discardReadAhead(s);

    const base: i64 = switch (op) {
        0 => 0,
        1 => @intCast(s.pos),
        else => @intCast(s.file.length(io) catch |e|
            return pushFileResult(L, @errorName(e), null)),
    };
    const target = base +| offset;
    if (target < 0) return pushFileResult(L, "InvalidSeek", null);

    s.pos = @intCast(target);
    try api.pushInteger(L, target);
    return 1;
}

fn fFlush(L: *state.LuaState) !i32 {
    const s = try toFile(L, 1);
    s.last_error = null;
    _ = flushWrites(s, stdio.io());
    return pushStreamResult(L, s);
}

fn fSetvbuf(L: *state.LuaState) !i32 {
    const s = try toFile(L, 1);
    const op = try aux.checkOption(L, 2, null, &.{ "no", "full", "line" });
    const size = try aux.optInteger(L, 3, BUF_SIZE);

    s.last_error = null;
    if (!flushWrites(s, stdio.io())) return pushStreamResult(L, s);
    s.buffering = switch (op) {
        0 => .none,
        1 => .full,
        else => .line,
    };
    // The buffer lives inside the GC-managed handle, so a requested size can
    // only ever shrink it.
    s.wcap = @intCast(std.math.clamp(size, 1, BUF_SIZE));
    try api.pushBoolean(L, true);
    return 1;
}

/// Close the handle at index 1 (aux_close)
fn auxClose(L: *state.LuaState) !i32 {
    const s = try checkStream(L, 1);
    if (s.std_stream) {
        // io_noclose: the process owns these, so the handle stays usable.
        _ = flushWrites(s, stdio.io());
        try api.pushNil(L);
        try api.pushString(L, "cannot close standard file");
        return 2;
    }
    s.last_error = null;
    if (s.child != null) {
        const term = reapChild(L.allocator, s) catch |err| return pushFileResult(L, @errorName(err), null);
        return oslib.execResult(L, term);
    }
    _ = closeStream(s, stdio.io());
    return pushStreamResult(L, s);
}

fn fClose(L: *state.LuaState) !i32 {
    _ = try toFile(L, 1);
    return auxClose(L);
}

fn fGc(L: *state.LuaState) !i32 {
    const s = try checkStream(L, 1); // tolstream: a wrong argument is an error even here
    if (s.open and !s.std_stream) { // ignore closed files
        if (s.child != null) _ = reapChild(L.allocator, s) catch {} else _ = closeStream(s, stdio.io());
    }
    return 0;
}

fn fToString(L: *state.LuaState) !i32 {
    const s = try checkStream(L, 1);
    var buf: [64]u8 = undefined;
    const text = if (s.open)
        std.fmt.bufPrint(&buf, "file (0x{x})", .{@intFromPtr(s)}) catch "file"
    else
        "file (closed)";
    try api.pushString(L, text);
    return 1;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

const iolib = [_]aux.Reg{
    .{ .name = "close", .func = ioClose },
    .{ .name = "flush", .func = ioFlush },
    .{ .name = "input", .func = ioInput },
    .{ .name = "lines", .func = ioLines },
    .{ .name = "open", .func = ioOpen },
    .{ .name = "output", .func = ioOutput },
    .{ .name = "popen", .func = ioPopen },
    .{ .name = "read", .func = ioRead },
    .{ .name = "tmpfile", .func = ioTmpfile },
    .{ .name = "type", .func = ioType },
    .{ .name = "write", .func = ioWrite },
};

const methods = [_]aux.Reg{
    .{ .name = "close", .func = fClose },
    .{ .name = "flush", .func = fFlush },
    .{ .name = "lines", .func = fLines },
    .{ .name = "read", .func = fRead },
    .{ .name = "seek", .func = fSeek },
    .{ .name = "setvbuf", .func = fSetvbuf },
    .{ .name = "write", .func = fWrite },
};

fn createMeta(L: *state.LuaState) !void {
    try api.newTable(L);

    try api.pushCFunction(L, fGc);
    try api.setField(L, -2, "__gc");
    try api.pushCFunction(L, fGc);
    try api.setField(L, -2, "__close");
    try api.pushCFunction(L, fToString);
    try api.setField(L, -2, "__tostring");
    try api.pushString(L, FILEHANDLE_KEY);
    try api.setField(L, -2, "__name");

    try aux.newLib(L, &methods);
    try api.setField(L, -2, "__index");

    try api.setField(L, REGISTRY, FILEHANDLE_KEY);
}

/// Add a standard handle to the io table on top of the stack (createstdfile)
fn createStdFile(
    L: *state.LuaState,
    file: std.Io.File,
    comptime regkey: ?[]const u8,
    name: []const u8,
    readable: bool,
    writable: bool,
) !void {
    const s = try newStream(L);
    s.file = file;
    s.open = true;
    s.std_stream = true;
    s.readable = readable;
    s.writable = writable;
    s.seekable = false;
    // Unbuffered: `print` and the REPL write to the same descriptors through
    // their own writers, and buffering here would reorder the output.
    s.buffering = .none;

    if (regkey) |key| {
        try api.pushValueAt(L, -1);
        try api.setField(L, REGISTRY, key);
    }
    try api.setField(L, -2, name);
}

pub fn openIo(L: *state.LuaState) !void {
    try createMeta(L);
    try aux.registerLib(L, "io", &iolib);

    try createStdFile(L, std.Io.File.stdin(), IO_INPUT, "stdin", true, false);
    try createStdFile(L, std.Io.File.stdout(), IO_OUTPUT, "stdout", false, true);
    try createStdFile(L, std.Io.File.stderr(), null, "stderr", false, true);

    api.pop(L, 1); // the io table left by registerLib
}

test "parseMode accepts the modes fopen does" {
    try std.testing.expect(parseMode("r") != null);
    try std.testing.expect(parseMode("rb") != null);
    try std.testing.expect(parseMode("w+b") != null);
    try std.testing.expect(parseMode("a+") != null);
    try std.testing.expectEqual(@as(u8, 'a'), parseMode("ab").?.base);
    try std.testing.expect(parseMode("a+").?.plus);
    try std.testing.expect(parseMode("") == null);
    try std.testing.expect(parseMode("rw") == null);
    try std.testing.expect(parseMode("x") == null);
    try std.testing.expect(parseMode("r+x") == null);
}

test "errnoFor maps the errors scripts check for" {
    try std.testing.expectEqual(@as(i64, 2), errnoFor("FileNotFound"));
    try std.testing.expectEqual(@as(i64, 13), errnoFor("AccessDenied"));
    try std.testing.expectEqual(@as(i64, -1), errnoFor("SomethingElse"));
}
