// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The command line: process entry, the dispatch of `prolua [command]`,
//! and the error reporting every command shares (the structure of `lua.c`;
//! `args.zig` is the grammar, `run.zig` is `prolua run`, `init.zig` is
//! `prolua init`, `project.zig` finds and reads a project's `module.toml`,
//! `disasm.zig` is `prolua disasm`, `bench.zig` is `prolua bench`,
//! `test.zig` is `prolua test`, `eval.zig` is `prolua eval`, `add.zig`, `remove.zig`, `update.zig`,
//! `install.zig`, `vendor.zig`, `verify.zig`, `tree.zig`, `why.zig` and
//! `clean.zig` the dependency commands,
//! `repl.zig` is the interactive session).
//!
//! Everything runs inside `pmain`, a native function called through `pcall`,
//! so that an uncaught error anywhere ends up in one place and is reported
//! with a traceback. That structure is also what puts the `[C]: in ?` line at
//! the bottom of every traceback, as in the reference interpreter.

const std = @import("std");
const builtin = @import("builtin");
const prolua = @import("prolua");
const state = prolua.state;
const api = prolua.api;
const debug = prolua.debug;
const lib = prolua.lib;
const version = prolua.version;
const stdio = prolua.stdio;
const args_mod = @import("args.zig");
const run = @import("run.zig");
const init_cmd = @import("init.zig");
const project = @import("project.zig");
const disasm = @import("disasm.zig");
const bench = @import("bench.zig");
const test_cmd = @import("test.zig");
const add = @import("add.zig");
const tree = @import("tree.zig");
const install = @import("install.zig");
const remove = @import("remove.zig");
const update = @import("update.zig");
const vendor = @import("vendor.zig");
const verify = @import("verify.zig");
const why = @import("why.zig");
const clean = @import("clean.zig");
const eval = @import("eval.zig");
const repl = @import("repl.zig");

const LuaState = state.LuaState;

pub const default_progname = "prolua";
/// Prefix for messages; cleared while the REPL runs, as lua.c does, so that
/// interactive errors are not prefixed with the program name
pub var progname: ?[]const u8 = default_progname;

/// Exit codes: 1 for a failure of what was asked, 2 for a usage error
pub const EXIT_FAILURE: u8 = 1;
pub const EXIT_USAGE: u8 = 2;

/// The process, for `pmain` (the reference passes the command line through
/// a light userdata; file-level variables serve the same purpose for a
/// program with one main thread)
var script_args: []const []const u8 = &.{};
var process_allocator: std.mem.Allocator = undefined;
var process_io: std.Io = undefined;
var process_environ: *const std.process.Environ.Map = undefined;
var exit_code: u8 = 0;

pub fn main(init: std.process.Init) !void {
    // Zig 0.16: the runtime hands us a general-purpose allocator, a
    // process-lifetime arena, an `Io` and the argument list via `Init`.
    process_allocator = init.gpa;
    process_io = init.io;
    process_environ = init.environ_map;
    script_args = try init.minimal.args.toSlice(init.arena.allocator());

    const L = try LuaState.init(process_allocator, null);
    defer L.deinit();

    try api.pushCFunction(L, pmain);
    const status = api.pcall(L, 0, 1, 0);
    const result = api.toBoolean(L, -1);
    report(L, status);
    if (result and status == .ok) return;
    std.process.exit(if (exit_code != 0) exit_code else EXIT_FAILURE);
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

/// Print `msg` on stderr, prefixed with the program name (l_message)
pub fn message(msg: []const u8) void {
    if (progname) |p| {
        stdio.eprint("{s}: {s}\n", .{ p, msg });
    } else {
        stdio.eprint("{s}\n", .{msg});
    }
}

/// `message` with a format
pub fn messagef(comptime fmt: []const u8, args: anytype) void {
    if (progname) |p| stdio.eprint("{s}: ", .{p});
    stdio.eprint(fmt ++ "\n", args);
}

/// Report the error object on top of the stack when `status` is not ok, and
/// pop it (report)
pub fn report(L: *LuaState, status: state.ThreadStatus) void {
    if (status == .ok) return;
    if (api.getTop(L) == 0) { // nothing could be pushed: memory, most likely
        message(if (status == .errmem) "not enough memory" else "(no error object)");
        return;
    }
    if (api.toStringCoerce(L, -1) catch null) |msg| {
        message(msg);
    } else {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "(error object is a {s} value)", .{api.typeName(L, api.type_(L, -1))}) catch "(error object)";
        message(text);
    }
    api.pop(L, 1);
}

