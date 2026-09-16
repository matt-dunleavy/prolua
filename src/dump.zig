// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Serialising a function prototype as a precompiled chunk (ldump.c), in the
//! Lua 5.4 format: `string.dump` produces it and `load` reads it back through
//! `undump.zig`. The output is byte-compatible with `luac` on a 64-bit
//! little-endian build, which is what the reference interpreter checks a
//! chunk against before loading it.

const std = @import("std");
const proto_module = @import("proto.zig");
const value = @import("value.zig");
const state = @import("state.zig");

const Proto = proto_module.Proto;

/// Header fields (lundump.h)
pub const LUA_SIGNATURE = "\x1bLua";
pub const LUAC_VERSION: u8 = 0x54;
pub const LUAC_FORMAT: u8 = 0; // the official format
/// Data to catch conversion errors
pub const LUAC_DATA = "\x19\x93\r\n\x1a\n";
pub const LUAC_INT: i64 = 0x5678;
pub const LUAC_NUM: f64 = 370.5;

/// Type tags of constants, as lobject.h's variant tags (makevariant)
pub const Tag = struct {
    pub const VNIL: u8 = 0;
    pub const VFALSE: u8 = 1;
    pub const VTRUE: u8 = 1 | (1 << 4);
    pub const VNUMINT: u8 = 3;
    pub const VNUMFLT: u8 = 3 | (1 << 4);
    pub const VSHRSTR: u8 = 4;
    pub const VLNGSTR: u8 = 4 | (1 << 4);
};

/// Longest string a short (interned) string can be (LUAI_MAXSHORTLEN)
pub const MAXSHORTLEN = 40;

/// Receives the bytes of the chunk, in order (lua_Writer)
pub const WriterFn = *const fn (L: *state.LuaState, data: []const u8, ud: *anyopaque) anyerror!void;

