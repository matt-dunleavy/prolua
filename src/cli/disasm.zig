// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! `prolua disasm <file>...`: the bytecode listing, in the format of
//! `luac -l -l -p` (luac.c's PrintFunction), so a listing can be diffed
//! against the reference's for the same source when working on the code
//! generator. `zig build disasm -- file.lua` runs it.
//!
//! Each file is loaded (source or precompiled chunk) and listed without
//! being run. Addresses are those of this process's prototypes, exactly as
//! `luac` prints its own; strip them with `sed 's/0x[0-9a-f]*/ADDR/g'` before
//! comparing two listings.

const std = @import("std");
const prolua = @import("prolua");
const state = prolua.state;
const api = prolua.api;
const value = prolua.value;
const proto_module = prolua.proto;
const opcode = prolua.opcode;
const debug = prolua.debug;
const stdio = prolua.stdio;
const main = @import("main.zig");

const Proto = proto_module.Proto;
const OpCode = opcode.OpCode;

/// `prolua disasm <file>...`: the listing of each file, compiled or
/// precompiled, to standard output. Returns the exit code: 1 when any file
/// failed to load (the rest are still listed).
pub fn execute(L: *state.LuaState, files: []const []const u8) !u8 {
    var out_buf: [8192]u8 = undefined;
    var w = stdio.stdoutWriter(&out_buf);
    const out = &w.interface;
    defer out.flush() catch {};

    var failed = false;
    for (files) |name| {
        if (api.loadFile(L, name, "bt") != .ok) {
            out.flush() catch {};
            main.message(api.toString(L, -1) orelse "cannot load");
            api.pop(L, 1);
            failed = true;
            continue;
        }
        const cl = (L.top - 1)[0].asClosure().?;
        try printFunction(L, out, cl.proto, true);
        api.pop(L, 1);
    }
    return if (failed) 1 else 0;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

fn upvalName(f: *const Proto, i: usize) []const u8 {
    if (i >= f.sizeupvalues) return "-";
    const s = f.upvalues[i].name orelse return "-";
    return s.slice();
}

/// A string constant, quoted with C escapes (PrintString)
fn printString(out: anytype, s: []const u8) !void {
    try out.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            0x07 => try out.writeAll("\\a"),
            0x08 => try out.writeAll("\\b"),
            0x0c => try out.writeAll("\\f"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x0b => try out.writeAll("\\v"),
            else => {
                if (std.ascii.isPrint(c)) try out.writeByte(c) else try out.print("\\{d:0>3}", .{c});
            },
        }
    }
    try out.writeByte('"');
}

fn printConstant(out: anytype, f: *const Proto, i: usize) !void {
    if (i >= f.sizek) {
        try out.print("?{d}", .{i});
        return;
    }
    const k = f.constants[i];
    switch (k.tag()) {
        .nil => try out.writeAll("nil"),
        .boolean => try out.writeAll(if (k.booleanValue()) "true" else "false"),
        .number => switch (k.numberValue()) {
            .integer => |n| try out.print("{d}", .{n}),
            .float => |x| {
                // LUA_NUMBER_FMT is "%.14g", with ".0" added to integral
                // values: exactly what `tostring` does
                var buf: [64]u8 = undefined;
                try out.writeAll(prolua.vm.numberToStringBuf(&buf, .{ .float = x }));
            },
        },
        .string => try printString(out, k.stringValue().slice()),
        else => try out.print("?{d}", .{@intFromEnum(k.tag())}),
    }
}

fn printType(out: anytype, f: *const Proto, i: usize) !void {
    const k = f.constants[i];
    const t: []const u8 = switch (k.tag()) {
        .nil => "N",
        .boolean => "B",
        .number => if (k.numberValue() == .integer) "I" else "F",
        .string => "S",
        else => "?",
    };
    try out.print("{s}\t", .{t});
}

fn eventName(L: *state.LuaState, c: u8) []const u8 {
    if (c >= value.TMS.count) return "?";
    return L.l_G.tmname[c].slice();
}

fn printHeader(out: anytype, f: *const Proto) !void {
    var s: []const u8 = if (f.source) |src| src.slice() else "=?";
    if (s.len > 0 and (s[0] == '@' or s[0] == '=')) {
        s = s[1..];
    } else if (s.len > 0 and s[0] == 0x1b) {
        s = "(bstring)";
    } else {
        s = "(string)";
    }
    try out.print("\n{s} <{s}:{d},{d}> ({d} instruction{s} at 0x{x})\n", .{
        if (f.linedefined == 0) "main" else "function",
        s,
        f.linedefined,
        f.lastlinedefined,
        f.sizecode,
        plural(f.sizecode),
        @intFromPtr(f),
    });
    try out.print("{d}{s} param{s}, {d} slot{s}, {d} upvalue{s}, ", .{
        f.numparams,
        if (f.is_vararg) "+" else "",
        plural(f.numparams),
        f.maxstacksize,
        plural(f.maxstacksize),
        f.sizeupvalues,
        plural(f.sizeupvalues),
    });
    try out.print("{d} local{s}, {d} constant{s}, {d} function{s}\n", .{
        f.sizelocvars,
        plural(f.sizelocvars),
        f.sizek,
        plural(f.sizek),
        f.sizep,
        plural(f.sizep),
    });
}

