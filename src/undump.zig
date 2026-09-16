// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Loading a precompiled chunk (lundump.c), the inverse of `dump.zig`.

const std = @import("std");
const proto_module = @import("proto.zig");
const value = @import("value.zig");
const state = @import("state.zig");
const opcode = @import("opcode.zig");
const dump = @import("dump.zig");

const Proto = proto_module.Proto;
const LuaState = state.LuaState;

pub const UndumpError = error{ BadBinaryFormat, OutOfMemory };

const LoadState = struct {
    L: *LuaState,
    data: []const u8,
    pos: usize = 0,
    /// The chunk's name as shown in messages
    name: []const u8,
    /// Set when a check fails, for the caller's message
    why: []const u8 = "",

    fn fail(self: *LoadState, why: []const u8) UndumpError {
        if (self.why.len == 0) self.why = why;
        return error.BadBinaryFormat;
    }

    fn loadBlock(self: *LoadState, n: usize) UndumpError![]const u8 {
        if (self.pos + n > self.data.len) return self.fail("truncated chunk");
        const b = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return b;
    }

    /// A count of items that take at least `per` bytes each cannot exceed
    /// what is left of the chunk: reject it before allocating for it. The
    /// reference allocates first and fails later ("not enough memory" or
    /// "truncated chunk"); a mutated size field here would otherwise ask
    /// for gigabytes.
    fn ensure(self: *LoadState, n: u64, per: u64) UndumpError!void {
        if (n * per > self.data.len - self.pos) return self.fail("truncated chunk");
    }

    fn loadByte(self: *LoadState) UndumpError!u8 {
        return (try self.loadBlock(1))[0];
    }

    /// Variable-length size, at most `limit` (loadUnsigned)
    fn loadUnsigned(self: *LoadState, limit_in: u64) UndumpError!u64 {
        var x: u64 = 0;
        const limit = limit_in >> 7;
        while (true) {
            const b = try self.loadByte();
            if (x >= limit) return self.fail("integer overflow");
            x = (x << 7) | (b & 0x7f);
            if (b & 0x80 != 0) break;
        }
        return x;
    }

    fn loadSize(self: *LoadState) UndumpError!usize {
        return @intCast(try self.loadUnsigned(std.math.maxInt(usize)));
    }

    fn loadInt(self: *LoadState) UndumpError!u32 {
        return @intCast(try self.loadUnsigned(std.math.maxInt(i32)));
    }

    fn loadInteger(self: *LoadState) UndumpError!i64 {
        const b = try self.loadBlock(8);
        return std.mem.readInt(i64, b[0..8], .little);
    }

    fn loadNumber(self: *LoadState) UndumpError!f64 {
        const b = try self.loadBlock(8);
        return @bitCast(std.mem.readInt(u64, b[0..8], .little));
    }

    /// A string, or null for size zero (loadStringN)
    fn loadString(self: *LoadState) UndumpError!?*value.String {
        const size = try self.loadSize();
        if (size == 0) return null;
        const bytes = try self.loadBlock(size - 1);
        const pool = &self.L.l_G.string_pool;
        // Short strings are interned, as they are everywhere else
        if (bytes.len <= dump.MAXSHORTLEN) return pool.intern(bytes) catch return error.OutOfMemory;
        return pool.create(bytes) catch return error.OutOfMemory;
    }

    fn alloc(self: *LoadState, comptime T: type, n: usize) UndumpError![]T {
        if (n == 0) return &[_]T{};
        return self.L.allocator.alloc(T, n) catch return error.OutOfMemory;
    }

    fn loadCode(self: *LoadState, f: *Proto) UndumpError!void {
        const n = try self.loadInt();
        try self.ensure(n, 4);
        const code = try self.alloc(opcode.Instruction, n);
        f.code = code;
        f.sizecode = n;
        const bytes = try self.loadBlock(@as(usize, n) * 4);
        for (code, 0..) |*inst, i| {
            inst.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        }
    }

    fn loadConstants(self: *LoadState, f: *Proto) UndumpError!void {
        const n = try self.loadInt();
        try self.ensure(n, 1); // a tag byte each at least
        const ks = try self.alloc(value.TValue, n);
        f.constants = ks;
        f.sizek = 0;
        for (ks) |*k| {
            k.* = value.TValue.nil(); // in case of an error while filling
            f.sizek += 1;
            const t = try self.loadByte();
            k.* = switch (t) {
                dump.Tag.VNIL => value.TValue.nil(),
                dump.Tag.VFALSE => value.TValue.boolean(false),
                dump.Tag.VTRUE => value.TValue.boolean(true),
                dump.Tag.VNUMFLT => value.TValue.float(try self.loadNumber()),
                dump.Tag.VNUMINT => value.TValue.integerOrBox(&self.L.l_G.gc, try self.loadInteger()) catch return error.OutOfMemory,
                dump.Tag.VSHRSTR, dump.Tag.VLNGSTR => blk: {
                    const s = (try self.loadString()) orelse return self.fail("bad format for constant string");
                    break :blk value.TValue.string(s);
                },
                else => return self.fail("bad format for constant"),
            };
        }
    }

    fn loadProtos(self: *LoadState, f: *Proto) UndumpError!void {
        const n = try self.loadInt();
        try self.ensure(n, 8); // source, lines, three bytes, four counts: more than eight bytes each
        const ps = try self.alloc(*Proto, n);
        f.protos = ps;
        f.sizep = 0;
        for (ps) |*slot| {
            const p = try self.newProto();
            slot.* = p;
            f.sizep += 1;
            try self.loadFunction(p, f.source);
        }
    }

    fn loadUpvalues(self: *LoadState, f: *Proto) UndumpError!void {
        const n = try self.loadInt();
        // A function has at most MAXUPVAL (255) upvalues; the reference does
        // not check binary chunks and would read on, but `sizeupvalues` is
        // a byte here
        if (n > 255) return self.fail("too many upvalues");
        try self.ensure(n, 3);
        const uvs = try self.alloc(proto_module.Upvaldesc, n);
        f.upvalues = uvs;
        f.sizeupvalues = @intCast(n);
        for (uvs) |*uv| {
            uv.name = null;
            uv.instack = (try self.loadByte()) != 0;
            uv.idx = try self.loadByte();
            uv.kind = try self.loadByte();
        }
    }

    fn loadDebug(self: *LoadState, f: *Proto) UndumpError!void {
        var n = try self.loadInt();
        try self.ensure(n, 1);
        f.lineinfo = try self.alloc(u8, n);
        f.sizelineinfo = n;
        @memcpy(f.lineinfo, try self.loadBlock(n));

        n = try self.loadInt();
        try self.ensure(n, 2);
        f.abslineinfo = try self.alloc(proto_module.AbsLineInfo, n);
        f.sizeabslineinfo = n;
        for (f.abslineinfo) |*abs| {
            abs.pc = try self.loadInt();
            abs.line = try self.loadInt();
        }

        n = try self.loadInt();
        try self.ensure(n, 3);
        f.locvars = try self.alloc(proto_module.LocVar, n);
        f.sizelocvars = 0;
        for (f.locvars) |*lv| {
            lv.name = (try self.loadString()) orelse return self.fail("bad format for local variable name");
            f.sizelocvars += 1;
            lv.start_pc = try self.loadInt();
            lv.end_pc = try self.loadInt();
        }

        n = try self.loadInt();
        if (n != 0 and n != f.sizeupvalues) return self.fail("upvalue names do not match upvalues");
        for (f.upvalues[0..n]) |*uv| {
            uv.name = try self.loadString();
        }
    }

    fn loadFunction(self: *LoadState, f: *Proto, psource: ?*value.String) UndumpError!void {
        f.source = (try self.loadString()) orelse psource; // no source: reuse the parent's
        f.linedefined = try self.loadInt();
        f.lastlinedefined = try self.loadInt();
        f.numparams = try self.loadByte();
        f.is_vararg = (try self.loadByte()) != 0;
        f.maxstacksize = try self.loadByte();
        try self.loadCode(f);
        try self.loadConstants(f);
        try self.loadUpvalues(f);
        try self.loadProtos(f);
        try self.loadDebug(f);
    }

    fn checkLiteral(self: *LoadState, s: []const u8, msg: []const u8) UndumpError!void {
        const b = try self.loadBlock(s.len);
        if (!std.mem.eql(u8, b, s)) return self.fail(msg);
    }

    fn checkSize(self: *LoadState, expected: u8, msg: []const u8) UndumpError!void {
        if ((try self.loadByte()) != expected) return self.fail(msg);
    }

    fn checkHeader(self: *LoadState) UndumpError!void {
        // The first byte of the signature was already checked by the caller
        try self.checkLiteral(dump.LUA_SIGNATURE[1..], "not a binary chunk");
        if ((try self.loadByte()) != dump.LUAC_VERSION) return self.fail("version mismatch");
        if ((try self.loadByte()) != dump.LUAC_FORMAT) return self.fail("format mismatch");
        try self.checkLiteral(dump.LUAC_DATA, "corrupted chunk");
        try self.checkSize(4, "Instruction size mismatch");
        try self.checkSize(8, "lua_Integer size mismatch");
        try self.checkSize(8, "lua_Number size mismatch");
        if ((try self.loadInteger()) != dump.LUAC_INT) return self.fail("integer format mismatch");
        if ((try self.loadNumber()) != dump.LUAC_NUM) return self.fail("float format mismatch");
    }

    /// A prototype owned by the collector, like the compiler makes them
    fn newProto(self: *LoadState) UndumpError!*Proto {
        const p = Proto.init(self.L.allocator) catch return error.OutOfMemory;
        self.L.l_G.gc.linkObject(&p.header, @sizeOf(Proto));
        return p;
    }
};

