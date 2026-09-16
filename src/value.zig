// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! Value Representation (NaN-boxed)
//!
//! This module implements NaN-boxed value representation, which diverges from
//! the official Lua implementation.
//!
//! The official Lua implementation uses a single tagged value representation,
//! while this implementation uses a NaN-boxed value representation.

const std = @import("std");
const config = @import("config.zig");

// The concrete object types live in their own modules. They are re-exported
// here so that `value.String`, `value.Table`, ... name exactly one struct
// across the code base (see docs/project/project.md, "One type surface").
const string_module = @import("string.zig");
const table_module = @import("table.zig");
const proto_module = @import("proto.zig");
const closure_module = @import("closure.zig");
const state_module = @import("state.zig");

/// Lua value types (matching Lua 5.4)
pub const ValueType = enum(u8) {
    nil = 0,
    boolean = 1,
    light_userdata = 2,
    number = 3,
    string = 4,
    table = 5,
    function = 6,
    userdata = 7,
    thread = 8,

    // Internal types (not exposed to Lua). `lclosure`/`cclosure` are the
    // fine-grained tags stored in `GCObject.tt`; a `TValue` always carries
    // `.function` for both.
    proto = 9, // Function prototype
    upvalue = 10, // Upvalue
    lclosure = 11, // Lua closure (GC header tag only)
    cclosure = 12, // C closure with upvalues (GC header tag only)
    deadkey = 13, // key of a removed table entry whose object was collected (table nodes only)
    boxint = 14, // BoxedInt (GC header tag only): an integer beyond the 48-bit inline range

    /// Get the Lua-visible type name
    pub fn name(self: ValueType) []const u8 {
        return switch (self) {
            .nil => "nil",
            .boolean => "boolean",
            .light_userdata => "userdata",
            .number => "number",
            .string => "string",
            .table => "table",
            .function => "function",
            .userdata => "userdata",
            .thread => "thread",
            .proto => "proto",
            .upvalue => "upvalue",
            .lclosure, .cclosure => "function",
            .deadkey => "deadkey",
            .boxint => "number",
        };
    }

    /// Check if this is a collectible type
    pub fn isCollectible(self: ValueType) bool {
        return switch (self) {
            .string, .table, .function, .userdata, .thread, .proto, .upvalue, .lclosure, .cclosure, .boxint => true,
            else => false,
        };
    }
};

/// Number subtypes in Lua 5.4
pub const NumberType = enum {
    integer,
    float,
};

/// GC object header - all collectible objects start with this.
/// Mark-bit layout is the single source of truth shared with gc.zig
/// (WHITE0, WHITE1, BLACK, FINALIZED, ...); gray is "neither white nor black".
pub const GCObject = extern struct {
    next: ?*GCObject, // link in the collector's `allgc` list
    tt: u8, // fine-grained type tag (ValueType)
    marked: u8, // mark bits for GC

    pub const WHITE0: u8 = 1;
    pub const WHITE1: u8 = 2;
    pub const WHITE: u8 = WHITE0 | WHITE1;
    pub const BLACK: u8 = 4;
    pub const FINALIZEDBIT: u8 = 8;

    pub fn isWhite(self: *const GCObject) bool {
        return (self.marked & WHITE) != 0;
    }

    pub fn isBlack(self: *const GCObject) bool {
        return (self.marked & BLACK) != 0;
    }

    pub fn isGray(self: *const GCObject) bool {
        return !self.isWhite() and !self.isBlack();
    }

    pub fn typeTag(self: *const GCObject) ValueType {
        return @enumFromInt(self.tt);
    }
};

/// Canonical object types (one definition each, see the module headers).
pub const String = string_module.String;
pub const Table = table_module.Table;
pub const Proto = proto_module.Proto;
pub const Thread = state_module.LuaState;
pub const Upvalue = closure_module.Upvalue;
pub const LClosure = closure_module.LClosure;
pub const CClosure = closure_module.CClosure;

/// Light userdata - just a pointer
pub const LightUserdata = *anyopaque;

/// Native function type. Handlers are ordinary Zig functions returning the
/// number of results; Lua errors propagate as Zig errors (`error.LuaError`).
pub const NativeFn = state_module.CFunction;

