// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");

// Instruction format: 32-bit unsigned integer
pub const Instruction = u32;

// Basic instruction formats
pub const OpMode = enum(u3) {
    iABC,
    iABx,
    iAsBx,
    iAx,
    isJ,
};

// Size and position of opcode arguments
const SIZE_C = 8;
const SIZE_B = 8;
const SIZE_Bx = SIZE_C + SIZE_B + 1;
const SIZE_A = 8;
const SIZE_Ax = SIZE_Bx + SIZE_A;
const SIZE_sJ = SIZE_Bx + SIZE_A;
const SIZE_OP = 7;

const POS_OP = 0;
const POS_A = POS_OP + SIZE_OP;
const POS_k = POS_A + SIZE_A;
const POS_B = POS_k + 1;
const POS_C = POS_B + SIZE_B;
const POS_Bx = POS_k;
const POS_Ax = POS_A;
const POS_sJ = POS_A;

// Argument limits
pub const MAXARG_A = (1 << SIZE_A) - 1;
pub const MAXARG_B = (1 << SIZE_B) - 1;
pub const MAXARG_C = (1 << SIZE_C) - 1;
pub const MAXARG_Bx = (1 << SIZE_Bx) - 1;
pub const MAXARG_Ax = (1 << SIZE_Ax) - 1;
pub const MAXARG_sJ = (1 << SIZE_sJ) - 1;

pub const OFFSET_sBx = MAXARG_Bx >> 1;
pub const OFFSET_sJ = MAXARG_sJ >> 1;
pub const OFFSET_sC = MAXARG_C >> 1;

pub const NO_REG = MAXARG_A;
pub const MAXINDEXRK = MAXARG_B;

