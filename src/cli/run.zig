// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua run`: a script file, a project's entry point, or standard input,
//! with the `arg` table, `-e` and `-l` in order, `LUA_INIT`, and the REPL
//! after it when asked (the chunk-running half of `lua.c`, under the new
//! grammar).

const std = @import("std");
const prolua = @import("prolua");
const state = prolua.state;
const api = prolua.api;
const oslib = prolua.oslib;
const lib = prolua.lib;
const main = @import("main.zig");
const args_mod = @import("args.zig");
const project = @import("project.zig");
const repl = @import("repl.zig");
const resolver = prolua.resolver;

const LuaState = state.LuaState;

const LUA_INIT_VAR = "LUA_INIT";
const LUA_INITVARVERSION = LUA_INIT_VAR ++ "_5_4";

/// Returns the exit code
pub fn execute(L: *LuaState, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, argv: []const []const u8, opts: args_mod.RunOptions) !u8 {
    // What to run: a file name (null for standard input), or nothing; and
    // the project it belongs to, whose manifest resolves module paths
    var script: ?[]const u8 = null;
    var have_script = false;
    var entry_path: ?[]u8 = null;
    defer if (entry_path) |p| allocator.free(p);
    var proj: ?project.Project = null;
    defer if (proj) |*p| p.deinit(allocator);
    // Where the search for a project started, for the message when there is none
    var where: []const u8 = ".";
    var where_owned: ?[:0]u8 = null;
    defer if (where_owned) |w| allocator.free(w);

    if (opts.target) |t| {
        have_script = true;
        if (std.mem.eql(u8, t, "-")) {
            script = null; // standard input
            proj = findProject(allocator, io, null, &where, &where_owned) catch |err| switch (err) {
                error.Reported => return 1,
                else => return err,
            };
        } else if (std.Io.Dir.cwd().statFile(io, t, .{})) |st| {
            if (st.kind == .directory) {
                proj = project.load(allocator, io, t) catch |err| switch (err) {
                    error.Reported => return 1,
                    else => return err,
                };
                entry_path = proj.?.programEntry(allocator, io) catch |err| switch (err) {
                    error.Reported => return 1,
                    else => return err,
                };
                script = entry_path;
            } else {
                script = t;
                // A file's project is the one above it; failing that, the working directory's
                proj = findProject(allocator, io, std.fs.path.dirname(t) orelse ".", &where, &where_owned) catch |err| switch (err) {
                    error.Reported => return 1,
                    else => return err,
                };
                if (proj == null) proj = findProject(allocator, io, null, &where, &where_owned) catch |err| switch (err) {
                    error.Reported => return 1,
                    else => return err,
                };
            }
        } else |err| {
            main.messagef("cannot open {s}: {s}", .{ t, @errorName(err) });
            return 1;
        }
    } else {
        proj = findProject(allocator, io, null, &where, &where_owned) catch |err| switch (err) {
            error.Reported => return 1,
            else => return err,
        };
        const evals_only = opts.evals.len > 0 or opts.interactive;
        if (proj) |*p| {
            // The project's entry runs after the evals; with evals or -i, a
            // project without one (a library) is a context, not an error
            if (evals_only and !(try p.hasEntry(allocator, io))) {
                // nothing to run after the evals
            } else {
                entry_path = p.programEntry(allocator, io) catch |err| switch (err) {
                    error.Reported => return 1,
                    else => return err,
                };
                script = entry_path;
                have_script = true;
            }
        } else if (!evals_only) {
            main.messagef("nothing to run: give a .lua file, a project directory, or run inside a project (prolua run --help)", .{});
            return 2;
        }
    }

    try main.openLibraries(L, opts.no_env);
    if (opts.warn) L.l_G.warn_on = true;
    const modules = installResolver(L, allocator, io, environ, if (proj) |*p| p else null, where) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    defer {
        modules.deinit();
        allocator.destroy(modules);
    }
    if (have_script) {
        try createArgTable(L, argv[0..opts.target_index], script orelse "-", opts.args);
    } else {
        // As the reference does without a script: the interpreter at 0, its options after it
        try createArgTable(L, &.{}, argv[0], argv[1..]);
    }

    if (!opts.no_env and handleLuaInit(L) != .ok) return 1;
    for (opts.evals) |e| {
        const status = switch (e.kind) {
            .eval => dostring(L, e.text, "=(command line)"),
            .lib => dolibrary(L, e.text),
        };
        if (status != .ok) return 1;
    }
    if (have_script) {
        if (runScript(L, script) != .ok) return 1;
    }
    if (opts.interactive) try repl.doREPL(L);
    return 0;
}

/// The project above `start` (null: the working directory); `where`
/// records where the search began, for the message when there is none
fn findProject(allocator: std.mem.Allocator, io: std.Io, start: ?[]const u8, where: *[]const u8, where_owned: *?[:0]u8) !?project.Project {
    if (start) |s| {
        where.* = s;
    } else {
        if (where_owned.*) |w| allocator.free(w);
        where_owned.* = try std.process.currentPathAlloc(io, allocator);
        where.* = where_owned.*.?;
    }
    // A manifest that does not read was reported by findFrom; the caller exits 1
    return project.findFrom(allocator, io, where.*);
}