fn printCode(L: *state.LuaState, out: anytype, f: *const Proto) !void {
    const comment = "\t; ";
    var pc: usize = 0;
    while (pc < f.sizecode) : (pc += 1) {
        const i = f.code[pc];
        const o = opcode.getOpcode(i);
        const a: i64 = opcode.getA(i);
        const b: i64 = opcode.getB(i);
        const c: i64 = opcode.getC(i);
        const ax: i64 = opcode.getAx(i);
        const bx: i64 = opcode.getBx(i);
        const sb: i64 = opcode.getsB(i);
        const sc: i64 = opcode.getsC(i);
        const sbx: i64 = opcode.getsBx(i);
        const sj: i64 = opcode.getsJ(i);
        const isk = opcode.getk(i);
        const ks: []const u8 = if (isk) "k" else "";
        const extra: i64 = if (pc + 1 < f.sizecode) opcode.getAx(f.code[pc + 1]) else 0;
        const line = debug.getFuncLine(f, @intCast(pc));
        const ipc: i64 = @intCast(pc);

        try out.print("\t{d}\t", .{pc + 1});
        if (line > 0) try out.print("[{d}]\t", .{line}) else try out.writeAll("[-]\t");
        try out.print("{s: <9}\t", .{@tagName(o)});
        switch (o) {
            .MOVE => try out.print("{d} {d}", .{ a, b }),
            .LOADI, .LOADF => try out.print("{d} {d}", .{ a, sbx }),
            .LOADK => {
                try out.print("{d} {d}{s}", .{ a, bx, comment });
                try printConstant(out, f, @intCast(bx));
            },
            .LOADKX => {
                try out.print("{d}{s}", .{ a, comment });
                try printConstant(out, f, @intCast(extra));
            },
            .LOADFALSE, .LFALSESKIP, .LOADTRUE => try out.print("{d}", .{a}),
            .LOADNIL => try out.print("{d} {d}{s}{d} out", .{ a, b, comment, b + 1 }),
            .GETUPVAL, .SETUPVAL => try out.print("{d} {d}{s}{s}", .{ a, b, comment, upvalName(f, @intCast(b)) }),
            .GETTABUP => {
                try out.print("{d} {d} {d}{s}{s} ", .{ a, b, c, comment, upvalName(f, @intCast(b)) });
                try printConstant(out, f, @intCast(c));
            },
            .GETTABLE, .GETI => try out.print("{d} {d} {d}", .{ a, b, c }),
            .GETFIELD => {
                try out.print("{d} {d} {d}{s}", .{ a, b, c, comment });
                try printConstant(out, f, @intCast(c));
            },
            .SETTABUP => {
                try out.print("{d} {d} {d}{s}{s}{s} ", .{ a, b, c, ks, comment, upvalName(f, @intCast(a)) });
                try printConstant(out, f, @intCast(b));
                if (isk) {
                    try out.writeAll(" ");
                    try printConstant(out, f, @intCast(c));
                }
            },
            .SETTABLE, .SETI => {
                try out.print("{d} {d} {d}{s}", .{ a, b, c, ks });
                if (isk) {
                    try out.writeAll(comment);
                    try printConstant(out, f, @intCast(c));
                }
            },
            .SETFIELD => {
                try out.print("{d} {d} {d}{s}{s}", .{ a, b, c, ks, comment });
                try printConstant(out, f, @intCast(b));
                if (isk) {
                    try out.writeAll(" ");
                    try printConstant(out, f, @intCast(c));
                }
            },
            .NEWTABLE => try out.print("{d} {d} {d}{s}{d}", .{ a, b, c, comment, c + extra * (opcode.MAXARG_C + 1) }),
            .SELF => {
                try out.print("{d} {d} {d}{s}", .{ a, b, c, ks });
                if (isk) {
                    try out.writeAll(comment);
                    try printConstant(out, f, @intCast(c));
                }
            },
            .ADDI, .SHRI, .SHLI => try out.print("{d} {d} {d}", .{ a, b, sc }),
            .ADDK, .SUBK, .MULK, .MODK, .POWK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK => {
                try out.print("{d} {d} {d}{s}", .{ a, b, c, comment });
                try printConstant(out, f, @intCast(c));
            },
            .ADD, .SUB, .MUL, .MOD, .POW, .DIV, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR => try out.print("{d} {d} {d}", .{ a, b, c }),
            .MMBIN => try out.print("{d} {d} {d}{s}{s}", .{ a, b, c, comment, eventName(L, @intCast(c)) }),
            .MMBINI => {
                try out.print("{d} {d} {d} {d}{s}{s}", .{ a, sb, c, @intFromBool(isk), comment, eventName(L, @intCast(c)) });
                if (isk) try out.writeAll(" flip");
            },
            .MMBINK => {
                try out.print("{d} {d} {d} {d}{s}{s} ", .{ a, b, c, @intFromBool(isk), comment, eventName(L, @intCast(c)) });
                try printConstant(out, f, @intCast(b));
                if (isk) try out.writeAll(" flip");
            },
            .UNM, .BNOT, .NOT, .LEN, .CONCAT => try out.print("{d} {d}", .{ a, b }),
            .CLOSE, .TBC => try out.print("{d}", .{a}),
            .JMP => try out.print("{d}{s}to {d}", .{ sj, comment, sj + ipc + 2 }),
            .EQ, .LT, .LE => try out.print("{d} {d} {d}", .{ a, b, @intFromBool(isk) }),
            .EQK => {
                try out.print("{d} {d} {d}{s}", .{ a, b, @intFromBool(isk), comment });
                try printConstant(out, f, @intCast(b));
            },
            .EQI, .LTI, .LEI, .GTI, .GEI => try out.print("{d} {d} {d}", .{ a, sb, @intFromBool(isk) }),
            .TEST => try out.print("{d} {d}", .{ a, @intFromBool(isk) }),
            .TESTSET => try out.print("{d} {d} {d}", .{ a, b, @intFromBool(isk) }),
            .CALL => {
                try out.print("{d} {d} {d}{s}", .{ a, b, c, comment });
                if (b == 0) try out.writeAll("all in ") else try out.print("{d} in ", .{b - 1});
                if (c == 0) try out.writeAll("all out") else try out.print("{d} out", .{c - 1});
            },
            .TAILCALL => try out.print("{d} {d} {d}{s}{s}{d} in", .{ a, b, c, ks, comment, b - 1 }),
            .RETURN => {
                try out.print("{d} {d} {d}{s}{s}", .{ a, b, c, ks, comment });
                if (b == 0) try out.writeAll("all out") else try out.print("{d} out", .{b - 1});
            },
            .RETURN0 => {},
            .RETURN1 => try out.print("{d}", .{a}),
            .FORLOOP => try out.print("{d} {d}{s}to {d}", .{ a, bx, comment, ipc - bx + 2 }),
            .FORPREP => try out.print("{d} {d}{s}exit to {d}", .{ a, bx, comment, ipc + bx + 3 }),
            .TFORPREP => try out.print("{d} {d}{s}to {d}", .{ a, bx, comment, ipc + bx + 2 }),
            .TFORCALL => try out.print("{d} {d}", .{ a, c }),
            .TFORLOOP => try out.print("{d} {d}{s}to {d}", .{ a, bx, comment, ipc - bx + 2 }),
            .SETLIST => {
                try out.print("{d} {d} {d}", .{ a, b, c });
                if (isk) try out.print("{s}{d}", .{ comment, c + extra * (opcode.MAXARG_C + 1) });
            },
            .CLOSURE => try out.print("{d} {d}{s}0x{x}", .{ a, bx, comment, @intFromPtr(f.protos[@intCast(bx)]) }),
            .VARARG => {
                try out.print("{d} {d}{s}", .{ a, c, comment });
                if (c == 0) try out.writeAll("all out") else try out.print("{d} out", .{c - 1});
            },
            .VARARGPREP => try out.print("{d}", .{a}),
            .EXTRAARG => try out.print("{d}", .{ax}),
        }
        try out.writeAll("\n");
    }
}

