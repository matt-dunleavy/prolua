// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! The package library and `require` (loadlib.c).
//!
//! Only the Lua-source searchers are present: this interpreter cannot load C
//! modules, so `package.cpath` and the all-in-one loader have no counterpart.

const std = @import("std");
const api = @import("../api.zig");
const aux = @import("auxlib.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const oslib = @import("oslib.zig");

/// Registry keys, matching LUA_LOADED_TABLE and LUA_PRELOAD_TABLE
pub const LOADED = "_LOADED";
pub const PRELOAD = "_PRELOAD";

/// Stock Lua's default search path (LUA_ROOT "/usr/local/"): pure-Lua
/// modules installed there, then the current directory. Fedora's `lua`
/// is built with /usr/share and /usr/lib64 instead; like LUA_IDSIZE, the
/// stock value is the one followed.
const DEFAULT_PATH = "/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua;/usr/local/lib/lua/5.4/?.lua;/usr/local/lib/lua/5.4/?/init.lua;./?.lua;./?/init.lua";
const PATH_SEP = ';';
const PATH_MARK = '?';

pub fn openPackage(L: *state.LuaState) !void {
    const regs = [_]aux.Reg{
        .{ .name = "searchpath", .func = pkg_searchpath },
        .{ .name = "loadlib", .func = pkg_loadlib },
    };
    try aux.registerLib(L, "package", &regs);

    // package.loaded doubles as the registry's _LOADED table, so `require`
    // and the error-message name lookup both see the same table
    try loadedTable(L);
    try api.setField(L, -2, "loaded");

    try api.newTable(L);
    try api.pushValueAt(L, -1);
    try setRegistryTable(L, PRELOAD);
    try api.setField(L, -2, "preload");

    try setPath(L, "path", "LUA_PATH", DEFAULT_PATH);
    // No C loader exists, but scripts probe for these fields
    try setPath(L, "cpath", "LUA_CPATH", "");
    try api.pushString(L, "/\n;\n?\n!\n-\n"); // LUA_DIRSEP PATH_SEP PATH_MARK EXEC_DIR IGMARK
    try api.setField(L, -2, "config");

    const searchers = [_]api.CFunction{ searcherPreload, searcherLua, searcherC, searcherCroot };
    try api.createTable(L, searchers.len, 0);
    for (searchers, 1..) |f, i| {
        try api.pushCFunction(L, f);
        try api.setI(L, -2, @intCast(i));
    }
    try api.setField(L, -2, "searchers");

    api.pop(L, 1); // the package table

    try api.pushCFunction(L, pkg_require);
    try api.setGlobal(L, "require");
}

/// Whether `-E` was given: the registry's LUA_NOENV, as lua.c sets it
fn noEnv(L: *state.LuaState) !bool {
    try api.getRegistry(L);
    _ = try api.getField(L, -1, "LUA_NOENV");
    const b = api.toBoolean(L, -1);
    api.pop(L, 2);
    return b;
}

/// Set `package.<fieldname>` from the environment (luaL's setpath): the
/// versioned variable first (`LUA_PATH_5_4`), then the plain one; a ";;"
/// in the value stands for the default path; the default alone when the
/// variable is absent or `-E` was given. The package table is at the top.
fn setPath(L: *state.LuaState, comptime fieldname: []const u8, comptime envname: []const u8, dft: []const u8) !void {
    const env = oslib.getEnv(envname ++ "_5_4") orelse oslib.getEnv(envname);
    if (env == null or try noEnv(L)) {
        try api.pushString(L, dft);
    } else if (std.mem.indexOf(u8, env.?, ";;")) |mark| {
        const path = env.?;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(L.allocator);
        if (mark > 0) {
            try out.appendSlice(L.allocator, path[0..mark]);
            try out.append(L.allocator, ';');
        }
        try out.appendSlice(L.allocator, dft);
        if (mark + 2 < path.len) {
            try out.append(L.allocator, ';');
            try out.appendSlice(L.allocator, path[mark + 2 ..]);
        }
        try api.pushString(L, out.items);
    } else {
        try api.pushString(L, env.?);
    }
    try api.setField(L, -2, fieldname);
}

/// Push the registry's `_LOADED` table, creating it on first use
pub fn loadedTable(L: *state.LuaState) !void {
    try api.getRegistry(L);
    if ((try api.getField(L, -1, LOADED)) != .table) {
        api.pop(L, 1);
        try api.newTable(L);
        try api.pushValueAt(L, -1);
        try api.setField(L, -3, LOADED);
    }
    try api.remove(L, -2); // drop the registry, keep the table
}

fn setRegistryTable(L: *state.LuaState, name: []const u8) !void {
    try api.getRegistry(L);
    try api.insert(L, -2);
    try api.setField(L, -2, name);
    api.pop(L, 1);
}

/// Record an already-open library in `package.loaded` so `require "string"`
/// returns it rather than searching the filesystem
pub fn markLoaded(L: *state.LuaState, name: []const u8) !void {
    try loadedTable(L);
    if ((try api.getGlobal(L, name)) == .nil) {
        api.pop(L, 2);
        return;
    }
    try api.setField(L, -2, name);
    api.pop(L, 1);
}

/// package.searchpath(name, path [, sep [, rep]])
fn pkg_searchpath(L: *state.LuaState) !i32 {
    const name = try api.checkString(L, 1);
    const path = try api.checkString(L, 2);
    const sep = try aux.optString(L, 3, ".");
    const rep = try aux.optString(L, 4, "/");

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(L.allocator);

    // Translate `sep` to `rep` in the module name (e.g. a.b -> a/b)
    var fixed = std.ArrayList(u8).empty;
    defer fixed.deinit(L.allocator);
    if (sep.len == 0) {
        try fixed.appendSlice(L.allocator, name);
    } else {
        var rest = name;
        while (std.mem.indexOf(u8, rest, sep)) |at| {
            try fixed.appendSlice(L.allocator, rest[0..at]);
            try fixed.appendSlice(L.allocator, rep);
            rest = rest[at + sep.len ..];
        }
        try fixed.appendSlice(L.allocator, rest);
    }

    // Every template is tried, including empty ones, exactly as
    // getnextfilename splits the path; an empty path has no templates
    if (path.len > 0) {
        var it = std.mem.splitScalar(u8, path, PATH_SEP);
        while (it.next()) |template| {
            buf.clearRetainingCapacity();
            for (template) |c| {
                if (c == PATH_MARK) {
                    try buf.appendSlice(L.allocator, fixed.items);
                } else {
                    try buf.append(L.allocator, c);
                }
            }
            if (readable(buf.items)) {
                try api.pushString(L, buf.items);
                return 1;
            }
        }
    }

    // The message is the substituted path with each separator turned into
    // a new "no file" line (pusherrornotfound); the caller supplies the
    // prefix for the first one
    var errors = std.ArrayList(u8).empty;
    defer errors.deinit(L.allocator);
    try errors.appendSlice(L.allocator, "no file '");
    for (path) |c| {
        if (c == PATH_MARK) {
            try errors.appendSlice(L.allocator, fixed.items);
        } else if (c == PATH_SEP) {
            try errors.appendSlice(L.allocator, "'\n\tno file '");
        } else {
            try errors.append(L.allocator, c);
        }
    }
    try errors.append(L.allocator, '\'');

    try api.pushNil(L);
    try api.pushString(L, errors.items);
    return 2;
}

fn readable(path: []const u8) bool {
    const stdio = @import("../utils/stdio.zig");
    var file = std.Io.Dir.cwd().openFile(stdio.io(), path, .{}) catch return false;
    file.close(stdio.io());
    return true;
}

/// The preload searcher: package.preload[name]
fn searcherPreload(L: *state.LuaState) !i32 {
    const name = try api.checkString(L, 1);
    try api.getRegistry(L);
    _ = try api.getField(L, -1, PRELOAD);
    try api.remove(L, -2);

    if ((try api.getField(L, -1, name)) == .nil) {
        api.pop(L, 2);
        try api.pushFString(L, "no field package.preload['{s}']", .{name});
        return 1;
    }
    try api.remove(L, -2);
    try api.pushString(L, ":preload:");
    return 2;
}

/// Look for `name` on `package.<pname>` (findfile). Returns the file name,
/// left on top of the stack; when nothing is found the searcher's "no file"
/// lines are left there instead and null is returned.
fn findFile(L: *state.LuaState, name: []const u8, comptime pname: []const u8) !?[]const u8 {
    if ((try api.getGlobal(L, "package")) != .table) {
        api.pop(L, 1);
        return aux.err(L, "'package' must be a table", .{});
    }
    if ((try api.getField(L, -1, pname)) != .string) {
        api.pop(L, 2);
        return aux.err(L, "'package." ++ pname ++ "' must be a string", .{});
    }
    const path = api.toString(L, -1).?;

    // Reuse searchpath by calling it directly on a small stack frame
    try api.pushCFunction(L, pkg_searchpath);
    try api.pushString(L, name);
    try api.pushString(L, path);
    try api.call(L, 2, 2);
    // Stack: package, path, filename-or-nil, nil-or-message
    const found = !api.isNil(L, -2);
    try api.remove(L, if (found) -1 else -2);
    try api.remove(L, -2);
    try api.remove(L, -2);
    return if (found) api.toString(L, -1).? else null;
}

/// The Lua-source searcher: find `name` on package.path and load it
fn searcherLua(L: *state.LuaState) !i32 {
    const name = try api.checkString(L, 1);
    const filename = (try findFile(L, name, "path")) orelse return 1; // module not found in this path

    const status = api.loadFile(L, filename, "bt");
    if (status != .ok) {
        const msg = api.toString(L, -1) orelse "syntax error";
        return aux.err(L, "error loading module '{s}' from file '{s}':\n\t{s}", .{ name, filename, msg });
    }

    // Leave: loader function, filename (passed to the loader as its 2nd arg)
    try api.pushValueAt(L, -2);
    return 2;
}

/// Native modules cannot be loaded: this is what a Lua built without
/// dynamic-library support reports once it has found the file (DLMSG)
fn cLibraryError(L: *state.LuaState, name: []const u8, filename: []const u8) anyerror {
    return aux.err(L, "error loading module '{s}' from file '{s}':\n\tdynamic libraries not enabled; check your Lua installation", .{ name, filename });
}

/// package.loadlib(path, funcname): no dynamic loading here, so the answer
/// is the one a Lua built without LUA_USE_DLOPEN gives
fn pkg_loadlib(L: *state.LuaState) !i32 {
    _ = try api.checkString(L, 1);
    _ = try api.checkString(L, 2);
    try api.pushNil(L);
    try api.pushString(L, "dynamic libraries not enabled; check your Lua installation");
    try api.pushString(L, "absent");
    return 3;
}

/// The C-library searcher (searcher_C): looks on package.cpath, so the
/// "no file" lines of a failed require match the reference
fn searcherC(L: *state.LuaState) !i32 {
    const name = try api.checkString(L, 1);
    const filename = (try findFile(L, name, "cpath")) orelse return 1;
    return cLibraryError(L, name, filename);
}

/// The all-in-one C-library searcher (searcher_Croot): for `a.b.c` looks
/// for the library of the root module `a` on package.cpath
fn searcherCroot(L: *state.LuaState) !i32 {
    const name = try api.checkString(L, 1);
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return 0; // is root
    const filename = (try findFile(L, name[0..dot], "cpath")) orelse return 1; // root not found
    return cLibraryError(L, name, filename);
}

/// require(modname)
fn pkg_require(L: *state.LuaState) !i32 {
    const name = try api.checkString(L, 1);
    api.setTop(L, 1) catch {};

    try loadedTable(L);
    _ = try api.getField(L, -1, name);
    if (api.toBoolean(L, -1)) {
        return 1; // already loaded
    }
    api.pop(L, 1);

    // Try each searcher in turn, accumulating their failure messages
    if ((try api.getGlobal(L, "package")) != .table) {
        return aux.err(L, "'package' must be a table", .{});
    }
    if ((try api.getField(L, -1, "searchers")) != .table) {
        return aux.err(L, "'package.searchers' must be a table", .{});
    }

    var errors = std.ArrayList(u8).empty;
    defer errors.deinit(L.allocator);

    var i: i64 = 1;
    while (true) : (i += 1) {
        try api.getI(L, -1, i);
        if (api.isNil(L, -1)) {
            api.pop(L, 1);
            return aux.err(L, "module '{s}' not found:{s}", .{ name, errors.items });
        }

        try api.pushString(L, name);
        try api.call(L, 1, 2);

        if (api.isFunction(L, -2)) break; // found a loader

        if (api.isString(L, -2)) {
            // Each searcher's message goes on its own indented line (findloader)
            try errors.appendSlice(L.allocator, "\n\t");
            try errors.appendSlice(L.allocator, api.toString(L, -2).?);
        }
        api.pop(L, 2);
    }

    // Call loader(name, extra) and store whatever it returns
    try api.pushString(L, name);
    try api.insert(L, -2); // loader, name, extra
    try api.call(L, 2, 1);

    if (api.isNil(L, -1)) {
        api.pop(L, 1);
        try api.pushBoolean(L, true);
    }

    // package.loaded[name] = result
    try api.pushValueAt(L, -1);
    try loadedTable(L);
    try api.insert(L, -2);
    try api.setField(L, -2, name);
    api.pop(L, 1);

    return 1;
}
