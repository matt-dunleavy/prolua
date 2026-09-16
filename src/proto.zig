// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");
const value = @import("value.zig");
const opcode = @import("opcode.zig");

/// Upvalue description
pub const Upvaldesc = struct {
    name: ?*value.String, // upvalue name (for debug)
    instack: bool, // whether it is in the stack (register)
    idx: u8, // index of upvalue (in stack or in outer function's list)
    kind: u8, // kind of corresponding variable

    pub const VDKREG = 0; // regular variable
    pub const RDKCONST = 1; // constant
    pub const RDKTOCLOSE = 2; // to-be-closed variable
    pub const RDKCTC = 3; // compile-time constant
};

/// Local variable information (for debug)
pub const LocVar = struct {
    name: *value.String, // variable name
    start_pc: u32, // first point where variable is active
    end_pc: u32, // first point where variable is dead
};

/// Absolute line info (for optimized debug info)
pub const AbsLineInfo = struct {
    pc: u32, // instruction index
    line: u32, // line number
};

/// Marker in `lineinfo` for an absolute entry
pub const ABSLINEINFO: i8 = -0x80;
/// Maximum delta stored inline
pub const LIMLINEDIFF: i64 = 0x7f;
/// Maximum instructions without an absolute entry
pub const MAXIWTHABS: u32 = 128;

/// Constant identity used for pool deduplication
fn sameConstant(a: value.TValue, b: value.TValue) bool {
    if (a.tag() != b.tag()) return false;
    if (a.tag() == .number) {
        return switch (a.numberValue()) {
            .integer => |x| b.numberValue() == .integer and b.integerValue() == x,
            .float => |x| b.numberValue() == .float and @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.floatValue())),
        };
    }
    return a.rawEqual(b);
}

