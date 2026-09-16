// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");
const api = @import("../api.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");
const vm = @import("../vm.zig");
const table = @import("../table.zig");
const string_mod = @import("../string.zig");
const gc_module = @import("../gc.zig");
const stdio = @import("../utils/stdio.zig");
const aux = @import("auxlib.zig");

/// Opens all base library functions
pub fn openBase(L: *state.LuaState) !void {
    // Register global functions
    try registerFunction(L, "print", base_print);
    try registerFunction(L, "type", base_type);
    try registerFunction(L, "tostring", base_tostring);
    try registerFunction(L, "tonumber", base_tonumber);
    try registerFunction(L, "assert", base_assert);
    try registerFunction(L, "error", base_error);
    try registerFunction(L, "pcall", base_pcall);
    try registerFunction(L, "xpcall", base_xpcall);
    try registerFunction(L, "getmetatable", base_getmetatable);
    try registerFunction(L, "setmetatable", base_setmetatable);
    try registerFunction(L, "rawget", base_rawget);
    try registerFunction(L, "rawset", base_rawset);
    try registerFunction(L, "rawlen", base_rawlen);
    try registerFunction(L, "rawequal", base_rawequal);
    try registerFunction(L, "next", base_next);
    try registerFunction(L, "pairs", base_pairs);
    try registerFunction(L, "ipairs", base_ipairs);
    try registerFunction(L, "select", base_select);
    try registerFunction(L, "collectgarbage", base_collectgarbage);
    try registerFunction(L, "dofile", base_dofile);
    try registerFunction(L, "loadfile", base_loadfile);
    try registerFunction(L, "load", base_load);
    try registerFunction(L, "warn", base_warn);

    // Set global _G
    try api.pushGlobalTable(L);
    try api.setGlobal(L, "_G");

    // Scripts version-check against this, so it must read exactly as
    // the reference interpreter's does
    try api.pushString(L, "Lua 5.4");
    try api.setGlobal(L, "_VERSION");
}

fn registerFunction(L: *state.LuaState, name: []const u8, func: api.CFunction) !void {
    try api.pushCFunction(L, func);
    try api.setGlobal(L, name);
}

/// warn(msg1, ···)
/// Emits a warning made of its string arguments. A single argument starting
/// with '@' is a control message: "@on" and "@off" switch warnings on and
/// off; they start off, as in the reference interpreter (luaB_warn and
/// lauxlib's warning functions).
fn base_warn(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    _ = try api.checkString(L, 1); // at least one argument
    var i: i32 = 2;
    while (i <= n) : (i += 1) _ = try api.checkString(L, i);

    const first = api.toString(L, 1).?;
    if (n == 1 and first.len > 0 and first[0] == '@') {
        if (std.mem.eql(u8, first, "@on")) L.l_G.warn_on = true;
        if (std.mem.eql(u8, first, "@off")) L.l_G.warn_on = false;
        return 0; // control messages, known or not, are not printed
    }
    i = 1;
    while (i <= n) : (i += 1) api.warning(L, api.toString(L, i).?, i < n);
    return 0;
}

/// print(···)
/// Receives any number of arguments and prints their values to stdout
fn base_print(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    var out_buf: [1024]u8 = undefined;
    var stdout_writer = stdio.stdoutWriter(&out_buf);
    const writer = &stdout_writer.interface;

    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) try writer.writeAll("\t");

        // Call tostring on each argument
        if ((try api.getGlobal(L, "tostring")) == .function) {
            try api.pushValueAt(L, i);
            try api.call(L, 1, 1);

            const s = api.toString(L, -1) orelse return api.argError(L, i, "'tostring' must return a string");
            try writer.writeAll(s);

            api.pop(L, 1); // Remove string result
        } else {
            // Fallback if tostring not available
            const type_tag = api.type_(L, i);
            switch (type_tag) {
                .string => {
                    const s = api.toString(L, i).?;
                    try writer.writeAll(s);
                },
                .number => {
                    const num: value.Number = if (api.isInteger(L, i))
                        .{ .integer = api.toInteger(L, i).? }
                    else
                        .{ .float = api.toNumber(L, i).? };
                    var buf: [64]u8 = undefined;
                    try writer.writeAll(vm.numberToStringBuf(&buf, num));
                },
                .boolean => {
                    const b = api.toBoolean(L, i);
                    try writer.writeAll(if (b) "true" else "false");
                },
                .nil => try writer.writeAll("nil"),
                else => {
                    // For other types, print type and address
                    const ptr = api.toPointer(L, i);
                    try writer.print("{s}: 0x{x}", .{ @tagName(type_tag), @intFromPtr(ptr) });
                },
            }
        }
    }
    try writer.writeAll("\n");
    try writer.flush();

    return 0;
}