/// Message handler for uncaught errors: a string message gets a traceback
/// appended; an object with `__tostring` is reported as that string; anything
/// else as its type (msghandler)
fn msghandler(L: *LuaState) !i32 {
    const msg: []const u8 = (try api.toStringCoerce(L, 1)) orelse blk: {
        if (try api.getMetafield(L, 1, "__tostring")) {
            try api.pushValueAt(L, 1);
            try api.call(L, 1, 1);
            if (api.type_(L, -1) == .string) return 1; // that is the message
            api.pop(L, 2);
        }
        try api.pushFString(L, "(error object is a {s} value)", .{api.typeName(L, api.type_(L, 1))});
        break :blk api.toString(L, -1).?;
    };
    try debug.traceback(L, L, msg, 1); // append a standard traceback
    return 1;
}

// ---------------------------------------------------------------------------
// Interrupting a running chunk (lua.c's laction / lstop)
// ---------------------------------------------------------------------------

const can_interrupt = builtin.os.tag != .windows;

/// The state a Ctrl-C interrupts: set around every `docall`
var interrupt_state: ?*LuaState = null;

/// Signal handler: a second Ctrl-C ends the process (the default action is
/// restored), the first one asks the interpreter to stop at its next
/// instruction through a hook, which is the only safe thing to do here
fn laction(sig: std.posix.SIG) callconv(.c) void {
    const default_action = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(sig, &default_action, null);
    if (interrupt_state) |L| {
        L.hook = lstop;
        L.hookmask = .{ .call = true, .ret = true, .line = true, .count = true };
        L.basehookcount = 1;
        L.hookcount = 1;
    }
}

/// The hook the signal handler installs: remove itself and raise
fn lstop(L: *LuaState, ar: *state.DebugInfo) anyerror!void {
    _ = ar;
    L.hook = null;
    L.hookmask = .{};
    return prolua.lib.auxlib.err(L, "interrupted!", .{});
}

