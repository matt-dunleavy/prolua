// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

const std = @import("std");
const lex = @import("lex.zig");

/// Index into the AST node array
pub const NodeIndex = u32;
pub const NodeList = []const NodeIndex;

/// Invalid node index sentinel
pub const INVALID_NODE: NodeIndex = std.math.maxInt(NodeIndex);

/// Interned string index
pub const InternedString = u32;

/// Binary operators
pub const BinaryOp = enum(u8) {
    // Logical
    @"or",
    @"and",

    // Comparison
    less,
    greater,
    less_eq,
    greater_eq,
    not_eq,
    eq_eq,

    // Concatenation
    concat,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    floor_div,
    mod,
    pow,

    // Bitwise
    band,
    bor,
    bxor,
    shl,
    shr,
};

/// Unary operators
pub const UnaryOp = enum(u8) {
    not,
    neg,
    len,
    bnot,
};

/// AST node types
pub const NodeTag = enum(u8) {
    // Literals
    nil_literal,
    bool_literal,
    number_literal,
    integer_literal,
    string_literal,

    // Expressions
    varargs,
    identifier,
    binary_op,
    unary_op,
    table_constructor,
    field_access, // t.field
    index_access, // t[index]
    function_call,
    method_call, // t:method()
    function_expr,
    paren_expr, // (expr): truncates multiple results to one

    // Statements
    block,
    assignment,
    local_assignment,
    local_function,
    function_def,
    return_stmt,
    break_stmt,
    goto_stmt,
    label_stmt,
    if_stmt,
    while_stmt,
    repeat_stmt,
    for_numeric,
    for_generic,
    do_block,
    expression_stmt,

    // Lists (used internally)
    expr_list,
    name_list,
    param_list,
    field_list,
};

/// Get binary operator from token type
pub fn binaryOpFromToken(token: lex.TokenType) ?BinaryOp {
    return switch (token) {
        .kw_or => .@"or",
        .kw_and => .@"and",
        .less => .less,
        .greater => .greater,
        .less_eq => .less_eq,
        .greater_eq => .greater_eq,
        .not_eq => .not_eq,
        .eq_eq => .eq_eq,
        .concat => .concat,
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .floor_div => .floor_div,
        .percent => .mod,
        .caret => .pow,
        .ampersand => .band,
        .pipe => .bor,
        .tilde => .bxor,
        .shift_left => .shl,
        .shift_right => .shr,
        else => null,
    };
}

/// Get unary operator from token type
pub fn unaryOpFromToken(token: lex.TokenType) ?UnaryOp {
    return switch (token) {
        .kw_not => .not,
        .minus => .neg,
        .hash => .len,
        .tilde => .bnot,
        else => null,
    };
}

/// Binary operation node
pub const BinaryOpNode = struct {
    op: BinaryOp,
    left: NodeIndex,
    right: NodeIndex,
};

/// Unary operation node
pub const UnaryOpNode = struct {
    op: UnaryOp,
    operand: NodeIndex,
};

/// Block node (list of statements)
pub const BlockNode = struct {
    statements: NodeList,
    return_stmt: ?NodeIndex = null,
};

/// Assignment node
pub const AssignmentNode = struct {
    targets: NodeList, // Left-hand side expressions
    values: NodeList, // Right-hand side expressions
};

/// Attribute on a local variable: `local x <const>` / `local x <close>`
pub const LocalAttrib = enum(u8) { none, constant, close };

/// Local assignment node
pub const LocalAssignmentNode = struct {
    names: NodeList, // Variable names (identifiers)
    values: NodeList, // Initial values (optional)
    attribs: []const LocalAttrib = &.{}, // One per name when any is present, else empty
};

/// If statement node
pub const IfNode = struct {
    condition: NodeIndex,
    then_block: NodeIndex,
    elseif_parts: NodeList, // List of elseif nodes
    else_block: ?NodeIndex,
    then_line: u32 = 0, // the test is emitted once `then` has been read
};

/// Elseif part of if statement
pub const ElseIfNode = struct {
    condition: NodeIndex,
    block: NodeIndex,
};