// Lua VM Opcodes
pub const OpCode = enum(u7) {
    // Basic operations
    MOVE, // R[A] := R[B]
    LOADI, // R[A] := sBx
    LOADF, // R[A] := (lua_Number)sBx
    LOADK, // R[A] := K[Bx]
    LOADKX, // R[A] := K[extra arg]
    LOADFALSE, // R[A] := false
    LFALSESKIP, // R[A] := false; pc++
    LOADTRUE, // R[A] := true
    LOADNIL, // R[A], R[A+1], ..., R[A+B] := nil
    GETUPVAL, // R[A] := UpValue[B]
    SETUPVAL, // UpValue[B] := R[A]

    // Table operations
    GETTABUP, // R[A] := UpValue[B][K[C]:string]
    GETTABLE, // R[A] := R[B][R[C]]
    GETI, // R[A] := R[B][C]
    GETFIELD, // R[A] := R[B][K[C]:string]
    SETTABUP, // UpValue[A][K[B]:string] := RK(C)
    SETTABLE, // R[A][R[B]] := RK(C)
    SETI, // R[A][B] := RK(C)
    SETFIELD, // R[A][K[B]:string] := RK(C)
    NEWTABLE, // R[A] := {}
    SELF, // R[A+1] := R[B]; R[A] := R[B][RK(C):string]

    // Arithmetic operations with immediate operand
    ADDI, // R[A] := R[B] + sC

    // Arithmetic operations with constant operand
    ADDK, // R[A] := R[B] + K[C]
    SUBK, // R[A] := R[B] - K[C]
    MULK, // R[A] := R[B] * K[C]
    MODK, // R[A] := R[B] % K[C]
    POWK, // R[A] := R[B] ^ K[C]
    DIVK, // R[A] := R[B] / K[C]
    IDIVK, // R[A] := R[B] // K[C]

    // Bitwise operations with constant operand
    BANDK, // R[A] := R[B] & K[C]:integer
    BORK, // R[A] := R[B] | K[C]:integer
    BXORK, // R[A] := R[B] ~ K[C]:integer

    // Shift operations with immediate operand
    SHRI, // R[A] := R[B] >> sC
    SHLI, // R[A] := sC << R[B]

    // Arithmetic operations
    ADD, // R[A] := RK(B) + RK(C)
    SUB, // R[A] := RK(B) - RK(C)
    MUL, // R[A] := RK(B) * RK(C)
    MOD, // R[A] := RK(B) % RK(C)
    POW, // R[A] := RK(B) ^ RK(C)
    DIV, // R[A] := RK(B) / RK(C)
    IDIV, // R[A] := RK(B) // RK(C)

    // Bitwise operations
    BAND, // R[A] := RK(B) & RK(C)
    BOR, // R[A] := RK(B) | RK(C)
    BXOR, // R[A] := RK(B) ~ RK(C)
    SHL, // R[A] := RK(B) << RK(C)
    SHR, // R[A] := RK(B) >> RK(C)

    // Metamethod operations
    MMBIN, // call C metamethod over R[A] and R[B]
    MMBINI, // call C metamethod over R[A] and sB
    MMBINK, // call C metamethod over R[A] and K[B]

    // Unary operations
    UNM, // R[A] := -R[B]
    BNOT, // R[A] := ~R[B]
    NOT, // R[A] := not R[B]
    LEN, // R[A] := #R[B]

    // Concatenation
    CONCAT, // R[A] := R[A].. ... ..R[C]

    // Jumps and control flow
    CLOSE, // close all upvalues >= R[A]
    TBC, // mark variable A "to be closed"
    JMP, // pc += sJ
    EQ, // if ((R[A] == R[B]) ~= k) then pc++
    LT, // if ((R[A] <  R[B]) ~= k) then pc++
    LE, // if ((R[A] <= R[B]) ~= k) then pc++
    EQK, // if ((R[A] == K[B]) ~= k) then pc++
    EQI, // if ((R[A] == sB) ~= k) then pc++
    LTI, // if ((R[A] < sB) ~= k) then pc++
    LEI, // if ((R[A] <= sB) ~= k) then pc++
    GTI, // if ((R[A] > sB) ~= k) then pc++
    GEI, // if ((R[A] >= sB) ~= k) then pc++
    TEST, // if (not R[A] <=> k) then pc++
    TESTSET, // if (not R[B] <=> k) then pc++ else R[A] := R[B]

    // Function calls
    CALL, // R[A], ... ,R[A+C-2] := R[A](R[A+1], ... ,R[A+B-1])
    TAILCALL, // return R[A](R[A+1], ... ,R[A+B-1])
    RETURN, // return R[A], ... ,R[A+B-2]
    RETURN0, // return
    RETURN1, // return R[A]

    // Loops
    FORLOOP, // Update and test numeric for loop
    FORPREP, // Prepare numeric for loop
    TFORPREP, // Prepare generic for loop
    TFORCALL, // Call iterator function
    TFORLOOP, // Test and loop generic for

    // Table operations
    SETLIST, // R[A][(C-1)*FPF+i] := R[A+i], 1 <= i <= B

    // Closure and variable argument
    CLOSURE, // R[A] := closure(KPROTO[Bx])
    VARARG, // R[A], R[A+1], ..., R[A+C-2] = vararg
    VARARGPREP, // (adjust vararg parameters)

    // Extra argument
    EXTRAARG, // extra (larger) argument for previous opcode

    pub const NUM_OPCODES = @intFromEnum(OpCode.EXTRAARG) + 1;
};

// Opcode properties (format: MMOTITAM)
// MM - metamethod bit
// OT - out top bit
// IT - in top bit
// T - test bit
// A - sets register A bit
// M - mode (3 bits)
const OpModeData = struct {
    mode: OpMode,
    sets_a: bool,
    is_test: bool,
    in_top: bool,
    out_top: bool,
    is_mm: bool,
};

fn opmode(mm: u1, ot: u1, it: u1, t: u1, a: u1, m: OpMode) u8 {
    return (@as(u8, mm) << 7) | (@as(u8, ot) << 6) | (@as(u8, it) << 5) | (@as(u8, t) << 4) | (@as(u8, a) << 3) | @intFromEnum(m);
}

