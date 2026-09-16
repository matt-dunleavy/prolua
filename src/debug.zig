// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Debug interface (ldebug.c): walking activation records, naming the
//! variables involved in an error, hooks, and tracebacks.

const std = @import("std");
const mem = std.mem;

const value = @import("value.zig");
const state = @import("state.zig");
const proto_module = @import("proto.zig");
const opcode = @import("opcode.zig");
const vm = @import("vm.zig");
const stack = @import("stack.zig");
const config = @import("config.zig");
const closure_module = @import("closure.zig");

const TValue = value.TValue;
const LuaState = state.LuaState;
const CallInfo = state.CallInfo;
const Proto = proto_module.Proto;
const Instruction = opcode.Instruction;

pub const Info = state.DebugInfo;

/// A name and what kind of variable it names ("global", "local", ...)
pub const Name = struct {
    name: []const u8,
    kind: []const u8,
};

// ---------------------------------------------------------------------------
// Activation records
// ---------------------------------------------------------------------------

/// The activation record `level` calls up from the running function: level 0
/// is the running function, 1 its caller, and so on (lua_getstack)
pub fn getStack(L: *LuaState, level: i32) ?*CallInfo {
    if (level < 0) return null;
    var ci: *CallInfo = L.ci;
    var n = level;
    while (n > 0 and ci != &L.base_ci) : (n -= 1) {
        ci = ci.previous orelse return null;
    }
    if (ci == &L.base_ci) return null;
    return ci;
}

/// Index of the instruction a Lua frame is executing (currentpc)
pub fn currentPc(ci: *const CallInfo) i32 {
    const cl = ci.func[0].asClosure() orelse return -1;
    const savedpc = ci.u.l.savedpc orelse return -1;
    const idx = (@intFromPtr(savedpc) - @intFromPtr(cl.proto.code.ptr)) / @sizeOf(Instruction);
    return @as(i32, @intCast(idx)) - 1;
}

/// Source line of instruction `pc` of `p` (luaG_getfuncline)
pub fn getFuncLine(p: *const Proto, pc: i32) i32 {
    if (pc < 0 or p.sizelineinfo == 0) return -1; // no debug information

    return @intCast(p.getLine(@intCast(pc)));
}

fn currentLine(ci: *const CallInfo) i32 {
    const cl = ci.func[0].asClosure() orelse return -1;
    return getFuncLine(cl.proto, currentPc(ci));
}

fn isLua(ci: *const CallInfo) bool {
    return ci.callstatus.isLua;
}

/// Fill the 'S' fields of `ar` for function `f` (funcinfo)
fn funcInfo(ar: *Info, f: TValue) void {
    if (f.asClosure()) |cl| {
        const p = cl.proto;
        ar.source = if (p.source) |s| s.slice() else "=?";
        ar.linedefined = @intCast(p.linedefined);
        ar.lastlinedefined = @intCast(p.lastlinedefined);
        ar.what = if (p.linedefined == 0) "main" else "Lua";
    } else {
        ar.source = "=[C]";
        ar.linedefined = -1;
        ar.lastlinedefined = -1;
        ar.what = "C";
    }
    const short = vm.shortSource(&ar.short_src_buf, ar.source);
    ar.short_src_len = short.len;
}

/// Push a table whose keys are the lines with code in `f`, or nil for a
/// native function (collectvalidlines)
fn collectValidLines(L: *LuaState, f: TValue) !void {
    const cl = f.asClosure() orelse {
        try stack.push(L, TValue.nil());
        return;
    };
    const p = cl.proto;
    const t = try L.l_G.gc.newTable(0, 0);
    try stack.push(L, TValue.table(t));
    // A vararg function's first instruction (VARARGPREP) is not a line of
    // its own
    var i: u32 = if (p.is_vararg) 1 else 0;
    while (i < p.sizelineinfo) : (i += 1) {
        try t.setInt(@intCast(p.getLine(i)), TValue.boolean(true));
    }
}