const DumpState = struct {
    L: *state.LuaState,
    writer: WriterFn,
    data: *anyopaque,
    strip: bool,

    fn write(self: *DumpState, bytes: []const u8) anyerror!void {
        try self.writer(self.L, bytes, self.data);
    }

    fn dumpByte(self: *DumpState, b: u8) anyerror!void {
        try self.write(&[_]u8{b});
    }

    /// Sizes and counts are variable-length: seven bits per byte, most
    /// significant first, with the high bit set on the last byte (dumpSize)
    fn dumpSize(self: *DumpState, x_in: u64) anyerror!void {
        var buff: [10]u8 = undefined;
        var x = x_in;
        var n: usize = 0;
        while (true) {
            n += 1;
            buff[buff.len - n] = @intCast(x & 0x7f);
            x >>= 7;
            if (x == 0) break;
        }
        buff[buff.len - 1] |= 0x80; // mark last byte
        try self.write(buff[buff.len - n ..]);
    }

    fn dumpInt(self: *DumpState, x: anytype) anyerror!void {
        try self.dumpSize(@intCast(x));
    }

    fn dumpInteger(self: *DumpState, x: i64) anyerror!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, x, .little);
        try self.write(&bytes);
    }

    fn dumpNumber(self: *DumpState, x: f64) anyerror!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @bitCast(x), .little);
        try self.write(&bytes);
    }

    /// A string is its size plus one, then its bytes; null is size zero
    fn dumpString(self: *DumpState, s: ?*value.String) anyerror!void {
        const str = s orelse {
            try self.dumpSize(0);
            return;
        };
        const bytes = str.slice();
        try self.dumpSize(bytes.len + 1);
        try self.write(bytes);
    }

    fn dumpCode(self: *DumpState, f: *const Proto) anyerror!void {
        try self.dumpInt(f.sizecode);
        for (f.code[0..f.sizecode]) |inst| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, inst, .little);
            try self.write(&bytes);
        }
    }

    fn dumpConstants(self: *DumpState, f: *const Proto) anyerror!void {
        try self.dumpInt(f.sizek);
        for (f.constants[0..f.sizek]) |k| {
            switch (k.tag()) {
                .nil => try self.dumpByte(Tag.VNIL),
                .boolean => try self.dumpByte(if (k.booleanValue()) Tag.VTRUE else Tag.VFALSE),
                .number => switch (k.numberValue()) {
                    .integer => |i| {
                        try self.dumpByte(Tag.VNUMINT);
                        try self.dumpInteger(i);
                    },
                    .float => |x| {
                        try self.dumpByte(Tag.VNUMFLT);
                        try self.dumpNumber(x);
                    },
                },
                .string => {
                    const s = k.stringValue();
                    try self.dumpByte(if (s.len() <= MAXSHORTLEN) Tag.VSHRSTR else Tag.VLNGSTR);
                    try self.dumpString(s);
                },
                else => return error.InvalidConstant,
            }
        }
    }

    fn dumpUpvalues(self: *DumpState, f: *const Proto) anyerror!void {
        try self.dumpInt(f.sizeupvalues);
        for (f.upvalues[0..f.sizeupvalues]) |uv| {
            try self.dumpByte(if (uv.instack) 1 else 0);
            try self.dumpByte(uv.idx);
            try self.dumpByte(uv.kind);
        }
    }

    fn dumpProtos(self: *DumpState, f: *const Proto) anyerror!void {
        try self.dumpInt(f.sizep);
        for (f.protos[0..f.sizep]) |p| {
            try self.dumpFunction(p, f.source);
        }
    }

    fn dumpDebug(self: *DumpState, f: *const Proto) anyerror!void {
        const n_line: u32 = if (self.strip) 0 else f.sizelineinfo;
        try self.dumpInt(n_line);
        try self.write(f.lineinfo[0..n_line]);

        const n_abs: u32 = if (self.strip) 0 else f.sizeabslineinfo;
        try self.dumpInt(n_abs);
        for (f.abslineinfo[0..n_abs]) |abs| {
            try self.dumpInt(abs.pc);
            try self.dumpInt(abs.line);
        }

        const n_loc: u32 = if (self.strip) 0 else f.sizelocvars;
        try self.dumpInt(n_loc);
        for (f.locvars[0..n_loc]) |lv| {
            try self.dumpString(lv.name);
            try self.dumpInt(lv.start_pc);
            try self.dumpInt(lv.end_pc);
        }

        const n_up: u32 = if (self.strip) 0 else f.sizeupvalues;
        try self.dumpInt(n_up);
        for (f.upvalues[0..n_up]) |uv| {
            try self.dumpString(uv.name);
        }
    }

    fn dumpFunction(self: *DumpState, f: *const Proto, psource: ?*value.String) anyerror!void {
        // The source is written once: nested functions that share their
        // parent's source get null (and no source at all when stripping)
        if (self.strip or f.source == psource) {
            try self.dumpString(null);
        } else {
            try self.dumpString(f.source);
        }
        try self.dumpInt(f.linedefined);
        try self.dumpInt(f.lastlinedefined);
        try self.dumpByte(f.numparams);
        try self.dumpByte(if (f.is_vararg) 1 else 0);
        try self.dumpByte(f.maxstacksize);
        try self.dumpCode(f);
        try self.dumpConstants(f);
        try self.dumpUpvalues(f);
        try self.dumpProtos(f);
        try self.dumpDebug(f);
    }

    fn dumpHeader(self: *DumpState) anyerror!void {
        try self.write(LUA_SIGNATURE);
        try self.dumpByte(LUAC_VERSION);
        try self.dumpByte(LUAC_FORMAT);
        try self.write(LUAC_DATA);
        try self.dumpByte(4); // sizeof(Instruction)
        try self.dumpByte(8); // sizeof(lua_Integer)
        try self.dumpByte(8); // sizeof(lua_Number)
        try self.dumpInteger(LUAC_INT);
        try self.dumpNumber(LUAC_NUM);
    }
};

/// Write `f` as a binary chunk through `writer` (luaU_dump)
pub fn dump(L: *state.LuaState, f: *const Proto, writer: WriterFn, data: *anyopaque, strip: bool) anyerror!void {
    var d = DumpState{ .L = L, .writer = writer, .data = data, .strip = strip };
    try d.dumpHeader();
    try d.dumpByte(f.sizeupvalues);
    try d.dumpFunction(f, null);
}

/// A writer that appends to a byte list, for callers that want the chunk in
/// memory
pub fn appendWriter(L: *state.LuaState, data: []const u8, ud: *anyopaque) anyerror!void {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(ud));
    try list.appendSlice(L.allocator, data);
}

test "dumpSize encodes the way luac does" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    // A DumpState only needs a state for the writer; this writer ignores it
    var d = DumpState{ .L = undefined, .writer = struct {
        fn w(_: *state.LuaState, data: []const u8, ud: *anyopaque) anyerror!void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud));
            try l.appendSlice(std.testing.allocator, data);
        }
    }.w, .data = &out, .strip = false };
    try d.dumpSize(0);
    try d.dumpSize(0x7f);
    try d.dumpSize(0x80);
    try d.dumpSize(300);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0xff, 0x01, 0x80, 0x02, 0xac }, out.items);
}
