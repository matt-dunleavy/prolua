// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Coroutines: suspending and resuming a thread (the coroutine half of
//! `ldo.c`, plus `luaV_finishOp` from `lvm.c`).

const std = @import("std");

const value = @import("value.zig");
const state = @import("state.zig");
const opcode = @import("opcode.zig");
const vm = @import("vm.zig");
const stack = @import("stack.zig");
const config = @import("config.zig");
const closure_module = @import("closure.zig");

const TValue = value.TValue;
const LuaState = state.LuaState;
const CallInfo = state.CallInfo;
const ThreadStatus = state.ThreadStatus;

/// The error that carries a yield up to `resume`. Never a Lua error: nothing
/// may catch it except `resume`, and `api.pcall` lets it through.
pub const YieldError = error{Yield};

pub fn isYieldable(L: *const LuaState) bool {
    return L.nny == 0;
}

// ---------------------------------------------------------------------------
// Yield
// ---------------------------------------------------------------------------

/// Suspend the running coroutine, returning the top `nresults` values to
/// whoever resumed it (lua_yieldk). Only valid inside a native function of a
/// yieldable thread; the function's frame is left in place so `resume` can
/// finish its call with the values passed to the next resume.
pub fn yield(L: *LuaState, nresults: i32) anyerror {
    const ci = L.ci;
    if (!isYieldable(L)) {
        if (L != L.l_G.mainthread) {
            return vm.runtimeError(L, "attempt to yield across a C-call boundary", .{});
        }
        return vm.runtimeError(L, "attempt to yield from outside a coroutine", .{});
    }
    L.status = .yield;
    ci.u.c.nyield = @intCast(nresults);
    return error.Yield;
}

// ---------------------------------------------------------------------------
// Resume
// ---------------------------------------------------------------------------

/// Push `msg` on `L`'s stack in place of the resume arguments and report an
/// error without touching the coroutine's state (resume_error)
fn resumeError(L: *LuaState, msg: []const u8, narg: usize) ThreadStatus {
    L.top -= narg;
    const s = L.l_G.string_pool.intern(msg) catch return .errmem;
    L.top[0] = TValue.string(s);
    L.top += 1;
    return .errrun;
}

/// Start or continue running coroutine `L` with `n` arguments on top of its
/// stack (resume)
fn runResume(L: *LuaState, n: usize) anyerror!void {
    const first_arg = L.top - n;
    const ci = L.ci;
    if (L.status == .ok) {
        // Starting: the body is just below the arguments
        try vm.call(L, first_arg - 1, vm.MULTRET);
        return;
    }
    // Resuming after a yield
    std.debug.assert(L.status == .yield);
    L.status = .ok;
    if (ci.callstatus.isLua) {
        // A yield inside a hook is not supported; a Lua frame can only be on
        // top after one, so this cannot happen
        unreachable;
    }
    // The frame that yielded: its results are the values passed to resume
    var nres = n;
    if (ci.u.c.k) |k| {
        const r = try k(L, .yield, ci.u.c.ctx);
        nres = @intCast(r);
    }
    try vm.posCall(L, ci, @intCast(nres));
    try unroll(L);
}

/// Run every frame below the top of the CallInfo chain until the thread is
/// back at its base: native frames are finished through their continuation,
/// Lua frames have their interrupted instruction completed and are executed
/// again (unroll)
pub fn unroll(L: *LuaState) anyerror!void {
    while (L.ci != &L.base_ci) {
        const ci = L.ci;
        if (!ci.callstatus.isLua) {
            try finishCcall(L, ci);
        } else {
            try finishOp(L);
            try vm.execute(L, ci);
        }
    }
}

/// Finish a native call whose frame was unwound by a yield (finishCcall)
fn finishCcall(L: *LuaState, ci: *CallInfo) anyerror!void {
    var status: ThreadStatus = .yield; // default: interrupted by a yield, no error
    if (ci.callstatus.isYpcall) status = try finishPcallk(L, ci);
    // Only a native function with a continuation can be here (a plain
    // `api.call` made the thread non-yieldable)
    const k = ci.u.c.k orelse return error.YieldAcrossNativeBoundary;
    const n = try k(L, status, ci.u.c.ctx);
    try vm.posCall(L, ci, @intCast(n));
}

/// Complete an interrupted `pcallk`: after a plain yield nothing is needed;
/// after an error (recorded by `precover`) close the callee's to-be-closed
/// variables and leave the error object where the callee was (finishpcallk)
fn finishPcallk(L: *LuaState, ci: *CallInfo) anyerror!ThreadStatus {
    var status = ci.u.c.recst;
    if (status == .ok) {
        status = .yield; // interrupted by a yield, no error
    } else {
        const func_off = ci.u.c.funcidx;
        // The error object is on top of the stack; closing may yield or raise
        const errobj = (L.top - 1)[0];
        try vm.closeAll(L, L.stack + func_off, errobj);
        const func = L.stack + func_off;
        func[0] = errobj;
        L.top = func + 1;
        ci.u.c.recst = .ok;
    }
    ci.callstatus.isYpcall = false;
    return status;
}