/// While loop node
pub const WhileNode = struct {
    condition: NodeIndex,
    block: NodeIndex,
};

/// Repeat-until loop node
pub const RepeatNode = struct {
    block: NodeIndex,
    condition: NodeIndex,
};

/// Numeric for loop node
pub const ForNumericNode = struct {
    var_name: InternedString,
    start: NodeIndex,
    limit: NodeIndex,
    step: ?NodeIndex,
    block: NodeIndex,
    do_line: u32 = 0, // FORPREP is emitted once `do` has been read
};

/// Generic for loop node
pub const ForGenericNode = struct {
    names: NodeList, // Iterator variable names
    exprs: NodeList, // Iterator expressions
    block: NodeIndex,
    do_line: u32 = 0, // TFORPREP is emitted once `do` has been read
    in_line: u32 = 0, // line after `in`: what TFORCALL/TFORLOOP are attributed to
};

/// Function definition node
pub const FunctionDefNode = struct {
    name: ?NodeIndex, // Name (chain of identifiers/field accesses)
    params: NodeList, // Parameter names
    is_vararg: bool,
    is_method: bool = false, // `function a:b()`: implicit `self` first parameter
    block: NodeIndex,
    // Line of the closing `end`: `lastlinedefined`, and the line of the
    // final return and of the CLOSURE instruction
    end_line: u32 = 0,
    // Line of the token after the closing `end`. Lua blames errors it can
    // only detect when a function is complete (an unresolved goto, a break
    // outside any loop) on the lexer's position at that moment, which is here.
    follow_line: u32 = 0,
};

/// Function call node
pub const FunctionCallNode = struct {
    func: NodeIndex, // Function expression
    args: NodeList, // Arguments
};

/// Method call node
pub const MethodCallNode = struct {
    object: NodeIndex, // Object expression
    method: InternedString, // Method name
    args: NodeList, // Arguments
};

/// Table constructor node
pub const TableConstructorNode = struct {
    fields: NodeList, // Field nodes
};

/// Table field types
pub const TableField = union(enum) {
    list: NodeIndex, // List-style field (just expression)
    record: struct { // Record-style field
        key: NodeIndex,
        value: NodeIndex,
    },
};

/// Field access node (t.field)
pub const FieldAccessNode = struct {
    object: NodeIndex,
    field: InternedString,
};

/// Index access node (t[index])
pub const IndexAccessNode = struct {
    object: NodeIndex,
    index: NodeIndex,
};

/// Return statement node
pub const ReturnNode = struct {
    values: NodeList,
};

/// Label statement node
pub const LabelNode = struct {
    name: InternedString,
};

/// Goto statement node
pub const GotoNode = struct {
    label: InternedString,
};

/// AST node data
pub const NodeData = union(NodeTag) {
    // Literals
    nil_literal: void,
    bool_literal: bool,
    number_literal: f64,
    integer_literal: i64,
    string_literal: InternedString,

    // Expressions
    varargs: void,
    identifier: InternedString,
    binary_op: BinaryOpNode,
    unary_op: UnaryOpNode,
    table_constructor: TableConstructorNode,
    field_access: FieldAccessNode,
    index_access: IndexAccessNode,
    function_call: FunctionCallNode,
    method_call: MethodCallNode,
    function_expr: FunctionDefNode,
    paren_expr: NodeIndex,

    // Statements
    block: BlockNode,
    assignment: AssignmentNode,
    local_assignment: LocalAssignmentNode,
    local_function: FunctionDefNode,
    function_def: FunctionDefNode,
    return_stmt: ReturnNode,
    break_stmt: void,
    goto_stmt: GotoNode,
    label_stmt: LabelNode,
    if_stmt: IfNode,
    while_stmt: WhileNode,
    repeat_stmt: RepeatNode,
    for_numeric: ForNumericNode,
    for_generic: ForGenericNode,
    do_block: NodeIndex, // Points to block node
    expression_stmt: NodeIndex, // Points to expression

    // Lists
    expr_list: NodeList,
    name_list: NodeList,
    param_list: NodeList,
    field_list: []const TableField,
};