/// Load a precompiled chunk (luaU_undump). `data` starts with the signature.
/// On failure the message, in the reference's wording, is in `why_out`.
pub fn undump(L: *LuaState, data: []const u8, chunkname: []const u8, why_out: *[]const u8) UndumpError!*Proto {
    // The name shown in messages (luaU_undump)
    const name: []const u8 = if (chunkname.len > 0 and (chunkname[0] == '@' or chunkname[0] == '='))
        chunkname[1..]
    else if (chunkname.len > 0 and chunkname[0] == dump.LUA_SIGNATURE[0])
        "binary string"
    else
        chunkname;
    var S = LoadState{ .L = L, .data = data, .pos = 1, .name = name };
    errdefer why_out.* = S.why;
    try S.checkHeader();
    const p = try S.newProto();
    const nupvalues = try S.loadByte();
    try S.loadFunction(p, null);
    if (p.sizeupvalues != nupvalues) return S.fail("corrupted chunk");
    return p;
}

/// The message-name part `undump` derives from a chunk name, for callers
/// formatting "name: bad binary format (why)"
pub fn messageName(chunkname: []const u8) []const u8 {
    if (chunkname.len > 0 and (chunkname[0] == '@' or chunkname[0] == '=')) return chunkname[1..];
    if (chunkname.len > 0 and chunkname[0] == dump.LUA_SIGNATURE[0]) return "binary string";
    return chunkname;
}
