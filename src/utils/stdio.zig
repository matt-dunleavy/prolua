// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Process standard I/O for Zig 0.16's explicit `std.Io` model.
//!
//! Zig 0.16 removed `std.io.getStdOut()` and friends; every file operation now
//! takes an `std.Io` instance. This module owns one process-wide single-threaded
//! `Io` so that code deep inside the interpreter (the `print` builtin, error
//! reporting) can reach stdout/stderr/stdin without threading an `Io` through
//! every call. Entry points that receive `std.process.Init` may prefer `init.io`.

const std = @import("std");

var threaded: std.Io.Threaded = .init_single_threaded;

/// The process-wide `Io` used for standard streams.
pub fn io() std.Io {
    return threaded.io();
}

/// A buffered writer on stdout. Call `flush()` on `.interface` before the
/// buffer goes out of scope or before reading from stdin.
pub fn stdoutWriter(buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(io(), buffer);
}

/// A buffered writer on stderr. Pass an empty buffer for unbuffered output.
pub fn stderrWriter(buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(io(), buffer);
}

/// A buffered reader on stdin.
pub fn stdinReader(buffer: []u8) std.Io.File.Reader {
    return std.Io.File.stdin().readerStreaming(io(), buffer);
}

/// Formatted print to stdout, flushed before returning. Errors are ignored,
/// mirroring `std.debug.print`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = stdoutWriter(&buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// Formatted print to stderr, flushed before returning. Errors are ignored.
pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = stderrWriter(&buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// Whether stdout is attached to a terminal.
pub fn stdoutIsTty() bool {
    return std.Io.File.stdout().isTty(io()) catch false;
}

test "stdio writers construct" {
    var buf: [16]u8 = undefined;
    var w = stderrWriter(&buf);
    try w.interface.writeAll("");
    try w.interface.flush();
}