/// Fill `ar` according to `what` (lua_getinfo). With a `ci`, describes that
/// activation; otherwise describes the function value `func` alone. Options
/// 'f' and 'L' push a value onto `L`'s stack, in that order.
pub fn getInfo(L: *LuaState, what: []const u8, ci: ?*CallInfo, func_in: TValue, ar: *Info) !void {
    const func = if (ci) |c| c.func[0] else func_in;
    ar.i_ci = ci;
    for (what) |opt| {
        switch (opt) {
            'S' => funcInfo(ar, func),
            'l' => ar.currentline = if (ci != null and isLua(ci.?)) currentLine(ci.?) else -1,
            'u' => {
                if (func.asClosure()) |cl| {
                    ar.nups = cl.nupvalues;
                    ar.isvararg = cl.proto.is_vararg;
                    ar.nparams = cl.proto.numparams;
                } else {
                    ar.nups = if (func.asCClosure()) |cc| cc.nupvalues else 0;
                    ar.isvararg = true;
                    ar.nparams = 0;
                }
            },
            't' => ar.istailcall = if (ci) |c| c.callstatus.isTailCall else false,
            'n' => {
                if (getFuncName(L, ci)) |n| {
                    ar.name = n.name;
                    ar.namewhat = n.kind;
                } else {
                    ar.name = null;
                    ar.namewhat = "";
                }
            },
            'r' => {
                if (ci != null and ci.?.callstatus.hasTransfer) {
                    ar.ftransfer = ci.?.ftransfer;
                    ar.ntransfer = ci.?.transfer;
                } else {
                    ar.ftransfer = 0;
                    ar.ntransfer = 0;
                }
            },
            'f', 'L' => {}, // handled below, in a fixed order
            else => return error.InvalidOption,
        }
    }
    if (mem.indexOfScalar(u8, what, 'f') != null) try stack.push(L, func);
    if (mem.indexOfScalar(u8, what, 'L') != null) try collectValidLines(L, func);
}

// ---------------------------------------------------------------------------
// Local variables
// ---------------------------------------------------------------------------

/// Name of the `n`-th local variable active at instruction `pc`
/// (luaF_getlocalname)
pub fn getLocalName(p: *const Proto, n_in: i32, pc: i32) ?[]const u8 {
    var n = n_in;
    var i: usize = 0;
    while (i < p.sizelocvars and @as(i64, p.locvars[i].start_pc) <= pc) : (i += 1) {
        if (pc < @as(i64, p.locvars[i].end_pc)) { // is variable active?
            n -= 1;
            if (n == 0) return p.locvars[i].name.slice();
        }
    }
    return null;
}

/// A local variable of an activation record: its name and its stack slot
pub const Local = struct {
    name: []const u8,
    pos: *TValue,
};

fn findVararg(ci: *CallInfo, n: i32) ?Local {
    const cl = ci.func[0].asClosure() orelse return null;
    if (!cl.proto.is_vararg) return null;
    const nextra: i32 = @intCast(ci.u.l.nextraargs);
    if (n >= -nextra) { // n is negative
        const off: usize = @intCast(nextra + (n + 1));
        return .{ .name = "(vararg)", .pos = &(ci.func - off)[0] };
    }
    return null;
}

/// The `n`-th local of activation `ci` (luaG_findlocal). Negative `n` counts
/// varargs; slots without a name are "(temporary)".
pub fn findLocal(L: *LuaState, ci: *CallInfo, n: i32) ?Local {
    const base = ci.func + 1;
    var name: ?[]const u8 = null;
    if (isLua(ci)) {
        if (n < 0) return findVararg(ci, n);
        const cl = ci.func[0].asClosure().?;
        name = getLocalName(cl.proto, n, currentPc(ci));
    }
    if (name == null) {
        const limit: [*]TValue = if (ci == L.ci) L.top else if (ci.next) |nx| nx.func else L.top;
        const avail = (@intFromPtr(limit) - @intFromPtr(base)) / @sizeOf(TValue);
        if (n > 0 and avail >= @as(usize, @intCast(n))) {
            name = if (isLua(ci)) "(temporary)" else "(C temporary)";
        } else {
            return null;
        }
    }
    return .{ .name = name.?, .pos = &base[@intCast(n - 1)] };
}