pub const opmodes = blk: {
    var modes: [OpCode.NUM_OPCODES]u8 = undefined;
    modes[@intFromEnum(OpCode.MOVE)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.LOADI)] = opmode(0, 0, 0, 0, 1, .iAsBx);
    modes[@intFromEnum(OpCode.LOADF)] = opmode(0, 0, 0, 0, 1, .iAsBx);
    modes[@intFromEnum(OpCode.LOADK)] = opmode(0, 0, 0, 0, 1, .iABx);
    modes[@intFromEnum(OpCode.LOADKX)] = opmode(0, 0, 0, 0, 1, .iABx);
    modes[@intFromEnum(OpCode.LOADFALSE)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.LFALSESKIP)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.LOADTRUE)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.LOADNIL)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.GETUPVAL)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SETUPVAL)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.GETTABUP)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.GETTABLE)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.GETI)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.GETFIELD)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SETTABUP)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.SETTABLE)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.SETI)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.SETFIELD)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.NEWTABLE)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SELF)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.ADDI)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.ADDK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SUBK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.MULK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.MODK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.POWK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.DIVK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.IDIVK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BANDK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BORK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BXORK)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SHRI)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SHLI)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.ADD)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SUB)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.MUL)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.MOD)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.POW)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.DIV)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.IDIV)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BAND)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BOR)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BXOR)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SHL)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.SHR)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.MMBIN)] = opmode(1, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.MMBINI)] = opmode(1, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.MMBINK)] = opmode(1, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.UNM)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.BNOT)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.NOT)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.LEN)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.CONCAT)] = opmode(0, 0, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.CLOSE)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.TBC)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.JMP)] = opmode(0, 0, 0, 0, 0, .isJ);
    modes[@intFromEnum(OpCode.EQ)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.LT)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.LE)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.EQK)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.EQI)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.LTI)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.LEI)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.GTI)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.GEI)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.TEST)] = opmode(0, 0, 0, 1, 0, .iABC);
    modes[@intFromEnum(OpCode.TESTSET)] = opmode(0, 0, 0, 1, 1, .iABC);
    modes[@intFromEnum(OpCode.CALL)] = opmode(0, 1, 1, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.TAILCALL)] = opmode(0, 1, 1, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.RETURN)] = opmode(0, 0, 1, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.RETURN0)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.RETURN1)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.FORLOOP)] = opmode(0, 0, 0, 0, 1, .iABx);
    modes[@intFromEnum(OpCode.FORPREP)] = opmode(0, 0, 0, 0, 1, .iABx);
    modes[@intFromEnum(OpCode.TFORPREP)] = opmode(0, 0, 0, 0, 0, .iABx);
    modes[@intFromEnum(OpCode.TFORCALL)] = opmode(0, 0, 0, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.TFORLOOP)] = opmode(0, 0, 0, 0, 1, .iABx);
    modes[@intFromEnum(OpCode.SETLIST)] = opmode(0, 0, 1, 0, 0, .iABC);
    modes[@intFromEnum(OpCode.CLOSURE)] = opmode(0, 0, 0, 0, 1, .iABx);
    modes[@intFromEnum(OpCode.VARARG)] = opmode(0, 1, 0, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.VARARGPREP)] = opmode(0, 0, 1, 0, 1, .iABC);
    modes[@intFromEnum(OpCode.EXTRAARG)] = opmode(0, 0, 0, 0, 0, .iAx);
    break :blk modes;
};

// Instruction manipulation - performance critical inline functions.
// This is the one accessor set used by vm.zig, codegen.zig, proto.zig and dump.zig.
pub inline fn getOpcode(i: Instruction) OpCode {
    return @enumFromInt((i >> POS_OP) & ((1 << SIZE_OP) - 1));
}

pub inline fn setOpcode(i: *Instruction, op: OpCode) void {
    const mask: Instruction = ((1 << SIZE_OP) - 1) << POS_OP;
    i.* = (i.* & ~mask) | (@as(Instruction, @intFromEnum(op)) << POS_OP);
}