/// The innermost protected call that can be recovered after a yield
fn findPcall(L: *LuaState) ?*CallInfo {
    var ci: ?*CallInfo = L.ci;
    while (ci) |c| : (ci = c.previous) {
        if (c.callstatus.isYpcall) return c;
    }
    return null;
}

/// Turn a Zig error that escaped the coroutine into a thread status,
/// pushing a message for the ones that never became a Lua value
fn errorStatus(L: *LuaState, err: anyerror, jmp: *const state.ErrorJmp) ThreadStatus {
    if (err == error.Yield) return .yield;
    if (jmp.status != .ok) return jmp.status;
    const text = if (err == error.OutOfMemory) "not enough memory" else @errorName(err);
    const s = L.l_G.string_pool.intern(text) catch return .errmem;
    stack.push(L, TValue.string(s)) catch return .errmem;
    return if (err == error.OutOfMemory) .errmem else .errrun;
}

/// After an error inside a resumed coroutine, hand it to the innermost
/// `pcall` whose native frame a yield had unwound, and keep running from
/// there; repeat while errors keep coming (precover)
fn precover(L: *LuaState, status_in: ThreadStatus, jmp: *state.ErrorJmp) ThreadStatus {
    var status = status_in;
    while (status.isError()) {
        const ci = findPcall(L) orelse break;
        // The message handler runs first, while the failing frames are still
        // there to be seen by a traceback
        if (status == .errrun and ci.u.c.errfunc != 0) {
            const handler = L.stack[ci.u.c.errfunc];
            if (handler.isFunction()) {
                const errobj = (L.top - 1)[0];
                stack.checkStack(L, 2) catch {};
                const call_base = L.top;
                call_base[0] = handler;
                call_base[1] = errobj;
                L.top = call_base + 2;
                L.nny += 1;
                if (vm.call(L, call_base, 1)) |_| {
                    // The result replaces the error object
                    (call_base - 1)[0] = (L.top - 1)[0];
                    L.top = call_base;
                } else |_| {
                    status = .errerr;
                    const s = L.l_G.string_pool.intern("error in error handling") catch null;
                    L.top = call_base;
                    if (s) |str| (L.top - 1)[0] = TValue.string(str);
                }
                L.nny -= 1;
            }
        }
        L.ci = ci; // go down to the recovery function
        ci.u.c.recst = status;
        jmp.status = .ok;
        L.status = .ok;
        if (unroll(L)) |_| {
            status = .ok;
        } else |err| {
            status = errorStatus(L, err, jmp);
        }
    }
    return status;
}

/// Run coroutine `L` until it yields, returns or fails (lua_resume). `from`
/// is the thread doing the resuming. The arguments are the top `nargs`
/// values of `L`'s stack; afterwards the yielded or returned values are on
/// top, `nresults` of them, or the error object when the status is an error.
pub fn resumeThread(L: *LuaState, from: ?*LuaState, nargs: usize, nresults: *usize) ThreadStatus {
    if (L.status == .ok) { // may be starting a coroutine
        if (L.ci != &L.base_ci) return resumeError(L, "cannot resume non-suspended coroutine", nargs);
        const on_stack = (@intFromPtr(L.top) - @intFromPtr(L.ci.func + 1)) / @sizeOf(TValue);
        if (on_stack == nargs) return resumeError(L, "cannot resume dead coroutine", nargs); // no function
    } else if (L.status != .yield) { // ended with errors?
        return resumeError(L, "cannot resume dead coroutine", nargs);
    }
    L.nCcalls = if (from) |f| f.nCcalls else 0;
    if (L.nCcalls >= config.MAXCCALLS) return resumeError(L, "C stack overflow", nargs);
    L.nCcalls += 1;

    // The coroutine's own recovery point, so `throw` can record the status
    var jmp = state.ErrorJmp{ .previous = L.errorJmp, .status = .ok };
    L.errorJmp = &jmp;
    defer L.errorJmp = jmp.previous;

    var status: ThreadStatus = .ok;
    if (runResume(L, nargs)) |_| {
        status = .ok;
    } else |err| {
        status = errorStatus(L, err, &jmp);
    }
    // Continue running after recoverable errors
    status = precover(L, status, &jmp);

    if (!status.isError()) {
        std.debug.assert(status == L.status); // normal end or yield
    } else {
        L.status = status; // mark the thread as dead
        // Leave a second copy of the error object on top (luaD_seterrorobj
        // at `top`): the resumer takes one, and `closeThread` still finds
        // the other when it closes the dead coroutine
        L.top[0] = (L.top - 1)[0];
        L.top += 1;
        L.ci.top = L.top;
    }
    nresults.* = if (status == .yield)
        L.ci.u.c.nyield
    else
        (@intFromPtr(L.top) - @intFromPtr(L.ci.func + 1)) / @sizeOf(TValue);
    return status;
}