// ---------------------------------------------------------------------------
// Symbolic execution: naming registers (ldebug.c getobjname and friends)
// ---------------------------------------------------------------------------

fn upvalName(p: *const Proto, uv: usize) []const u8 {
    if (uv >= p.sizeupvalues) return "?";
    const s = p.upvalues[uv].name orelse return "?";
    return s.slice();
}

/// Code before a jump target is conditional: nothing can be said about it
fn filterPc(pc: i32, jmptarget: i32) i32 {
    return if (pc < jmptarget) -1 else pc;
}

/// The last instruction before `lastpc` that set register `reg`, or -1
fn findSetReg(p: *const Proto, lastpc_in: i32, reg: i32) i32 {
    var lastpc = lastpc_in;
    var setreg: i32 = -1;
    var jmptarget: i32 = 0;
    if (lastpc >= 0 and opcode.testMMMode(opcode.getOpcode(p.code[@intCast(lastpc)]))) {
        lastpc -= 1; // the previous instruction was not actually executed
    }
    var pc: i32 = 0;
    while (pc < lastpc) : (pc += 1) {
        const i = p.code[@intCast(pc)];
        const op = opcode.getOpcode(i);
        const a: i32 = opcode.getA(i);
        var change: bool = undefined;
        switch (op) {
            .LOADNIL => { // sets registers a to a+b
                const b: i32 = opcode.getB(i);
                change = a <= reg and reg <= a + b;
            },
            .TFORCALL => change = reg >= a + 2, // affects all registers above its base
            .CALL, .TAILCALL => change = reg >= a, // affects all registers above base
            .JMP => {
                const dest = pc + 1 + @as(i32, opcode.getsJ(i));
                // A jump that does not skip lastpc and is further than the current target
                if (dest <= lastpc and dest > jmptarget) jmptarget = dest;
                change = false;
            },
            else => change = opcode.testAMode(op) and reg == a,
        }
        if (change) setreg = filterPc(pc, jmptarget);
    }
    return setreg;
}

/// Name for constant `index`: "constant" with the string, or null
fn kName(p: *const Proto, index: usize) Name {
    if (index < p.sizek) {
        if (p.constants[index].asString()) |s| return .{ .name = s.slice(), .kind = "constant" };
    }
    return .{ .name = "?", .kind = "" };
}

/// Name for register `reg` from locals or the instruction that set it
/// (basicgetobjname). Updates `ppc` to that instruction.
fn basicGetObjName(p: *const Proto, ppc: *i32, reg: i32) ?Name {
    const pc = ppc.*;
    if (getLocalName(p, reg + 1, pc)) |n| return .{ .name = n, .kind = "local" };
    // Try symbolic execution
    ppc.* = findSetReg(p, pc, reg);
    const spc = ppc.*;
    if (spc != -1) {
        const i = p.code[@intCast(spc)];
        switch (opcode.getOpcode(i)) {
            .MOVE => {
                const b: i32 = opcode.getB(i);
                if (b < opcode.getA(i)) return basicGetObjName(p, ppc, b); // name for b
            },
            .GETUPVAL => return .{ .name = upvalName(p, opcode.getB(i)), .kind = "upvalue" },
            .LOADK => {
                const k = kName(p, opcode.getBx(i));
                return if (k.kind.len > 0) k else null;
            },
            .LOADKX => {
                const k = kName(p, opcode.getAx(p.code[@intCast(spc + 1)]));
                return if (k.kind.len > 0) k else null;
            },
            else => {},
        }
    }
    return null;
}

/// Name for the register `c` used as a key: a constant's string or "?"
fn rName(p: *const Proto, pc: i32, c: i32) []const u8 {
    var ppc = pc;
    if (basicGetObjName(p, &ppc, c)) |n| {
        if (mem.eql(u8, n.kind, "constant")) return n.name;
    }
    return "?";
}