fn setSignal(handler: ?std.posix.Sigaction.handler_fn) void {
    const action = std.posix.Sigaction{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

/// Call the function with `narg` arguments below the top, under the message
/// handler, interruptible by Ctrl-C while it runs (docall)
pub fn docall(L: *LuaState, narg: i32, nres: i32) state.ThreadStatus {
    const base = api.getTop(L) - narg; // function index
    api.pushCFunction(L, msghandler) catch return .errmem;
    api.insert(L, base) catch return .errmem;
    if (can_interrupt) {
        interrupt_state = L;
        setSignal(laction);
    }
    const status = api.pcall(L, narg, nres, base);
    if (can_interrupt) {
        setSignal(std.posix.SIG.DFL);
        interrupt_state = null;
    }
    api.remove(L, base) catch {};
    return status;
}

pub fn printVersion() void {
    stdio.print("{s}\n", .{version.BANNER});
}

/// Open the standard libraries; with `no_env`, tell them to ignore the
/// environment first (lua.c's LUA_NOENV: `package` reads LUA_PATH and
/// LUA_CPATH while it opens)
pub fn openLibraries(L: *LuaState, no_env: bool) !void {
    if (no_env) {
        try api.getRegistry(L);
        try api.pushBoolean(L, true);
        try api.setField(L, -2, "LUA_NOENV");
        api.pop(L, 1);
    }
    try lib.openLibs(L);
    // lua.c runs the collector in generational mode (its pmain: LUA_GCGEN
    // after the libraries are open); a script that switches modes sees
    // "generational" as the previous one, and an allocation-heavy program
    // marks a young generation instead of the whole heap
    _ = api.gcGenerational(L, 0, 0);
}

// ---------------------------------------------------------------------------
// Entry point in protected mode (pmain)
// ---------------------------------------------------------------------------

/// Everything the interpreter does, run under `pcall` so that an error is
/// reported rather than crashing. Returns true on the stack for success.
fn pmain(L: *LuaState) !i32 {
    const argv = script_args;
    const command = args_mod.parse(process_allocator, argv) catch |err| switch (err) {
        error.Usage => {
            exit_code = EXIT_USAGE;
            return 0;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    exit_code = switch (command) {
        .version => blk: {
            printVersion();
            break :blk 0;
        },
        .help => |topic| blk: {
            args_mod.printHelp(topic);
            break :blk 0;
        },
        .run => |opts| blk: {
            defer process_allocator.free(opts.evals);
            break :blk try run.execute(L, process_allocator, process_io, process_environ, argv, opts);
        },
        .init => |name| try init_cmd.execute(process_allocator, process_io, name),
        .disasm => |files| try disasm.execute(L, files),
        .bench => |opts| try bench.execute(process_allocator, process_io, process_environ, opts),
        .run_tests => |names| try test_cmd.execute(process_allocator, process_io, process_environ, names),
        .add => |opts| try add.execute(process_allocator, process_io, process_environ, opts),
        .tree => try tree.execute(process_allocator, process_io, process_environ),
        .install => |opts| try install.execute(process_allocator, process_io, process_environ, opts),
        .remove => |module| try remove.execute(process_allocator, process_io, process_environ, module),
        .update => |names| try update.execute(process_allocator, process_io, process_environ, names),
        .vendor => try vendor.execute(process_allocator, process_io, process_environ),
        .verify => try verify.execute(process_allocator, process_io, process_environ),
        .why => |module| try why.execute(process_allocator, process_io, process_environ, module),
        .clean => try clean.execute(process_allocator, process_io, process_environ),
        .eval => |opts| try eval.execute(L, process_allocator, process_io, process_environ, opts),
        .repl => blk: {
            // No arguments at all: interactive if a terminal, else run stdin;
            // module paths resolve through the working directory's project
            try openLibraries(L, false);
            try run.createArgTable(L, &.{}, argv[0], &.{});
            const cwd = try std.process.currentPathAlloc(process_io, process_allocator);
            defer process_allocator.free(cwd);
            var proj = project.findFrom(process_allocator, process_io, cwd) catch |err| switch (err) {
                error.Reported => break :blk EXIT_FAILURE,
                else => return err,
            };
            defer if (proj) |*p| p.deinit(process_allocator);
            const modules = run.installResolver(L, process_allocator, process_io, process_environ, if (proj) |*p| p else null, cwd) catch |err| switch (err) {
                error.Reported => break :blk EXIT_FAILURE,
                else => return err,
            };
            defer {
                modules.deinit();
                process_allocator.destroy(modules);
            }
            if (repl.stdinIsTty()) {
                printVersion();
                try repl.doREPL(L);
                break :blk 0;
            }
            break :blk if (run.dofile(L, null) == .ok) 0 else EXIT_FAILURE;
        },
    };
    if (exit_code != 0) return 0;
    try api.pushBoolean(L, true);
    return 1;
}

test "docall reports a traceback through the message handler" {
    const L = try LuaState.init(std.testing.allocator, null);
    defer L.deinit();
    try lib.openLibs(L);
    try std.testing.expectEqual(state.ThreadStatus.ok, api.loadBuffer(L, "local function f() error('boom') end f()", "=t", "t"));
    const status = docall(L, 0, 0);
    try std.testing.expectEqual(state.ThreadStatus.errrun, status);
    const msg = api.toString(L, -1).?;
    try std.testing.expect(std.mem.startsWith(u8, msg, "t:1: boom\nstack traceback:\n\t[C]: in function 'error'\n\tt:1: in local 'f'"));
}

test {
    _ = args_mod;
    _ = run;
    _ = init_cmd;
    _ = project;
    _ = disasm;
    _ = bench;
    _ = test_cmd;
    _ = add;
    _ = tree;
    _ = install;
    _ = remove;
    _ = update;
    _ = vendor;
    _ = verify;
    _ = why;
    _ = clean;
    _ = eval;
    _ = repl;
    _ = prolua.source;
    _ = prolua.integrity;
    _ = prolua.manifest;
    _ = prolua.import_path;
    _ = prolua.resolver;
}