/// AST node structure
pub const AstNode = struct {
    tag: NodeTag,
    line: u32,
    /// Line of the last token consumed when the construct was complete:
    /// Lua's `ls->lastline`, the line most instructions are attributed to
    last_line: u32 = 0,
    data: NodeData,
};

/// String interning table
pub const StringTable = struct {
    map: std.StringHashMap(InternedString),
    strings: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StringTable {
        return .{
            .map = std.StringHashMap(InternedString).init(allocator),
            .strings = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringTable) void {
        // Free all allocated strings
        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.map.deinit();
        self.strings.deinit(self.allocator);
    }

    pub fn intern(self: *StringTable, str: []const u8) !InternedString {
        if (self.map.get(str)) |id| {
            return id;
        }

        const id: InternedString = @intCast(self.strings.items.len);
        const owned = try self.allocator.dupe(u8, str);
        try self.strings.append(self.allocator, owned);
        try self.map.put(owned, id);
        return id;
    }

    pub fn getString(self: *const StringTable, id: InternedString) []const u8 {
        return self.strings.items[id];
    }
};

/// Complete AST structure
pub const Ast = struct {
    nodes: []AstNode,
    strings: StringTable,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    root: NodeIndex,

    pub fn deinit(self: *Ast) void {
        self.strings.deinit();
        self.allocator.free(self.nodes);
        self.arena.deinit();
    }

    pub fn getNode(self: *const Ast, index: NodeIndex) *const AstNode {
        return &self.nodes[index];
    }

    pub fn getNodeMut(self: *Ast, index: NodeIndex) *AstNode {
        return &self.nodes[index];
    }

    pub fn getString(self: *const Ast, id: InternedString) []const u8 {
        return self.strings.getString(id);
    }
};

/// AST visitor interface
pub const AstVisitor = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        visitNode: *const fn (ctx: *anyopaque, ast: *const Ast, node: NodeIndex) anyerror!void,
    };

    pub fn visit(self: AstVisitor, ast: *const Ast, node: NodeIndex) !void {
        try self.vtable.visitNode(self.context, ast, node);
    }
};