/// Name for the C operand of an RK instruction
fn rkName(p: *const Proto, pc: i32, i: Instruction) []const u8 {
    const c: i32 = opcode.getC(i);
    if (opcode.getk(i)) return kName(p, @intCast(c)).name;
    return rName(p, pc, c);
}

/// Whether the table indexed by `i` is the `_ENV` upvalue or a variable
/// holding it, which makes the access a global (isEnv)
fn isEnv(p: *const Proto, pc: i32, i: Instruction, isup: bool) []const u8 {
    const t: i32 = opcode.getB(i);
    var name: ?[]const u8 = null;
    if (isup) {
        name = upvalName(p, @intCast(t));
    } else {
        var ppc = pc;
        if (basicGetObjName(p, &ppc, t)) |n| {
            // only a local or upvalue can be the variable _ENV (5.4.7 fix)
            if (mem.eql(u8, n.kind, "local") or mem.eql(u8, n.kind, "upvalue")) name = n.name;
        }
    }
    if (name) |n| {
        if (mem.eql(u8, n, "_ENV")) return "global";
    }
    return "field";
}

/// Name for register `reg` at instruction `lastpc`, including table
/// accesses (getobjname)
pub fn getObjName(p: *const Proto, lastpc_in: i32, reg: i32) ?Name {
    var lastpc = lastpc_in;
    if (basicGetObjName(p, &lastpc, reg)) |n| return n;
    if (lastpc == -1) return null;
    const i = p.code[@intCast(lastpc)];
    switch (opcode.getOpcode(i)) {
        .GETTABUP => return .{ .name = kName(p, opcode.getC(i)).name, .kind = isEnv(p, lastpc, i, true) },
        .GETTABLE => return .{ .name = rName(p, lastpc, opcode.getC(i)), .kind = isEnv(p, lastpc, i, false) },
        .GETI => return .{ .name = "integer index", .kind = "field" },
        .GETFIELD => return .{ .name = kName(p, opcode.getC(i)).name, .kind = isEnv(p, lastpc, i, false) },
        .SELF => return .{ .name = rkName(p, lastpc, i), .kind = "method" },
        else => return null,
    }
}

/// Name for the function being called by the instruction at `pc`
/// (funcnamefromcode)
fn funcNameFromCode(L: *LuaState, p: *const Proto, pc: i32) ?Name {
    if (pc < 0) return null;
    const i = p.code[@intCast(pc)];
    const tm: value.TMS = switch (opcode.getOpcode(i)) {
        .CALL, .TAILCALL => return getObjName(p, pc, opcode.getA(i)),
        .TFORCALL => return .{ .name = "for iterator", .kind = "for iterator" },
        // Other instructions call through metamethods
        .SELF, .GETTABUP, .GETTABLE, .GETI, .GETFIELD => .__index,
        .SETTABUP, .SETTABLE, .SETI, .SETFIELD => .__newindex,
        .MMBIN, .MMBINI, .MMBINK => @enumFromInt(opcode.getC(i)),
        .UNM => .__unm,
        .BNOT => .__bnot,
        .LEN => .__len,
        .CONCAT => .__concat,
        .EQ => .__eq,
        .LT, .LTI, .GTI => .__lt,
        .LE, .LEI, .GEI => .__le,
        .CLOSE, .RETURN => .__close,
        else => return null,
    };
    const full = L.l_G.tmname[@intFromEnum(tm)].slice();
    return .{ .name = full[2..], .kind = "metamethod" };
}

/// Name for the function running in `ci`, from how it was called
/// (funcnamefromcall)
pub fn funcNameFromCall(L: *LuaState, ci: *CallInfo) ?Name {
    if (ci.callstatus.isHooked) return .{ .name = "?", .kind = "hook" };
    if (ci.callstatus.isFinalizer) return .{ .name = "__gc", .kind = "metamethod" };
    if (isLua(ci)) {
        const cl = ci.func[0].asClosure() orelse return null;
        return funcNameFromCode(L, cl.proto, currentPc(ci));
    }
    return null;
}