/// Function prototype - compiled representation of a function
pub const Proto = struct {
    header: value.GCObject,
    gclist: ?*value.GCObject = null, // link in the gray / grayagain lists

    // Function metadata
    numparams: u8, // number of fixed parameters
    is_vararg: bool, // whether function accepts varargs
    maxstacksize: u8, // number of registers needed

    // Bytecode
    code: []opcode.Instruction, // bytecode instructions
    sizecode: u32, // size of code array

    // Constants
    constants: []value.TValue, // constants used by the function
    sizek: u32, // size of constants array

    // Upvalues
    upvalues: []Upvaldesc, // upvalue descriptors
    sizeupvalues: u8, // number of upvalues

    // Nested functions
    protos: []*Proto, // functions defined inside this function
    sizep: u32, // size of protos array

    // Debug information
    source: ?*value.String, // source name
    linedefined: u32, // line where function starts
    lastlinedefined: u32, // line where function ends

    lineinfo: []u8, // line info (encoded)
    sizelineinfo: u32, // size of lineinfo
    abslineinfo: []AbsLineInfo, // absolute line info
    sizeabslineinfo: u32, // size of absolute line info

    locvars: []LocVar, // local variable names
    sizelocvars: u32, // size of locvars

    // Line-info encoder state (compile time only)
    previousline: u32 = 0,
    iwthabs: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !*Proto {
        const p = try allocator.create(Proto);
        p.* = .{
            .header = .{
                .next = null,
                .tt = @intFromEnum(value.ValueType.proto),
                .marked = 0,
            },
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = 0,
            .code = &[_]opcode.Instruction{},
            .sizecode = 0,
            .constants = &[_]value.TValue{},
            .sizek = 0,
            .upvalues = &[_]Upvaldesc{},
            .sizeupvalues = 0,
            .protos = &[_]*Proto{},
            .sizep = 0,
            .source = null,
            .linedefined = 0,
            .lastlinedefined = 0,
            .lineinfo = &[_]u8{},
            .sizelineinfo = 0,
            .abslineinfo = &[_]AbsLineInfo{},
            .sizeabslineinfo = 0,
            .locvars = &[_]LocVar{},
            .sizelocvars = 0,
        };
        return p;
    }

    pub fn deinit(self: *Proto, allocator: std.mem.Allocator) void {
        if (self.code.len > 0) allocator.free(self.code);
        if (self.constants.len > 0) allocator.free(self.constants);
        if (self.upvalues.len > 0) allocator.free(self.upvalues);
        if (self.protos.len > 0) allocator.free(self.protos);
        if (self.lineinfo.len > 0) allocator.free(self.lineinfo);
        if (self.abslineinfo.len > 0) allocator.free(self.abslineinfo);
        if (self.locvars.len > 0) allocator.free(self.locvars);
        allocator.destroy(self);
    }

    /// Add an instruction to the code array
    pub fn addInstruction(self: *Proto, allocator: std.mem.Allocator, inst: opcode.Instruction) !u32 {
        const pc = self.sizecode;
        if (self.sizecode >= self.code.len) {
            // Grow code array
            const new_size = if (self.code.len == 0) 4 else self.code.len * 2;
            const new_code = try allocator.alloc(opcode.Instruction, new_size);
            @memcpy(new_code[0..self.code.len], self.code);
            if (self.code.len > 0) allocator.free(self.code);
            self.code = new_code;
        }
        self.code[self.sizecode] = inst;
        self.sizecode += 1;
        return pc;
    }

    /// Add a constant to the constant pool (deduplicated by raw identity:
    /// the integer 1 and the float 1.0 are different constants, as are 0.0
    /// and -0.0)
    pub fn addConstant(self: *Proto, allocator: std.mem.Allocator, k: value.TValue) !u32 {
        for (self.constants[0..self.sizek], 0..) |existing, i| {
            if (sameConstant(existing, k)) {
                return @intCast(i);
            }
        }

        // Add new constant
        const idx = self.sizek;
        if (self.sizek >= self.constants.len) {
            // Grow constants array
            const new_size = if (self.constants.len == 0) 4 else self.constants.len * 2;
            const new_constants = try allocator.alloc(value.TValue, new_size);
            @memcpy(new_constants[0..self.constants.len], self.constants);
            if (self.constants.len > 0) allocator.free(self.constants);
            self.constants = new_constants;
        }
        self.constants[self.sizek] = k;
        self.sizek += 1;
        return idx;
    }

    /// Add an upvalue descriptor
    pub fn addUpvalue(self: *Proto, allocator: std.mem.Allocator, desc: Upvaldesc) !u8 {
        if (self.sizeupvalues >= 255) {
            return error.TooManyUpvalues;
        }

        const idx = self.sizeupvalues;
        if (self.sizeupvalues >= self.upvalues.len) {
            // Grow upvalues array
            const new_size = if (self.upvalues.len == 0) 4 else self.upvalues.len * 2;
            const new_upvalues = try allocator.alloc(Upvaldesc, @min(new_size, 255));
            @memcpy(new_upvalues[0..self.upvalues.len], self.upvalues);
            if (self.upvalues.len > 0) allocator.free(self.upvalues);
            self.upvalues = new_upvalues;
        }
        self.upvalues[self.sizeupvalues] = desc;
        self.sizeupvalues += 1;
        return idx;
    }

    /// Add a nested prototype
    pub fn addProto(self: *Proto, allocator: std.mem.Allocator, p: *Proto) !u32 {
        const idx = self.sizep;
        if (self.sizep >= self.protos.len) {
            // Grow protos array
            const new_size = if (self.protos.len == 0) 4 else self.protos.len * 2;
            const new_protos = try allocator.alloc(*Proto, new_size);
            @memcpy(new_protos[0..self.protos.len], self.protos);
            if (self.protos.len > 0) allocator.free(self.protos);
            self.protos = new_protos;
        }
        self.protos[self.sizep] = p;
        self.sizep += 1;
        return idx;
    }

    /// Add debug line info for the instruction at `pc == sizelineinfo`
    /// (Lua 5.4 encoding: a signed delta from the previous instruction's line,
    /// with an absolute entry every `MAXIWTHABS` instructions or when the
    /// delta does not fit in a byte).
    pub fn addLineInfo(self: *Proto, allocator: std.mem.Allocator, line: u32) !void {
        const pc = self.sizelineinfo;
        const delta: i64 = @as(i64, line) - @as(i64, self.previousline);
        self.previousline = line;

        if (self.sizelineinfo >= self.lineinfo.len) {
            const new_size = if (self.lineinfo.len == 0) 64 else self.lineinfo.len * 2;
            const new_lineinfo = try allocator.alloc(u8, new_size);
            @memcpy(new_lineinfo[0..self.lineinfo.len], self.lineinfo);
            if (self.lineinfo.len > 0) allocator.free(self.lineinfo);
            self.lineinfo = new_lineinfo;
        }

        if (delta < -LIMLINEDIFF or delta > LIMLINEDIFF or self.iwthabs >= MAXIWTHABS) {
            // Absolute entry
            if (self.sizeabslineinfo >= self.abslineinfo.len) {
                const new_size = if (self.abslineinfo.len == 0) 4 else self.abslineinfo.len * 2;
                const new_abs = try allocator.alloc(AbsLineInfo, new_size);
                @memcpy(new_abs[0..self.abslineinfo.len], self.abslineinfo);
                if (self.abslineinfo.len > 0) allocator.free(self.abslineinfo);
                self.abslineinfo = new_abs;
            }
            self.abslineinfo[self.sizeabslineinfo] = .{ .pc = pc, .line = line };
            self.sizeabslineinfo += 1;
            self.lineinfo[pc] = @bitCast(@as(i8, ABSLINEINFO));
            self.iwthabs = 0;
        } else {
            self.lineinfo[pc] = @bitCast(@as(i8, @intCast(delta)));
            self.iwthabs += 1;
        }
        self.sizelineinfo += 1;
    }

    /// Add a local variable (for debug)
    pub fn addLocVar(self: *Proto, allocator: std.mem.Allocator, name: *value.String, start_pc: u32, end_pc: u32) !void {
        if (self.sizelocvars >= self.locvars.len) {
            // Grow locvars array
            const new_size = if (self.locvars.len == 0) 4 else self.locvars.len * 2;
            const new_locvars = try allocator.alloc(LocVar, new_size);
            @memcpy(new_locvars[0..self.locvars.len], self.locvars);
            if (self.locvars.len > 0) allocator.free(self.locvars);
            self.locvars = new_locvars;
        }
        self.locvars[self.sizelocvars] = .{
            .name = name,
            .start_pc = start_pc,
            .end_pc = end_pc,
        };
        self.sizelocvars += 1;
    }

    /// Get line number for a given PC
    pub fn getLine(self: *const Proto, pc: u32) u32 {
        if (self.sizelineinfo == 0 or pc >= self.sizelineinfo) return self.linedefined;
        // Find the closest absolute entry at or before pc
        var base_pc: i64 = -1;
        var line: i64 = self.linedefined;
        var lo: usize = 0;
        while (lo < self.sizeabslineinfo and self.abslineinfo[lo].pc <= pc) : (lo += 1) {
            base_pc = self.abslineinfo[lo].pc;
            line = self.abslineinfo[lo].line;
        }
        // Walk the deltas forward from there
        var i: i64 = base_pc + 1;
        while (i <= pc) : (i += 1) {
            const d: i8 = @bitCast(self.lineinfo[@intCast(i)]);
            if (d != ABSLINEINFO) line += d;
        }
        return @intCast(@max(line, 0));
    }

    /// Validate proto structure
    pub fn validate(self: *const Proto) !void {
        // Basic validation
        if (self.sizecode > self.code.len) return error.InvalidCodeSize;
        if (self.sizek > self.constants.len) return error.InvalidConstantSize;
        if (self.sizeupvalues > self.upvalues.len) return error.InvalidUpvalueSize;
        if (self.sizep > self.protos.len) return error.InvalidProtoSize;

        // Validate instructions reference valid constants/registers
        for (self.code[0..self.sizecode]) |inst| {
            const op = opcode.getOpcode(inst);
            const mode = opcode.getOpMode(op);

            switch (mode) {
                .iABC => {
                    const a = opcode.getA(inst);
                    const c = opcode.getC(inst);

                    // Check register bounds
                    if (a >= self.maxstacksize) return error.InvalidRegister;

                    // Check constant indices if used
                    if (opcode.getk(inst)) {
                        if (c >= self.sizek) return error.InvalidConstantIndex;
                    }
                },
                .iABx => {
                    const bx = opcode.getBx(inst);
                    // Check constant index for LOADK
                    if (op == .LOADK and bx >= self.sizek) {
                        return error.InvalidConstantIndex;
                    }
                    // Check proto index for CLOSURE
                    if (op == .CLOSURE and bx >= self.sizep) {
                        return error.InvalidProtoIndex;
                    }
                },
                else => {},
            }
        }
    }
};

test "Proto basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const p = try Proto.init(allocator);
    defer p.deinit(allocator);

    // Test adding instructions
    const inst1 = opcode.createABCk(.MOVE, 0, 1, 0, false);
    const pc1 = try p.addInstruction(allocator, inst1);
    try testing.expect(pc1 == 0);
    try testing.expect(p.sizecode == 1);

    // Test adding constants
    const k1 = value.TValue.integer(42);
    const idx1 = try p.addConstant(allocator, k1);
    try testing.expect(idx1 == 0);

    const k2 = value.TValue.float(3.14);
    const idx2 = try p.addConstant(allocator, k2);
    try testing.expect(idx2 == 1);

    // Test duplicate constant
    const k3 = value.TValue.integer(42);
    const idx3 = try p.addConstant(allocator, k3);
    try testing.expect(idx3 == 0); // Should return existing index

    // Test adding upvalue
    const upval = Upvaldesc{
        .name = null,
        .instack = true,
        .idx = 0,
        .kind = Upvaldesc.VDKREG,
    };
    const upval_idx = try p.addUpvalue(allocator, upval);
    try testing.expect(upval_idx == 0);
    try testing.expect(p.sizeupvalues == 1);
}