/// Operator precedence levels (higher = tighter binding)
pub const Precedence = enum(u8) {
    none = 0,
    @"or" = 1, // or
    @"and" = 2, // and
    comparison = 3, // < > <= >= ~= ==
    concat = 4, // ..
    bitwise_or = 5, // |
    bitwise_xor = 6, // ~
    bitwise_and = 7, // &
    shift = 8, // << >>
    addition = 9, // + -
    multiplication = 10, // * / // %
    unary = 11, // not # - ~
    power = 12, // ^

    pub fn next(self: Precedence) Precedence {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

/// Get operator precedence
pub fn getOperatorPrecedence(op: BinaryOp) Precedence {
    return switch (op) {
        .@"or" => .@"or",
        .@"and" => .@"and",
        .less, .greater, .less_eq, .greater_eq, .not_eq, .eq_eq => .comparison,
        .concat => .concat,
        .bor => .bitwise_or,
        .bxor => .bitwise_xor,
        .band => .bitwise_and,
        .shl, .shr => .shift,
        .add, .sub => .addition,
        .mul, .div, .floor_div, .mod => .multiplication,
        .pow => .power,
    };
}

/// Check if operator is right associative
pub fn isRightAssociative(op: BinaryOp) bool {
    return switch (op) {
        .pow, .concat => true,
        else => false,
    };
}

// Tests
test "operator precedence" {
    try std.testing.expect(@intFromEnum(Precedence.@"or") < @intFromEnum(Precedence.@"and"));
    try std.testing.expect(@intFromEnum(Precedence.addition) < @intFromEnum(Precedence.multiplication));
    try std.testing.expect(@intFromEnum(Precedence.multiplication) < @intFromEnum(Precedence.power));
}

test "string interning" {
    var table = StringTable.init(std.testing.allocator);
    defer table.deinit();

    const id1 = try table.intern("hello");
    const id2 = try table.intern("world");
    const id3 = try table.intern("hello");

    try std.testing.expect(id1 == id3);
    try std.testing.expect(id1 != id2);
    try std.testing.expectEqualStrings("hello", table.getString(id1));
    try std.testing.expectEqualStrings("world", table.getString(id2));
}

test "binary operator from token conversion" {
    // Test all binary operators
    try std.testing.expect(binaryOpFromToken(.kw_or).? == .@"or");
    try std.testing.expect(binaryOpFromToken(.kw_and).? == .@"and");
    try std.testing.expect(binaryOpFromToken(.less).? == .less);
    try std.testing.expect(binaryOpFromToken(.greater).? == .greater);
    try std.testing.expect(binaryOpFromToken(.less_eq).? == .less_eq);
    try std.testing.expect(binaryOpFromToken(.greater_eq).? == .greater_eq);
    try std.testing.expect(binaryOpFromToken(.not_eq).? == .not_eq);
    try std.testing.expect(binaryOpFromToken(.eq_eq).? == .eq_eq);
    try std.testing.expect(binaryOpFromToken(.concat).? == .concat);
    try std.testing.expect(binaryOpFromToken(.plus).? == .add);
    try std.testing.expect(binaryOpFromToken(.minus).? == .sub);
    try std.testing.expect(binaryOpFromToken(.star).? == .mul);
    try std.testing.expect(binaryOpFromToken(.slash).? == .div);
    try std.testing.expect(binaryOpFromToken(.floor_div).? == .floor_div);
    try std.testing.expect(binaryOpFromToken(.percent).? == .mod);
    try std.testing.expect(binaryOpFromToken(.caret).? == .pow);
    try std.testing.expect(binaryOpFromToken(.ampersand).? == .band);
    try std.testing.expect(binaryOpFromToken(.pipe).? == .bor);
    try std.testing.expect(binaryOpFromToken(.tilde).? == .bxor);
    try std.testing.expect(binaryOpFromToken(.shift_left).? == .shl);
    try std.testing.expect(binaryOpFromToken(.shift_right).? == .shr);

    // Test invalid tokens
    try std.testing.expect(binaryOpFromToken(.kw_if) == null);
    try std.testing.expect(binaryOpFromToken(.identifier) == null);
    try std.testing.expect(binaryOpFromToken(.number) == null);
}

test "unary operator from token conversion" {
    // Test all unary operators
    try std.testing.expect(unaryOpFromToken(.kw_not).? == .not);
    try std.testing.expect(unaryOpFromToken(.minus).? == .neg);
    try std.testing.expect(unaryOpFromToken(.hash).? == .len);
    try std.testing.expect(unaryOpFromToken(.tilde).? == .bnot);

    // Test invalid tokens
    try std.testing.expect(unaryOpFromToken(.plus) == null);
    try std.testing.expect(unaryOpFromToken(.star) == null);
    try std.testing.expect(unaryOpFromToken(.kw_and) == null);
    try std.testing.expect(unaryOpFromToken(.identifier) == null);
}

test "get operator precedence for all binary operators" {
    // Test precedence for each operator
    try std.testing.expect(getOperatorPrecedence(.@"or") == .@"or");
    try std.testing.expect(getOperatorPrecedence(.@"and") == .@"and");

    // All comparison operators have same precedence
    try std.testing.expect(getOperatorPrecedence(.less) == .comparison);
    try std.testing.expect(getOperatorPrecedence(.greater) == .comparison);
    try std.testing.expect(getOperatorPrecedence(.less_eq) == .comparison);
    try std.testing.expect(getOperatorPrecedence(.greater_eq) == .comparison);
    try std.testing.expect(getOperatorPrecedence(.not_eq) == .comparison);
    try std.testing.expect(getOperatorPrecedence(.eq_eq) == .comparison);

    try std.testing.expect(getOperatorPrecedence(.concat) == .concat);
    try std.testing.expect(getOperatorPrecedence(.bor) == .bitwise_or);
    try std.testing.expect(getOperatorPrecedence(.bxor) == .bitwise_xor);
    try std.testing.expect(getOperatorPrecedence(.band) == .bitwise_and);

    // Shift operators
    try std.testing.expect(getOperatorPrecedence(.shl) == .shift);
    try std.testing.expect(getOperatorPrecedence(.shr) == .shift);

    // Addition operators
    try std.testing.expect(getOperatorPrecedence(.add) == .addition);
    try std.testing.expect(getOperatorPrecedence(.sub) == .addition);

    // Multiplication operators
    try std.testing.expect(getOperatorPrecedence(.mul) == .multiplication);
    try std.testing.expect(getOperatorPrecedence(.div) == .multiplication);
    try std.testing.expect(getOperatorPrecedence(.floor_div) == .multiplication);
    try std.testing.expect(getOperatorPrecedence(.mod) == .multiplication);

    try std.testing.expect(getOperatorPrecedence(.pow) == .power);
}

test "operator precedence ordering" {
    // Verify complete precedence ordering
    const precedences = [_]Precedence{
        .none,
        .@"or",
        .@"and",
        .comparison,
        .concat,
        .bitwise_or,
        .bitwise_xor,
        .bitwise_and,
        .shift,
        .addition,
        .multiplication,
        .unary,
        .power,
    };

    // Each precedence should be less than the next
    for (0..precedences.len - 1) |i| {
        try std.testing.expect(@intFromEnum(precedences[i]) < @intFromEnum(precedences[i + 1]));
    }
}

test "precedence next function" {
    try std.testing.expect(Precedence.none.next() == .@"or");
    try std.testing.expect(Precedence.@"or".next() == .@"and");
    try std.testing.expect(Precedence.@"and".next() == .comparison);
    try std.testing.expect(Precedence.comparison.next() == .concat);
    try std.testing.expect(Precedence.concat.next() == .bitwise_or);
    try std.testing.expect(Precedence.bitwise_or.next() == .bitwise_xor);
    try std.testing.expect(Precedence.bitwise_xor.next() == .bitwise_and);
    try std.testing.expect(Precedence.bitwise_and.next() == .shift);
    try std.testing.expect(Precedence.shift.next() == .addition);
    try std.testing.expect(Precedence.addition.next() == .multiplication);
    try std.testing.expect(Precedence.multiplication.next() == .unary);
    try std.testing.expect(Precedence.unary.next() == .power);
}

test "operator associativity" {
    // Test right associative operators
    try std.testing.expect(isRightAssociative(.pow) == true);
    try std.testing.expect(isRightAssociative(.concat) == true);

    // Test left associative operators (all others)
    try std.testing.expect(isRightAssociative(.@"or") == false);
    try std.testing.expect(isRightAssociative(.@"and") == false);
    try std.testing.expect(isRightAssociative(.less) == false);
    try std.testing.expect(isRightAssociative(.greater) == false);
    try std.testing.expect(isRightAssociative(.less_eq) == false);
    try std.testing.expect(isRightAssociative(.greater_eq) == false);
    try std.testing.expect(isRightAssociative(.not_eq) == false);
    try std.testing.expect(isRightAssociative(.eq_eq) == false);
    try std.testing.expect(isRightAssociative(.add) == false);
    try std.testing.expect(isRightAssociative(.sub) == false);
    try std.testing.expect(isRightAssociative(.mul) == false);
    try std.testing.expect(isRightAssociative(.div) == false);
    try std.testing.expect(isRightAssociative(.floor_div) == false);
    try std.testing.expect(isRightAssociative(.mod) == false);
    try std.testing.expect(isRightAssociative(.band) == false);
    try std.testing.expect(isRightAssociative(.bor) == false);
    try std.testing.expect(isRightAssociative(.bxor) == false);
    try std.testing.expect(isRightAssociative(.shl) == false);
    try std.testing.expect(isRightAssociative(.shr) == false);
}

test "string table edge cases" {
    var table = StringTable.init(std.testing.allocator);
    defer table.deinit();

    // Test empty string
    const empty_id = try table.intern("");
    try std.testing.expectEqualStrings("", table.getString(empty_id));

    // Test same empty string returns same ID
    const empty_id2 = try table.intern("");
    try std.testing.expect(empty_id == empty_id2);

    // Test whitespace strings
    const space_id = try table.intern(" ");
    const tab_id = try table.intern("\t");
    const newline_id = try table.intern("\n");
    try std.testing.expect(space_id != tab_id);
    try std.testing.expect(space_id != newline_id);
    try std.testing.expect(tab_id != newline_id);

    // Test Unicode string
    const unicode_id = try table.intern("你好世界");
    try std.testing.expectEqualStrings("你好世界", table.getString(unicode_id));

    // Test long string
    const long_str = "a" ** 1000;
    const long_id = try table.intern(long_str);
    try std.testing.expectEqualStrings(long_str, table.getString(long_id));

    // Test many unique strings
    var ids: std.ArrayList(InternedString) = .empty;
    defer ids.deinit(std.testing.allocator);

    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "string_{}", .{i});
        const id = try table.intern(str);
        try ids.append(std.testing.allocator, id);
    }

    // Verify all IDs are unique
    for (0..ids.items.len) |i| {
        for (i + 1..ids.items.len) |j| {
            try std.testing.expect(ids.items[i] != ids.items[j]);
        }
    }

    // Verify we can retrieve all strings correctly
    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buf, "string_{}", .{i});
        const actual = table.getString(ids.items[i]);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "node tag enum values" {
    // Ensure node tags don't accidentally change values
    // This is important if these values are serialized
    try std.testing.expect(@intFromEnum(NodeTag.nil_literal) == 0);
    try std.testing.expect(@intFromEnum(NodeTag.bool_literal) == 1);
    try std.testing.expect(@intFromEnum(NodeTag.number_literal) == 2);
    try std.testing.expect(@intFromEnum(NodeTag.integer_literal) == 3);
    try std.testing.expect(@intFromEnum(NodeTag.string_literal) == 4);
}