/// Name for the function of activation `ci` (getfuncname): only its caller,
/// when that is a Lua function that did not tail-call it, can say
fn getFuncName(L: *LuaState, ci: ?*CallInfo) ?Name {
    const c = ci orelse return null;
    if (c.callstatus.isTailCall) return null;
    const caller = c.previous orelse return null;
    return funcNameFromCall(L, caller);
}

// ---------------------------------------------------------------------------
// Error messages (luaG_typeerror and friends)
// ---------------------------------------------------------------------------

/// Whether `o` is a register of frame `ci`, and which
fn inStack(ci: *const CallInfo, o: *const TValue) ?i32 {
    const base = ci.func + 1;
    var pos: usize = 0;
    while (@intFromPtr(base + pos) < @intFromPtr(ci.top)) : (pos += 1) {
        if (@intFromPtr(o) == @intFromPtr(base + pos)) return @intCast(pos);
    }
    return null;
}

/// Whether `o` is an upvalue of the running closure, and its name
fn getUpvalName(ci: *const CallInfo, o: *const TValue) ?Name {
    const cl = ci.func[0].asClosure() orelse return null;
    var i: usize = 0;
    while (i < cl.nupvalues) : (i += 1) {
        const uv = cl.upvals[i] orelse continue;
        if (@intFromPtr(uv.getValue()) == @intFromPtr(o)) {
            return .{ .name = upvalName(cl.proto, i), .kind = "upvalue" };
        }
    }
    return null;
}

/// " (kind 'name')" on the heap, freed by the caller: a name has no bound,
/// as luaO_pushfstring has none in the reference
fn kindName(L: *LuaState, n: Name) ?[]u8 {
    return std.fmt.allocPrint(L.allocator, " ({s} '{s}')", .{ n.kind, n.name }) catch null;
}

/// " (kind 'name')" for `o`, or null when nothing is known about it
/// (varinfo); the caller frees it. Only a value that lives in a register
/// or an upvalue of the running Lua function can be described, which is
/// why callers pass stack pointers rather than copies.
pub fn varInfo(L: *LuaState, o: *const TValue) ?[]u8 {
    const ci = L.ci;
    if (!isLua(ci)) return null;
    var found: ?Name = getUpvalName(ci, o);
    if (found == null) {
        if (inStack(ci, o)) |reg| {
            const cl = ci.func[0].asClosure().?;
            found = getObjName(cl.proto, currentPc(ci), reg);
        }
    }
    const n = found orelse return null;
    return kindName(L, n);
}

/// Type name for messages, honouring a `__name` field in the metatable of a
/// table or userdata (luaT_objtypename)
pub fn objTypeName(L: *LuaState, o: *const TValue) []const u8 {
    const mt: ?*value.Table = switch (o.tag()) {
        .table => o.tableValue().metatable,
        .userdata => o.userdataValue().metatable,
        else => null,
    };
    if (mt) |m| {
        const key = L.l_G.string_pool.intern("__name") catch return o.tag().name();
        const v = m.getShortStr(key);
        if (v.asString()) |s| return s.slice();
    }
    return o.tag().name();
}

pub fn typeError(L: *LuaState, o: *const TValue, op: []const u8) anyerror {
    const info = varInfo(L, o);
    defer if (info) |s| L.allocator.free(s);
    return vm.runtimeError(L, "attempt to {s} a {s} value{s}", .{ op, objTypeName(L, o), info orelse "" });
}

/// A call of a non-callable value: named after the calling instruction when
/// possible (luaG_callerror)
pub fn callError(L: *LuaState, o: *const TValue) anyerror {
    const info: ?[]u8 = if (funcNameFromCall(L, L.ci)) |n| kindName(L, n) else varInfo(L, o);
    defer if (info) |s| L.allocator.free(s);
    return vm.runtimeError(L, "attempt to call a {s} value{s}", .{ objTypeName(L, o), info orelse "" });
}