/// type(v)
/// Returns the type of its only argument as a string
fn base_type(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);
    try api.pushString(L, api.typeName(L, api.type_(L, 1)));
    return 1;
}

/// tostring(v)
/// Converts value to string, respecting __tostring metamethod
fn base_tostring(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);
    _ = try aux.toLString(L, 1);
    return 1;
}

/// tonumber(e [, base])
/// Converts string to number with optional base
fn base_tonumber(L: *state.LuaState) !i32 {
    if (aux.isNoneOrNil(L, 2)) { // standard conversion?
        if (api.type_(L, 1) == .number) { // already a number?
            try api.setTop(L, 1);
            return 1;
        }
        if (api.type_(L, 1) == .string) {
            const s = api.toString(L, 1).?;
            if (api.stringToNumber(L, s)) return 1;
        }
        try api.checkAny(L, 1); // (but there must be some parameter)
    } else {
        const base = try api.checkInteger(L, 2);
        try api.checkType(L, 1, .string); // no numbers as strings
        const s = api.toString(L, 1).?;
        try aux.argCheck(L, 2 <= base and base <= 36, 2, "base out of range");
        if (strToInt(s, @intCast(base))) |n| {
            try api.pushInteger(L, n);
            return 1;
        }
    }
    try api.pushNil(L); // not a number
    return 1;
}

/// Convert a string to an integer in the given base (b_str2int): optional
/// surrounding whitespace and sign, at least one digit, nothing else.
/// Overflow wraps around, as it does in Lua.
fn strToInt(s: []const u8, base: u8) ?i64 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') {
        i += 1;
    }
    if (i >= s.len or !std.ascii.isAlphanumeric(s[i])) return null; // no digit
    var n: u64 = 0;
    while (i < s.len and std.ascii.isAlphanumeric(s[i])) : (i += 1) {
        const c = s[i];
        const digit: u8 = if (std.ascii.isDigit(c)) c - '0' else std.ascii.toUpper(c) - 'A' + 10;
        if (digit >= base) return null; // invalid numeral
        n = n *% base +% digit;
    }
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i != s.len) return null; // trailing garbage
    const v: i64 = @bitCast(n);
    return if (neg) 0 -% v else v;
}

/// assert(v [, message])
/// Throws error if v is false or nil
fn base_assert(L: *state.LuaState) !i32 {
    if (api.toBoolean(L, 1)) return api.getTop(L); // condition is true: return all arguments
    try api.checkAny(L, 1); // there must be a condition
    try api.remove(L, 1); // remove it
    try api.pushString(L, "assertion failed!"); // default message
    try api.setTop(L, 1); // leave only the message (default if no other one)
    return base_error(L); // call 'error' with it (luaB_assert)
}

/// error(message [, level])
/// Throws an error with given message
fn base_error(L: *state.LuaState) !i32 {
    const level = if (api.getTop(L) >= 2) try api.checkInteger(L, 2) else 1;
    // `error()` with no argument raises nil rather than complaining, so the
    // message slot is filled in rather than checked (luaB_error)
    if (api.getTop(L) < 1) try api.pushNil(L);
    api.setTop(L, 1) catch {};

    // A string message is blamed on the caller's line; level 0 suppresses
    // that, and a non-string value is raised untouched so error objects
    // survive intact (luaB_error)
    if (level > 0 and api.type_(L, 1) == .string) {
        var wherebuf: [api.WHERE_SIZE]u8 = undefined;
        const w = api.whereLevel(L, level, &wherebuf); // add extra information
        if (w.len > 0) {
            const msg = api.toString(L, 1).?;
            try api.pushFString(L, "{s}{s}", .{ w, msg });
            try api.replace(L, 1);
        }
    }
    return api.error_(L);
}

/// Finish `pcall`/`xpcall`, both directly and as the continuation that runs
/// when the protected function yielded and the coroutine was resumed
/// (finishpcall). `extra` is the number of stack slots below the results.
fn finishPcall(L: *state.LuaState, status: state.ThreadStatus, extra: usize) !i32 {
    if (status != .ok and status != .yield) { // error?
        try api.pushBoolean(L, false); // first result (false)
        try api.pushValueAt(L, -2); // error message
        return 2; // return false, msg
    }
    return api.getTop(L) - @as(i32, @intCast(extra)); // return all results
}