fn printDebug(out: anytype, f: *const Proto) !void {
    try out.print("constants ({d}) for 0x{x}:\n", .{ f.sizek, @intFromPtr(f) });
    var i: usize = 0;
    while (i < f.sizek) : (i += 1) {
        try out.print("\t{d}\t", .{i});
        try printType(out, f, i);
        try printConstant(out, f, i);
        try out.writeAll("\n");
    }
    try out.print("locals ({d}) for 0x{x}:\n", .{ f.sizelocvars, @intFromPtr(f) });
    i = 0;
    while (i < f.sizelocvars) : (i += 1) {
        const lv = f.locvars[i];
        try out.print("\t{d}\t{s}\t{d}\t{d}\n", .{ i, lv.name.slice(), lv.start_pc + 1, lv.end_pc + 1 });
    }
    try out.print("upvalues ({d}) for 0x{x}:\n", .{ f.sizeupvalues, @intFromPtr(f) });
    i = 0;
    while (i < f.sizeupvalues) : (i += 1) {
        const uv = f.upvalues[i];
        try out.print("\t{d}\t{s}\t{d}\t{d}\n", .{ i, upvalName(f, i), @intFromBool(uv.instack), uv.idx });
    }
}

/// List `f` and, recursively, the functions defined inside it (PrintFunction)
pub fn printFunction(L: *state.LuaState, out: anytype, f: *const Proto, full: bool) anyerror!void {
    try printHeader(out, f);
    try printCode(L, out, f);
    if (full) try printDebug(out, f);
    for (f.protos[0..f.sizep]) |p| try printFunction(L, out, p, full);
}