/// Concatenation error: blame the operand that is not a string or number
/// (luaG_concaterror)
pub fn concatError(L: *LuaState, p1: *const TValue, p2: *const TValue) anyerror {
    const bad = if (p1.isString() or p1.isNumber()) p2 else p1;
    return typeError(L, bad, "concatenate");
}

/// Arithmetic on a non-number: blame the operand that cannot be a number
/// (luaG_opinterror)
pub fn opIntError(L: *LuaState, p1: *const TValue, p2: *const TValue, msg: []const u8) anyerror {
    const bad = if (!p1.isNumber()) p1 else p2;
    return typeError(L, bad, msg);
}

/// Bitwise operation on a number with no integer representation
/// (luaG_tointerror)
pub fn toIntError(L: *LuaState, p1: *const TValue, p2: *const TValue) anyerror {
    // Exact conversion only (LUA_FLOORN2I is F2Ieq): 1.5 is the culprit, not
    // the operand it was combined with
    const bad = if (vm.toInteger(p1, .eq) == null) p1 else p2;
    const info = varInfo(L, bad);
    defer if (info) |t| L.allocator.free(t);
    return vm.runtimeError(L, "number{s} has no integer representation", .{info orelse ""});
}

pub fn orderError(L: *LuaState, p1: *const TValue, p2: *const TValue) anyerror {
    const t1 = objTypeName(L, p1);
    const t2 = objTypeName(L, p2);
    if (mem.eql(u8, t1, t2)) return vm.runtimeError(L, "attempt to compare two {s} values", .{t1});
    return vm.runtimeError(L, "attempt to compare {s} with {s}", .{ t1, t2 });
}

// ---------------------------------------------------------------------------
// Hooks (ldo.c luaD_hook, ldebug.c luaG_traceexec)
// ---------------------------------------------------------------------------

/// Call the hook for `event` (luaD_hook). The activation's stack is
/// protected while the hook runs, and hooks cannot nest.
pub fn hook(L: *LuaState, event: state.HookEvent, line: i32, ftransfer: u16, ntransfer: u16) anyerror!void {
    const h = L.hook orelse return;
    if (L.allowhook == 0) return;
    const ci = L.ci;
    const top_off = (@intFromPtr(L.top) - @intFromPtr(L.stack)) / @sizeOf(TValue);
    const ci_top_off = (@intFromPtr(ci.top) - @intFromPtr(L.stack)) / @sizeOf(TValue);
    var ar = Info{ .event = event, .currentline = line, .i_ci = ci };
    if (ntransfer != 0) {
        ci.callstatus.hasTransfer = true;
        ci.ftransfer = ftransfer;
        ci.transfer = ntransfer;
    }
    // Protect the whole activation register of a Lua function
    if (isLua(ci) and @intFromPtr(L.top) < @intFromPtr(ci.top)) L.top = ci.top;
    try stack.checkStack(L, @intCast(config.MINSTACK));
    if (@intFromPtr(ci.top) < @intFromPtr(L.top + config.MINSTACK)) ci.top = L.top + config.MINSTACK;
    L.allowhook = 0; // cannot call hooks inside a hook
    ci.callstatus.isHooked = true;
    // An error unwinds past here with its error object on top of the
    // stack, so nothing is restored on that path (luaD_hook only restores
    // on a normal return): the frame keeps its "hooked" mark for the
    // traceback a message handler may build, and the protected call that
    // catches the error restores `allowhook`
    try h(L, &ar);
    L.allowhook = 1;
    ci.top = L.stack + ci_top_off;
    L.top = L.stack + top_off;
    ci.callstatus.isHooked = false;
    ci.callstatus.hasTransfer = false;
}