/// Full userdata: a GC-managed block of bytes with an optional metatable and
/// `nuvalue` associated Lua values.
pub const Userdata = struct {
    header: GCObject,
    gclist: ?*GCObject = null, // link in the gray / grayagain lists
    metatable: ?*Table,
    len: usize,
    nuvalue: u16,
    data: [*]u8,
    values: []TValue,

    pub fn bytes(self: *const Userdata) []u8 {
        return self.data[0..self.len];
    }
};

/// The three kinds of callable a `.function` value can hold.
pub const Function = union(enum) {
    closure: *LClosure, // Lua function
    cclosure: *CClosure, // native function with upvalues
    native_fn: NativeFn, // light native function (no upvalues)

    pub fn eql(a: Function, b: Function) bool {
        return switch (a) {
            .closure => |x| b == .closure and b.closure == x,
            .cclosure => |x| b == .cclosure and b.cclosure == x,
            .native_fn => |x| b == .native_fn and b.native_fn == x,
        };
    }

    pub fn gcObject(self: Function) ?*GCObject {
        return switch (self) {
            .closure => |c| &c.header,
            .cclosure => |c| &c.header,
            .native_fn => null,
        };
    }
};

/// Tag method names (metamethods)
pub const TMS = enum(u8) {
    __index,
    __newindex,
    __gc,
    __mode,
    __len,
    __eq,
    __add,
    __sub,
    __mul,
    __mod,
    __pow,
    __div,
    __idiv,
    __band,
    __bor,
    __bxor,
    __shl,
    __shr,
    __unm,
    __bnot,
    __lt,
    __le,
    __concat,
    __call,
    __close,

    /// Number of metamethods
    pub const count = @typeInfo(TMS).@"enum".fields.len;

    pub fn name(self: TMS) []const u8 {
        return @tagName(self);
    }
};

/// Number value - can be integer or float
pub const Number = union(NumberType) {
    integer: i64,
    float: f64,

    pub fn fromInteger(i: i64) Number {
        return .{ .integer = i };
    }

    pub fn fromFloat(f: f64) Number {
        return .{ .float = f };
    }

    pub fn toFloat(self: Number) f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
        };
    }

    pub fn toInteger(self: Number) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .float => |f| floatToInteger(f),
        };
    }

    /// Format number according to Lua rules
    pub fn format(self: Number, writer: anytype) !void {
        switch (self) {
            .integer => |i| try writer.print("{}", .{i}),
            .float => |f| {
                // Lua formats floats specially to avoid trailing zeros
                if (@floor(f) == f and @abs(f) < 1e14) {
                    try writer.print("{d:.0}", .{f});
                } else {
                    try writer.print("{d}", .{f});
                }
            },
        }
    }

    /// Compare two Numbers for equality
    pub fn equals(self: Number, other: Number) bool {
        return switch (self) {
            .integer => |i| switch (other) {
                .integer => |j| i == j,
                .float => |f| @as(f64, @floatFromInt(i)) == f,
            },
            .float => |f| switch (other) {
                .integer => |j| f == @as(f64, @floatFromInt(j)),
                .float => |g| f == g,
            },
        };
    }
};

/// Boxed integer: an integer that does not fit the 48-bit inline payload
/// of a `TValue` lives in one of these, a leaf collectable object like a
/// string (never cleared from weak tables, compared by value). Values are
/// immutable except for the numeric `for` counter, which the loop
/// decrements in place so a huge iteration count does not allocate per
/// iteration.
pub const BoxedInt = struct {
    header: GCObject,
    v: i64,
};

/// The 8-byte payload viewed as each of the kinds a value can hold; a
/// transit type for code that wants a union, not the stored form.
pub const Value = extern union {
    boolean: bool,
    light_userdata: LightUserdata,
    integer: i64,
    float: f64,
    string: *String,
    table: *Table,
    lclosure: *LClosure,
    cclosure: *CClosure,
    native_fn: *const anyopaque,
    deadkey: *GCObject, // identity only; the object may already be freed
    userdata: *Userdata,
    thread: *Thread,
    /// Any payload viewed as a raw pointer, for identity comparison
    raw: usize,
};