/// pcall(f [, arg1, ···])
/// Protected call - catches errors (luaB_pcall)
fn base_pcall(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);
    try api.pushBoolean(L, true); // first result if no errors
    try api.insert(L, 1); // put it in place
    const status = try api.pcallk(L, api.getTop(L) - 2, api.LUA_MULTRET, 0, finishPcall, 0);
    return finishPcall(L, status, 0);
}

/// xpcall(f, msgh [, arg1, ···])
/// Protected call with a message handler (luaB_xpcall)
fn base_xpcall(L: *state.LuaState) !i32 {
    const n = api.getTop(L);
    try api.checkType(L, 2, .function); // check error function
    try api.pushBoolean(L, true); // first result
    try api.pushValueAt(L, 1); // function
    try api.rotate(L, 3, 2); // move them below the function's arguments
    const status = try api.pcallk(L, n - 2, api.LUA_MULTRET, 2, finishPcall, 2);
    return finishPcall(L, status, 2);
}

/// getmetatable(object)
/// Returns metatable of object or nil
fn base_getmetatable(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);

    if (!api.getMetatable(L, 1)) {
        try api.pushNil(L);
        return 1;
    }

    // Check for __metatable field
    _ = try api.getField(L, -1, "__metatable");
    if (!api.isNil(L, -1)) {
        // Return __metatable field instead
        return 1;
    }

    api.pop(L, 1); // Remove nil
    return 1; // Return actual metatable
}

/// setmetatable(table, metatable)
/// Sets metatable for table
fn base_setmetatable(L: *state.LuaState) !i32 {
    try api.checkType(L, 1, .table);
    const mt_type = api.type_(L, 2);
    if (mt_type != .table and mt_type != .nil) {
        return api.argError(L, 2, "table or nil expected");
    }

    // Check for protected metatable
    if (api.getMetatable(L, 1)) {
        _ = try api.getField(L, -1, "__metatable");
        if (!api.isNil(L, -1)) {
            try api.pushString(L, "cannot change a protected metatable");
            return api.error_(L);
        }
        api.pop(L, 2); // Remove __metatable and metatable
    }

    _ = try api.setMetatable(L, 1);
    return 1;
}

/// rawget(table, index)
/// Gets table[index] without metamethods
fn base_rawget(L: *state.LuaState) !i32 {
    try api.checkType(L, 1, .table);
    try api.checkAny(L, 2);
    try api.setTop(L, 2); // extra arguments are ignored

    try api.rawGet(L, 1);
    return 1;
}

/// rawset(table, index, value)
/// Sets table[index] = value without metamethods
fn base_rawset(L: *state.LuaState) !i32 {
    try api.checkType(L, 1, .table);
    try api.checkAny(L, 2);
    try api.checkAny(L, 3);
    try api.setTop(L, 3); // extra arguments are ignored

    try api.rawSet(L, 1);
    return 1;
}

/// rawlen(v)
/// Returns length without __len metamethod
fn base_rawlen(L: *state.LuaState) !i32 {
    const t = api.type_(L, 1);
    if (t != .table and t != .string) {
        return api.argError(L, 1, "table or string expected");
    }

    try api.pushInteger(L, @intCast(api.rawLen(L, 1)));
    return 1;
}

/// rawequal(v1, v2)
/// Compares values without metamethods
fn base_rawequal(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);
    try api.checkAny(L, 2);

    try api.pushBoolean(L, api.rawEqual(L, 1, 2));
    return 1;
}

/// next(table [, index])
/// Returns next key-value pair
fn base_next(L: *state.LuaState) !i32 {
    try api.checkType(L, 1, .table);
    try api.setTop(L, 2); // Ensure 2 arguments

    if (try api.next(L, 1)) {
        return 2;
    } else {
        try api.pushNil(L);
        return 1;
    }
}

/// Continuation of `pairs` after a yield inside `__pairs`: the three
/// results are already on the stack
fn pairsCont(L: *state.LuaState, status: state.ThreadStatus, ctx: usize) anyerror!i32 {
    _ = L;
    _ = status;
    _ = ctx;
    return 3;
}

/// pairs(t)
/// Returns iterator for table
fn base_pairs(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);

    // Try __pairs metamethod; it may yield (pairscont)
    if (try api.getMetafield(L, 1, "__pairs")) {
        try api.pushValueAt(L, 1);
        try api.callk(L, 1, 3, 0, pairsCont);
        return 3;
    }

    // Default: next, table, nil
    if ((try api.getGlobal(L, "next")) != .function) {
        // Fallback if next not registered yet
        try api.pushCFunction(L, base_next);
    }
    try api.pushValueAt(L, 1);
    try api.pushNil(L);

    return 3;
}