/// Call hook at the start of a Lua function (luaD_hookcall)
pub fn hookCall(L: *LuaState, ci: *CallInfo) anyerror!void {
    L.oldpc = 0; // for the new function
    if (!L.hookmask.call) return;
    const cl = ci.func[0].asClosure() orelse return;
    const event: state.HookEvent = if (ci.callstatus.isTailCall) .tail_call else .call;
    // Point past the first instruction so `currentline` inside the hook is
    // the function's first line
    const saved = ci.u.l.savedpc;
    ci.u.l.savedpc = cl.proto.code.ptr + 1;
    defer ci.u.l.savedpc = saved;
    try hook(L, event, -1, 1, cl.proto.numparams);
}

/// Return hook, before the results are moved (rethook)
pub fn retHook(L: *LuaState, ci: *CallInfo, nres: u32) anyerror!void {
    if (L.hookmask.ret) {
        const firstres = L.top - nres;
        var delta: usize = 0; // correction for vararg functions
        if (isLua(ci)) {
            const p = ci.func[0].asClosure().?.proto;
            if (p.is_vararg) delta = ci.u.l.nextraargs + p.numparams + 1;
        }
        ci.func += delta; // if vararg, back to the virtual `func`
        const ftransfer: u16 = @intCast((@intFromPtr(firstres) - @intFromPtr(ci.func)) / @sizeOf(TValue));
        try hook(L, .ret, -1, ftransfer, @intCast(nres));
        ci.func -= delta;
    }
    if (ci.previous) |prev| {
        if (isLua(prev)) {
            const pc = currentPc(prev);
            L.oldpc = if (pc >= 0) @intCast(pc) else 0;
        }
    }
}

/// Call hook for a native function about to run (precallC)
pub fn hookCallC(L: *LuaState, narg: u16) anyerror!void {
    if (L.hookmask.call) try hook(L, .call, -1, 1, narg);
}

/// Whether instructions `oldpc` and `newpc` are on different lines
fn changedLine(p: *const Proto, oldpc: i32, newpc: i32) bool {
    return getFuncLine(p, oldpc) != getFuncLine(p, newpc);
}

/// Called before each instruction while a hook is set (luaG_traceexec).
/// `pc` points at the instruction about to run.
pub fn traceExec(L: *LuaState, pc: [*]const Instruction) anyerror!void {
    const ci = L.ci;
    const mask = L.hookmask;
    if (!mask.line and !mask.count) return;
    const cl = ci.func[0].asClosure() orelse return;
    const p = cl.proto;
    if (p.is_vararg and pc == p.code.ptr) return; // hooks start at VARARGPREP's successor
    ci.u.l.savedpc = pc + 1; // the reference is always the next instruction
    var counthook = false;
    if (mask.count) {
        L.hookcount -= 1;
        if (L.hookcount == 0) {
            L.hookcount = L.basehookcount;
            counthook = true;
        }
    }
    if (!counthook and !mask.line) return; // count != 0 and no line hook
    if (ci.callstatus.isHookYielded) { // called hook last time?
        ci.callstatus.isHookYielded = false;
        return;
    }
    if (!opcode.isIT(pc[0])) L.top = ci.top; // top not in use: correct it
    if (counthook) try hook(L, .count, -1, 0, 0);
    if (mask.line) {
        const oldpc: i32 = if (L.oldpc < p.sizecode) @intCast(L.oldpc) else 0;
        const npci = currentPc(ci);
        if (npci <= oldpc or changedLine(p, oldpc, npci)) {
            try hook(L, .line, getFuncLine(p, npci), 0, 0);
        }
        L.oldpc = @intCast(npci);
    }
}

// ---------------------------------------------------------------------------
// Tracebacks (lauxlib.c luaL_traceback)
// ---------------------------------------------------------------------------