/// NaN-boxed value, 8 bytes. A float is stored as its own bits, with every
/// NaN canonicalised to one of two quiet NaNs (one per sign, since the
/// reference prints `0/0` as "-nan" and `-(0/0)` as "nan"), so that no
/// float other than the negative one has its top 16 bits at 0xFFF1 or
/// above. Every other kind is a "negative NaN" with a 16-bit prefix (bits
/// 63..48) naming the kind and a 48-bit payload: a biased integer, a
/// pointer, or a small immediate. The prefixes are ordered so the hot
/// tests are single compares: a number is prefix <= 0xFFF2, an integer of
/// either form is prefix 0xFFF1 or 0xFFF2, a function is 0xFFF9..0xFFFB.
/// The negative canonical NaN, 0xFFF8_0000_0000_0000, shares its prefix
/// with nil (payload 1) and dead keys (an address), kinds whose payload is
/// never dereferenced, so no pointer accessor can meet it.
pub const TValue = extern struct {
    bits: u64,

    comptime {
        std.debug.assert(@sizeOf(TValue) == 8);
        std.debug.assert(@sizeOf(usize) == 8); // 48-bit pointers in a 64-bit word
    }

    // Prefixes (bits 63..48). 0xFFF0 is never used: 0xFFF0_0000_0000_0000 is -inf.
    pub const P_INT: u64 = 0xFFF1; // inline integer: bits = INT_BASE + i for i in [-2^47, 2^47)
    pub const P_BOXINT: u64 = 0xFFF2; // *BoxedInt
    pub const P_BOOL: u64 = 0xFFF3; // payload 0 = false, 1 = true
    pub const P_LUD: u64 = 0xFFF4; // light userdata pointer
    pub const P_STRING: u64 = 0xFFF5; // *String (short or long: see String.isShort)
    pub const P_TABLE: u64 = 0xFFF6;
    pub const P_USERDATA: u64 = 0xFFF7;
    pub const P_NIL: u64 = 0xFFF8; // payload 1 = nil; an address = dead key; 0 = the negative NaN
    pub const P_LCLOSURE: u64 = 0xFFF9;
    pub const P_CCLOSURE: u64 = 0xFFFA;
    pub const P_NATIVE: u64 = 0xFFFB; // light native function pointer
    pub const P_THREAD: u64 = 0xFFFC;

    const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;
    const NAN_POS: u64 = 0x7FF8_0000_0000_0000;
    const NAN_NEG: u64 = 0xFFF8_0000_0000_0000;
    /// Inline integers are stored biased so that decoding is one subtraction
    const INT_BASE: u64 = (P_INT << 48) | (1 << 47);
    pub const NIL_BITS: u64 = (P_NIL << 48) | 1;
    pub const FALSE_BITS: u64 = P_BOOL << 48;
    pub const TRUE_BITS: u64 = (P_BOOL << 48) | 1;

    /// Largest and smallest inline integers
    pub const INLINE_MAX: i64 = (1 << 47) - 1;
    pub const INLINE_MIN: i64 = -(1 << 47);

    /// Whether `i` fits the inline payload
    pub inline fn fitsInline(i: i64) bool {
        return (i +% (1 << 47)) >> 48 == 0;
    }

    inline fn prefix(self: TValue) u64 {
        return self.bits >> 48;
    }

    /// Both inline integers, as one test: the prefixes of both differ from
    /// `P_INT` in no bit
    pub inline fn bothInlineInts(x: TValue, y: TValue) bool {
        return ((x.bits ^ (P_INT << 48)) | (y.bits ^ (P_INT << 48))) >> 48 == 0;
    }

    /// `i` encoded inline, or null when it does not fit. `INT_BASE + i`
    /// keeps the `P_INT` prefix exactly when `i` is in the inline range, so
    /// the range check is the prefix test on the encoded word and no
    /// second constant is needed
    pub inline fn integerChecked(i: i64) ?TValue {
        const r = TValue{ .bits = INT_BASE +% @as(u64, @bitCast(i)) };
        return if (r.isInlineInt()) r else null;
    }

    /// x + y for two inline integers, computed on the encoded words: the
    /// biases cancel, so no decode and no re-encode. Null when the sum
    /// leaves the inline range
    pub inline fn addInline(x: TValue, y: TValue) ?TValue {
        std.debug.assert(x.isInlineInt() and y.isInlineInt());
        const r = TValue{ .bits = x.bits +% y.bits -% INT_BASE };
        return if (r.isInlineInt()) r else null;
    }

    /// x - y, as `addInline`
    pub inline fn subInline(x: TValue, y: TValue) ?TValue {
        std.debug.assert(x.isInlineInt() and y.isInlineInt());
        const r = TValue{ .bits = x.bits -% y.bits +% INT_BASE };
        return if (r.isInlineInt()) r else null;
    }

    /// x + imm for an inline integer x and a small immediate, as `addInline`
    pub inline fn addInlineImm(x: TValue, imm: i64) ?TValue {
        std.debug.assert(x.isInlineInt());
        const r = TValue{ .bits = x.bits +% @as(u64, @bitCast(imm)) };
        return if (r.isInlineInt()) r else null;
    }

    inline fn payload(self: TValue) u64 {
        return self.bits & PAYLOAD_MASK;
    }

    inline fn ptr(self: TValue, comptime T: type) T {
        // A collectable object or a function is never at address zero;
        // saying so lets the optimiser drop the null test that turning the
        // payload into an optional pointer would otherwise add at every
        // `asTable` / `asClosure` / `asString` site (a light userdata may
        // be null, and is the one exception)
        if (@typeInfo(T) != .optional) std.debug.assert(self.payload() != 0);
        return @ptrFromInt(self.payload());
    }

    inline fn box(p: u64, comptime T: type, x: T) TValue {
        const addr = @intFromPtr(x);
        std.debug.assert(addr & ~PAYLOAD_MASK == 0);
        return .{ .bits = (p << 48) | addr };
    }

    // Constructors

    /// Create nil value
    pub inline fn nil() TValue {
        return .{ .bits = NIL_BITS };
    }

    /// Create boolean value
    pub inline fn boolean(b: bool) TValue {
        return .{ .bits = (P_BOOL << 48) | @intFromBool(b) };
    }

    /// Inline integer value; `i` must fit 48 bits (`fitsInline`). Use
    /// `integerOrBox` for an integer of unknown range.
    pub inline fn integer(i: i64) TValue {
        std.debug.assert(fitsInline(i));
        return .{ .bits = INT_BASE +% @as(u64, @bitCast(i)) };
    }

    /// Integer value of any range: inline when it fits, else a `BoxedInt`
    /// owned by the collector `g`
    pub inline fn integerOrBox(g: anytype, i: i64) !TValue {
        if (fitsInline(i)) return integer(i);
        return boxedInteger(try g.newBoxedInt(i));
    }

    /// Value holding an existing box
    pub inline fn boxedInteger(b: *BoxedInt) TValue {
        return box(P_BOXINT, *BoxedInt, b);
    }

    /// Create float number value. NaNs are canonicalised (keeping the sign,
    /// which `tostring` shows): an arbitrary NaN payload could read as a
    /// tagged value.
    pub inline fn float(f: f64) TValue {
        if (f != f) return .{ .bits = if (std.math.signbit(f)) NAN_NEG else NAN_POS };
        return .{ .bits = @bitCast(f) };
    }

    /// Create number from either int or float; the integer must fit inline
    pub fn number(n: Number) TValue {
        return switch (n) {
            .integer => |i| integer(i),
            .float => |f| float(f),
        };
    }

    /// Create number from either int or float, boxing a large integer
    pub fn numberOrBox(g: anytype, n: Number) !TValue {
        return switch (n) {
            .integer => |i| try integerOrBox(g, i),
            .float => |f| float(f),
        };
    }

    /// Create string value
    pub inline fn string(s: *String) TValue {
        return box(P_STRING, *String, s);
    }

    /// Create table value
    pub inline fn table(t: *Table) TValue {
        return box(P_TABLE, *Table, t);
    }

    /// Marker for a table key whose object is dead: compares by identity only
    pub fn deadKey(o: *GCObject) TValue {
        return box(P_NIL, *GCObject, o);
    }

    /// Create a function value from any callable kind
    pub fn function(f: Function) TValue {
        return switch (f) {
            .closure => |c| closure(c),
            .cclosure => |c| cclosure(c),
            .native_fn => |n| nativeFunction(n),
        };
    }

    /// Create Lua closure value
    pub inline fn closure(c: *LClosure) TValue {
        return box(P_LCLOSURE, *LClosure, c);
    }

    /// Create C closure value
    pub inline fn cclosure(c: *CClosure) TValue {
        return box(P_CCLOSURE, *CClosure, c);
    }

    /// Create light native function value
    pub inline fn nativeFunction(f: NativeFn) TValue {
        return box(P_NATIVE, NativeFn, f);
    }

    /// Create userdata value
    pub inline fn userdata(u: *Userdata) TValue {
        return box(P_USERDATA, *Userdata, u);
    }

    /// Create light userdata value
    pub inline fn lightUserdata(p: LightUserdata) TValue {
        return box(P_LUD, LightUserdata, p);
    }

    /// Create thread value
    pub inline fn thread(t: *Thread) TValue {
        return box(P_THREAD, *Thread, t);
    }

    // Type checking

    /// The Lua-visible type (plus `.deadkey` for a dead table key)
    pub fn tag(self: TValue) ValueType {
        const p = self.prefix();
        if (p <= P_BOXINT) return .number;
        return switch (p) {
            P_NIL => if (self.bits == NIL_BITS) .nil else if (self.bits == NAN_NEG) .number else .deadkey,
            P_BOOL => .boolean,
            P_LUD => .light_userdata,
            P_STRING => .string,
            P_TABLE => .table,
            P_LCLOSURE, P_CCLOSURE, P_NATIVE => .function,
            P_USERDATA => .userdata,
            P_THREAD => .thread,
            else => unreachable,
        };
    }

    pub inline fn isNil(self: TValue) bool {
        return self.bits == NIL_BITS;
    }

    pub inline fn isDeadKey(self: TValue) bool {
        return self.prefix() == P_NIL and self.bits != NIL_BITS and self.bits != NAN_NEG;
    }

    pub inline fn isBoolean(self: TValue) bool {
        return self.prefix() == P_BOOL;
    }

    pub inline fn isNumber(self: TValue) bool {
        return self.prefix() <= P_BOXINT or self.bits == NAN_NEG;
    }

    /// Integer of either form (inline or boxed)
    pub inline fn isInteger(self: TValue) bool {
        return self.prefix() -% P_INT <= 1;
    }

    /// Inline integer: the form the arithmetic fast paths take
    pub inline fn isInlineInt(self: TValue) bool {
        return self.prefix() == P_INT;
    }

    pub inline fn isBoxedInt(self: TValue) bool {
        return self.prefix() == P_BOXINT;
    }

    pub inline fn isFloat(self: TValue) bool {
        return self.prefix() <= 0xFFF0 or self.bits == NAN_NEG;
    }

    /// Both values are floats other than the negative NaN: the arithmetic
    /// fast-path test, one compare on the larger prefix (a NaN operand
    /// takes the general path)
    pub inline fn bothFloats(x: TValue, y: TValue) bool {
        return @max(x.prefix(), y.prefix()) <= 0xFFF0;
    }

    pub inline fn isString(self: TValue) bool {
        return self.prefix() == P_STRING;
    }

    pub inline fn isTable(self: TValue) bool {
        return self.prefix() == P_TABLE;
    }

    pub inline fn isFunction(self: TValue) bool {
        return self.prefix() -% P_LCLOSURE <= 2;
    }

    pub inline fn isUserdata(self: TValue) bool {
        return self.prefix() == P_USERDATA;
    }

    pub inline fn isLightUserdata(self: TValue) bool {
        return self.prefix() == P_LUD;
    }

    pub inline fn isThread(self: TValue) bool {
        return self.prefix() == P_THREAD;
    }

    /// Check if value is false or nil (Lua falsy values)
    pub inline fn isFalsy(self: TValue) bool {
        return self.bits == NIL_BITS or self.bits == FALSE_BITS;
    }

    /// Check if value is truthy (not false or nil)
    pub inline fn isTruthy(self: TValue) bool {
        return !self.isFalsy();
    }

    /// Compare two TValues for equality
    pub fn equals(self: TValue, other: TValue) bool {
        return self.rawEqual(other);
    }

    // Value extraction

    /// The inline integer payload; the value must be an inline integer
    pub inline fn inlineInt(self: TValue) i64 {
        std.debug.assert(self.isInlineInt());
        return @bitCast(self.bits -% INT_BASE);
    }

    /// The integer payload of either form; the value must be an integer
    pub inline fn integerValue(self: TValue) i64 {
        std.debug.assert(self.isInteger());
        if (self.prefix() == P_INT) return self.inlineInt();
        return self.ptr(*BoxedInt).v;
    }

    /// The box of a boxed integer; the value must be one
    pub inline fn boxedIntObject(self: TValue) *BoxedInt {
        std.debug.assert(self.isBoxedInt());
        return self.ptr(*BoxedInt);
    }

    /// The float payload; the value must be a float
    pub inline fn floatValue(self: TValue) f64 {
        std.debug.assert(self.isFloat());
        return @bitCast(self.bits);
    }

    /// The boolean payload; the value must be a boolean
    pub inline fn booleanValue(self: TValue) bool {
        std.debug.assert(self.isBoolean());
        return self.bits == TRUE_BITS;
    }

    pub fn asBoolean(self: TValue) ?bool {
        return if (self.isBoolean()) self.bits == TRUE_BITS else null;
    }

    /// The number payload as a `Number`; the value must be a number
    pub inline fn numberValue(self: TValue) Number {
        std.debug.assert(self.isNumber());
        return if (self.isInteger()) .{ .integer = self.integerValue() } else .{ .float = self.floatValue() };
    }

    pub fn asNumber(self: TValue) ?Number {
        return if (self.isNumber()) self.numberValue() else null;
    }

    pub fn asInteger(self: TValue) ?i64 {
        if (!self.isNumber()) return null;
        return if (self.isInteger()) self.integerValue() else floatToInteger(self.floatValue());
    }

    pub fn asFloat(self: TValue) ?f64 {
        if (!self.isNumber()) return null;
        return if (self.isInteger()) @as(f64, @floatFromInt(self.integerValue())) else self.floatValue();
    }

    /// The string payload; the value must be a string
    pub inline fn stringValue(self: TValue) *String {
        std.debug.assert(self.isString());
        return self.ptr(*String);
    }

    pub inline fn asString(self: TValue) ?*String {
        return if (self.isString()) self.ptr(*String) else null;
    }

    /// The table payload; the value must be a table
    pub inline fn tableValue(self: TValue) *Table {
        std.debug.assert(self.isTable());
        return self.ptr(*Table);
    }

    pub inline fn asTable(self: TValue) ?*Table {
        return if (self.isTable()) self.ptr(*Table) else null;
    }

    /// The callable payload as a `Function`; the value must be a function
    pub fn functionValue(self: TValue) Function {
        std.debug.assert(self.isFunction());
        return switch (self.prefix()) {
            P_LCLOSURE => .{ .closure = self.ptr(*LClosure) },
            P_CCLOSURE => .{ .cclosure = self.ptr(*CClosure) },
            else => .{ .native_fn = self.ptr(NativeFn) },
        };
    }

    pub fn asFunction(self: TValue) ?Function {
        return if (self.isFunction()) self.functionValue() else null;
    }

    /// Lua closure, if this is one
    /// The Lua closure payload; the value must be one
    pub inline fn closureValue(self: TValue) *LClosure {
        std.debug.assert(self.prefix() == P_LCLOSURE);
        return self.ptr(*LClosure);
    }

    pub inline fn asClosure(self: TValue) ?*LClosure {
        return if (self.prefix() == P_LCLOSURE) self.ptr(*LClosure) else null;
    }

    /// C closure, if this is one
    pub inline fn asCClosure(self: TValue) ?*CClosure {
        return if (self.prefix() == P_CCLOSURE) self.ptr(*CClosure) else null;
    }

    /// Light native function, if this is one
    pub inline fn asNativeFunction(self: TValue) ?NativeFn {
        return if (self.prefix() == P_NATIVE) self.ptr(NativeFn) else null;
    }

    pub fn isLuaFunction(self: TValue) bool {
        return self.prefix() == P_LCLOSURE;
    }

    /// The userdata payload; the value must be a full userdata
    pub inline fn userdataValue(self: TValue) *Userdata {
        std.debug.assert(self.isUserdata());
        return self.ptr(*Userdata);
    }

    pub fn asUserdata(self: TValue) ?*Userdata {
        return if (self.isUserdata()) self.ptr(*Userdata) else null;
    }

    pub fn asLightUserdata(self: TValue) ?LightUserdata {
        return if (self.isLightUserdata()) self.ptr(LightUserdata) else null;
    }

    /// The thread payload; the value must be a thread
    pub inline fn threadValue(self: TValue) *Thread {
        std.debug.assert(self.isThread());
        return self.ptr(*Thread);
    }

    pub fn asThread(self: TValue) ?*Thread {
        return if (self.isThread()) self.ptr(*Thread) else null;
    }

    /// The dead-key marker's object address; the value must be a dead key
    pub inline fn deadKeyObject(self: TValue) *GCObject {
        std.debug.assert(self.isDeadKey());
        return self.ptr(*GCObject);
    }

    /// The payload as an address, for identity comparison and `%p`
    pub inline fn rawPointer(self: TValue) usize {
        return self.payload();
    }

    /// Convert to string representation (for debugging)
    pub fn toString(self: TValue, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.tag()) {
            .nil => try std.fmt.allocPrint(allocator, "nil", .{}),
            .boolean => try std.fmt.allocPrint(allocator, "{}", .{self.booleanValue()}),
            .number => blk: {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                defer aw.deinit();
                try self.numberValue().format(&aw.writer);
                break :blk try aw.toOwnedSlice();
            },
            .string => try std.fmt.allocPrint(allocator, "{s}", .{self.stringValue().slice()}),
            .table => try std.fmt.allocPrint(allocator, "table: 0x{x}", .{self.payload()}),
            .function => if (self.prefix() == P_NATIVE)
                try std.fmt.allocPrint(allocator, "function: builtin: 0x{x}", .{self.payload()})
            else
                try std.fmt.allocPrint(allocator, "function: 0x{x}", .{self.payload()}),
            .light_userdata => try std.fmt.allocPrint(allocator, "userdata: 0x{x}", .{self.payload()}),
            .userdata => try std.fmt.allocPrint(allocator, "userdata: 0x{x}", .{self.payload()}),
            .thread => try std.fmt.allocPrint(allocator, "thread: 0x{x}", .{self.payload()}),
            .deadkey => try std.fmt.allocPrint(allocator, "deadkey: 0x{x}", .{self.payload()}),
            .proto, .upvalue, .lclosure, .cclosure, .boxint => unreachable,
        };
    }

    /// Compare two values for raw equality (no metamethods). Strings compare
    /// by identity here (short strings are interned; long-string contents
    /// are the VM's `equalObj` business), as before.
    pub fn rawEqual(self: TValue, other: TValue) bool {
        if (self.bits == other.bits) {
            // Same bits: equal unless it is a NaN
            return !self.isFloat() or self.floatValue() == self.floatValue();
        }
        if (self.isNumber() and other.isNumber()) {
            // Integer against float, boxed integers, +0.0 against -0.0
            return numbersEqual(self.numberValue(), other.numberValue());
        }
        return false;
    }

    /// Check if value refers to a collectible object (light native
    /// functions and light userdata are not collectible)
    pub fn isGCObject(self: TValue) bool {
        return self.toGCObject() != null;
    }

    /// Get GC object header if value is a GC object
    pub inline fn toGCObject(self: TValue) ?*GCObject {
        // Floats and inline integers, the values most often stored, are
        // every prefix below the boxed integer's: one compare, no switch
        if (self.prefix() < P_BOXINT) return null;
        return switch (self.prefix()) {
            P_STRING => &self.ptr(*String).header,
            P_TABLE => &self.ptr(*Table).header,
            P_LCLOSURE => &self.ptr(*LClosure).header,
            P_CCLOSURE => &self.ptr(*CClosure).header,
            P_USERDATA => &self.ptr(*Userdata).header,
            P_THREAD => &self.ptr(*Thread).header,
            P_BOXINT => &self.ptr(*BoxedInt).header,
            else => null,
        };
    }
};

