// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Code Generation (AST -> Bytecode)

const std = @import("std");
const ast = @import("ast.zig");
const opcode = @import("opcode.zig");
const proto_module = @import("proto.zig");
const value = @import("value.zig");
const state = @import("state.zig");
const config = @import("config.zig");
const string_module = @import("string.zig");

const Instruction = opcode.Instruction;
const OpCode = opcode.OpCode;
const Proto = proto_module.Proto;
const NodeIndex = ast.NodeIndex;
const InternedString = ast.InternedString;

pub const CompileError = error{
    OutOfMemory,
    TooManyRegisters,
    TooManyUpvalues,
    TooManyLocals,
    TooManyConstants,
    ControlStructureTooLong,
    UndefinedGoto,
    JumpIntoScope,
    BreakOutsideLoop,
    VarargOutsideVararg,
    InvalidAssignmentTarget,
    DuplicateLabel,
    StringTooLong,
    SyntaxError,
    AssignToConst,
};

/// Maximum number of registers in a Lua function
pub const MAXREGS: u32 = 255;
/// Sentinel for "no jump" in jump lists
pub const NO_JUMP: i32 = -1;
/// Multiple returns / arguments marker
pub const MULTRET: i32 = -1;
/// Maximum local variables per function
pub const MAXVARS: u32 = config.MAXVARS;
/// Maximum upvalues per function
pub const MAXUPVAL: u32 = config.MAXUPVAL;

/// Name used for the implicit `break` label (cannot clash with a real one)
const BREAK_LABEL: InternedString = std.math.maxInt(InternedString);

/// Kinds of expression descriptors (lcode.h expkind)
pub const ExpKind = enum {
    VVOID, // empty expression (no value, or end of a list)
    VNIL,
    VTRUE,
    VFALSE,
    VK, // constant in K; info = index
    VKFLT, // float constant; nval
    VKINT, // integer constant; ival
    VKSTR, // string constant; strval (interned id)
    VNONRELOC, // value in a fixed register; info = register
    VLOCAL, // local variable; var_.ridx / var_.vidx
    VUPVAL, // upvalue; info = index
    VCONST, // compile-time constant (`<const>` local with a constant value); info = index into dyd.actvar
    VINDEXED, // R[ind.t][R[ind.idx]]
    VINDEXUP, // UpValue[ind.t][K[ind.idx]:string]
    VINDEXI, // R[ind.t][ind.idx] (integer)
    VINDEXSTR, // R[ind.t][K[ind.idx]:string]
    VJMP, // test/comparison; info = pc of the jump
    VRELOC, // result can go anywhere; info = pc of the instruction
    VCALL, // call; info = pc
    VVARARG, // vararg; info = pc
};

/// Expression descriptor
pub const ExpDesc = struct {
    k: ExpKind = .VVOID,
    u: union {
        info: i32,
        ival: i64,
        nval: f64,
        strval: InternedString,
        ind: struct { t: u8, idx: i32 },
        var_: struct { ridx: u8, vidx: u16 },
    } = .{ .info = 0 },
    t: i32 = NO_JUMP, // patch list of "exit when true"
    f: i32 = NO_JUMP, // patch list of "exit when false"

    fn init(k: ExpKind, info: i32) ExpDesc {
        return .{ .k = k, .u = .{ .info = info } };
    }

    fn hasJumps(self: *const ExpDesc) bool {
        return self.t != self.f;
    }

    fn isIndexed(self: *const ExpDesc) bool {
        return switch (self.k) {
            .VINDEXED, .VINDEXUP, .VINDEXI, .VINDEXSTR => true,
            else => false,
        };
    }

    fn hasMultRet(self: *const ExpDesc) bool {
        return self.k == .VCALL or self.k == .VVARARG;
    }

    /// Whether the expression is a numeric literal without pending jumps
    fn isNumeral(self: *const ExpDesc) bool {
        return !self.hasJumps() and (self.k == .VKINT or self.k == .VKFLT);
    }
};

/// Variable kinds (matching proto.Upvaldesc kinds)
const VDKREG: u8 = proto_module.Upvaldesc.VDKREG;
const RDKCONST: u8 = proto_module.Upvaldesc.RDKCONST;
const RDKTOCLOSE: u8 = proto_module.Upvaldesc.RDKTOCLOSE;
const RDKCTC: u8 = proto_module.Upvaldesc.RDKCTC;

/// The value of a compile-time constant variable (Vardesc.k)
const ConstVal = union(enum) {
    none,
    nil,
    tru,
    fals,
    int: i64,
    flt: f64,
    str: InternedString,
};

/// Description of an active local variable
const VarDesc = struct {
    name: InternedString,
    kind: u8 = VDKREG,
    ridx: u8 = 0, // register holding the variable
    pidx: i32 = -1, // index into Proto.locvars
    k: ConstVal = .none, // constant value when kind == RDKCTC
};

/// Description of a pending goto or an active label
const LabelDesc = struct {
    name: InternedString,
    pc: i32, // position in code
    line: u32,
    nactvar: u8, // number of active variables at that position
    close: bool, // goto that needs a CLOSE
};

/// Dynamic structures shared by all nested functions
const DynData = struct {
    actvar: std.ArrayList(VarDesc) = .empty,
    /// Length of the active prefix of `actvar`. Descriptors past it belong to
    /// variables that have left scope but are kept intact, because
    /// `moveGotosOut` still reads the levels of variables the block just
    /// removed.
    nactvar: u32 = 0,
    gt: std.ArrayList(LabelDesc) = .empty,
    label: std.ArrayList(LabelDesc) = .empty,
};

/// Nested block bookkeeping
const BlockCnt = struct {
    previous: ?*BlockCnt = null,
    firstlabel: u32 = 0,
    firstgoto: u32 = 0,
    nactvar: u8 = 0,
    upval: bool = false, // some variable in the block is an upvalue
    isloop: bool = false,
    insidetbc: bool = false, // inside the scope of a to-be-closed variable
};

/// Per-function compilation state
const FuncState = struct {
    f: *Proto,
    prev: ?*FuncState = null,
    bl: ?*BlockCnt = null,
    lasttarget: u32 = 0, // label of last jump target
    firstlocal: u32 = 0, // index of first local in dyd.actvar
    firstlabel: u32 = 0, // index of first label in dyd.label
    nactvar: u8 = 0, // number of active local variables
    freereg: u8 = 0, // first free register
    needclose: bool = false, // function needs to close upvalues on return
    upnames: std.ArrayList(InternedString) = .empty, // names of upvalues (by index)
    end_line: u32 = 0, // line the lexer was on when the function's `end` had been read

    fn pc(self: *const FuncState) u32 {
        return self.f.sizecode;
    }
};

