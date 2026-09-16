// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The interactive session (doREPL in lua.c): read a line, try it as an
//! expression first so its value prints, then as statements, reading more
//! lines while the chunk is incomplete.

const std = @import("std");
const prolua = @import("prolua");
const state = prolua.state;
const api = prolua.api;
const stdio = prolua.stdio;
const main = @import("main.zig");

const LuaState = state.LuaState;

const EOFMARK = "<eof>";

/// Whether a failed load stopped at the end of the input, so that more
/// lines might complete it (incomplete)
fn incomplete(L: *LuaState, status: state.ThreadStatus) bool {
    if (status == .errsyntax) {
        if (api.toString(L, -1)) |msg| {
            if (std.mem.endsWith(u8, msg, EOFMARK)) {
                api.pop(L, 1);
                return true;
            }
        }
    }
    return false;
}

const Repl = struct {
    L: *LuaState,
    reader: std.Io.File.Reader,
    line_buf: std.ArrayList(u8) = .empty,

    /// Show a prompt and read a line; null at end of input (pushline)
    fn readLine(self: *Repl, firstline: bool) !?[]const u8 {
        stdio.print("{s}", .{if (firstline) "> " else ">> "});
        // `takeDelimiter` consumes the newline; the "exclusive" variant leaves
        // it in the stream and would hand back an empty line forever
        return try self.reader.interface.takeDelimiter('\n');
    }

    /// Read a complete chunk, trying `return <line>` first so that
    /// expressions print their value (loadline). Leaves the compiled chunk
    /// on the stack, or the error message. Returns null at end of input.
    fn loadLine(self: *Repl) !?state.ThreadStatus {
        const L = self.L;
        api.setTop(L, 0) catch {};
        const first = (try self.readLine(true)) orelse return null;
        self.line_buf.clearRetainingCapacity();
        if (first.len > 0 and first[0] == '=') {
            // `=expr` still means `return expr`, for compatibility with 5.2
            try self.line_buf.appendSlice(L.allocator, "return ");
            try self.line_buf.appendSlice(L.allocator, first[1..]);
        } else {
            try self.line_buf.appendSlice(L.allocator, first);
        }

        // As an expression (addreturn)
        var retline: std.ArrayList(u8) = .empty;
        defer retline.deinit(L.allocator);
        try retline.appendSlice(L.allocator, "return ");
        try retline.appendSlice(L.allocator, self.line_buf.items);
        var status = api.loadBuffer(L, retline.items, "=stdin", "t");
        if (status == .ok) return status;
        api.pop(L, 1);

        // As statements, reading more lines while the chunk is incomplete
        // (multiline)
        while (true) {
            status = api.loadBuffer(L, self.line_buf.items, "=stdin", "t");
            if (!incomplete(L, status)) return status;
            const more = (try self.readLine(false)) orelse return status; // no more input
            try self.line_buf.append(L.allocator, '\n');
            try self.line_buf.appendSlice(L.allocator, more);
        }
    }

    /// Print whatever a chunk returned, through the global `print`
    /// (l_print)
    fn printResults(self: *Repl) void {
        const L = self.L;
        const n = api.getTop(L);
        if (n <= 0) return;
        _ = api.checkStack(L, 3);
        _ = api.getGlobal(L, "print") catch return;
        api.insert(L, 1) catch return;
        if (api.pcall(L, n, 0, 0) != .ok) {
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "error calling 'print' ({s})", .{api.toString(L, -1) orelse "?"}) catch "error calling 'print'";
            main.message(text);
        }
    }

    fn run(self: *Repl) !void {
        const L = self.L;
        defer self.line_buf.deinit(L.allocator);
        while (try self.loadLine()) |load_status| {
            var status = load_status;
            if (status == .ok) status = main.docall(L, 0, api.LUA_MULTRET);
            if (status == .ok) self.printResults() else main.report(L, status);
        }
        api.setTop(L, 0) catch {};
        stdio.print("\n", .{});
    }
};

pub fn doREPL(L: *LuaState) !void {
    const oldprogname = main.progname;
    main.progname = null; // no name prefix on interactive messages
    defer main.progname = oldprogname;
    var in_buf: [4096]u8 = undefined;
    var repl = Repl{ .L = L, .reader = stdio.stdinReader(&in_buf) };
    try repl.run();
}

pub fn stdinIsTty() bool {
    return std.Io.File.stdin().isTty(stdio.io()) catch false;
}