pub inline fn getA(i: Instruction) u8 {
    return @intCast((i >> POS_A) & ((1 << SIZE_A) - 1));
}

pub inline fn setA(i: *Instruction, v: u8) void {
    const mask = (@as(Instruction, (1 << SIZE_A) - 1)) << POS_A;
    i.* = (i.* & ~mask) | (@as(Instruction, v) << POS_A);
}

pub inline fn getB(i: Instruction) u8 {
    return @intCast((i >> POS_B) & ((1 << SIZE_B) - 1));
}

pub inline fn setB(i: *Instruction, v: u8) void {
    const mask = (@as(Instruction, (1 << SIZE_B) - 1)) << POS_B;
    i.* = (i.* & ~mask) | (@as(Instruction, v) << POS_B);
}

pub inline fn getC(i: Instruction) u8 {
    return @intCast((i >> POS_C) & ((1 << SIZE_C) - 1));
}

pub inline fn setC(i: *Instruction, v: u8) void {
    const mask = (@as(Instruction, (1 << SIZE_C) - 1)) << POS_C;
    i.* = (i.* & ~mask) | (@as(Instruction, v) << POS_C);
}

pub inline fn getk(i: Instruction) bool {
    return ((i >> POS_k) & 1) != 0;
}

pub inline fn setk(i: *Instruction, v: bool) void {
    const mask = @as(Instruction, 1) << POS_k;
    if (v) {
        i.* |= mask;
    } else {
        i.* &= ~mask;
    }
}

pub inline fn getBx(i: Instruction) u18 {
    return @intCast((i >> POS_Bx) & ((1 << SIZE_Bx) - 1));
}

pub inline fn setBx(i: *Instruction, v: u18) void {
    const mask = (@as(Instruction, (1 << SIZE_Bx) - 1)) << POS_Bx;
    i.* = (i.* & ~mask) | (@as(Instruction, v) << POS_Bx);
}

pub inline fn getAx(i: Instruction) u25 {
    return @intCast((i >> POS_Ax) & ((1 << SIZE_Ax) - 1));
}

pub inline fn setAx(i: *Instruction, v: u25) void {
    const mask = (@as(Instruction, (1 << SIZE_Ax) - 1)) << POS_Ax;
    i.* = (i.* & ~mask) | (@as(Instruction, v) << POS_Ax);
}

pub inline fn getsBx(i: Instruction) i19 {
    return @as(i19, @intCast(getBx(i))) - OFFSET_sBx;
}

pub inline fn setsBx(i: *Instruction, v: i19) void {
    setBx(i, @intCast(@as(i32, v) + OFFSET_sBx));
}

pub inline fn getsJ(i: Instruction) i26 {
    return @as(i26, @intCast((i >> POS_sJ) & ((1 << SIZE_sJ) - 1))) - OFFSET_sJ;
}

pub inline fn setsJ(i: *Instruction, v: i26) void {
    const mask = (@as(Instruction, (1 << SIZE_sJ) - 1)) << POS_sJ;
    const uv = @as(u32, @intCast(@as(i32, v) + OFFSET_sJ));
    i.* = (i.* & ~mask) | (uv << POS_sJ);
}

pub inline fn getsC(i: Instruction) i9 {
    return @as(i9, @intCast(getC(i))) - OFFSET_sC;
}

pub inline fn getsB(i: Instruction) i9 {
    return @as(i9, @intCast(getB(i))) - OFFSET_sC;
}

// Instruction creation functions
pub inline fn createABCk(op: OpCode, a: u8, b: u8, c: u8, k: bool) Instruction {
    return (@as(Instruction, @intFromEnum(op)) << POS_OP) |
        (@as(Instruction, a) << POS_A) |
        (@as(Instruction, b) << POS_B) |
        (@as(Instruction, c) << POS_C) |
        (@as(Instruction, @intFromBool(k)) << POS_k);
}

pub inline fn createABC(op: OpCode, a: u8, b: u8, c: u8) Instruction {
    return createABCk(op, a, b, c, false);
}