/// The code generator
pub const CodeGen = struct {
    L: *state.LuaState,
    allocator: std.mem.Allocator,
    tree: *ast.Ast,
    source: *value.String,
    fs: ?*FuncState = null,
    dyd: DynData = .{},
    line: u32 = 0, // line of the construct being compiled

    // Names needed by the compiler itself
    env_name: InternedString,
    self_name: InternedString,
    forstate_name: InternedString,

    // Long string literals of this chunk, so that equal literals share one
    // object the way the lexer's `luaX_newstring` table makes them (short
    // strings are interned globally anyway)
    long_strings: std.AutoHashMapUnmanaged(InternedString, *value.String) = .empty,

    // First error, for diagnostics
    err_msg: ?[]const u8 = null,
    err_line: u32 = 0,
    err_buf: [256]u8 = undefined,

    pub fn init(L: *state.LuaState, tree: *ast.Ast, chunkname: []const u8) !CodeGen {
        return .{
            .L = L,
            .allocator = L.allocator,
            .tree = tree,
            .source = try L.l_G.string_pool.intern(chunkname),
            .env_name = try tree.strings.intern("_ENV"),
            .self_name = try tree.strings.intern("self"),
            .forstate_name = try tree.strings.intern("(for state)"),
        };
    }

    pub fn deinit(self: *CodeGen) void {
        self.long_strings.deinit(self.allocator);
        self.dyd.actvar.deinit(self.allocator);
        self.dyd.gt.deinit(self.allocator);
        self.dyd.label.deinit(self.allocator);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    fn node(self: *const CodeGen, idx: NodeIndex) *const ast.AstNode {
        return &self.tree.nodes[idx];
    }

    fn str(self: *const CodeGen, id: InternedString) []const u8 {
        return self.tree.strings.getString(id);
    }

    fn internString(self: *CodeGen, id: InternedString) !*value.String {
        const text = self.str(id);
        if (text.len <= string_module.LUAI_MAXSHORTLEN) return self.L.l_G.string_pool.intern(text);
        if (self.long_strings.get(id)) |s| return s;
        const s = try self.L.l_G.string_pool.create(text);
        try self.long_strings.put(self.allocator, id, s);
        return s;
    }

    fn fail(self: *CodeGen, err: CompileError, msg: []const u8) CompileError {
        if (self.err_msg == null) {
            self.err_msg = msg;
            self.err_line = self.line;
        }
        return err;
    }

    /// `fail` with a formatted message
    fn failFmt(self: *CodeGen, err: CompileError, comptime fmt: []const u8, args: anytype) CompileError {
        if (self.err_msg != null) return err; // keep the first
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch fmt;
        return self.fail(err, msg);
    }

    /// "main function" or "function at line N", for limit messages (errorlimit)
    fn whereFunc(fs: *const FuncState, buf: []u8) []const u8 {
        if (fs.f.linedefined == 0) return "main function";
        return std.fmt.bufPrint(buf, "function at line {d}", .{fs.f.linedefined}) catch "function";
    }

    fn newProto(self: *CodeGen) !*Proto {
        const p = try Proto.init(self.allocator);
        self.L.l_G.gc.linkObject(&p.header, @sizeOf(Proto));
        p.source = self.source;
        p.maxstacksize = 2; // registers 0/1 are always valid
        return p;
    }

    // ------------------------------------------------------------------
    // Instruction emission (lcode.c)
    // ------------------------------------------------------------------

    fn code(self: *CodeGen, fs: *FuncState, i: Instruction) CompileError!u32 {
        const pc = try fs.f.addInstruction(self.allocator, i);
        try fs.f.addLineInfo(self.allocator, self.line);
        return pc;
    }

    fn codeABCk(self: *CodeGen, fs: *FuncState, op: OpCode, a: u32, b: u32, c: u32, k: bool) CompileError!u32 {
        std.debug.assert(a <= opcode.MAXARG_A and b <= opcode.MAXARG_B and c <= opcode.MAXARG_C);
        return self.code(fs, opcode.createABCk(op, @intCast(a), @intCast(b), @intCast(c), k));
    }

    fn codeABC(self: *CodeGen, fs: *FuncState, op: OpCode, a: u32, b: u32, c: u32) CompileError!u32 {
        return self.codeABCk(fs, op, a, b, c, false);
    }

    fn codeABx(self: *CodeGen, fs: *FuncState, op: OpCode, a: u32, bx: u32) CompileError!u32 {
        std.debug.assert(bx <= opcode.MAXARG_Bx);
        return self.code(fs, opcode.createABx(op, @intCast(a), @intCast(bx)));
    }

    fn codeAsBx(self: *CodeGen, fs: *FuncState, op: OpCode, a: u32, sbx: i32) CompileError!u32 {
        return self.code(fs, opcode.createAsBx(op, @intCast(a), @intCast(sbx)));
    }

    fn codesJ(self: *CodeGen, fs: *FuncState, op: OpCode, sj: i32, k: bool) CompileError!u32 {
        return self.code(fs, opcode.createsJ(op, @intCast(sj), k));
    }

    fn codeExtraArg(self: *CodeGen, fs: *FuncState, a: u32) CompileError!u32 {
        std.debug.assert(a <= opcode.MAXARG_Ax);
        return self.code(fs, opcode.createAx(.EXTRAARG, @intCast(a)));
    }

    /// Load constant `k` into `reg`
    fn codeK(self: *CodeGen, fs: *FuncState, reg: u32, k: u32) CompileError!u32 {
        if (k <= opcode.MAXARG_Bx) {
            return self.codeABx(fs, .LOADK, reg, k);
        }
        const p = try self.codeABx(fs, .LOADKX, reg, 0);
        _ = try self.codeExtraArg(fs, k);
        return p;
    }

    fn instruction(fs: *FuncState, e: *const ExpDesc) *Instruction {
        return &fs.f.code[@intCast(e.u.info)];
    }

    fn previousInstruction(fs: *FuncState) ?*Instruction {
        if (fs.pc() > fs.lasttarget) return &fs.f.code[fs.pc() - 1];
        return null;
    }

    /// Remove the last instruction (and its line info)
    fn removeLastInstruction(self: *CodeGen, fs: *FuncState) void {
        _ = self;
        const f = fs.f;
        f.sizecode -= 1;
        // Undo the line-info entry for it
        f.sizelineinfo -= 1;
        const d: i8 = @bitCast(f.lineinfo[f.sizelineinfo]);
        if (d == proto_module.ABSLINEINFO) {
            f.sizeabslineinfo -= 1;
            f.iwthabs = proto_module.MAXIWTHABS; // force an absolute entry next time
        } else {
            f.previousline = @intCast(@as(i64, f.previousline) - d);
            f.iwthabs -= 1;
        }
    }

    /// Change the line of the last instruction
    fn fixLine(self: *CodeGen, fs: *FuncState, line: u32) CompileError!void {
        const f = fs.f;
        f.sizelineinfo -= 1;
        const d: i8 = @bitCast(f.lineinfo[f.sizelineinfo]);
        if (d == proto_module.ABSLINEINFO) {
            f.sizeabslineinfo -= 1;
            f.iwthabs = proto_module.MAXIWTHABS;
        } else {
            f.previousline = @intCast(@as(i64, f.previousline) - d);
            f.iwthabs -= 1;
        }
        try f.addLineInfo(self.allocator, line);
    }

    // Registers

    fn checkStack(self: *CodeGen, fs: *FuncState, n: u32) CompileError!void {
        const newstack = @as(u32, fs.freereg) + n;
        if (newstack > fs.f.maxstacksize) {
            if (newstack >= MAXREGS) return self.fail(error.TooManyRegisters, "function or expression needs too many registers");
            fs.f.maxstacksize = @intCast(newstack);
        }
    }

    fn reserveRegs(self: *CodeGen, fs: *FuncState, n: u32) CompileError!void {
        try self.checkStack(fs, n);
        fs.freereg += @intCast(n);
    }

    fn freeReg(self: *CodeGen, fs: *FuncState, reg: u32) void {
        if (reg >= self.nvarstack(fs)) {
            fs.freereg -= 1;
            std.debug.assert(reg == fs.freereg);
        }
    }

    fn freeRegs(self: *CodeGen, fs: *FuncState, r1: u32, r2: u32) void {
        if (r1 > r2) {
            self.freeReg(fs, r1);
            self.freeReg(fs, r2);
        } else {
            self.freeReg(fs, r2);
            self.freeReg(fs, r1);
        }
    }

    fn freeExp(self: *CodeGen, fs: *FuncState, e: *const ExpDesc) void {
        if (e.k == .VNONRELOC) self.freeReg(fs, @intCast(e.u.info));
    }

    fn freeExps(self: *CodeGen, fs: *FuncState, e1: *const ExpDesc, e2: *const ExpDesc) void {
        const r1: i32 = if (e1.k == .VNONRELOC) e1.u.info else -1;
        const r2: i32 = if (e2.k == .VNONRELOC) e2.u.info else -1;
        if (r1 > r2) {
            if (r1 >= 0) self.freeReg(fs, @intCast(r1));
            if (r2 >= 0) self.freeReg(fs, @intCast(r2));
        } else {
            if (r2 >= 0) self.freeReg(fs, @intCast(r2));
            if (r1 >= 0) self.freeReg(fs, @intCast(r1));
        }
    }

    // Jumps

    fn getJump(fs: *FuncState, pc: i32) i32 {
        const offset = opcode.getsJ(fs.f.code[@intCast(pc)]);
        if (offset == NO_JUMP) return NO_JUMP;
        return pc + 1 + offset;
    }

    fn fixJump(self: *CodeGen, fs: *FuncState, pc: i32, dest: i32) CompileError!void {
        const offset = dest - (pc + 1);
        if (offset < -@as(i32, opcode.OFFSET_sJ) or offset > @as(i32, opcode.MAXARG_sJ) - @as(i32, opcode.OFFSET_sJ)) {
            return self.fail(error.ControlStructureTooLong, "control structure too long");
        }
        opcode.setsJ(&fs.f.code[@intCast(pc)], @intCast(offset));
    }

    /// Append jump list `l2` to `l1`
    fn concatJumps(self: *CodeGen, fs: *FuncState, l1: *i32, l2: i32) CompileError!void {
        if (l2 == NO_JUMP) return;
        if (l1.* == NO_JUMP) {
            l1.* = l2;
        } else {
            var list = l1.*;
            while (true) {
                const next = getJump(fs, list);
                if (next == NO_JUMP) break;
                list = next;
            }
            try self.fixJump(fs, list, l2);
        }
    }

    fn jump(self: *CodeGen, fs: *FuncState) CompileError!i32 {
        return @intCast(try self.codesJ(fs, .JMP, NO_JUMP, false));
    }

    /// `return R[first], ...` with `nret` values (MULTRET: up to the top)
    fn ret(self: *CodeGen, fs: *FuncState, first: u32, nret: i32) CompileError!void {
        const op: OpCode = switch (nret) {
            0 => .RETURN0,
            1 => .RETURN1,
            else => .RETURN,
        };
        _ = try self.codeABC(fs, op, first, @intCast(nret + 1), 0);
    }

    fn condJump(self: *CodeGen, fs: *FuncState, op: OpCode, a: u32, b: u32, c: u32, k: bool) CompileError!i32 {
        _ = try self.codeABCk(fs, op, a, b, c, k);
        return self.jump(fs);
    }

    /// Current pc, marked as a jump target (prevents merging optimisations)
    fn getLabel(fs: *FuncState) u32 {
        fs.lasttarget = fs.pc();
        return fs.pc();
    }

    /// The instruction controlling a jump (a TESTSET/TEST/comparison), or the jump itself
    fn getJumpControl(fs: *FuncState, pc: i32) *Instruction {
        const p: usize = @intCast(pc);
        if (p >= 1 and opcode.testTMode(opcode.getOpcode(fs.f.code[p - 1]))) {
            return &fs.f.code[p - 1];
        }
        return &fs.f.code[p];
    }

    /// Patch the destination register of a TESTSET (or turn it into a TEST)
    fn patchTestReg(fs: *FuncState, pc: i32, reg: u32) bool {
        const i = getJumpControl(fs, pc);
        if (opcode.getOpcode(i.*) != .TESTSET) return false;
        if (reg != opcode.NO_REG and reg != opcode.getB(i.*)) {
            opcode.setA(i, @intCast(reg));
        } else {
            i.* = opcode.createABCk(.TEST, opcode.getB(i.*), 0, 0, opcode.getk(i.*));
        }
        return true;
    }

    fn removeValues(fs: *FuncState, list_in: i32) void {
        var list = list_in;
        while (list != NO_JUMP) : (list = getJump(fs, list)) {
            _ = patchTestReg(fs, list, opcode.NO_REG);
        }
    }

    fn patchListAux(self: *CodeGen, fs: *FuncState, list_in: i32, vtarget: i32, reg: u32, dtarget: i32) CompileError!void {
        var list = list_in;
        while (list != NO_JUMP) {
            const next = getJump(fs, list);
            if (patchTestReg(fs, list, reg)) {
                try self.fixJump(fs, list, vtarget);
            } else {
                try self.fixJump(fs, list, dtarget);
            }
            list = next;
        }
    }

    fn patchList(self: *CodeGen, fs: *FuncState, list: i32, target: i32) CompileError!void {
        try self.patchListAux(fs, list, target, opcode.NO_REG, target);
    }

    fn patchToHere(self: *CodeGen, fs: *FuncState, list: i32) CompileError!void {
        const hr: i32 = @intCast(getLabel(fs));
        try self.patchList(fs, list, hr);
    }

    // Constants

    // A prototype under construction is a collectable object, and an
    // emergency collection can run while it is being built (a failed
    // allocation anywhere in the compiler). After one, the prototype is
    // black, in generational mode old, and nothing re-traverses it; so
    // every collectable thing attached to it afterwards goes through the
    // forward barrier, as lcode.c and lparser.c do (luaC_objbarrier)
    fn addK(self: *CodeGen, fs: *FuncState, v: value.TValue) CompileError!u32 {
        const idx = fs.f.addConstant(self.allocator, v) catch return error.OutOfMemory;
        self.L.l_G.gc.barrier(&fs.f.header, &v);
        if (idx > opcode.MAXARG_Ax) return self.fail(error.TooManyConstants, "too many constants");
        return idx;
    }

    fn stringK(self: *CodeGen, fs: *FuncState, id: InternedString) CompileError!u32 {
        const s = self.internString(id) catch return error.OutOfMemory;
        return self.addK(fs, value.TValue.string(s));
    }

    fn intK(self: *CodeGen, fs: *FuncState, i: i64) CompileError!u32 {
        return self.addK(fs, try value.TValue.integerOrBox(&self.L.l_G.gc, i));
    }

    fn numberK(self: *CodeGen, fs: *FuncState, r: f64) CompileError!u32 {
        return self.addK(fs, value.TValue.float(r));
    }

    fn boolFK(self: *CodeGen, fs: *FuncState) CompileError!u32 {
        return self.addK(fs, value.TValue.boolean(false));
    }

    fn boolTK(self: *CodeGen, fs: *FuncState) CompileError!u32 {
        return self.addK(fs, value.TValue.boolean(true));
    }

    fn nilK(self: *CodeGen, fs: *FuncState) CompileError!u32 {
        return self.addK(fs, value.TValue.nil());
    }

    fn fitsBx(i: i64) bool {
        return -@as(i64, opcode.OFFSET_sBx) <= i and i <= @as(i64, opcode.MAXARG_Bx) - @as(i64, opcode.OFFSET_sBx);
    }

    fn fitsC(i: i64) bool {
        // Compared without adding the offset: `i` can be anywhere in the
        // 64-bit range (fitsC)
        return -@as(i64, opcode.OFFSET_sC) <= i and i <= @as(i64, opcode.MAXARG_C) - @as(i64, opcode.OFFSET_sC);
    }

    fn int2sC(i: i64) u32 {
        return @intCast(i + opcode.OFFSET_sC);
    }

    fn codeInt(self: *CodeGen, fs: *FuncState, reg: u32, i: i64) CompileError!void {
        if (fitsBx(i)) {
            _ = try self.codeAsBx(fs, .LOADI, reg, @intCast(i));
        } else {
            _ = try self.codeK(fs, reg, try self.intK(fs, i));
        }
    }

    fn codeFloat(self: *CodeGen, fs: *FuncState, reg: u32, f: f64) CompileError!void {
        if (@floor(f) == f and f >= -9223372036854775808.0 and f < 9223372036854775808.0) {
            const fi: i64 = @intFromFloat(f);
            if (fitsBx(fi) and @as(f64, @floatFromInt(fi)) == f and !(f == 0 and std.math.signbit(f))) {
                _ = try self.codeAsBx(fs, .LOADF, reg, @intCast(fi));
                return;
            }
        }
        _ = try self.codeK(fs, reg, try self.numberK(fs, f));
    }

    /// Load `n` nils starting at `from`, merging with a previous LOADNIL
    fn codeNil(self: *CodeGen, fs: *FuncState, from_in: u32, n: u32) CompileError!void {
        var from = from_in;
        var l = from + n - 1;
        if (previousInstruction(fs)) |previous| {
            if (opcode.getOpcode(previous.*) == .LOADNIL) {
                const pfrom: u32 = opcode.getA(previous.*);
                const pl: u32 = pfrom + opcode.getB(previous.*);
                if ((pfrom <= from and from <= pl + 1) or (from <= pfrom and pfrom <= l + 1)) {
                    if (pfrom < from) from = pfrom;
                    if (pl > l) l = pl;
                    opcode.setA(previous, @intCast(from));
                    opcode.setB(previous, @intCast(l - from));
                    return;
                }
            }
        }
        _ = try self.codeABC(fs, .LOADNIL, from, n - 1, 0);
    }

    // Discharging expressions

    fn setReturns(self: *CodeGen, fs: *FuncState, e: *ExpDesc, nresults: i32) CompileError!void {
        const pc = instruction(fs, e);
        if (e.k == .VCALL) {
            opcode.setC(pc, @intCast(nresults + 1));
        } else {
            std.debug.assert(e.k == .VVARARG);
            opcode.setC(pc, @intCast(nresults + 1));
            opcode.setA(pc, fs.freereg);
            try self.reserveRegs(fs, 1);
        }
    }

    fn setMultRet(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        try self.setReturns(fs, e, MULTRET);
    }

    fn setOneRet(fs: *FuncState, e: *ExpDesc) void {
        if (e.k == .VCALL) {
            e.k = .VNONRELOC;
            e.u.info = opcode.getA(instruction(fs, e).*);
        } else if (e.k == .VVARARG) {
            opcode.setC(instruction(fs, e), 2);
            e.k = .VRELOC;
        }
    }

    fn dischargeVars(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        switch (e.k) {
            .VCONST => self.const2Exp(self.dyd.actvar.items[@intCast(e.u.info)].k, e),
            .VLOCAL => {
                const ridx: i32 = e.u.var_.ridx; // read before the union is rewritten
                e.u = .{ .info = ridx };
                e.k = .VNONRELOC;
            },
            .VUPVAL => {
                e.u.info = @intCast(try self.codeABC(fs, .GETUPVAL, 0, @intCast(e.u.info), 0));
                e.k = .VRELOC;
            },
            .VINDEXUP => {
                const t = e.u.ind.t;
                const idx: u32 = @intCast(e.u.ind.idx);
                e.u = .{ .info = @intCast(try self.codeABC(fs, .GETTABUP, 0, t, idx)) };
                e.k = .VRELOC;
            },
            .VINDEXI => {
                const t = e.u.ind.t;
                const idx: u32 = @intCast(e.u.ind.idx);
                self.freeReg(fs, t);
                e.u = .{ .info = @intCast(try self.codeABC(fs, .GETI, 0, t, idx)) };
                e.k = .VRELOC;
            },
            .VINDEXSTR => {
                const t = e.u.ind.t;
                const idx: u32 = @intCast(e.u.ind.idx);
                self.freeReg(fs, t);
                e.u = .{ .info = @intCast(try self.codeABC(fs, .GETFIELD, 0, t, idx)) };
                e.k = .VRELOC;
            },
            .VINDEXED => {
                const t = e.u.ind.t;
                const idx: u32 = @intCast(e.u.ind.idx);
                self.freeRegs(fs, t, idx);
                e.u = .{ .info = @intCast(try self.codeABC(fs, .GETTABLE, 0, t, idx)) };
                e.k = .VRELOC;
            },
            .VVARARG, .VCALL => setOneRet(fs, e),
            else => {},
        }
    }

    /// Turn a compile-time constant back into a literal expression (const2exp)
    fn const2Exp(self: *CodeGen, k: ConstVal, e: *ExpDesc) void {
        _ = self;
        switch (k) {
            .int => |i| e.* = .{ .k = .VKINT, .u = .{ .ival = i } },
            .flt => |f| e.* = .{ .k = .VKFLT, .u = .{ .nval = f } },
            .str => |sv| e.* = .{ .k = .VKSTR, .u = .{ .strval = sv } },
            .nil => e.* = ExpDesc.init(.VNIL, 0),
            .tru => e.* = ExpDesc.init(.VTRUE, 0),
            .fals => e.* = ExpDesc.init(.VFALSE, 0),
            .none => unreachable,
        }
    }

    /// The constant value of an expression, if it has one (luaK_exp2const)
    fn exp2Const(self: *CodeGen, e: *const ExpDesc) ?ConstVal {
        if (e.hasJumps()) return null;
        return switch (e.k) {
            .VFALSE => .fals,
            .VTRUE => .tru,
            .VNIL => .nil,
            .VKSTR => .{ .str = e.u.strval },
            .VKINT => .{ .int = e.u.ival },
            .VKFLT => .{ .flt = e.u.nval },
            .VCONST => self.dyd.actvar.items[@intCast(e.u.info)].k,
            else => null,
        };
    }

    fn str2K(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        std.debug.assert(e.k == .VKSTR);
        const k = try self.stringK(fs, e.u.strval);
        e.u = .{ .info = @intCast(k) };
        e.k = .VK;
    }

    fn discharge2Reg(self: *CodeGen, fs: *FuncState, e: *ExpDesc, reg: u32) CompileError!void {
        try self.dischargeVars(fs, e);
        switch (e.k) {
            .VNIL => try self.codeNil(fs, reg, 1),
            .VFALSE => _ = try self.codeABC(fs, .LOADFALSE, reg, 0, 0),
            .VTRUE => _ = try self.codeABC(fs, .LOADTRUE, reg, 0, 0),
            .VKSTR => {
                try self.str2K(fs, e);
                _ = try self.codeK(fs, reg, @intCast(e.u.info));
            },
            .VK => _ = try self.codeK(fs, reg, @intCast(e.u.info)),
            .VKFLT => try self.codeFloat(fs, reg, e.u.nval),
            .VKINT => try self.codeInt(fs, reg, e.u.ival),
            .VRELOC => opcode.setA(instruction(fs, e), @intCast(reg)),
            .VNONRELOC => {
                if (reg != e.u.info) {
                    _ = try self.codeABC(fs, .MOVE, reg, @intCast(e.u.info), 0);
                }
            },
            else => {
                std.debug.assert(e.k == .VJMP);
                return; // nothing to do
            },
        }
        e.u = .{ .info = @intCast(reg) };
        e.k = .VNONRELOC;
    }

    fn discharge2AnyReg(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        if (e.k != .VNONRELOC) {
            try self.reserveRegs(fs, 1);
            try self.discharge2Reg(fs, e, fs.freereg - 1);
        }
    }

    fn codeLoadBool(self: *CodeGen, fs: *FuncState, a: u32, op: OpCode) CompileError!i32 {
        _ = getLabel(fs);
        return @intCast(try self.codeABC(fs, op, a, 0, 0));
    }

    /// Whether some jump in the list needs a value (is not a TESTSET)
    fn needValue(fs: *FuncState, list_in: i32) bool {
        var list = list_in;
        while (list != NO_JUMP) : (list = getJump(fs, list)) {
            const i = getJumpControl(fs, list);
            if (opcode.getOpcode(i.*) != .TESTSET) return true;
        }
        return false;
    }

    fn exp2Reg(self: *CodeGen, fs: *FuncState, e: *ExpDesc, reg: u32) CompileError!void {
        try self.discharge2Reg(fs, e, reg);
        if (e.k == .VJMP) try self.concatJumps(fs, &e.t, e.u.info);
        if (e.hasJumps()) {
            var p_f: i32 = NO_JUMP;
            var p_t: i32 = NO_JUMP;
            if (needValue(fs, e.t) or needValue(fs, e.f)) {
                const fj: i32 = if (e.k == .VJMP) NO_JUMP else try self.jump(fs);
                p_f = try self.codeLoadBool(fs, reg, .LFALSESKIP);
                p_t = try self.codeLoadBool(fs, reg, .LOADTRUE);
                try self.patchToHere(fs, fj);
            }
            const final: i32 = @intCast(getLabel(fs));
            try self.patchListAux(fs, e.f, final, reg, p_f);
            try self.patchListAux(fs, e.t, final, reg, p_t);
        }
        e.f = NO_JUMP;
        e.t = NO_JUMP;
        e.u = .{ .info = @intCast(reg) };
        e.k = .VNONRELOC;
    }

    fn exp2NextReg(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        try self.dischargeVars(fs, e);
        self.freeExp(fs, e);
        try self.reserveRegs(fs, 1);
        try self.exp2Reg(fs, e, fs.freereg - 1);
    }

    fn exp2AnyReg(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!u32 {
        try self.dischargeVars(fs, e);
        if (e.k == .VNONRELOC) {
            if (!e.hasJumps()) return @intCast(e.u.info);
            if (e.u.info >= self.nvarstack(fs)) {
                try self.exp2Reg(fs, e, @intCast(e.u.info));
                return @intCast(e.u.info);
            }
        }
        try self.exp2NextReg(fs, e);
        return @intCast(e.u.info);
    }

    fn exp2AnyRegUp(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        if (e.k != .VUPVAL or e.hasJumps()) _ = try self.exp2AnyReg(fs, e);
    }

    fn exp2Val(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        // A bare VJMP has no jump lists yet but is still code that must be
        // materialised before anything else is emitted (5.4.7 fix)
        if (e.k == .VJMP or e.hasJumps()) {
            _ = try self.exp2AnyReg(fs, e);
        } else {
            try self.dischargeVars(fs, e);
        }
    }

    /// Try to make `e` a K operand (index fits in an RK field)
    fn exp2K(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!bool {
        if (!e.hasJumps()) {
            const info: u32 = switch (e.k) {
                .VTRUE => try self.boolTK(fs),
                .VFALSE => try self.boolFK(fs),
                .VNIL => try self.nilK(fs),
                .VKINT => try self.intK(fs, e.u.ival),
                .VKFLT => try self.numberK(fs, e.u.nval),
                .VKSTR => try self.stringK(fs, e.u.strval),
                .VK => @intCast(e.u.info),
                else => return false,
            };
            if (info <= opcode.MAXINDEXRK) {
                e.k = .VK;
                e.u = .{ .info = @intCast(info) };
                return true;
            }
        }
        return false;
    }

    fn exp2RK(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!bool {
        if (try self.exp2K(fs, e)) return true;
        _ = try self.exp2AnyReg(fs, e);
        return false;
    }

    fn codeABRK(self: *CodeGen, fs: *FuncState, op: OpCode, a: u32, b: u32, ec: *ExpDesc) CompileError!void {
        const k = try self.exp2RK(fs, ec);
        _ = try self.codeABCk(fs, op, a, b, @intCast(ec.u.info), k);
    }

    fn storeVar(self: *CodeGen, fs: *FuncState, v: *const ExpDesc, ex: *ExpDesc) CompileError!void {
        switch (v.k) {
            .VLOCAL => {
                self.freeExp(fs, ex);
                try self.exp2Reg(fs, ex, v.u.var_.ridx);
                return;
            },
            .VUPVAL => {
                const e = try self.exp2AnyReg(fs, ex);
                _ = try self.codeABC(fs, .SETUPVAL, e, @intCast(v.u.info), 0);
            },
            .VINDEXUP => try self.codeABRK(fs, .SETTABUP, v.u.ind.t, @intCast(v.u.ind.idx), ex),
            .VINDEXI => try self.codeABRK(fs, .SETI, v.u.ind.t, @intCast(v.u.ind.idx), ex),
            .VINDEXSTR => try self.codeABRK(fs, .SETFIELD, v.u.ind.t, @intCast(v.u.ind.idx), ex),
            .VINDEXED => try self.codeABRK(fs, .SETTABLE, v.u.ind.t, @intCast(v.u.ind.idx), ex),
            else => unreachable,
        }
        self.freeExp(fs, ex);
    }

    /// `e:key` method lookup: R[A+1] := e; R[A] := e[key]
    fn codeSelf(self: *CodeGen, fs: *FuncState, e: *ExpDesc, key: *ExpDesc) CompileError!void {
        _ = try self.exp2AnyReg(fs, e);
        const ereg: u32 = @intCast(e.u.info);
        self.freeExp(fs, e);
        e.u = .{ .info = fs.freereg };
        e.k = .VNONRELOC;
        try self.reserveRegs(fs, 2);
        try self.codeABRK(fs, .SELF, @intCast(e.u.info), ereg, key);
        self.freeExp(fs, key);
    }

    fn negateCondition(fs: *FuncState, e: *ExpDesc) void {
        const pc = getJumpControl(fs, e.u.info);
        opcode.setk(pc, !opcode.getk(pc.*));
    }

    fn jumpOnCond(self: *CodeGen, fs: *FuncState, e: *ExpDesc, jump_if: bool) CompileError!i32 {
        if (e.k == .VRELOC) {
            const ie = instruction(fs, e).*;
            if (opcode.getOpcode(ie) == .NOT) {
                self.removeLastInstruction(fs);
                return self.condJump(fs, .TEST, opcode.getB(ie), 0, 0, !jump_if);
            }
        }
        try self.discharge2AnyReg(fs, e);
        self.freeExp(fs, e);
        return self.condJump(fs, .TESTSET, opcode.NO_REG, @intCast(e.u.info), 0, jump_if);
    }

    fn goIfTrue(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        try self.dischargeVars(fs, e);
        const pc: i32 = switch (e.k) {
            .VJMP => blk: {
                negateCondition(fs, e);
                break :blk e.u.info;
            },
            .VK, .VKFLT, .VKINT, .VKSTR, .VTRUE => NO_JUMP,
            else => try self.jumpOnCond(fs, e, false),
        };
        try self.concatJumps(fs, &e.f, pc);
        try self.patchToHere(fs, e.t);
        e.t = NO_JUMP;
    }

    fn goIfFalse(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        try self.dischargeVars(fs, e);
        const pc: i32 = switch (e.k) {
            .VJMP => e.u.info,
            .VNIL, .VFALSE => NO_JUMP,
            else => try self.jumpOnCond(fs, e, true),
        };
        try self.concatJumps(fs, &e.t, pc);
        try self.patchToHere(fs, e.f);
        e.f = NO_JUMP;
    }

    fn codeNot(self: *CodeGen, fs: *FuncState, e: *ExpDesc) CompileError!void {
        switch (e.k) {
            .VNIL, .VFALSE => e.k = .VTRUE,
            .VK, .VKFLT, .VKINT, .VKSTR, .VTRUE => e.k = .VFALSE,
            .VJMP => negateCondition(fs, e),
            .VRELOC, .VNONRELOC => {
                try self.discharge2AnyReg(fs, e);
                self.freeExp(fs, e);
                e.u.info = @intCast(try self.codeABC(fs, .NOT, 0, @intCast(e.u.info), 0));
                e.k = .VRELOC;
            },
            else => unreachable,
        }
        const tmp = e.f;
        e.f = e.t;
        e.t = tmp;
        removeValues(fs, e.f);
        removeValues(fs, e.t);
    }

    /// Whether `e` is a constant short string usable as a key
    fn isKstr(self: *CodeGen, fs: *FuncState, e: *const ExpDesc) bool {
        _ = self;
        if (e.k != .VK or e.hasJumps() or e.u.info > opcode.MAXARG_B) return false;
        const k = fs.f.constants[@intCast(e.u.info)];
        return k.isString() and k.stringValue().isShort();
    }

    fn isKint(e: *const ExpDesc) bool {
        return e.k == .VKINT and !e.hasJumps();
    }

    fn isCint(e: *const ExpDesc) bool {
        return isKint(e) and e.u.ival >= 0 and e.u.ival <= opcode.MAXARG_C;
    }

    fn isSCint(e: *const ExpDesc) bool {
        return isKint(e) and fitsC(e.u.ival);
    }

    /// Integral numeral that fits sC: sets `pi` to the encoded value
    fn isSCnumber(e: *const ExpDesc, pi: *u32, isfloat: *bool) bool {
        var i: i64 = undefined;
        if (e.k == .VKINT) {
            i = e.u.ival;
        } else if (e.k == .VKFLT and @floor(e.u.nval) == e.u.nval and @abs(e.u.nval) < 1e15) {
            i = @intFromFloat(e.u.nval);
            isfloat.* = true;
        } else {
            return false;
        }
        if (!e.hasJumps() and fitsC(i)) {
            pi.* = int2sC(i);
            return true;
        }
        return false;
    }

    fn indexed(self: *CodeGen, fs: *FuncState, t: *ExpDesc, k: *ExpDesc) CompileError!void {
        if (k.k == .VKSTR) try self.str2K(fs, k);
        std.debug.assert(!t.hasJumps() and (t.k == .VLOCAL or t.k == .VNONRELOC or t.k == .VUPVAL));
        if (t.k == .VUPVAL and !self.isKstr(fs, k)) {
            _ = try self.exp2AnyReg(fs, t); // upvalue indexed by a non-constant: put it in a register
        }
        if (t.k == .VUPVAL) {
            const tidx: u8 = @intCast(t.u.info);
            const kidx = k.u.info;
            t.u = .{ .ind = .{ .t = tidx, .idx = kidx } };
            t.k = .VINDEXUP;
        } else {
            const treg: u8 = if (t.k == .VLOCAL) t.u.var_.ridx else @intCast(t.u.info);
            if (self.isKstr(fs, k)) {
                t.u = .{ .ind = .{ .t = treg, .idx = k.u.info } };
                t.k = .VINDEXSTR;
            } else if (isCint(k)) {
                t.u = .{ .ind = .{ .t = treg, .idx = @intCast(k.u.ival) } };
                t.k = .VINDEXI;
            } else {
                const kreg = try self.exp2AnyReg(fs, k);
                t.u = .{ .ind = .{ .t = treg, .idx = @intCast(kreg) } };
                t.k = .VINDEXED;
            }
        }
    }

    // Constant folding

    fn validOp(op: ast.BinaryOp, v1: value.Number, v2: value.Number) bool {
        return switch (op) {
            .band, .bor, .bxor, .shl, .shr => v1.toInteger() != null and v2.toInteger() != null,
            .div, .floor_div, .mod => v2.toFloat() != 0,
            else => true,
        };
    }

    fn foldArith(op: ast.BinaryOp, a: value.Number, b: value.Number) ?value.Number {
        const both_int = a == .integer and b == .integer;
        switch (op) {
            .add => return if (both_int) .{ .integer = a.integer +% b.integer } else .{ .float = a.toFloat() + b.toFloat() },
            .sub => return if (both_int) .{ .integer = a.integer -% b.integer } else .{ .float = a.toFloat() - b.toFloat() },
            .mul => return if (both_int) .{ .integer = a.integer *% b.integer } else .{ .float = a.toFloat() * b.toFloat() },
            .div => return .{ .float = a.toFloat() / b.toFloat() },
            .pow => return .{ .float = std.math.pow(f64, a.toFloat(), b.toFloat()) },
            .floor_div => {
                if (both_int) {
                    if (b.integer == 0) return null;
                    if (b.integer == -1) return .{ .integer = 0 -% a.integer }; // avoid overflow trap
                    return .{ .integer = @divFloor(a.integer, b.integer) };
                }
                return .{ .float = @floor(a.toFloat() / b.toFloat()) };
            },
            .mod => {
                if (both_int) {
                    if (b.integer == 0) return null;
                    if (b.integer == -1) return .{ .integer = 0 };
                    return .{ .integer = @mod(a.integer, b.integer) };
                }
                const x = a.toFloat();
                const y = b.toFloat();
                var m = @rem(x, y);
                if ((m > 0 and y < 0) or (m < 0 and y > 0)) m += y;
                return .{ .float = m };
            },
            .band => return .{ .integer = a.toInteger().? & b.toInteger().? },
            .bor => return .{ .integer = a.toInteger().? | b.toInteger().? },
            .bxor => return .{ .integer = a.toInteger().? ^ b.toInteger().? },
            .shl => return .{ .integer = shiftLeft(a.toInteger().?, b.toInteger().?) },
            .shr => return .{ .integer = shiftLeft(a.toInteger().?, 0 -% b.toInteger().?) },
            else => return null,
        }
    }

    fn shiftLeft(x: i64, y: i64) i64 {
        if (y <= -64) return 0;
        if (y >= 64) return 0;
        if (y >= 0) return @bitCast(@as(u64, @bitCast(x)) << @intCast(y));
        return @bitCast(@as(u64, @bitCast(x)) >> @intCast(-y));
    }

    fn numeralOf(e: *const ExpDesc) value.Number {
        return if (e.k == .VKINT) .{ .integer = e.u.ival } else .{ .float = e.u.nval };
    }

    /// Fold `e1 op e2` if both are numerals and the result is a safe constant
    fn constFolding(op: ast.BinaryOp, e1: *ExpDesc, e2: *const ExpDesc) bool {
        if (!e1.isNumeral() or !e2.isNumeral()) return false;
        const v1 = numeralOf(e1);
        const v2 = numeralOf(e2);
        if (!validOp(op, v1, v2)) return false;
        const res = foldArith(op, v1, v2) orelse return false;
        switch (res) {
            .integer => |i| {
                e1.k = .VKINT;
                e1.u = .{ .ival = i };
            },
            .float => |n| {
                if (std.math.isNan(n) or n == 0) return false; // folds could produce -0 or NaN
                e1.k = .VKFLT;
                e1.u = .{ .nval = n };
            },
        }
        return true;
    }

    fn constFoldingUnary(op: ast.UnaryOp, e: *ExpDesc) bool {
        if (!e.isNumeral()) return false;
        const v = numeralOf(e);
        switch (op) {
            .neg => switch (v) {
                .integer => |i| {
                    e.u = .{ .ival = 0 -% i };
                },
                .float => |f| {
                    if (f == 0) return false;
                    e.u = .{ .nval = -f };
                },
            },
            .bnot => {
                const i = v.toInteger() orelse return false;
                e.k = .VKINT;
                e.u = .{ .ival = ~i };
            },
            else => return false,
        }
        return true;
    }

    // Arithmetic and comparison code

    fn tmOf(op: ast.BinaryOp) value.TMS {
        return switch (op) {
            .add => .__add,
            .sub => .__sub,
            .mul => .__mul,
            .div => .__div,
            .mod => .__mod,
            .pow => .__pow,
            .floor_div => .__idiv,
            .band => .__band,
            .bor => .__bor,
            .bxor => .__bxor,
            .shl => .__shl,
            .shr => .__shr,
            .concat => .__concat,
            else => unreachable,
        };
    }

    fn arithOpcode(op: ast.BinaryOp) OpCode {
        return switch (op) {
            .add => .ADD,
            .sub => .SUB,
            .mul => .MUL,
            .div => .DIV,
            .mod => .MOD,
            .pow => .POW,
            .floor_div => .IDIV,
            .band => .BAND,
            .bor => .BOR,
            .bxor => .BXOR,
            .shl => .SHL,
            .shr => .SHR,
            else => unreachable,
        };
    }

    fn arithKOpcode(op: ast.BinaryOp) OpCode {
        return switch (op) {
            .add => .ADDK,
            .sub => .SUBK,
            .mul => .MULK,
            .div => .DIVK,
            .mod => .MODK,
            .pow => .POWK,
            .floor_div => .IDIVK,
            .band => .BANDK,
            .bor => .BORK,
            .bxor => .BXORK,
            else => unreachable,
        };
    }

    fn codeUnExpVal(self: *CodeGen, fs: *FuncState, op: OpCode, e: *ExpDesc, line: u32) CompileError!void {
        const r = try self.exp2AnyReg(fs, e);
        self.freeExp(fs, e);
        e.u = .{ .info = @intCast(try self.codeABC(fs, op, 0, r, 0)) };
        e.k = .VRELOC;
        try self.fixLine(fs, line);
    }

    fn finishBinExpVal(self: *CodeGen, fs: *FuncState, e1: *ExpDesc, e2: *ExpDesc, op: OpCode, v2: u32, flip: bool, line: u32, mmop: OpCode, event: value.TMS) CompileError!void {
        const v1 = try self.exp2AnyReg(fs, e1);
        const pc = try self.codeABCk(fs, op, 0, v1, v2, false);
        self.freeExps(fs, e1, e2);
        e1.u = .{ .info = @intCast(pc) };
        e1.k = .VRELOC;
        try self.fixLine(fs, line);
        _ = try self.codeABCk(fs, mmop, v1, v2, @intFromEnum(event), flip);
        try self.fixLine(fs, line);
    }

    fn codeBinExpVal(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc, line: u32) CompileError!void {
        const v2 = try self.exp2AnyReg(fs, e2);
        try self.finishBinExpVal(fs, e1, e2, arithOpcode(opr), v2, false, line, .MMBIN, tmOf(opr));
    }

    fn codeBinI(self: *CodeGen, fs: *FuncState, op: OpCode, e1: *ExpDesc, e2: *ExpDesc, flip: bool, line: u32, event: value.TMS) CompileError!void {
        const v2 = int2sC(e2.u.ival);
        try self.finishBinExpVal(fs, e1, e2, op, v2, flip, line, .MMBINI, event);
    }

    fn codeBinK(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc, flip: bool, line: u32) CompileError!void {
        const v2: u32 = @intCast(e2.u.info);
        try self.finishBinExpVal(fs, e1, e2, arithKOpcode(opr), v2, flip, line, .MMBINK, tmOf(opr));
    }

    /// `e1 - K` / `e1 >> K` as an immediate with the negated constant
    fn finishBinExpNeg(self: *CodeGen, fs: *FuncState, e1: *ExpDesc, e2: *ExpDesc, op: OpCode, line: u32, event: value.TMS) CompileError!bool {
        if (!isKint(e2)) return false;
        const k2 = e2.u.ival;
        if (!(fitsC(k2) and fitsC(-k2))) return false;
        try self.finishBinExpVal(fs, e1, e2, op, int2sC(-k2), false, line, .MMBINI, event);
        // The metamethod argument is the original constant
        opcode.setB(&fs.f.code[fs.pc() - 1], @intCast(int2sC(k2)));
        return true;
    }

    fn swapExps(e1: *ExpDesc, e2: *ExpDesc) void {
        const tmp = e1.*;
        e1.* = e2.*;
        e2.* = tmp;
    }

    fn codeArith(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc, flip: bool, line: u32) CompileError!void {
        if (e2.isNumeral() and try self.exp2K(fs, e2)) {
            try self.codeBinK(fs, opr, e1, e2, flip, line);
        } else {
            if (flip) swapExps(e1, e2);
            try self.codeBinExpVal(fs, opr, e1, e2, line);
        }
    }

    fn codeCommutative(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc, line: u32) CompileError!void {
        var flip = false;
        if (e1.isNumeral()) {
            swapExps(e1, e2);
            flip = true;
        }
        if (opr == .add and isSCint(e2)) {
            try self.codeBinI(fs, .ADDI, e1, e2, flip, line, .__add);
        } else {
            try self.codeArith(fs, opr, e1, e2, flip, line);
        }
    }

    fn codeBitwise(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc, line: u32) CompileError!void {
        var flip = false;
        if (e1.k == .VKINT) {
            swapExps(e1, e2);
            flip = true;
        }
        if (e2.k == .VKINT and try self.exp2K(fs, e2)) {
            try self.codeBinK(fs, opr, e1, e2, flip, line);
        } else {
            if (flip) swapExps(e1, e2); // back to the original order (codebinNoK)
            try self.codeBinExpVal(fs, opr, e1, e2, line);
        }
    }

    fn codeOrder(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc) CompileError!void {
        var r1: u32 = undefined;
        var r2: u32 = undefined;
        var im: u32 = 0;
        var isfloat = false;
        var op: OpCode = undefined;
        if (isSCnumber(e2, &im, &isfloat)) {
            r1 = try self.exp2AnyReg(fs, e1);
            r2 = im;
            op = if (opr == .less) .LTI else .LEI;
        } else if (isSCnumber(e1, &im, &isfloat)) {
            r1 = try self.exp2AnyReg(fs, e2);
            r2 = im;
            op = if (opr == .less) .GTI else .GEI;
        } else {
            r1 = try self.exp2AnyReg(fs, e1);
            r2 = try self.exp2AnyReg(fs, e2);
            op = if (opr == .less) .LT else .LE;
        }
        self.freeExps(fs, e1, e2);
        e1.u = .{ .info = try self.condJump(fs, op, r1, r2, @intFromBool(isfloat), true) };
        e1.k = .VJMP;
    }

    fn codeEq(self: *CodeGen, fs: *FuncState, opr: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc) CompileError!void {
        if (e1.k != .VNONRELOC) {
            std.debug.assert(e1.k == .VK or e1.k == .VKINT or e1.k == .VKFLT or e1.k == .VKSTR or e1.k == .VNIL or e1.k == .VTRUE or e1.k == .VFALSE);
            swapExps(e1, e2);
        }
        const r1 = try self.exp2AnyReg(fs, e1);
        var im: u32 = 0;
        var isfloat = false;
        var r2: u32 = undefined;
        var op: OpCode = undefined;
        if (isSCnumber(e2, &im, &isfloat)) {
            op = .EQI;
            r2 = im;
        } else if (try self.exp2RK(fs, e2)) {
            op = .EQK;
            r2 = @intCast(e2.u.info);
        } else {
            op = .EQ;
            r2 = try self.exp2AnyReg(fs, e2);
        }
        self.freeExps(fs, e1, e2);
        e1.u = .{ .info = try self.condJump(fs, op, r1, r2, @intFromBool(isfloat), opr == .eq_eq) };
        e1.k = .VJMP;
    }

    fn prefixOp(self: *CodeGen, fs: *FuncState, op: ast.UnaryOp, e: *ExpDesc, line: u32) CompileError!void {
        try self.dischargeVars(fs, e);
        switch (op) {
            .neg, .bnot => {
                if (constFoldingUnary(op, e)) return;
                try self.codeUnExpVal(fs, if (op == .neg) .UNM else .BNOT, e, line);
            },
            .len => try self.codeUnExpVal(fs, .LEN, e, line),
            .not => try self.codeNot(fs, e),
        }
    }

    /// Prepare the left operand before compiling the right one
    fn infixOp(self: *CodeGen, fs: *FuncState, op: ast.BinaryOp, v: *ExpDesc) CompileError!void {
        try self.dischargeVars(fs, v);
        switch (op) {
            .@"and" => try self.goIfTrue(fs, v),
            .@"or" => try self.goIfFalse(fs, v),
            .concat => try self.exp2NextReg(fs, v),
            .add, .sub, .mul, .div, .floor_div, .mod, .pow, .band, .bor, .bxor, .shl, .shr => {
                if (!v.isNumeral()) _ = try self.exp2AnyReg(fs, v);
            },
            .eq_eq, .not_eq => {
                if (!v.isNumeral()) _ = try self.exp2RK(fs, v);
            },
            .less, .less_eq, .greater, .greater_eq => {
                var dummy: u32 = 0;
                var dummy2 = false;
                if (!isSCnumber(v, &dummy, &dummy2)) _ = try self.exp2AnyReg(fs, v);
            },
        }
    }

    fn codeConcat(self: *CodeGen, fs: *FuncState, e1: *ExpDesc, e2: *ExpDesc, line: u32) CompileError!void {
        if (previousInstruction(fs)) |ie2| {
            if (opcode.getOpcode(ie2.*) == .CONCAT) {
                const n: u32 = opcode.getB(ie2.*);
                std.debug.assert(e1.u.info + 1 == opcode.getA(ie2.*));
                self.freeExp(fs, e2);
                opcode.setA(ie2, @intCast(e1.u.info));
                opcode.setB(ie2, @intCast(n + 1));
                return;
            }
        }
        _ = try self.codeABC(fs, .CONCAT, @intCast(e1.u.info), 2, 0);
        self.freeExp(fs, e2);
        try self.fixLine(fs, line);
    }

    fn foldable(op: ast.BinaryOp) bool {
        return switch (op) {
            .add, .sub, .mul, .div, .floor_div, .mod, .pow, .band, .bor, .bxor, .shl, .shr => true,
            else => false,
        };
    }

    fn posfixOp(self: *CodeGen, fs: *FuncState, op: ast.BinaryOp, e1: *ExpDesc, e2: *ExpDesc, line: u32) CompileError!void {
        try self.dischargeVars(fs, e2);
        if (foldable(op) and constFolding(op, e1, e2)) return;
        switch (op) {
            .@"and" => {
                std.debug.assert(e1.t == NO_JUMP);
                try self.concatJumps(fs, &e2.f, e1.f);
                e1.* = e2.*;
            },
            .@"or" => {
                std.debug.assert(e1.f == NO_JUMP);
                try self.concatJumps(fs, &e2.t, e1.t);
                e1.* = e2.*;
            },
            .concat => {
                try self.exp2NextReg(fs, e2);
                try self.codeConcat(fs, e1, e2, line);
            },
            .add, .mul => try self.codeCommutative(fs, op, e1, e2, line),
            .sub => {
                if (try self.finishBinExpNeg(fs, e1, e2, .ADDI, line, .__sub)) return;
                try self.codeArith(fs, op, e1, e2, false, line);
            },
            .div, .floor_div, .mod, .pow => try self.codeArith(fs, op, e1, e2, false, line),
            .band, .bor, .bxor => try self.codeBitwise(fs, op, e1, e2, line),
            .shl => {
                if (isSCint(e1)) {
                    swapExps(e1, e2);
                    try self.codeBinI(fs, .SHLI, e1, e2, true, line, .__shl);
                } else if (try self.finishBinExpNeg(fs, e1, e2, .SHRI, line, .__shl)) {
                    // done
                } else {
                    try self.codeBinExpVal(fs, op, e1, e2, line);
                }
            },
            .shr => {
                if (isSCint(e2)) {
                    try self.codeBinI(fs, .SHRI, e1, e2, false, line, .__shr);
                } else {
                    try self.codeBinExpVal(fs, op, e1, e2, line);
                }
            },
            .eq_eq, .not_eq => try self.codeEq(fs, op, e1, e2),
            .greater, .greater_eq => {
                // a > b  <=>  b < a
                swapExps(e1, e2);
                try self.codeOrder(fs, if (op == .greater) .less else .less_eq, e1, e2);
            },
            .less, .less_eq => try self.codeOrder(fs, op, e1, e2),
        }
    }

    // Table constructors

    fn setTableSize(self: *CodeGen, fs: *FuncState, pc: u32, ra: u32, asize: u32, hsize: u32) void {
        _ = self;
        const rb: u32 = if (hsize != 0) ceillog2(hsize) + 1 else 0;
        const extra = asize / (opcode.MAXARG_C + 1);
        const rc = asize % (opcode.MAXARG_C + 1);
        const k = extra > 0;
        fs.f.code[pc] = opcode.createABCk(.NEWTABLE, @intCast(ra), @intCast(rb), @intCast(rc), k);
        fs.f.code[pc + 1] = opcode.createAx(.EXTRAARG, @intCast(extra));
    }

    fn setList(self: *CodeGen, fs: *FuncState, base: u32, nelems: u32, tostore_in: i32) CompileError!void {
        const tostore: u32 = if (tostore_in == MULTRET) 0 else @intCast(tostore_in);
        if (nelems <= opcode.MAXARG_C) {
            _ = try self.codeABC(fs, .SETLIST, base, tostore, nelems);
        } else {
            const extra = nelems / (opcode.MAXARG_C + 1);
            const rest = nelems % (opcode.MAXARG_C + 1);
            _ = try self.codeABCk(fs, .SETLIST, base, tostore, rest, true);
            _ = try self.codeExtraArg(fs, extra);
        }
        fs.freereg = @intCast(base + 1);
    }

    // ------------------------------------------------------------------
    // Variables, blocks, gotos (lparser.c)
    // ------------------------------------------------------------------

    fn getLocalVarDesc(self: *CodeGen, fs: *FuncState, vidx: u32) *VarDesc {
        return &self.dyd.actvar.items[fs.firstlocal + vidx];
    }

    /// Register level of the `nvar`-th active variable
    fn regLevel(self: *CodeGen, fs: *FuncState, nvar_in: u32) u32 {
        var nvar = nvar_in;
        while (nvar > 0) {
            nvar -= 1;
            const vd = self.getLocalVarDesc(fs, nvar);
            if (vd.kind != RDKCTC) return @as(u32, vd.ridx) + 1;
        }
        return 0;
    }

    fn nvarstack(self: *CodeGen, fs: *FuncState) u32 {
        return self.regLevel(fs, fs.nactvar);
    }

    fn newLocalVar(self: *CodeGen, fs: *FuncState, name: InternedString) CompileError!u32 {
        const n = self.dyd.nactvar - fs.firstlocal;
        if (n + 1 > MAXVARS) {
            var wbuf: [64]u8 = undefined;
            return self.failFmt(error.TooManyLocals, "too many local variables (limit is {d}) in {s}", .{ MAXVARS, whereFunc(fs, &wbuf) });
        }
        if (self.dyd.nactvar == self.dyd.actvar.items.len) {
            try self.dyd.actvar.append(self.allocator, .{ .name = name });
        } else {
            self.dyd.actvar.items[self.dyd.nactvar] = .{ .name = name };
        }
        self.dyd.nactvar += 1;
        return @intCast(n);
    }

    fn registerLocalVar(self: *CodeGen, fs: *FuncState, name: InternedString) CompileError!i32 {
        const s = self.internString(name) catch return error.OutOfMemory;
        fs.f.addLocVar(self.allocator, s, fs.pc(), 0) catch return error.OutOfMemory;
        self.L.l_G.gc.barrierObject(&fs.f.header, &s.header);
        return @intCast(fs.f.sizelocvars - 1);
    }

    fn adjustLocalVars(self: *CodeGen, fs: *FuncState, nvars: u32) CompileError!void {
        var reglevel = self.nvarstack(fs);
        var i: u32 = 0;
        while (i < nvars) : (i += 1) {
            const vidx = fs.nactvar;
            fs.nactvar += 1;
            const vd = self.getLocalVarDesc(fs, vidx);
            vd.ridx = @intCast(reglevel);
            reglevel += 1;
            vd.pidx = try self.registerLocalVar(fs, vd.name);
        }
    }

    fn removeVars(self: *CodeGen, fs: *FuncState, tolevel: u32) void {
        const removed = fs.nactvar - tolevel;
        while (fs.nactvar > tolevel) {
            fs.nactvar -= 1;
            const vd = self.getLocalVarDesc(fs, fs.nactvar);
            if (vd.pidx >= 0) fs.f.locvars[@intCast(vd.pidx)].end_pc = fs.pc();
        }
        self.dyd.nactvar -= removed;
    }

    fn searchUpvalue(fs: *FuncState, name: InternedString) ?u32 {
        for (fs.upnames.items, 0..) |n, i| {
            if (n == name) return @intCast(i);
        }
        return null;
    }

    fn newUpvalue(self: *CodeGen, fs: *FuncState, name: InternedString, v: *const ExpDesc) CompileError!u32 {
        if (fs.upnames.items.len >= MAXUPVAL) {
            var wbuf: [64]u8 = undefined;
            return self.failFmt(error.TooManyUpvalues, "too many upvalues (limit is {d}) in {s}", .{ MAXUPVAL, whereFunc(fs, &wbuf) });
        }
        var desc: proto_module.Upvaldesc = undefined;
        const prev = fs.prev.?;
        if (v.k == .VLOCAL) {
            desc.instack = true;
            desc.idx = v.u.var_.ridx;
            desc.kind = self.getLocalVarDesc(prev, v.u.var_.vidx).kind;
        } else {
            desc.instack = false;
            desc.idx = @intCast(v.u.info);
            desc.kind = prev.f.upvalues[@intCast(v.u.info)].kind;
        }
        desc.name = self.internString(name) catch return error.OutOfMemory;
        const idx = fs.f.addUpvalue(self.allocator, desc) catch return error.OutOfMemory;
        if (desc.name) |n| self.L.l_G.gc.barrierObject(&fs.f.header, &n.header);
        try fs.upnames.append(self.allocator, name);
        return idx;
    }

    fn searchVar(self: *CodeGen, fs: *FuncState, name: InternedString, v: *ExpDesc) bool {
        var i: u32 = fs.nactvar;
        while (i > 0) {
            i -= 1;
            const vd = self.getLocalVarDesc(fs, i);
            if (vd.name == name) {
                if (vd.kind == RDKCTC) { // compile-time constant: no register
                    v.* = ExpDesc.init(.VCONST, @intCast(fs.firstlocal + i));
                } else {
                    v.* = .{ .k = .VLOCAL, .u = .{ .var_ = .{ .ridx = vd.ridx, .vidx = @intCast(i) } } };
                }
                return true;
            }
        }
        return false;
    }

    /// Mark the block where variable `level` lives as having an upvalue
    fn markUpval(fs: *FuncState, level: u32) void {
        var bl = fs.bl.?;
        while (bl.nactvar > level) bl = bl.previous.?;
        bl.upval = true;
        fs.needclose = true;
    }

    fn singleVarAux(self: *CodeGen, fs_opt: ?*FuncState, name: InternedString, v: *ExpDesc, base: bool) CompileError!void {
        const fs = fs_opt orelse {
            v.* = ExpDesc.init(.VVOID, 0); // global name
            return;
        };
        if (self.searchVar(fs, name, v)) {
            if (v.k == .VLOCAL and !base) markUpval(fs, v.u.var_.vidx); // local captured as upvalue
            return;
        }
        var idx = searchUpvalue(fs, name);
        if (idx == null) {
            try self.singleVarAux(fs.prev, name, v, false);
            if (v.k == .VLOCAL or v.k == .VUPVAL) {
                idx = try self.newUpvalue(fs, name, v);
            } else {
                return; // global (or void)
            }
        }
        v.* = ExpDesc.init(.VUPVAL, @intCast(idx.?));
    }

    fn singleVar(self: *CodeGen, fs: *FuncState, name: InternedString, v: *ExpDesc) CompileError!void {
        try self.singleVarAux(fs, name, v, true);
        if (v.k == .VVOID) {
            // Global: _ENV.name
            try self.singleVarAux(fs, self.env_name, v, true);
            std.debug.assert(v.k != .VVOID);
            // `_ENV` may itself be a compile-time constant (`local _ENV
            // <const> = nil`): put the value in a register first
            // (luaK_exp2anyregup)
            if (v.k == .VCONST) _ = try self.exp2AnyReg(fs, v);
            var key = ExpDesc{ .k = .VKSTR, .u = .{ .strval = name } };
            try self.indexed(fs, v, &key);
        }
    }

    fn adjustAssign(self: *CodeGen, fs: *FuncState, nvars: u32, nexps: u32, e: *ExpDesc) CompileError!void {
        const needed: i32 = @as(i32, @intCast(nvars)) - @as(i32, @intCast(nexps));
        if (e.hasMultRet()) {
            var extra = needed + 1;
            if (extra < 0) extra = 0;
            try self.setReturns(fs, e, extra);
        } else {
            if (e.k != .VVOID) try self.exp2NextReg(fs, e);
            if (needed > 0) try self.codeNil(fs, fs.freereg, @intCast(needed));
        }
        if (needed > 0) {
            try self.reserveRegs(fs, @intCast(needed));
        } else {
            fs.freereg = @intCast(@as(i32, fs.freereg) + needed);
        }
    }

    fn enterBlock(self: *CodeGen, fs: *FuncState, bl: *BlockCnt, isloop: bool) void {
        bl.* = .{
            .isloop = isloop,
            .nactvar = fs.nactvar,
            .firstlabel = @intCast(self.dyd.label.items.len),
            .firstgoto = @intCast(self.dyd.gt.items.len),
            .upval = false,
            .insidetbc = if (fs.bl) |p| p.insidetbc else false,
            .previous = fs.bl,
        };
        fs.bl = bl;
        std.debug.assert(fs.freereg == self.nvarstack(fs));
    }

    fn leaveBlock(self: *CodeGen, fs: *FuncState) CompileError!void {
        const bl = fs.bl.?;
        var hasclose = false;
        const stklevel = self.regLevel(fs, bl.nactvar);
        self.removeVars(fs, bl.nactvar);
        if (bl.isloop) hasclose = try self.createLabel(fs, BREAK_LABEL, 0, false);
        if (!hasclose and bl.previous != null and bl.upval) {
            _ = try self.codeABC(fs, .CLOSE, stklevel, 0, 0);
        }
        fs.freereg = @intCast(stklevel);
        self.dyd.label.items.len = bl.firstlabel;
        fs.bl = bl.previous;
        if (bl.previous != null) {
            self.moveGotosOut(fs, bl);
        } else if (bl.firstgoto < self.dyd.gt.items.len) {
            return self.undefGoto(fs, &self.dyd.gt.items[bl.firstgoto]);
        }
    }

    /// A goto (or break) with no label when its function ends. Lua reports
    /// it at the line the lexer had reached, which is the one after `end`.
    fn undefGoto(self: *CodeGen, fs: *FuncState, gt: *const LabelDesc) CompileError {
        self.line = fs.end_line;
        if (gt.name == BREAK_LABEL) {
            return self.failFmt(error.BreakOutsideLoop, "break outside loop at line {d}", .{gt.line});
        }
        return self.failFmt(error.UndefinedGoto, "no visible label '{s}' for <goto> at line {d}", .{ self.str(gt.name), gt.line });
    }

    fn newLabelEntry(self: *CodeGen, fs: *FuncState, list: *std.ArrayList(LabelDesc), name: InternedString, line: u32, pc: i32) CompileError!u32 {
        try list.append(self.allocator, .{ .name = name, .pc = pc, .line = line, .nactvar = fs.nactvar, .close = false });
        return @intCast(list.items.len - 1);
    }

    fn newGotoEntry(self: *CodeGen, fs: *FuncState, name: InternedString, line: u32, pc: i32) CompileError!u32 {
        return self.newLabelEntry(fs, &self.dyd.gt, name, line, pc);
    }

    /// Solve pending gotos matching label `lb` (in the current block)
    fn solveGotos(self: *CodeGen, fs: *FuncState, lb: *const LabelDesc) CompileError!bool {
        var i: usize = fs.bl.?.firstgoto;
        var needsclose = false;
        while (i < self.dyd.gt.items.len) {
            if (self.dyd.gt.items[i].name == lb.name) {
                needsclose = needsclose or self.dyd.gt.items[i].close;
                try self.solveGoto(fs, i, lb); // removes entry i
            } else {
                i += 1;
            }
        }
        return needsclose;
    }

    fn solveGoto(self: *CodeGen, fs: *FuncState, g: usize, label: *const LabelDesc) CompileError!void {
        const gt = self.dyd.gt.items[g];
        if (gt.nactvar < label.nactvar) {
            // The label is where the jump would land inside the local's scope
            self.line = label.line;
            const varname = self.str(self.getLocalVarDesc(fs, gt.nactvar).name);
            return self.failFmt(error.JumpIntoScope, "<goto {s}> at line {d} jumps into the scope of local '{s}'", .{ self.str(gt.name), gt.line, varname });
        }
        try self.patchList(fs, gt.pc, label.pc);
        _ = self.dyd.gt.orderedRemove(g);
    }

    fn findLabel(self: *CodeGen, fs: *FuncState, name: InternedString) ?*LabelDesc {
        var i: usize = fs.firstlabel;
        while (i < self.dyd.label.items.len) : (i += 1) {
            if (self.dyd.label.items[i].name == name) return &self.dyd.label.items[i];
        }
        return null;
    }

    /// Create a label at the current position; returns whether a CLOSE was emitted
    fn createLabel(self: *CodeGen, fs: *FuncState, name: InternedString, line: u32, last: bool) CompileError!bool {
        const l = try self.newLabelEntry(fs, &self.dyd.label, name, line, @intCast(getLabel(fs)));
        if (last) {
            // Label at the end of a block: gotos may jump over locals that are going out of scope
            self.dyd.label.items[l].nactvar = fs.bl.?.nactvar;
        }
        const lb = self.dyd.label.items[l];
        if (try self.solveGotos(fs, &lb)) {
            _ = try self.codeABC(fs, .CLOSE, self.nvarstack(fs), 0, 0);
            return true;
        }
        return false;
    }

    /// Pending gotos of a closing block move to the enclosing block
    fn moveGotosOut(self: *CodeGen, fs: *FuncState, bl: *const BlockCnt) void {
        var i: usize = bl.firstgoto;
        while (i < self.dyd.gt.items.len) : (i += 1) {
            const gt = &self.dyd.gt.items[i];
            if (self.regLevel(fs, gt.nactvar) > self.regLevel(fs, bl.nactvar)) {
                gt.close = gt.close or bl.upval; // jump may need a CLOSE
            }
            gt.nactvar = bl.nactvar;
        }
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    fn block(self: *CodeGen, fs: *FuncState, blk: NodeIndex) CompileError!void {
        var bl: BlockCnt = .{};
        self.enterBlock(fs, &bl, false);
        try self.statList(fs, blk);
        try self.leaveBlock(fs);
    }

    fn statList(self: *CodeGen, fs: *FuncState, blk: NodeIndex) CompileError!void {
        return self.statListIn(fs, blk, false);
    }

    /// `until_follows` is set for the body of a repeat-until: its locals are
    /// still in scope for the condition, so no label in it counts as "last"
    /// (block_follow with withuntil = 0 in labelstat)
    fn statListIn(self: *CodeGen, fs: *FuncState, blk: NodeIndex, until_follows: bool) CompileError!void {
        const b = self.node(blk).data.block;
        for (b.statements, 0..) |st, i| {
            // A label is "last" when only other labels follow it in the block
            // (labelstat skips them before testing block_follow), so a goto
            // may jump over locals to any label in a trailing run of them
            const is_last = !until_follows and b.return_stmt == null and self.onlyLabelsFrom(b.statements[i + 1 ..]);
            try self.statement(fs, st, is_last);
        }
        if (b.return_stmt) |r| try self.retStat(fs, r);
    }

    fn onlyLabelsFrom(self: *CodeGen, rest: []const NodeIndex) bool {
        for (rest) |st| {
            if (self.node(st).data != .label_stmt) return false;
        }
        return true;
    }

    fn statement(self: *CodeGen, fs: *FuncState, idx: NodeIndex, is_last: bool) CompileError!void {
        const n = self.node(idx);
        self.line = n.line;
        switch (n.data) {
            .block => try self.block(fs, idx),
            .do_block => |b| try self.block(fs, b),
            .if_stmt => try self.ifStat(fs, idx),
            .while_stmt => |w| try self.whileStat(fs, w, n.last_line),
            .repeat_stmt => |r| try self.repeatStat(fs, r),
            .for_numeric => |f| try self.forNum(fs, f, n.line, n.last_line),
            .for_generic => |f| try self.forList(fs, f, n.last_line),
            .function_def => |f| try self.funcStat(fs, f, n.line),
            .local_function => |f| try self.localFunc(fs, f, n.line),
            .local_assignment => |l| try self.localStat(fs, l, n.last_line),
            .return_stmt => try self.retStat(fs, idx),
            .break_stmt => _ = try self.newGotoEntry(fs, BREAK_LABEL, n.line, try self.jump(fs)),
            .goto_stmt => |g| try self.gotoStat(fs, g.label, n.line),
            .label_stmt => |l| try self.labelStat(fs, l.name, n.line, is_last),
            .expression_stmt => |e| try self.exprStat(fs, e),
            .assignment => |a| try self.assignStat(fs, a),
            else => return self.fail(error.SyntaxError, "unexpected expression as statement"),
        }
        std.debug.assert(fs.f.maxstacksize >= fs.freereg and fs.freereg >= self.nvarstack(fs));
        fs.freereg = @intCast(self.nvarstack(fs)); // free registers used by the statement
    }

    fn cond(self: *CodeGen, fs: *FuncState, idx: NodeIndex) CompileError!i32 {
        var v = ExpDesc{};
        try self.expr(fs, idx, &v);
        if (v.k == .VNIL) v.k = .VFALSE; // `falses` are all equal here
        try self.goIfTrue(fs, &v);
        return v.f;
    }

    fn testThenBlock(self: *CodeGen, fs: *FuncState, escapelist: *i32, condition: NodeIndex, then_line: u32, blk: NodeIndex, has_more: bool) CompileError!void {
        var v = ExpDesc{};
        try self.expr(fs, condition, &v);
        self.line = then_line; // the test follows the `then`
        try self.goIfTrue(fs, &v); // skip over block if condition is false
        const jf = v.f;
        var bl: BlockCnt = .{};
        self.enterBlock(fs, &bl, false);
        try self.statList(fs, blk);
        try self.leaveBlock(fs);
        if (has_more) try self.concatJumps(fs, escapelist, try self.jump(fs)); // jump over the other parts
        try self.patchToHere(fs, jf);
    }

    fn ifStat(self: *CodeGen, fs: *FuncState, idx: NodeIndex) CompileError!void {
        const s = self.node(idx).data.if_stmt;
        var escapelist: i32 = NO_JUMP;
        const nparts = s.elseif_parts.len;
        try self.testThenBlock(fs, &escapelist, s.condition, s.then_line, s.then_block, nparts > 0 or s.else_block != null);
        for (s.elseif_parts, 0..) |part, i| {
            const p = self.node(part).data.if_stmt;
            self.line = self.node(part).line;
            try self.testThenBlock(fs, &escapelist, p.condition, p.then_line, p.then_block, i + 1 < nparts or s.else_block != null);
        }
        if (s.else_block) |eb| try self.block(fs, eb);
        try self.patchToHere(fs, escapelist);
    }

    fn whileStat(self: *CodeGen, fs: *FuncState, w: ast.WhileNode, end_line: u32) CompileError!void {
        const whileinit: i32 = @intCast(getLabel(fs));
        const condexit = try self.cond(fs, w.condition);
        var bl: BlockCnt = .{};
        self.enterBlock(fs, &bl, true);
        try self.statList(fs, w.block);
        self.line = self.node(w.block).last_line; // the jump back is coded before `end` is read
        try self.patchList(fs, try self.jump(fs), whileinit);
        self.line = end_line; // the block is left once `end` was read (a CLOSE goes there)
        try self.leaveBlock(fs);
        try self.patchToHere(fs, condexit); // false conditions finish the loop
    }

    fn repeatStat(self: *CodeGen, fs: *FuncState, r: ast.RepeatNode) CompileError!void {
        const repeat_init: i32 = @intCast(getLabel(fs));
        var bl1: BlockCnt = .{};
        var bl2: BlockCnt = .{};
        self.enterBlock(fs, &bl1, true); // loop block
        self.enterBlock(fs, &bl2, false); // scope block
        try self.statListIn(fs, r.block, true);
        var condexit = try self.cond(fs, r.condition); // the condition sees the block's locals
        try self.leaveBlock(fs); // finish scope
        if (bl2.upval) {
            // Upvalues: the loop repetition must close them
            const exit = try self.jump(fs); // normal exit must jump over the fix
            try self.patchToHere(fs, condexit);
            _ = try self.codeABC(fs, .CLOSE, self.regLevel(fs, bl2.nactvar), 0, 0);
            condexit = try self.jump(fs);
            try self.patchToHere(fs, exit);
        }
        try self.patchList(fs, condexit, repeat_init); // close the loop
        try self.leaveBlock(fs); // finish loop
    }

    fn fixForJump(self: *CodeGen, fs: *FuncState, pc: u32, dest: u32, back: bool) CompileError!void {
        const jmp = &fs.f.code[pc];
        var offset: i64 = @as(i64, dest) - (@as(i64, pc) + 1);
        if (back) offset = -offset;
        if (offset > opcode.MAXARG_Bx) return self.fail(error.ControlStructureTooLong, "control structure too long");
        opcode.setBx(jmp, @intCast(offset));
    }

    fn forBody(self: *CodeGen, fs: *FuncState, base: u32, line: u32, do_line: u32, nvars: u32, isgen: bool, blk: NodeIndex) CompileError!void {
        self.line = do_line; // the prep instruction follows the `do`
        const prep = try self.codeABx(fs, if (isgen) .TFORPREP else .FORPREP, base, 0);
        var bl: BlockCnt = .{};
        self.enterBlock(fs, &bl, false); // scope for declared variables
        try self.adjustLocalVars(fs, nvars);
        try self.reserveRegs(fs, nvars);
        try self.statList(fs, blk);
        try self.leaveBlock(fs);
        try self.fixForJump(fs, prep, getLabel(fs), false);
        if (isgen) {
            _ = try self.codeABC(fs, .TFORCALL, base, 0, nvars);
            try self.fixLine(fs, line);
        }
        const endfor = try self.codeABx(fs, if (isgen) .TFORLOOP else .FORLOOP, base, 0);
        try self.fixForJump(fs, endfor, prep + 1, true);
        try self.fixLine(fs, line);
    }

    fn exp1(self: *CodeGen, fs: *FuncState, idx: NodeIndex) CompileError!void {
        var e = ExpDesc{};
        try self.expr(fs, idx, &e);
        try self.exp2NextReg(fs, &e);
        std.debug.assert(e.k == .VNONRELOC);
    }

    fn forNum(self: *CodeGen, fs: *FuncState, f: ast.ForNumericNode, line: u32, end_line: u32) CompileError!void {
        var bl: BlockCnt = .{};
        self.enterBlock(fs, &bl, true); // scope for loop and control variables
        const base = fs.freereg;
        _ = try self.newLocalVar(fs, self.forstate_name);
        _ = try self.newLocalVar(fs, self.forstate_name);
        _ = try self.newLocalVar(fs, self.forstate_name);
        _ = try self.newLocalVar(fs, f.var_name);
        try self.exp1(fs, f.start);
        try self.exp1(fs, f.limit);
        if (f.step) |st| {
            try self.exp1(fs, st);
        } else {
            try self.codeInt(fs, fs.freereg, 1);
            try self.reserveRegs(fs, 1);
        }
        try self.adjustLocalVars(fs, 3); // control variables
        try self.forBody(fs, base, line, f.do_line, 1, false, f.block);
        self.line = end_line; // the loop scope is left once `end` was read
        try self.leaveBlock(fs);
    }

    fn forList(self: *CodeGen, fs: *FuncState, f: ast.ForGenericNode, end_line: u32) CompileError!void {
        var bl: BlockCnt = .{};
        self.enterBlock(fs, &bl, true);
        const base = fs.freereg;
        // generator, state, control, closing (to-be-closed) + user variables
        _ = try self.newLocalVar(fs, self.forstate_name);
        _ = try self.newLocalVar(fs, self.forstate_name);
        _ = try self.newLocalVar(fs, self.forstate_name);
        _ = try self.newLocalVar(fs, self.forstate_name);
        for (f.names) |nm| {
            _ = try self.newLocalVar(fs, self.node(nm).data.identifier);
        }
        var e = ExpDesc{};
        const nexps = try self.expList(fs, f.exprs, &e);
        try self.adjustAssign(fs, 4, nexps, &e);
        try self.adjustLocalVars(fs, 4); // control variables
        // The closing value is to-be-closed
        fs.bl.?.upval = true;
        fs.bl.?.insidetbc = true;
        fs.needclose = true;
        try self.checkStack(fs, 3); // extra space to call the generator
        // The loop instructions are attributed to the line after `in`
        try self.forBody(fs, base, f.in_line, f.do_line, @intCast(f.names.len), true, f.block);
        self.line = end_line; // the loop scope is left once `end` was read (its CLOSE goes there)
        try self.leaveBlock(fs);
    }

    fn localFunc(self: *CodeGen, fs: *FuncState, f: ast.FunctionDefNode, line: u32) CompileError!void {
        const name = self.node(f.name.?).data.identifier;
        const fvar = fs.nactvar;
        _ = try self.newLocalVar(fs, name);
        try self.adjustLocalVars(fs, 1); // the local is visible inside the body (recursion)
        var b = ExpDesc{};
        try self.body(fs, f, false, line, &b);
        // Debug info: the function starts being active after its code is built
        const vd = self.getLocalVarDesc(fs, fvar);
        if (vd.pidx >= 0) fs.f.locvars[@intCast(vd.pidx)].start_pc = fs.pc();
    }

    fn localStat(self: *CodeGen, fs: *FuncState, l: ast.LocalAssignmentNode, last_line: u32) CompileError!void {
        var toclose: ?u32 = null; // level of the to-be-closed variable, if any
        for (l.names, 0..) |nm, i| {
            const vidx = try self.newLocalVar(fs, self.node(nm).data.identifier);
            const attrib: ast.LocalAttrib = if (i < l.attribs.len) l.attribs[i] else .none;
            const kind: u8 = switch (attrib) {
                .none => VDKREG,
                .constant => RDKCONST,
                .close => RDKTOCLOSE,
            };
            self.getLocalVarDesc(fs, vidx).kind = kind;
            // The parser rejects a second `<close>` in the same list
            if (kind == RDKTOCLOSE) toclose = fs.nactvar + @as(u32, @intCast(i));
        }
        var e = ExpDesc{};
        const nexps = try self.expList(fs, l.values, &e);
        // Stores and adjustments are coded once the whole list has been read
        self.line = if (l.values.len > 0) self.node(l.values[l.values.len - 1]).last_line else last_line;
        const nvars: u32 = @intCast(l.names.len);
        const last = self.getLocalVarDesc(fs, fs.nactvar + nvars - 1);
        const ctc: ?ConstVal = if (nvars == nexps and last.kind == RDKCONST) self.exp2Const(&e) else null;
        if (ctc) |kv| {
            // A `<const>` local with a constant value lives in no register:
            // its uses are folded into the code (lparser.c localstat)
            last.kind = RDKCTC;
            last.k = kv;
            try self.adjustLocalVars(fs, nvars - 1); // exclude the last variable
            fs.nactvar += 1; // but count it
        } else {
            try self.adjustAssign(fs, nvars, nexps, &e);
            try self.adjustLocalVars(fs, nvars);
        }
        if (toclose) |level| {
            // Its block closes it on exit, and the function on return
            // (marktobeclosed / checktoclose)
            fs.bl.?.upval = true;
            fs.bl.?.insidetbc = true;
            fs.needclose = true;
            _ = try self.codeABC(fs, .TBC, self.regLevel(fs, level), 0, 0);
        }
    }

    /// Refuse to assign to a `<const>` or `<close>` variable, whether it is
    /// reached as a local or through an upvalue (check_readonly)
    fn checkReadonly(self: *CodeGen, fs: *FuncState, e: *const ExpDesc) CompileError!void {
        const name: ?InternedString = switch (e.k) {
            .VLOCAL => blk: {
                const vd = self.getLocalVarDesc(fs, e.u.var_.vidx);
                break :blk if (vd.kind != VDKREG) vd.name else null;
            },
            .VUPVAL => blk: {
                const idx: usize = @intCast(e.u.info);
                break :blk if (fs.f.upvalues[idx].kind != VDKREG) fs.upnames.items[idx] else null;
            },
            .VCONST => self.dyd.actvar.items[@intCast(e.u.info)].name,
            else => null,
        };
        if (name) |n| {
            return self.failFmt(error.AssignToConst, "attempt to assign to const variable '{s}'", .{self.str(n)});
        }
    }

    fn funcStat(self: *CodeGen, fs: *FuncState, f: ast.FunctionDefNode, line: u32) CompileError!void {
        var v = ExpDesc{};
        try self.funcName(fs, f.name.?, &v);
        var b = ExpDesc{};
        try self.body(fs, f, f.is_method, line, &b);
        try self.checkReadonly(fs, &v);
        try self.storeVar(fs, &v, &b);
        try self.fixLine(fs, line); // definition "happens" in the first line
    }

    /// `a.b.c` name chain of a function statement
    fn funcName(self: *CodeGen, fs: *FuncState, idx: NodeIndex, v: *ExpDesc) CompileError!void {
        const n = self.node(idx);
        switch (n.data) {
            .identifier => |name| try self.singleVar(fs, name, v),
            .field_access => |fa| {
                try self.funcName(fs, fa.object, v);
                try self.exp2AnyRegUp(fs, v);
                var key = ExpDesc{ .k = .VKSTR, .u = .{ .strval = fa.field } };
                try self.indexed(fs, v, &key);
            },
            else => return self.fail(error.SyntaxError, "invalid function name"),
        }
    }

    fn retStat(self: *CodeGen, fs: *FuncState, idx: NodeIndex) CompileError!void {
        const r = self.node(idx).data.return_stmt;
        self.line = self.node(idx).line;
        var e = ExpDesc{};
        var first: u32 = self.nvarstack(fs);
        var nret: i32 = 0;
        if (r.values.len > 0) {
            nret = @intCast(try self.expList(fs, r.values, &e));
            self.line = self.node(r.values[r.values.len - 1]).last_line; // the return follows the list
            if (e.hasMultRet()) {
                try self.setMultRet(fs, &e);
                if (e.k == .VCALL and nret == 1 and !fs.bl.?.insidetbc) {
                    // Tail call
                    opcode.setOpcode(instruction(fs, &e), .TAILCALL);
                    std.debug.assert(opcode.getA(instruction(fs, &e).*) == self.nvarstack(fs));
                }
                nret = MULTRET;
            } else if (nret == 1) {
                first = try self.exp2AnyReg(fs, &e); // can use the original slot
            } else {
                try self.exp2NextReg(fs, &e); // values go to the top of the stack
                std.debug.assert(nret == @as(i32, fs.freereg) - @as(i32, @intCast(first)));
            }
        }
        try self.ret(fs, first, nret);
    }

    fn gotoStat(self: *CodeGen, fs: *FuncState, name: InternedString, line: u32) CompileError!void {
        if (self.findLabel(fs, name)) |lb| {
            // Backward jump: close upvalues of locals leaving scope
            const lblevel = self.regLevel(fs, lb.nactvar);
            if (self.nvarstack(fs) > lblevel) {
                _ = try self.codeABC(fs, .CLOSE, lblevel, 0, 0);
            }
            try self.patchList(fs, try self.jump(fs), lb.pc);
        } else {
            _ = try self.newGotoEntry(fs, name, line, try self.jump(fs)); // forward jump, solved later
        }
    }

    fn labelStat(self: *CodeGen, fs: *FuncState, name: InternedString, line: u32, is_last: bool) CompileError!void {
        if (self.findLabel(fs, name)) |lb| {
            self.line = line;
            return self.failFmt(error.DuplicateLabel, "label '{s}' already defined on line {d}", .{ self.str(name), lb.line });
        }
        _ = try self.createLabel(fs, name, line, is_last);
    }

    fn exprStat(self: *CodeGen, fs: *FuncState, idx: NodeIndex) CompileError!void {
        var v = ExpDesc{};
        try self.expr(fs, idx, &v);
        if (v.k != .VCALL) return self.fail(error.SyntaxError, "syntax error: expression is not a statement");
        opcode.setC(instruction(fs, &v), 1); // call statement uses no results
    }

    fn assignStat(self: *CodeGen, fs: *FuncState, a: ast.AssignmentNode) CompileError!void {
        var targets: std.ArrayList(ExpDesc) = .empty;
        defer targets.deinit(self.allocator);
        for (a.targets) |t| {
            var v = ExpDesc{};
            try self.assignTarget(fs, t, &v);
            try self.checkReadonly(fs, &v);
            for (targets.items) |*prev| try self.checkConflict(fs, prev, &v);
            try targets.append(self.allocator, v);
        }
        const nvars: u32 = @intCast(targets.items.len);
        var e = ExpDesc{};
        const nexps = try self.expList(fs, a.values, &e);
        self.line = self.node(a.values[a.values.len - 1]).last_line; // stores follow the whole list
        var last: usize = nvars;
        if (nexps == nvars) {
            setOneRet(fs, &e); // close last expression
            try self.storeVar(fs, &targets.items[nvars - 1], &e);
            last = nvars - 1;
        } else {
            try self.adjustAssign(fs, nvars, nexps, &e);
        }
        // Remaining targets take the values just below the free register
        var i = last;
        while (i > 0) {
            i -= 1;
            var ev = ExpDesc.init(.VNONRELOC, fs.freereg - 1);
            try self.storeVar(fs, &targets.items[i], &ev);
        }
    }

    fn assignTarget(self: *CodeGen, fs: *FuncState, idx: NodeIndex, v: *ExpDesc) CompileError!void {
        const n = self.node(idx);
        self.line = n.line;
        switch (n.data) {
            .identifier, .field_access, .index_access => try self.expr(fs, idx, v),
            else => return self.fail(error.InvalidAssignmentTarget, "syntax error: cannot assign to this expression"),
        }
        if (v.k == .VCONST) return self.checkReadonly(fs, v); // a compile-time constant: the const message
        if (v.k != .VLOCAL and v.k != .VUPVAL and !v.isIndexed()) {
            return self.fail(error.InvalidAssignmentTarget, "syntax error: cannot assign to this expression");
        }
    }

    /// A previous target indexes a local/upvalue that this statement assigns:
    /// copy the original value to a temporary first (lparser check_conflict)
    fn checkConflict(self: *CodeGen, fs: *FuncState, lh: *ExpDesc, v: *const ExpDesc) CompileError!void {
        const extra = fs.freereg;
        var conflict = false;
        if (lh.isIndexed()) {
            if (lh.k == .VINDEXUP) {
                if (v.k == .VUPVAL and lh.u.ind.t == v.u.info) {
                    conflict = true;
                    lh.k = .VINDEXSTR;
                    lh.u.ind.t = extra;
                }
            } else {
                if (v.k == .VLOCAL and lh.u.ind.t == v.u.var_.ridx) {
                    conflict = true;
                    lh.u.ind.t = extra;
                }
                if (lh.k == .VINDEXED and v.k == .VLOCAL and lh.u.ind.idx == v.u.var_.ridx) {
                    conflict = true;
                    lh.u.ind.idx = extra;
                }
            }
        }
        if (conflict) {
            if (v.k == .VLOCAL) {
                _ = try self.codeABC(fs, .MOVE, extra, v.u.var_.ridx, 0);
            } else {
                _ = try self.codeABC(fs, .GETUPVAL, extra, @intCast(v.u.info), 0);
            }
            try self.reserveRegs(fs, 1);
        }
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    /// Compile a list of expressions; all but the last go to consecutive
    /// registers, the last is left in `v`. Returns the count.
    fn expList(self: *CodeGen, fs: *FuncState, list: ast.NodeList, v: *ExpDesc) CompileError!u32 {
        if (list.len == 0) {
            v.* = ExpDesc{};
            return 0;
        }
        for (list, 0..) |item, i| {
            if (i > 0) try self.exp2NextReg(fs, v);
            try self.expr(fs, item, v);
        }
        return @intCast(list.len);
    }

    pub fn expr(self: *CodeGen, fs: *FuncState, idx: NodeIndex, v: *ExpDesc) CompileError!void {
        const n = self.node(idx);
        const line = n.line;
        self.line = line;
        switch (n.data) {
            .nil_literal => v.* = ExpDesc.init(.VNIL, 0),
            .bool_literal => |b| v.* = ExpDesc.init(if (b) .VTRUE else .VFALSE, 0),
            .integer_literal => |i| v.* = .{ .k = .VKINT, .u = .{ .ival = i } },
            .number_literal => |f| v.* = .{ .k = .VKFLT, .u = .{ .nval = f } },
            .string_literal => |s| v.* = .{ .k = .VKSTR, .u = .{ .strval = s } },
            .varargs => {
                // Lua checks before consuming the token, so its message always ends this way
                if (!fs.f.is_vararg) return self.fail(error.VarargOutsideVararg, "cannot use '...' outside a vararg function near '...'");
                v.* = ExpDesc.init(.VVARARG, @intCast(try self.codeABC(fs, .VARARG, 0, 0, 1)));
            },
            .identifier => |name| try self.singleVar(fs, name, v),
            .paren_expr => |inner| {
                try self.expr(fs, inner, v);
                try self.dischargeVars(fs, v); // (f()) / (...) yield one value
            },
            .unary_op => |u| {
                try self.expr(fs, u.operand, v);
                // The operand is put in a register once it has been read in
                // full; the operation itself is attributed to its operator
                self.line = self.node(u.operand).last_line;
                try self.prefixOp(fs, u.op, v, line);
            },
            .binary_op => |b| {
                try self.expr(fs, b.left, v);
                self.line = line; // the left operand is discharged after the operator is read
                try self.infixOp(fs, b.op, v);
                var v2 = ExpDesc{};
                try self.expr(fs, b.right, &v2);
                self.line = self.node(b.right).last_line; // and the right one once it is complete
                try self.posfixOp(fs, b.op, v, &v2, line);
            },
            .table_constructor => |t| try self.constructor(fs, t, v),
            .field_access => |fa| {
                try self.expr(fs, fa.object, v);
                try self.exp2AnyRegUp(fs, v);
                var key = ExpDesc{ .k = .VKSTR, .u = .{ .strval = fa.field } };
                try self.indexed(fs, v, &key);
            },
            .index_access => |ia| {
                try self.expr(fs, ia.object, v);
                try self.exp2AnyRegUp(fs, v);
                var key = ExpDesc{};
                try self.expr(fs, ia.index, &key);
                try self.exp2Val(fs, &key);
                try self.indexed(fs, v, &key);
            },
            .function_call => |c| {
                try self.expr(fs, c.func, v);
                try self.exp2NextReg(fs, v);
                try self.funcArgs(fs, v, c.args, line);
            },
            .method_call => |m| {
                try self.expr(fs, m.object, v);
                var key = ExpDesc{ .k = .VKSTR, .u = .{ .strval = m.method } };
                try self.codeSelf(fs, v, &key);
                try self.funcArgs(fs, v, m.args, line);
            },
            .function_def, .function_expr => |f| try self.body(fs, f, f.is_method, line, v),
            else => return self.fail(error.SyntaxError, "unexpected statement in expression"),
        }
    }

    fn funcArgs(self: *CodeGen, fs: *FuncState, f: *ExpDesc, args: ast.NodeList, line: u32) CompileError!void {
        std.debug.assert(f.k == .VNONRELOC);
        var a = ExpDesc{};
        _ = try self.expList(fs, args, &a);
        if (a.hasMultRet()) {
            try self.setMultRet(fs, &a);
        } else if (a.k != .VVOID) {
            try self.exp2NextReg(fs, &a); // close last argument
        }
        const base: u32 = @intCast(f.u.info);
        const nparams: i32 = if (a.hasMultRet()) MULTRET else @as(i32, fs.freereg) - @as(i32, @intCast(base + 1));
        f.* = ExpDesc.init(.VCALL, @intCast(try self.codeABC(fs, .CALL, base, @intCast(nparams + 1), 2)));
        try self.fixLine(fs, line);
        fs.freereg = @intCast(base + 1); // the call removes function and arguments and leaves one result
    }

    fn constructor(self: *CodeGen, fs: *FuncState, t: ast.TableConstructorNode, v: *ExpDesc) CompileError!void {
        const pc = try self.codeABC(fs, .NEWTABLE, 0, 0, 0);
        _ = try self.codeExtraArg(fs, 0); // space for the extra arg
        var na: u32 = 0; // array elements
        var nh: u32 = 0; // hash elements
        var tostore: u32 = 0; // pending array elements
        var item = ExpDesc{}; // last list item read
        v.* = ExpDesc.init(.VNONRELOC, fs.freereg);
        try self.reserveRegs(fs, 1);
        const treg: u32 = @intCast(v.u.info);

        for (t.fields) |field| {
            // Close a pending list item
            if (item.k != .VVOID) {
                try self.exp2NextReg(fs, &item);
                item.k = .VVOID;
                if (tostore == opcode.LFIELDS_PER_FLUSH) {
                    try self.setList(fs, treg, na, @intCast(tostore));
                    na += tostore;
                    tostore = 0;
                }
            }
            const fnode = self.node(field);
            if (fnode.data == .expr_list) {
                // Record field: key = value
                const pair = fnode.data.expr_list;
                const reg = fs.freereg;
                var tab = v.*;
                var key = ExpDesc{};
                try self.expr(fs, pair[0], &key);
                if (key.k != .VKSTR) try self.exp2Val(fs, &key);
                try self.indexed(fs, &tab, &key);
                var val = ExpDesc{};
                try self.expr(fs, pair[1], &val);
                try self.storeVar(fs, &tab, &val);
                fs.freereg = reg;
                nh += 1;
            } else {
                try self.expr(fs, field, &item);
                tostore += 1;
            }
        }

        // Last list item
        if (tostore > 0) {
            if (item.hasMultRet()) {
                try self.setMultRet(fs, &item);
                try self.setList(fs, treg, na, MULTRET);
                na += tostore - 1; // the last expression has an unknown number of elements
            } else {
                if (item.k != .VVOID) try self.exp2NextReg(fs, &item);
                try self.setList(fs, treg, na, @intCast(tostore));
                na += tostore;
            }
        }
        self.setTableSize(fs, pc, treg, na, nh);
    }

    // ------------------------------------------------------------------
    // Functions
    // ------------------------------------------------------------------

    fn openFunc(self: *CodeGen, fs: *FuncState, bl: *BlockCnt) void {
        fs.prev = self.fs;
        self.fs = fs;
        fs.firstlocal = self.dyd.nactvar;
        fs.firstlabel = @intCast(self.dyd.label.items.len);
        self.enterBlock(fs, bl, false);
    }

    fn closeFunc(self: *CodeGen, fs: *FuncState) CompileError!void {
        try self.ret(fs, self.nvarstack(fs), 0); // final return
        try self.leaveBlock(fs);
        try self.finish(fs);
        fs.upnames.deinit(self.allocator);
        fs.upnames = .empty;
        self.fs = fs.prev;
    }

    fn setVararg(self: *CodeGen, fs: *FuncState, nparams: u32) CompileError!void {
        fs.f.is_vararg = true;
        _ = try self.codeABC(fs, .VARARGPREP, nparams, 0, 0);
    }

    fn body(self: *CodeGen, parent: *FuncState, f: ast.FunctionDefNode, ismethod: bool, line: u32, e: *ExpDesc) CompileError!void {
        var new_fs = FuncState{ .f = try self.newProto(), .end_line = f.follow_line };
        errdefer new_fs.upnames.deinit(self.allocator); // closeFunc frees it on success
        var bl: BlockCnt = .{};
        new_fs.f.linedefined = line;
        // Line info is stored as deltas from the previous instruction's line,
        // and `getLine` reconstructs them starting at `linedefined`, so the
        // first delta must be measured from there too (open_func)
        new_fs.f.previousline = line;
        // Register the nested prototype in the parent
        _ = parent.f.addProto(self.allocator, new_fs.f) catch return error.OutOfMemory;
        self.L.l_G.gc.barrierObject(&parent.f.header, &new_fs.f.header);
        self.openFunc(&new_fs, &bl);
        const fs = &new_fs;
        if (ismethod) {
            _ = try self.newLocalVar(fs, self.self_name);
            try self.adjustLocalVars(fs, 1);
        }
        for (f.params) |p| {
            _ = try self.newLocalVar(fs, self.node(p).data.identifier);
        }
        try self.adjustLocalVars(fs, @intCast(f.params.len));
        fs.f.numparams = fs.nactvar;
        if (f.is_vararg) try self.setVararg(fs, fs.f.numparams);
        try self.reserveRegs(fs, fs.nactvar);
        try self.statList(fs, f.block);
        fs.f.lastlinedefined = f.end_line; // the line of the `end` (body)
        self.line = f.end_line; // the final return belongs to that line too
        try self.closeFunc(fs);
        // In the parent: the closure instruction, coded once `end` was read
        // (a function statement then moves its store to the `function` line)
        self.line = f.end_line;
        e.* = ExpDesc.init(.VRELOC, @intCast(try self.codeABx(parent, .CLOSURE, 0, parent.f.sizep - 1)));
        try self.exp2NextReg(parent, e);
    }

    /// Final pass over the code (luaK_finish)
    fn finish(self: *CodeGen, fs: *FuncState) CompileError!void {
        const p = fs.f;
        var pc: u32 = 0;
        while (pc < p.sizecode) : (pc += 1) {
            const i = &p.code[pc];
            switch (opcode.getOpcode(i.*)) {
                .RETURN0, .RETURN1 => {
                    if (!(fs.needclose or p.is_vararg)) continue;
                    opcode.setOpcode(i, .RETURN); // use the general form
                    if (fs.needclose) opcode.setk(i, true);
                    if (p.is_vararg) opcode.setC(i, p.numparams + 1);
                },
                .RETURN, .TAILCALL => {
                    if (fs.needclose) opcode.setk(i, true);
                    if (p.is_vararg) opcode.setC(i, p.numparams + 1);
                },
                .JMP => {
                    const target = finalTarget(p.code, pc);
                    try self.fixJump(fs, @intCast(pc), @intCast(target));
                },
                else => {},
            }
        }
    }

    /// Follow chains of jumps to their final destination
    fn finalTarget(code_slice: []const Instruction, i_in: u32) u32 {
        var i = i_in;
        var count: u32 = 0;
        while (count < 100) : (count += 1) {
            const pc = code_slice[i];
            if (opcode.getOpcode(pc) != .JMP) break;
            i = @intCast(@as(i64, i) + opcode.getsJ(pc) + 1);
        }
        return i;
    }

    // ------------------------------------------------------------------
    // Entry point
    // ------------------------------------------------------------------

    /// Compile the whole chunk into the main function's prototype. The main
    /// function is vararg and has `_ENV` as its single upvalue.
    pub fn compileMain(self: *CodeGen) CompileError!*Proto {
        // The main block's node carries the line of the end of the input
        var fs = FuncState{ .f = try self.newProto(), .end_line = self.node(self.tree.root).line };
        errdefer fs.upnames.deinit(self.allocator); // closeFunc frees it on success
        var bl: BlockCnt = .{};
        self.openFunc(&fs, &bl);
        // The main function's VARARGPREP is always attributed to line 1, as
        // the reference's lexer reports that line before any token is read
        self.line = 1;
        try self.setVararg(&fs, 0);
        // The upvalue _ENV (index 0) refers to register 0 of a fictitious enclosing function
        const env_desc = proto_module.Upvaldesc{
            .name = self.internString(self.env_name) catch return error.OutOfMemory,
            .instack = true,
            .idx = 0,
            .kind = VDKREG,
        };
        _ = fs.f.addUpvalue(self.allocator, env_desc) catch return error.OutOfMemory;
        if (env_desc.name) |n| self.L.l_G.gc.barrierObject(&fs.f.header, &n.header);
        try fs.upnames.append(self.allocator, self.env_name);
        try self.statList(&fs, self.tree.root);
        // A main chunk has no `end`: its last line stays 0, as in luac, and
        // its final return is attributed to the last token of the chunk
        fs.f.lastlinedefined = 0;
        self.line = self.node(self.tree.root).last_line;
        try self.closeFunc(&fs);
        return fs.f;
    }
};

/// Compile an AST into the main prototype of the chunk, owned by `L`'s collector
pub fn compile(L: *state.LuaState, tree: *ast.Ast, chunkname: []const u8) CompileError!*Proto {
    var cg = CodeGen.init(L, tree, chunkname) catch return error.OutOfMemory;
    defer cg.deinit();
    return cg.compileMain();
}

/// Compile with diagnostics: on failure returns the message and line. The
/// message is copied, since the compiler that produced it is gone by the time
/// the caller reads it.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    line: u32,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn compileWithDiag(L: *state.LuaState, tree: *ast.Ast, chunkname: []const u8, diag: *?Diagnostic) CompileError!*Proto {
    var cg = CodeGen.init(L, tree, chunkname) catch return error.OutOfMemory;
    defer cg.deinit();
    return cg.compileMain() catch |err| {
        var d = Diagnostic{ .line = cg.err_line };
        const msg = cg.err_msg orelse @errorName(err);
        d.len = @min(msg.len, d.buf.len);
        @memcpy(d.buf[0..d.len], msg[0..d.len]);
        diag.* = d;
        return err;
    };
}

fn ceillog2(x: u32) u32 {
    if (x <= 1) return 0;
    return 32 - @clz(x - 1);
}

// ------------------------------------------------------------------
// Tests: compile small programs and check the emitted opcodes
// ------------------------------------------------------------------

const lex = @import("lex.zig");
const parser = @import("parser.zig");

/// Compile `source` in a fresh state; returns the state (caller closes it) and the proto
fn compileSource(allocator: std.mem.Allocator, source: []const u8) !struct { L: *state.LuaState, p: *Proto } {
    const L = try state.LuaState.init(allocator, null);
    errdefer L.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lexer = try lex.LexState.init(source, "test", arena.allocator());
    defer lexer.deinit();
    var p = try parser.Parser.init(&lexer, arena.allocator());
    defer p.deinit();
    var tree = try p.parse();
    defer tree.deinit();
    if (p.errors.items.len > 0) return error.SyntaxError;
    const proto = try compile(L, &tree, "=test");
    return .{ .L = L, .p = proto };
}

fn opcodes(allocator: std.mem.Allocator, p: *const Proto) ![]OpCode {
    const out = try allocator.alloc(OpCode, p.sizecode);
    for (p.code[0..p.sizecode], 0..) |i, k| out[k] = opcode.getOpcode(i);
    return out;
}

fn expectOps(p: *const Proto, expected: []const OpCode) !void {
    const ops = try opcodes(std.testing.allocator, p);
    defer std.testing.allocator.free(ops);
    try std.testing.expectEqualSlices(OpCode, expected, ops);
}

test "codegen: locals and arithmetic" {
    const r = try compileSource(std.testing.allocator, "local a, b = 1, 2.5\nlocal c = a + b * 2\nreturn c");
    defer r.L.deinit();
    const p = r.p;
    try std.testing.expect(p.is_vararg);
    try std.testing.expectEqual(@as(u8, 1), p.sizeupvalues); // _ENV
    // 2.5 is not integral, so it is a K constant; `b * 2` uses the integer
    // constant 2 (no folding across the float); the two RETURNs are the
    // explicit one and the implicit one closing the chunk, both in the
    // general form because the main function is vararg (C = numparams + 1).
    try expectOps(p, &.{ .VARARGPREP, .LOADI, .LOADK, .MULK, .MMBINK, .ADD, .MMBIN, .RETURN, .RETURN });
    try std.testing.expectEqual(@as(u8, 3), p.maxstacksize); // a, b, c (the temporary reuses c's slot)
    try std.testing.expectEqual(@as(u8, 2), opcode.getB(p.code[7])); // one value
    try std.testing.expectEqual(@as(u8, 1), opcode.getC(p.code[7]));
}

test "codegen: globals, calls and strings" {
    const r = try compileSource(std.testing.allocator, "print(\"hi\", 1)\nx = f(g())");
    defer r.L.deinit();
    try expectOps(r.p, &.{ .VARARGPREP, .GETTABUP, .LOADK, .LOADI, .CALL, .GETTABUP, .GETTABUP, .CALL, .CALL, .SETTABUP, .RETURN });
    const call1 = r.p.code[4];
    try std.testing.expectEqual(@as(u8, 3), opcode.getB(call1)); // 2 args
    try std.testing.expectEqual(@as(u8, 1), opcode.getC(call1)); // statement: no results
    const inner = r.p.code[7];
    try std.testing.expectEqual(@as(u8, 0), opcode.getC(inner)); // g() multiple results
    const outer = r.p.code[8];
    try std.testing.expectEqual(@as(u8, 0), opcode.getB(outer)); // f(g()) passes all of them
}

test "codegen: constant folding and immediates" {
    const r = try compileSource(std.testing.allocator, "local x = 2 * 3 + 1\nlocal y = x - 1\nlocal z = -x\nreturn x < 10, x == y");
    defer r.L.deinit();
    const ops = try opcodes(std.testing.allocator, r.p);
    defer std.testing.allocator.free(ops);
    try std.testing.expectEqual(OpCode.LOADI, ops[1]); // folded to 7
    try std.testing.expectEqual(@as(i19, 7), opcode.getsBx(r.p.code[1]));
    try std.testing.expectEqual(OpCode.ADDI, ops[2]); // x - 1 => ADDI with -1
    try std.testing.expectEqual(OpCode.UNM, ops[4]);
    // comparisons produce LTI / EQ with jump lists materialised as booleans
    var has_lti = false;
    var has_eq = false;
    for (ops) |o| {
        if (o == .LTI) has_lti = true;
        if (o == .EQ) has_eq = true;
    }
    try std.testing.expect(has_lti and has_eq);
}

test "codegen: control flow" {
    const src =
        \\local n = 0
        \\while n < 3 do n = n + 1 end
        \\if n == 3 then n = 0 elseif n then n = 1 else n = 2 end
        \\repeat n = n + 1 until n > 5
        \\for i = 1, 10, 2 do n = n + i end
        \\for k, v in pairs({}) do n = n + 1 end
        \\return n
    ;
    const r = try compileSource(std.testing.allocator, src);
    defer r.L.deinit();
    const ops = try opcodes(std.testing.allocator, r.p);
    defer std.testing.allocator.free(ops);
    const want = [_]OpCode{ .LTI, .JMP, .ADDI, .EQI, .TEST, .GTI, .FORPREP, .FORLOOP, .TFORPREP, .TFORCALL, .TFORLOOP, .RETURN };
    for (want) |w| {
        var found = false;
        for (ops) |o| {
            if (o == w) found = true;
        }
        if (!found) {
            std.debug.print("missing opcode {s}\n", .{@tagName(w)});
            return error.TestUnexpectedResult;
        }
    }
    // every JMP lands inside the function
    for (r.p.code[0..r.p.sizecode], 0..) |i, pc| {
        if (opcode.getOpcode(i) == .JMP) {
            const target = @as(i64, @intCast(pc)) + 1 + opcode.getsJ(i);
            try std.testing.expect(target >= 0 and target <= r.p.sizecode);
        }
    }
}

test "codegen: closures, upvalues and methods" {
    const src =
        \\local count = 0
        \\local function inc() count = count + 1 return count end
        \\local t = {}
        \\function t:get(x) return self.v + x end
        \\local a = { 1, 2, x = 3, [4] = 5, inc() }
        \\return inc, t:get(1), ...
    ;
    const r = try compileSource(std.testing.allocator, src);
    defer r.L.deinit();
    const p = r.p;
    try std.testing.expectEqual(@as(u32, 2), p.sizep); // two nested functions
    const inc = p.protos[0];
    try std.testing.expectEqual(@as(u8, 1), inc.sizeupvalues); // count
    try std.testing.expect(inc.upvalues[0].instack); // captured from the enclosing stack
    try std.testing.expectEqual(@as(u8, 0), inc.upvalues[0].idx);
    try expectOps(inc, &.{ .GETUPVAL, .ADDI, .MMBINI, .SETUPVAL, .GETUPVAL, .RETURN1, .RETURN0 });
    const get = p.protos[1];
    try std.testing.expectEqual(@as(u8, 2), get.numparams); // self, x
    try std.testing.expectEqual(OpCode.GETFIELD, opcode.getOpcode(get.code[0]));
    // main: NEWTABLE for `a` has 3 array items (1, 2 and the call), 2 hash items
    var newtable_count: u32 = 0;
    var saw_self = false;
    var saw_vararg = false;
    var saw_setlist = false;
    for (p.code[0..p.sizecode]) |i| {
        switch (opcode.getOpcode(i)) {
            .NEWTABLE => newtable_count += 1,
            .SELF => saw_self = true,
            .VARARG => saw_vararg = true,
            .SETLIST => {
                saw_setlist = true;
                try std.testing.expectEqual(@as(u8, 0), opcode.getB(i)); // multret from inc()
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u32, 2), newtable_count);
    try std.testing.expect(saw_self and saw_vararg and saw_setlist);
    // the local `count` is captured, so the main function closes upvalues on return
    try std.testing.expectEqual(OpCode.RETURN, opcode.getOpcode(p.code[p.sizecode - 1]));
    try std.testing.expect(opcode.getk(p.code[p.sizecode - 1]));
}

test "codegen: goto, labels and break" {
    const src =
        \\local i = 1
        \\::top::
        \\if i < 3 then i = i + 1 goto top end
        \\while true do break end
        \\do goto done end
        \\::done::
        \\return i
    ;
    const r = try compileSource(std.testing.allocator, src);
    defer r.L.deinit();
    for (r.p.code[0..r.p.sizecode], 0..) |i, pc| {
        if (opcode.getOpcode(i) == .JMP) {
            const target = @as(i64, @intCast(pc)) + 1 + opcode.getsJ(i);
            try std.testing.expect(target >= 0 and target < r.p.sizecode);
        }
    }
}

test "codegen: errors" {
    const cases = [_]struct { src: []const u8, err: CompileError }{
        .{ .src = "goto nowhere", .err = error.UndefinedGoto },
        .{ .src = "while true do local function f() break end end", .err = error.BreakOutsideLoop },
        .{ .src = "break", .err = error.BreakOutsideLoop },
        .{ .src = "local x <const> = 1; x = 2", .err = error.AssignToConst },
        .{ .src = "local x <close> = nil; local function f() x = 2 end", .err = error.AssignToConst },
        .{ .src = "local function f() return ... end", .err = error.VarargOutsideVararg },
        .{ .src = "::a:: ::a::", .err = error.DuplicateLabel },
        .{ .src = "goto l; local x = 1; ::l:: print(x)", .err = error.JumpIntoScope },
    };
    for (cases) |c| {
        const res = compileSource(std.testing.allocator, c.src);
        if (res) |r| {
            r.L.deinit();
            std.debug.print("expected error for: {s}\n", .{c.src});
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(c.err, err);
        }
    }
}

test "codegen: line info" {
    const r = try compileSource(std.testing.allocator, "local a = 1\n\nlocal b = 2\nreturn a + b");
    defer r.L.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.p.getLine(1)); // LOADI a
    try std.testing.expectEqual(@as(u32, 3), r.p.getLine(2)); // LOADI b
    try std.testing.expectEqual(@as(u32, 4), r.p.getLine(3)); // ADD
}