// Helper functions

/// Convert float to integer if possible
fn floatToInteger(f: f64) ?i64 {
    // The bound has to be tested as `f < 2^63`, not `f <= maxInt(i64)`:
    // maxInt(i64) is not representable as an f64 and rounds up to 2^63, so the
    // inclusive form admits 2^63 itself and @intFromFloat then traps. This is
    // lua_numbertointeger's comparison.
    const min_int = @as(f64, @floatFromInt(std.math.minInt(i64)));
    const two_pow_63 = -min_int;

    if (f >= min_int and f < two_pow_63 and @floor(f) == f) {
        return @intFromFloat(f);
    }
    return null;
}

test "floatToInteger rejects out-of-range values without trapping" {
    const min_int = std.math.minInt(i64);
    const two_pow_63 = -@as(f64, @floatFromInt(min_int));

    try std.testing.expectEqual(@as(?i64, null), floatToInteger(two_pow_63));
    try std.testing.expectEqual(@as(?i64, null), floatToInteger(-two_pow_63 - 2048.0));
    try std.testing.expectEqual(@as(?i64, null), floatToInteger(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, null), floatToInteger(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, null), floatToInteger(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?i64, null), floatToInteger(1.5));

    // minInt is exactly representable, so it stays in range
    try std.testing.expectEqual(@as(?i64, min_int), floatToInteger(-two_pow_63));
    // the largest float below 2^63
    try std.testing.expectEqual(@as(?i64, 9223372036854774784), floatToInteger(two_pow_63 - 1024.0));
    try std.testing.expectEqual(@as(?i64, 0), floatToInteger(0.0));
    try std.testing.expectEqual(@as(?i64, -7), floatToInteger(-7.0));
}