test "binary op enum values" {
    // Ensure binary op values are stable
    try std.testing.expect(@intFromEnum(BinaryOp.@"or") == 0);
    try std.testing.expect(@intFromEnum(BinaryOp.@"and") == 1);
    try std.testing.expect(@intFromEnum(BinaryOp.less) == 2);
    try std.testing.expect(@intFromEnum(BinaryOp.pow) == 15);
    try std.testing.expect(@intFromEnum(BinaryOp.shr) == 20);
}

test "unary op enum values" {
    // Ensure unary op values are stable
    try std.testing.expect(@intFromEnum(UnaryOp.not) == 0);
    try std.testing.expect(@intFromEnum(UnaryOp.neg) == 1);
    try std.testing.expect(@intFromEnum(UnaryOp.len) == 2);
    try std.testing.expect(@intFromEnum(UnaryOp.bnot) == 3);
}

test "invalid node constant" {
    // Ensure INVALID_NODE is max value
    try std.testing.expect(INVALID_NODE == std.math.maxInt(NodeIndex));
}

test "ast node data size" {
    // Ensure node data union isn't too large
    // This helps catch accidental size regressions
    const size = @sizeOf(NodeData);
    try std.testing.expect(size <= 64); // Three slices (local attributes) plus the tag
}

test "string table concurrent interning" {
    // Test that interning the same strings in different orders produces same IDs
    var table1 = StringTable.init(std.testing.allocator);
    defer table1.deinit();

    var table2 = StringTable.init(std.testing.allocator);
    defer table2.deinit();

    // Intern in different orders
    const a1 = try table1.intern("alpha");
    const b1 = try table1.intern("beta");
    const c1 = try table1.intern("gamma");

    const c2 = try table2.intern("gamma");
    const b2 = try table2.intern("beta");
    const a2 = try table2.intern("alpha");

    // Same strings should have same relative ordering within each table
    try std.testing.expect(a1 < b1);
    try std.testing.expect(b1 < c1);
    try std.testing.expect(a2 > b2);
    try std.testing.expect(b2 > c2);

    // Verify strings are correct
    try std.testing.expectEqualStrings("alpha", table1.getString(a1));
    try std.testing.expectEqualStrings("beta", table1.getString(b1));
    try std.testing.expectEqualStrings("gamma", table1.getString(c1));
    try std.testing.expectEqualStrings("alpha", table2.getString(a2));
    try std.testing.expectEqualStrings("beta", table2.getString(b2));
    try std.testing.expectEqualStrings("gamma", table2.getString(c2));
}