/// ipairs(t)
/// Returns iterator for array part
fn base_ipairs(L: *state.LuaState) !i32 {
    try api.checkAny(L, 1);

    // Return ipairsaux, table, 0 (5.4 has no __ipairs; the iterator itself
    // respects __index through `getI`)
    try api.pushCFunction(L, ipairsaux);
    try api.pushValueAt(L, 1);
    try api.pushInteger(L, 0);

    return 3;
}

fn ipairsaux(L: *state.LuaState) !i32 {
    const i = (try api.checkInteger(L, 2)) +% 1; // luaL_intop wraps

    if (api.toTable(L, 1)) |t| {
        if (t.metatable == null) { // no __index: read the table directly
            const v = t.getInt(i);
            if (v.isNil()) return 0;
            try api.pushInteger(L, i);
            try api.pushValue(L, v);
            return 2;
        }
    }
    try api.pushInteger(L, i);
    try api.getI(L, 1, i);

    if (api.isNil(L, -1)) {
        api.pop(L, 2);
        return 0;
    } else {
        return 2;
    }
}

/// select(index, ···)
/// Returns arguments from index or count with '#'
fn base_select(L: *state.LuaState) !i32 {
    const n = api.getTop(L);

    if (api.type_(L, 1) == .string) {
        const s = api.toString(L, 1).?;
        if (std.mem.eql(u8, s, "#")) {
            try api.pushInteger(L, n - 1);
            return 1;
        }
    }

    var i = try api.checkInteger(L, 1);
    // luaB_select: negative counts from the end, too large yields nothing
    if (i < 0) {
        i = n + i;
    } else if (i > n) {
        i = n;
    }
    if (i < 1) return api.argError(L, 1, "index out of range");
    return @intCast(n - i);
}

/// collectgarbage([opt [, arg]])
/// Controls garbage collector
fn base_collectgarbage(L: *state.LuaState) !i32 {
    const opts = [_][]const u8{
        "stop",     "restart",    "collect",   "count",        "step",
        "setpause", "setstepmul", "isrunning", "generational", "incremental",
    };
    const opt = try api.checkOption(L, 1, "collect", &opts);

    switch (opt) {
        0 => { // stop
            _ = api.gc(L, api.GCOpt.stop, 0);
            return 0;
        },
        1 => { // restart
            _ = api.gc(L, api.GCOpt.restart, 0);
            return 0;
        },
        2 => { // collect
            _ = api.gc(L, api.GCOpt.collect, 0);
            return 0;
        },
        3 => { // count
            const kb = api.gc(L, api.GCOpt.count, 0);
            const b = api.gc(L, api.GCOpt.countb, 0);
            try api.pushNumber(L, @as(f64, @floatFromInt(kb)) + @as(f64, @floatFromInt(b)) / 1024.0);
            return 1;
        },
        4 => { // step
            const size = try aux.optInteger(L, 2, 0);
            const res = api.gc(L, api.GCOpt.step, clampInt(size));
            try api.pushBoolean(L, res != 0);
            return 1;
        },
        5, 6 => { // setpause / setstepmul: return the previous value
            const p = try aux.optInteger(L, 2, 0);
            const prev = api.gc(L, if (opt == 5) api.GCOpt.setpause else api.GCOpt.setstepmul, clampInt(p));
            try api.pushInteger(L, prev);
            return 1;
        },
        7 => { // isrunning
            const res = api.gc(L, api.GCOpt.isrunning, 0);
            try api.pushBoolean(L, res != 0);
            return 1;
        },
        8 => { // generational [minormul, majormul]: returns the previous mode
            const minormul = clampInt(try aux.optInteger(L, 2, 0));
            const majormul = clampInt(try aux.optInteger(L, 3, 0));
            const prev = api.gcGenerational(L, minormul, majormul);
            try api.pushString(L, if (prev == @intFromEnum(api.GCOpt.gen)) "generational" else "incremental");
            return 1;
        },
        9 => { // incremental [pause, stepmul, stepsize]: returns the previous mode
            const pause = clampInt(try aux.optInteger(L, 2, 0));
            const stepmul = clampInt(try aux.optInteger(L, 3, 0));
            const stepsize = clampInt(try aux.optInteger(L, 4, 0));
            const prev = api.gcIncremental(L, pause, stepmul, stepsize);
            try api.pushString(L, if (prev == @intFromEnum(api.GCOpt.gen)) "generational" else "incremental");
            return 1;
        },
        else => unreachable,
    }
}