/// Reset a thread to its initial state, closing its pending to-be-closed
/// variables and upvalues (lua_closethread / luaE_resetthread). Returns the
/// status of that closing; on an error the error object is left on the stack.
pub fn closeThread(L: *LuaState, from: ?*LuaState) ThreadStatus {
    L.nCcalls = if (from) |f| f.nCcalls else 0;
    var status = L.status;
    // The error object of a dead coroutine, if any, is passed to the handlers
    const errobj: ?TValue = if (status.isError() and @intFromPtr(L.top) > @intFromPtr(L.stack + 1)) (L.top - 1)[0] else null;

    L.ci = &L.base_ci; // unwind the CallInfo list
    L.stack[0] = TValue.nil(); // 'function' entry of the base frame
    L.base_ci.func = L.stack;
    L.base_ci.callstatus = .{};
    if (status == .yield) status = .ok;
    L.status = .ok; // so it can run __close metamethods

    var jmp = state.ErrorJmp{ .previous = L.errorJmp, .status = .ok };
    L.errorJmp = &jmp;
    defer L.errorJmp = jmp.previous;
    var current_err = errobj;
    L.nny += 1; // closing here cannot yield
    defer L.nny -= 1;
    while (true) {
        vm.closeAll(L, L.stack + 1, current_err) catch |err| {
            // A failing handler replaces the error object; keep closing
            status = if (err == error.OutOfMemory) .errmem else if (jmp.status != .ok) jmp.status else .errrun;
            current_err = (L.top - 1)[0];
            jmp.status = .ok;
            L.status = .ok;
            L.ci = &L.base_ci;
            continue;
        };
        break;
    }
    if (status.isError()) {
        L.stack[1] = current_err orelse TValue.nil();
        L.top = L.stack + 2;
    } else {
        L.top = L.stack + 1;
    }
    L.base_ci.top = L.top + config.MINSTACK;
    L.tbclist.items.len = 0;
    return status;
}

// ---------------------------------------------------------------------------
// Finishing an interrupted instruction (luaV_finishOp)
// ---------------------------------------------------------------------------

/// Complete the instruction of `L.ci` that a yield interrupted, using the
/// result the interrupted call left on top of the stack, so that `execute`
/// can continue at the next instruction
pub fn finishOp(L: *LuaState) anyerror!void {
    const ci = L.ci;
    const base = ci.func + 1;
    const savedpc = ci.u.l.savedpc orelse return;
    const inst = (savedpc - 1)[0]; // the interrupted instruction
    switch (opcode.getOpcode(inst)) {
        .MMBIN, .MMBINI, .MMBINK => {
            // The result goes to the register of the arithmetic instruction
            // just before the metamethod fall-back
            const arith = (savedpc - 2)[0];
            L.top -= 1;
            base[opcode.getA(arith)] = L.top[0];
        },
        .UNM, .BNOT, .LEN, .GETTABUP, .GETTABLE, .GETI, .GETFIELD, .SELF => {
            L.top -= 1;
            base[opcode.getA(inst)] = L.top[0];
        },
        .LT, .LE, .LTI, .LEI, .GTI, .GEI, .EQ => { // EQI and EQK cannot yield
            L.top -= 1;
            const res = !L.top[0].isFalsy();
            // The next instruction is the jump; skip it when the condition failed
            std.debug.assert(opcode.getOpcode(savedpc[0]) == .JMP);
            if (res != opcode.getk(inst)) ci.u.l.savedpc = savedpc + 1;
        },
        .CONCAT => {
            const top = L.top - 1; // top when the metamethod was called
            const a: usize = opcode.getA(inst);
            const total: u32 = @intCast((@intFromPtr(top - 1) - @intFromPtr(base + a)) / @sizeOf(TValue)); // yet to concatenate
            (top - 2)[0] = top[0]; // put the result in its place
            L.top = top - 1; // one past the last element
            try vm.concatenate(L, total); // may yield again
        },
        .CLOSE => {
            ci.u.l.savedpc = savedpc - 1; // repeat, to close the remaining variables
        },
        .RETURN => {
            // Restore the number of results, in case the return is "up to
            // top", and repeat the instruction to finish closing and return
            const ra = base + opcode.getA(inst);
            L.top = ra + ci.u.l.nres;
            ci.u.l.savedpc = savedpc - 1;
        },
        else => {
            // The only other instructions that can yield need nothing more:
            // CALL, TAILCALL, TFORCALL and the SET* family
        },
    }
}

/// Close the open upvalues of a thread about to be freed, so that closures
/// that captured them keep their values (luaE_freethread's luaF_closeupval)
pub fn closeUpvaluesOnFree(L: *LuaState) void {
    closure_module.closeUpvalues(L, &L.stack[0]) catch {};
}