/// Compare numbers (handles int/float comparison)
fn numbersEqual(a: Number, b: Number) bool {
    return switch (a) {
        .integer => |ai| switch (b) {
            .integer => |bi| ai == bi,
            .float => |bf| @as(f64, @floatFromInt(ai)) == bf,
        },
        .float => |af| switch (b) {
            .integer => |bi| af == @as(f64, @floatFromInt(bi)),
            .float => |bf| af == bf,
        },
    };
}

/// Arithmetic operations
pub const ArithOp = enum {
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,
    unm,
    band,
    bor,
    bxor,
    shl,
    shr,
    bnot,
};

// Tests

test "TValue creation and type checking" {
    const testing = std.testing;

    const nil_val = TValue.nil();
    try testing.expect(nil_val.isNil());
    try testing.expect(nil_val.isFalsy());

    const bool_val = TValue.boolean(true);
    try testing.expect(bool_val.isBoolean());
    try testing.expect(bool_val.isTruthy());
    try testing.expect(bool_val.asBoolean().? == true);

    const int_val = TValue.integer(42);
    try testing.expect(int_val.isNumber());
    try testing.expect(int_val.isInteger());
    try testing.expect(int_val.asInteger().? == 42);
    try testing.expect(TValue.integer(-1).inlineInt() == -1);
    try testing.expect(TValue.integer(TValue.INLINE_MIN).inlineInt() == TValue.INLINE_MIN);
    try testing.expect(TValue.integer(TValue.INLINE_MAX).inlineInt() == TValue.INLINE_MAX);
    try testing.expect(TValue.fitsInline(TValue.INLINE_MAX) and !TValue.fitsInline(TValue.INLINE_MAX + 1));
    try testing.expect(TValue.fitsInline(TValue.INLINE_MIN) and !TValue.fitsInline(TValue.INLINE_MIN - 1));
    try testing.expect(!TValue.fitsInline(std.math.maxInt(i64)) and !TValue.fitsInline(std.math.minInt(i64)));
    try testing.expect(TValue.float(std.math.nan(f64)).isFloat());
    try testing.expect(TValue.float(-std.math.nan(f64)).isFloat());
    try testing.expect(TValue.float(-std.math.inf(f64)).isFloat());
    try testing.expect(!TValue.float(std.math.nan(f64)).rawEqual(TValue.float(std.math.nan(f64))));
    try testing.expect(TValue.float(0.0).rawEqual(TValue.float(-0.0)));

    const float_val = TValue.float(3.14);
    try testing.expect(float_val.isNumber());
    try testing.expect(float_val.isFloat());
    try testing.expect(float_val.asFloat().? == 3.14);
}

test "Number conversions" {
    const testing = std.testing;

    const n1 = Number.fromInteger(42);
    try testing.expect(n1.toFloat() == 42.0);
    try testing.expect(n1.toInteger().? == 42);

    const n2 = Number.fromFloat(3.14);
    try testing.expect(n2.toFloat() == 3.14);
    try testing.expect(n2.toInteger() == null);

    const n3 = Number.fromFloat(5.0);
    try testing.expect(n3.toInteger().? == 5);
}

test "Value equality" {
    const testing = std.testing;

    const v1 = TValue.integer(42);
    const v2 = TValue.integer(42);
    const v3 = TValue.float(42.0);
    const v4 = TValue.float(42.1);

    try testing.expect(v1.rawEqual(v2));
    try testing.expect(v1.rawEqual(v3)); // int 42 == float 42.0
    try testing.expect(!v1.rawEqual(v4));
}