/// The module searcher for `proj` (or for no project: module paths then
/// fail with a message saying so), installed in `package.searchers`. The
/// searcher holds the pointer, so the resolver lives on the heap until the
/// caller destroys it after the last `require` can run.
pub fn installResolver(L: *LuaState, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, proj: ?*const project.Project, where: []const u8) !*resolver.Resolver {
    const r = try allocator.create(resolver.Resolver);
    errdefer allocator.destroy(r);
    r.* = resolver.Resolver.init(allocator, io, environ, if (proj) |p| p.root else null, if (proj) |p| &p.fields else null, where) catch |err| switch (err) {
        error.VendorInconsistent => {
            main.messagef("vendor directory is inconsistent with module.toml\n\nrun:\n\n    prolua vendor\n", .{});
            return error.Reported;
        },
        error.VendorManifestInvalid => {
            main.messagef("{s}/{s}/{s} is not a vendor manifest prolua vendor wrote; run prolua vendor again, or delete vendor/", .{ proj.?.root, resolver.integrity.VENDOR_DIR, resolver.integrity.VENDOR_FILE });
            return error.Reported;
        },
        else => return err,
    };
    errdefer r.deinit();
    try resolver.install(L, r);
    return r;
}

/// Run a loaded chunk, or report why it could not load (dochunk)
fn dochunk(L: *LuaState, load_status: state.ThreadStatus) state.ThreadStatus {
    var status = load_status;
    if (status == .ok) status = main.docall(L, 0, 0);
    main.report(L, status);
    return status;
}

pub fn dofile(L: *LuaState, name: ?[]const u8) state.ThreadStatus {
    return dochunk(L, api.loadFile(L, name, "bt"));
}

pub fn dostring(L: *LuaState, s: []const u8, name: []const u8) state.ThreadStatus {
    return dochunk(L, api.loadBuffer(L, s, name, "bt"));
}

/// `require` a module and store it in a global (dolibrary): `-l mod` or
/// `-l g=mod`
pub fn dolibrary(L: *LuaState, globname_in: []const u8) state.ThreadStatus {
    var globname = globname_in;
    var modname = globname_in;
    if (std.mem.indexOfScalar(u8, globname_in, '=')) |eq| {
        globname = globname_in[0..eq];
        modname = globname_in[eq + 1 ..];
    }
    _ = api.getGlobal(L, "require") catch return .errmem;
    api.pushString(L, modname) catch return .errmem;
    const status = main.docall(L, 1, 1); // call require(modname)
    if (status == .ok) api.setGlobal(L, globname) catch return .errmem; // globname = require(modname)
    main.report(L, status);
    return status;
}

/// Push the script arguments from the global `arg` table (pushargs)
fn pushargs(L: *LuaState) !i32 {
    if ((try api.getGlobal(L, "arg")) != .table) return error.NoArgTable;
    const n: i32 = @intCast(api.rawLen(L, -1));
    if (!api.checkStack(L, n + 3)) return error.StackOverflow;
    var i: i32 = 1;
    while (i <= n) : (i += 1) try api.rawGetI(L, -i, i);
    try api.remove(L, -i); // remove the table
    return n;
}

/// Load and run the script (null: standard input) with the arguments of
/// the `arg` table (handle_script)
fn runScript(L: *LuaState, fname: ?[]const u8) state.ThreadStatus {
    var status = api.loadFile(L, fname, "bt");
    if (status == .ok) {
        const n = pushargs(L) catch {
            api.pushString(L, "'arg' is not a table") catch {};
            main.report(L, .errrun);
            return .errrun;
        };
        status = main.docall(L, n, api.LUA_MULTRET);
    }
    main.report(L, status);
    return status;
}

/// The global `arg` table: `before` (the interpreter and its options) at
/// negative indices ending at -1, `zero` at 0, `after` from 1 (createargtable)
pub fn createArgTable(L: *LuaState, before: []const []const u8, zero: []const u8, after: []const []const u8) !void {
    try api.createTable(L, @intCast(after.len), @intCast(before.len + 1));
    for (before, 0..) |a, i| {
        try api.pushString(L, a);
        try api.rawSetI(L, -2, -@as(i64, @intCast(before.len - i)));
    }
    try api.pushString(L, zero);
    try api.rawSetI(L, -2, 0);
    for (after, 1..) |a, i| {
        try api.pushString(L, a);
        try api.rawSetI(L, -2, @intCast(i));
    }
    try api.setGlobal(L, "arg");
}

/// Run `LUA_INIT_5_4` or `LUA_INIT`: a file when it starts with '@', a
/// chunk otherwise (handle_luainit)
pub fn handleLuaInit(L: *LuaState) state.ThreadStatus {
    var name: []const u8 = "=" ++ LUA_INITVARVERSION;
    var init = oslib.getEnv(LUA_INITVARVERSION);
    if (init == null) {
        name = "=" ++ LUA_INIT_VAR;
        init = oslib.getEnv(LUA_INIT_VAR);
    }
    const text = init orelse return .ok;
    if (text.len > 0 and text[0] == '@') return dofile(L, text[1..]);
    return dostring(L, text, name);
}

test "createArgTable puts the script at index 0" {
    const L = try LuaState.init(std.testing.allocator, null);
    defer L.deinit();
    try lib.openLibs(L);
    const before = [_][]const u8{ "prolua", "run", "-e", "x" };
    const after = [_][]const u8{ "a", "b" };
    try createArgTable(L, &before, "script.lua", &after);
    _ = try api.getGlobal(L, "arg");
    try api.rawGetI(L, -1, 0);
    try std.testing.expectEqualStrings("script.lua", api.toString(L, -1).?);
    try api.rawGetI(L, -2, 2);
    try std.testing.expectEqualStrings("b", api.toString(L, -1).?);
    try api.rawGetI(L, -3, -4);
    try std.testing.expectEqualStrings("prolua", api.toString(L, -1).?);
    try api.rawGetI(L, -4, -1);
    try std.testing.expectEqualStrings("x", api.toString(L, -1).?);
    try std.testing.expectEqual(@as(usize, 2), api.rawLen(L, -5));
}