/// A Lua integer argument as a C `int` (what `lua_gc` takes)
fn clampInt(n: i64) i32 {
    return @intCast(std.math.clamp(n, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// dofile([filename])
/// Executes file as Lua chunk
fn base_dofile(L: *state.LuaState) !i32 {
    const fname: ?[]const u8 = if (api.getTop(L) >= 1 and !api.isNil(L, 1))
        api.toString(L, 1)
    else
        null;

    const status = loadFile(L, fname, "bt");
    if (status != .ok) {
        return api.error_(L);
    }

    try api.callk(L, 0, api.LUA_MULTRET, 0, dofileCont);
    return dofileCont(L, .ok, 0);
}

/// Continuation of `dofile`: everything above the file name is a result
fn dofileCont(L: *state.LuaState, status: state.ThreadStatus, ctx: usize) anyerror!i32 {
    _ = status;
    _ = ctx;
    return api.getTop(L) - 1;
}

/// loadfile([filename [, mode [, env]]])
/// Loads file but doesn't execute
fn base_loadfile(L: *state.LuaState) !i32 {
    const fname: ?[]const u8 = if (api.getTop(L) >= 1 and !api.isNil(L, 1))
        api.toString(L, 1)
    else
        null;
    const mode: []const u8 = if (api.getTop(L) >= 2 and !api.isNil(L, 2))
        api.toString(L, 2) orelse "bt"
    else
        "bt";
    const env_idx: i32 = if (api.getTop(L) >= 3) 3 else 0; // 'env' index or 0 if no 'env'

    const status = loadFile(L, fname, mode);

    if (status == .ok and env_idx != 0) { // 'env' parameter?
        try api.pushValueAt(L, env_idx); // environment for loaded function
        if (api.setUpvalue(L, -2, 1) == null) { // set it as 1st upvalue
            api.pop(L, 1); // remove 'env' if not used by previous call
        }
    }

    return switch (status) {
        .ok => 1,
        else => {
            try api.pushNil(L);
            try api.insert(L, -2);
            return 2;
        },
    };
}

fn loadFile(L: *state.LuaState, filename: ?[]const u8, mode: []const u8) api.ThreadStatus {
    return api.loadFile(L, filename, mode);
}

/// load(chunk [, chunkname [, mode [, env]]])
/// Loads string as chunk
fn base_load(L: *state.LuaState) !i32 {
    const mode: []const u8 = if (api.getTop(L) >= 3 and !api.isNil(L, 3))
        api.toString(L, 3) orelse "bt"
    else
        "bt";
    const env_idx: i32 = if (api.getTop(L) >= 4) 4 else 0; // 'env' index or 0 if no 'env'

    // A reader function is called repeatedly until it yields nil or "", and
    // the pieces are concatenated; Lua streams them into the parser instead,
    // but the parser here needs the whole chunk anyway (generic_reader).
    var reader_text = std.ArrayList(u8).empty;
    defer reader_text.deinit(L.allocator);

    const from_reader = api.isFunction(L, 1);
    if (from_reader) {
        while (true) {
            try api.pushValueAt(L, 1);
            // `lua_load` runs the reader in protected mode: an error in it,
            // or a wrong result, is reported as a failed load
            if (api.pcall(L, 0, 1, 0) != .ok) {
                try api.pushNil(L);
                try api.insert(L, -2);
                return 2;
            }
            if (api.isNil(L, -1)) {
                api.pop(L, 1);
                break;
            }
            const piece = api.toString(L, -1) orelse {
                api.pop(L, 1);
                try api.pushNil(L);
                try api.pushString(L, "reader function must return a string");
                return 2;
            };
            if (piece.len == 0) {
                api.pop(L, 1);
                break;
            }
            try reader_text.appendSlice(L.allocator, piece);
            api.pop(L, 1);
        }
    }

    const chunk = if (from_reader) reader_text.items else try api.checkString(L, 1);
    // Lua names a string chunk after its own source text, and a reader chunk
    // "=(load)" (luaB_load)
    const chunkname: []const u8 = if (api.getTop(L) >= 2 and !api.isNil(L, 2))
        api.toString(L, 2) orelse chunk
    else if (from_reader)
        "=(load)"
    else
        chunk;

    const status = api.loadBuffer(L, chunk, chunkname, mode);

    if (status == .ok and env_idx != 0) { // 'env' parameter?
        try api.pushValueAt(L, env_idx); // environment for loaded function
        if (api.setUpvalue(L, -2, 1) == null) { // set it as 1st upvalue
            api.pop(L, 1); // remove 'env' if not used by previous call
        }
    }

    return switch (status) {
        .ok => 1,
        else => {
            try api.pushNil(L);
            try api.insert(L, -2);
            return 2;
        },
    };
}