pub inline fn createABx(op: OpCode, a: u8, bx: u18) Instruction {
    return (@as(Instruction, @intFromEnum(op)) << POS_OP) |
        (@as(Instruction, a) << POS_A) |
        (@as(Instruction, bx) << POS_Bx);
}

pub inline fn createAsBx(op: OpCode, a: u8, sbx: i19) Instruction {
    return createABx(op, a, @intCast(@as(i32, sbx) + OFFSET_sBx));
}

pub inline fn createAx(op: OpCode, ax: u25) Instruction {
    return (@as(Instruction, @intFromEnum(op)) << POS_OP) |
        (@as(Instruction, ax) << POS_Ax);
}

pub inline fn createsJ(op: OpCode, sj: i26, k: bool) Instruction {
    const usj = @as(u32, @intCast(@as(i32, sj) + OFFSET_sJ));
    return (@as(Instruction, @intFromEnum(op)) << POS_OP) |
        (usj << POS_sJ) |
        (@as(Instruction, @intFromBool(k)) << POS_k);
}

// Mode query functions
pub inline fn getOpMode(op: OpCode) OpMode {
    return @enumFromInt(opmodes[@intFromEnum(op)] & 0x07);
}

pub inline fn testAMode(op: OpCode) bool {
    return (opmodes[@intFromEnum(op)] & (1 << 3)) != 0;
}

pub inline fn testTMode(op: OpCode) bool {
    return (opmodes[@intFromEnum(op)] & (1 << 4)) != 0;
}

pub inline fn testITMode(op: OpCode) bool {
    return (opmodes[@intFromEnum(op)] & (1 << 5)) != 0;
}

pub inline fn testOTMode(op: OpCode) bool {
    return (opmodes[@intFromEnum(op)] & (1 << 6)) != 0;
}

pub inline fn testMMMode(op: OpCode) bool {
    return (opmodes[@intFromEnum(op)] & (1 << 7)) != 0;
}

pub inline fn isIT(i: Instruction) bool {
    const op = getOpcode(i);
    return testITMode(op) and getB(i) == 0;
}

pub inline fn isOT(i: Instruction) bool {
    const op = getOpcode(i);
    return (testOTMode(op) and getC(i) == 0) or op == .TAILCALL;
}

// List manipulation constant
pub const LFIELDS_PER_FLUSH = 50;

// Tests
test "instruction encoding/decoding" {
    const testing = std.testing;

    // Test createABC and getters
    const inst1 = createABC(.MOVE, 10, 20, 30);
    try testing.expectEqual(OpCode.MOVE, getOpcode(inst1));
    try testing.expectEqual(@as(u8, 10), getA(inst1));
    try testing.expectEqual(@as(u8, 20), getB(inst1));
    try testing.expectEqual(@as(u8, 30), getC(inst1));

    // Test createABx
    const inst2 = createABx(.LOADK, 5, 1000);
    try testing.expectEqual(OpCode.LOADK, getOpcode(inst2));
    try testing.expectEqual(@as(u8, 5), getA(inst2));
    try testing.expectEqual(@as(u18, 1000), getBx(inst2));

    // Test signed arguments
    const inst3 = createAsBx(.LOADI, 7, -100);
    try testing.expectEqual(OpCode.LOADI, getOpcode(inst3));
    try testing.expectEqual(@as(u8, 7), getA(inst3));
    try testing.expectEqual(@as(i19, -100), getsBx(inst3));
}

test "opcode modes" {
    const testing = std.testing;

    try testing.expectEqual(OpMode.iABC, getOpMode(.MOVE));
    try testing.expectEqual(OpMode.iABx, getOpMode(.LOADK));
    try testing.expectEqual(OpMode.iAsBx, getOpMode(.LOADI));
    try testing.expectEqual(OpMode.isJ, getOpMode(.JMP));

    try testing.expect(testAMode(.MOVE));
    try testing.expect(!testAMode(.SETUPVAL));
    try testing.expect(testTMode(.EQ));
    try testing.expect(!testTMode(.MOVE));
}