/// Qualified name of `func` found by searching the loaded modules
/// (pushglobalfuncname): "print" for functions in `_G`, "string.rep"
/// otherwise
pub fn globalFuncName(L: *LuaState, func: TValue, buf: []u8) ?[]const u8 {
    if (!func.isFunction()) return null;
    const reg = L.l_G.l_registry.asTable() orelse return null;
    const loaded_key = L.l_G.string_pool.intern("_LOADED") catch return null;
    const loaded = reg.getShortStr(loaded_key).asTable() orelse return null;

    var modkey = TValue.nil();
    while (loaded.nextPair(&modkey)) |module| {
        const mod_table = module.asTable() orelse continue;
        const mod_name = (modkey.asString() orelse continue).slice();

        var fkey = TValue.nil();
        while (mod_table.nextPair(&fkey)) |v| {
            if (!v.equals(func)) continue;
            const fname = (fkey.asString() orelse continue).slice();
            if (mem.eql(u8, mod_name, "_G")) return std.fmt.bufPrint(buf, "{s}", .{fname}) catch null;
            return std.fmt.bufPrint(buf, "{s}.{s}", .{ mod_name, fname }) catch null;
        }
    }
    return null;
}

/// How a frame is described in a traceback (pushfuncname)
fn appendFuncName(L: *LuaState, out: *std.ArrayList(u8), ar: *const Info) !void {
    var buf: [256]u8 = undefined;
    const func = if (ar.i_ci) |ci| ci.func[0] else TValue.nil();
    if (globalFuncName(L, func, &buf)) |name| {
        try out.print(L.allocator, "function '{s}'", .{name});
    } else if (ar.namewhat.len > 0) {
        try out.print(L.allocator, "{s} '{s}'", .{ ar.namewhat, ar.name orelse "?" });
    } else if (mem.eql(u8, ar.what, "main")) {
        try out.appendSlice(L.allocator, "main chunk");
    } else if (!mem.eql(u8, ar.what, "C")) {
        try out.print(L.allocator, "function <{s}:{d}>", .{ ar.shortSrc(), ar.linedefined });
    } else {
        try out.appendSlice(L.allocator, "?");
    }
}

/// Number of levels in the stack of `L1`
fn lastLevel(L1: *LuaState) i32 {
    var li: i32 = 1;
    var le: i32 = 1;
    // Find an upper bound
    while (getStack(L1, le) != null) {
        li = le;
        le *= 2;
    }
    // Binary search between them
    while (li < le) {
        const m = @divTrunc(li + le, 2);
        if (getStack(L1, m) != null) li = m + 1 else le = m;
    }
    return le - 1;
}

const LEVELS1 = 10; // size of the first part of the stack
const LEVELS2 = 11; // size of the second part of the stack

/// Push onto `L` a traceback of `L1`'s stack starting at `level`, preceded
/// by `msg` when given (luaL_traceback)
pub fn traceback(L: *LuaState, L1: *LuaState, msg: ?[]const u8, level_in: i32) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(L.allocator);

    var level = level_in;
    const last = lastLevel(L1);
    var limit2show: i32 = if (last - level > LEVELS1 + LEVELS2) LEVELS1 else -1;
    if (msg) |m| {
        try out.appendSlice(L.allocator, m);
        try out.append(L.allocator, '\n');
    }
    try out.appendSlice(L.allocator, "stack traceback:");
    while (getStack(L1, level)) |ci| {
        level += 1;
        if (limit2show == 0) { // too many levels?
            const n = last - level - LEVELS2 + 1; // number of levels to skip
            try out.print(L.allocator, "\n\t...\t(skipping {d} levels)", .{n});
            level += n; // and skip to the last levels
        } else {
            var ar = Info{};
            try getInfo(L1, "Slnt", ci, TValue.nil(), &ar);
            if (ar.currentline <= 0) {
                try out.print(L.allocator, "\n\t{s}: in ", .{ar.shortSrc()});
            } else {
                try out.print(L.allocator, "\n\t{s}:{d}: in ", .{ ar.shortSrc(), ar.currentline });
            }
            try appendFuncName(L, &out, &ar);
            if (ar.istailcall) try out.appendSlice(L.allocator, "\n\t(...tail calls...)");
        }
        limit2show -= 1;
    }
    const s = try L.l_G.string_pool.create(out.items);
    try stack.push(L, TValue.string(s));
}
