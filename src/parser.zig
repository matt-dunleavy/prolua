// Copyright (c) 2024-2026 Matt Dunleavy.
// This software is distributed under the MIT license.
// See LICENSE file for details.

//! A Recursive-descent parser producing the AST

const std = @import("std");
const lex = @import("lex.zig");
const ast = @import("ast.zig");
const config = @import("config.zig");

/// Parser errors (includes lexer errors that can propagate)
pub const ParseError = error{
    /// A syntax error; the message is in `Parser.errors`
    SyntaxError,
    OutOfMemory,

    // Lexer errors that can propagate (the message is recorded too)
    UnfinishedString,
    UnfinishedLongString,
    UnfinishedLongComment,
    MalformedNumber,
    DecimalEscapeTooLarge,
    InvalidEscapeSequence,
    InvalidLongStringDelimiter,
    HexadecimalDigitExpected,
    MissingBrace,
    UTF8ValueTooLarge,
    UnexpectedCharacter,
    ChunkHasTooManyLines,
    LexicalElementTooLong,
};

/// Error information
pub const ErrorInfo = struct {
    msg: []const u8,
    line: u32,
    column: u32,
    /// Whether the message is reported with a "chunk:line:" prefix. The
    /// nesting-limit error is not: the reference raises it as a runtime
    /// error from inside `load`, which has no position.
    positioned: bool = true,
};

/// Parser state
pub const Parser = struct {
    lexer: *lex.LexState,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(ast.AstNode),
    node_lists: std.ArrayList(ast.NodeIndex),
    strings: ast.StringTable,
    errors: std.ArrayList(ErrorInfo),

    // Current token (cached from lexer)
    current_token: lex.Token,
    current_line: u32,
    current_column: u32,
    prev_line: u32 = 1, // line of the last consumed token (Lua's `lastline`)

    /// Recursion depth of the parser, counted where `lparser.c` calls
    /// `enterlevel` (statements, sub-expressions, assignment targets). The
    /// caller seeds it with the thread's C-call depth, so the limit falls
    /// where the reference's `LUAI_MAXCCALLS` does.
    level: u32 = 0,
    /// Locals declared so far in the current function (Lua's
    /// `actvar.n - firstlocal`), checked against `MAXVARS`; blocks and
    /// functions restore it on exit
    nactvar: u32 = 0,
    /// `linedefined` of the current function, 0 for the main chunk
    func_line: u32 = 0,

    const MAX_LEVEL: u32 = config.MAXCCALLS;

    /// Initialize parser
    pub fn init(lexer: *lex.LexState, allocator: std.mem.Allocator) !Parser {
        var parser = Parser{
            .lexer = lexer,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .nodes = .empty,
            .node_lists = .empty,
            .strings = ast.StringTable.init(allocator),
            .errors = .empty,
            .current_token = undefined,
            .current_line = 1,
            .current_column = 1,
        };

        // Prime the parser with first token
        try parser.advance();
        return parser;
    }

    /// Deinitialize parser
    pub fn deinit(self: *Parser) void {
        self.errors.deinit(self.allocator);
        self.node_lists.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        // Don't deinit strings here - ownership is transferred to AST
        // self.strings.deinit();
        // Don't deinit arena here - ownership is transferred to AST
        // self.arena.deinit();
    }

    /// Get the arena allocator for AST allocations
    fn arenaAllocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// Add an error to the error list
    fn addError(self: *Parser, msg: []const u8) void {
        self.errors.append(self.allocator, .{
            .msg = msg,
            .line = self.current_line,
            .column = self.current_column,
        }) catch {}; // Ignore allocation failures in error reporting
    }

    /// How a token type is written in an "expected" message (luaX_token2str):
    /// symbols and reserved words are quoted, the `<...>` classes are not.
    fn tokenName(tok: lex.TokenType, buf: []u8) []const u8 {
        const s = lex.tokenToString(tok);
        return switch (tok) {
            .eof, .number, .integer, .identifier, .string => s,
            else => std.fmt.bufPrint(buf, "'{s}'", .{s}) catch s,
        };
    }

    /// The current token as it appears after "near" (txtToken). Names,
    /// strings and numerals show their own text, taken from the lexer's
    /// buffer, which still holds the token just read.
    fn currentTokenText(self: *Parser, buf: []u8) []const u8 {
        return switch (self.current_token.token_type) {
            .identifier, .string, .number, .integer => std.fmt.bufPrint(buf, "'{s}'", .{lex.LexState.cString(self.lexer.buff.slice())}) catch "'?'",
            // a byte that is no token: quoted if printable, else as <\ddd> (luaX_token2str)
            .unknown => if (std.ascii.isPrint(self.lexer.unknown_char))
                std.fmt.bufPrint(buf, "'{c}'", .{self.lexer.unknown_char}) catch "'?'"
            else
                std.fmt.bufPrint(buf, "'<\\{d}>'", .{self.lexer.unknown_char}) catch "'?'",
            else => |t| tokenName(t, buf),
        };
    }

    /// Report a syntax error at the current token (luaX_syntaxerror)
    fn syntaxError(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        var tokbuf: [128]u8 = undefined;
        // lexerror adds "near" only `if (token)`: a NUL byte token gets none
        if (self.current_token.token_type == .unknown and self.lexer.unknown_char == 0) {
            const bare = std.fmt.allocPrint(self.arenaAllocator(), fmt, args) catch "syntax error";
            self.addError(bare);
            return error.SyntaxError;
        }
        const near = self.currentTokenText(&tokbuf);
        const msg = std.fmt.allocPrint(self.arenaAllocator(), fmt ++ " near {s}", args ++ .{near}) catch "syntax error";
        self.addError(msg);
        return error.SyntaxError;
    }

    /// Report an error that is not about the current token, so no "near"
    /// part is added (luaK_semerror)
    fn semError(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        const msg = std.fmt.allocPrint(self.arenaAllocator(), fmt, args) catch "syntax error";
        self.addError(msg);
        return error.SyntaxError;
    }

    /// "'x' expected" (error_expected)
    fn errorExpected(self: *Parser, tok: lex.TokenType) ParseError {
        var buf: [32]u8 = undefined;
        return self.syntaxError("{s} expected", .{tokenName(tok, &buf)});
    }

    /// One more level of recursion (enterlevel / luaE_incCstack). At the
    /// limit the reference raises "C stack overflow" as a runtime error,
    /// with no chunk name, line or "near" part.
    fn enterLevel(self: *Parser) ParseError!void {
        self.level += 1;
        if (self.level >= MAX_LEVEL) {
            self.errors.append(self.allocator, .{
                .msg = "C stack overflow",
                .line = self.current_line,
                .column = self.current_column,
                .positioned = false,
            }) catch {};
            return error.SyntaxError;
        }
    }

    fn leaveLevel(self: *Parser) void {
        self.level -= 1;
    }

    /// Register `n` more local variables of the current function
    /// (new_localvar). The limit counts everything declared in the function
    /// so far, including the names of the statement being parsed, and the
    /// error names the current token, as the reference's one-pass parser
    /// does.
    fn newLocals(self: *Parser, n: u32) ParseError!void {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (self.nactvar + 1 > config.MAXVARS) {
                if (self.func_line == 0) return self.syntaxError("too many local variables (limit is {d}) in main function", .{config.MAXVARS});
                return self.syntaxError("too many local variables (limit is {d}) in function at line {d}", .{ config.MAXVARS, self.func_line });
            }
            self.nactvar += 1;
        }
    }

    /// Record the lexer's error in Lua's wording, then pass it on
    fn lexError(self: *Parser, err: anyerror) ParseError {
        var buf: [256]u8 = undefined;
        const text = self.lexer.errorMessage(&buf);
        const msg = self.arenaAllocator().dupe(u8, text) catch text;
        // The lexer's line is where the error is, not where the last good
        // token was
        self.current_line = @intCast(self.lexer.getCurrentLine());
        self.addError(msg);
        return @errorCast(err);
    }

    // ------------------------------------------------------------------
    // Token handling
    // ------------------------------------------------------------------

    /// Advance to next token
    fn advance(self: *Parser) ParseError!void {
        self.prev_line = self.current_line;
        self.lexer.next() catch |err| return self.lexError(err);
        // Record the position of the token just read, so errors and node
        // positions refer to the current token rather than the previous one.
        self.current_line = @intCast(self.lexer.getCurrentLine());
        self.current_column = @intCast(self.lexer.getCurrentColumn());
        self.current_token = .{
            .token_type = self.lexer.getCurrentToken(),
            .seminfo = self.lexer.getCurrentSeminfo(),
            .line = self.lexer.getCurrentLine(),
            .column = self.lexer.getCurrentColumn(),
        };
    }

    /// Check if current token matches expected type
    fn check(self: *Parser, token_type: lex.TokenType) bool {
        return self.current_token.token_type == token_type;
    }

    /// Consume the current token, which must be `tok` (checknext)
    fn expect(self: *Parser, tok: lex.TokenType) ParseError!void {
        if (!self.check(tok)) return self.errorExpected(tok);
        try self.advance();
    }

    /// Consume the closing token `what` of a construct opened by `who` on
    /// line `where_line`, naming the opener when it is on another line
    /// (check_match)
    fn checkMatch(self: *Parser, what: lex.TokenType, who: lex.TokenType, where_line: u32) ParseError!void {
        if (!self.check(what)) {
            if (where_line == self.current_line) return self.errorExpected(what);
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            return self.syntaxError("{s} expected (to close {s} at line {d})", .{ tokenName(what, &b1), tokenName(who, &b2), where_line });
        }
        try self.advance();
    }

    /// Try to consume a token, return true if consumed
    fn tryConsume(self: *Parser, token_type: lex.TokenType) ParseError!bool {
        if (self.check(token_type)) {
            try self.advance();
            return true;
        }
        return false;
    }

    /// Allocate a new AST node
    fn allocNode(self: *Parser, node: ast.AstNode) ParseError!ast.NodeIndex {
        const index = @as(ast.NodeIndex, @intCast(self.nodes.items.len));
        var n = node;
        n.last_line = self.prev_line; // nodes are made once their last token is consumed
        try self.nodes.append(self.allocator, n);
        return index;
    }

    /// Allocate a node list
    fn allocNodeList(self: *Parser, items: []const ast.NodeIndex) ParseError!ast.NodeList {
        if (items.len == 0) return &[_]ast.NodeIndex{};
        // Each list is its own arena allocation: it lives as long as the AST
        // and is never invalidated by later lists (a growable buffer would be).
        return try self.arenaAllocator().dupe(ast.NodeIndex, items);
    }

    /// An identifier node for the current token, which must be a name
    fn nameNode(self: *Parser) ParseError!ast.NodeIndex {
        const line = self.current_line;
        const name = try self.parseIdentifier();
        return self.allocNode(.{
            .tag = .identifier,
            .line = line,
            .data = .{ .identifier = name },
        });
    }

    // ------------------------------------------------------------------
    // Chunks, blocks and statements
    // ------------------------------------------------------------------

    /// Parse a complete source file (chunk in Lua terms)
    pub fn parse(self: *Parser) ParseError!ast.Ast {
        const root = try self.parseBlock();

        // Only the end of the input may follow the main block
        if (!self.check(.eof)) return self.errorExpected(.eof);

        // Build final AST
        const nodes = try self.allocator.dupe(ast.AstNode, self.nodes.items);

        return ast.Ast{
            .nodes = nodes,
            .strings = self.strings,
            .allocator = self.allocator,
            .arena = self.arena,
            .root = root,
        };
    }

    /// Parse a block of statements (statlist). Stops at a token that ends a
    /// block; the caller decides whether that token was the right one.
    fn parseBlock(self: *Parser) ParseError!ast.NodeIndex {
        const saved_nactvar = self.nactvar; // the block's locals end with it
        defer self.nactvar = saved_nactvar;
        var statements: std.ArrayList(ast.NodeIndex) = .empty;
        defer statements.deinit(self.arenaAllocator());

        var return_stmt: ?ast.NodeIndex = null;
        while (!self.isBlockEnd()) {
            // Skip semicolons (optional statement separators)
            if (try self.tryConsume(.semicolon)) continue;

            // A return must be the last statement of its block
            if (self.check(.kw_return)) {
                return_stmt = try self.parseReturn();
                break;
            }

            const stmt = try self.parseStatement();
            try statements.append(self.arenaAllocator(), stmt);
        }

        const stmt_list = try self.allocNodeList(statements.items);

        return self.allocNode(.{
            .tag = .block,
            .line = self.current_line,
            .data = .{ .block = .{
                .statements = stmt_list,
                .return_stmt = return_stmt,
            } },
        });
    }

    /// Check if we're at the end of a block (block_follow with `until`)
    fn isBlockEnd(self: *Parser) bool {
        return switch (self.current_token.token_type) {
            .kw_else, .kw_elseif, .kw_end, .kw_until, .eof => true,
            else => false,
        };
    }

    /// Parse a statement
    fn parseStatement(self: *Parser) ParseError!ast.NodeIndex {
        try self.enterLevel();
        defer self.leaveLevel();
        switch (self.current_token.token_type) {
            .kw_if => return self.parseIf(),
            .kw_while => return self.parseWhile(),
            .kw_do => return self.parseDo(),
            .kw_for => return self.parseFor(),
            .kw_repeat => return self.parseRepeat(),
            .kw_function => return self.parseFunctionDef(),
            .kw_local => return self.parseLocal(),
            .kw_break => return self.parseBreak(),
            .kw_goto => return self.parseGoto(),
            .label_delim => return self.parseLabel(),
            else => return self.parseExprStat(),
        }
    }

    /// Parse if statement
    fn parseIf(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'if'

        const condition = try self.parseExpression();
        const then_line = self.current_line;
        try self.expect(.kw_then);

        const then_block = try self.parseBlock();

        var elseif_parts: std.ArrayList(ast.NodeIndex) = .empty;
        defer elseif_parts.deinit(self.arenaAllocator());

        // Handle elseif parts
        while (self.check(.kw_elseif)) {
            const elseif_line = self.current_line;
            try self.advance();

            const elseif_cond = try self.parseExpression();
            const elseif_then_line = self.current_line;
            try self.expect(.kw_then);
            const elseif_block = try self.parseBlock();

            // Store as a special node that parseIf knows about
            const elseif_node = try self.allocNode(.{
                .tag = .if_stmt, // Reuse if_stmt with special marking
                .line = elseif_line,
                .data = .{ .if_stmt = .{
                    .condition = elseif_cond,
                    .then_block = elseif_block,
                    .elseif_parts = &[_]ast.NodeIndex{},
                    .else_block = null,
                    .then_line = elseif_then_line,
                } },
            });
            try elseif_parts.append(self.arenaAllocator(), elseif_node);
        }

        // Handle else part
        var else_block: ?ast.NodeIndex = null;
        if (self.check(.kw_else)) {
            try self.advance();
            else_block = try self.parseBlock();
        }

        try self.checkMatch(.kw_end, .kw_if, start_line);

        const elseif_list = try self.allocNodeList(elseif_parts.items);

        return self.allocNode(.{
            .tag = .if_stmt,
            .line = start_line,
            .data = .{ .if_stmt = .{
                .condition = condition,
                .then_block = then_block,
                .elseif_parts = elseif_list,
                .else_block = else_block,
                .then_line = then_line,
            } },
        });
    }

    /// Parse while statement
    fn parseWhile(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'while'

        const condition = try self.parseExpression();
        try self.expect(.kw_do);

        const block = try self.parseBlock();
        try self.checkMatch(.kw_end, .kw_while, start_line);

        return self.allocNode(.{
            .tag = .while_stmt,
            .line = start_line,
            .data = .{ .while_stmt = .{
                .condition = condition,
                .block = block,
            } },
        });
    }

    /// Parse do block
    fn parseDo(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'do'

        const block = try self.parseBlock();
        try self.checkMatch(.kw_end, .kw_do, start_line);

        return self.allocNode(.{
            .tag = .do_block,
            .line = start_line,
            .data = .{ .do_block = block },
        });
    }

    /// Parse for statement (both numeric and generic)
    fn parseFor(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'for'

        const first_name = try self.parseIdentifier();

        // The hidden "(for state)" locals and the loop names belong to the
        // loop block (fornum / forlist)
        const saved_nactvar = self.nactvar;
        defer self.nactvar = saved_nactvar;

        switch (self.current_token.token_type) {
            .eq => {
                // Numeric for
                try self.newLocals(3 + 1);
                try self.advance();
                const start_exp = try self.parseExpression();
                try self.expect(.comma);
                const limit = try self.parseExpression();

                var step: ?ast.NodeIndex = null;
                if (try self.tryConsume(.comma)) {
                    step = try self.parseExpression();
                }

                const do_line = self.current_line;
                try self.expect(.kw_do);
                const block = try self.parseBlock();
                try self.checkMatch(.kw_end, .kw_for, start_line);

                return self.allocNode(.{
                    .tag = .for_numeric,
                    .line = start_line,
                    .data = .{ .for_numeric = .{
                        .var_name = first_name,
                        .start = start_exp,
                        .limit = limit,
                        .step = step,
                        .block = block,
                        .do_line = do_line,
                    } },
                });
            },
            .comma, .kw_in => {
                // Generic for - collect all names
                try self.newLocals(4 + 1);
                var names: std.ArrayList(ast.NodeIndex) = .empty;
                defer names.deinit(self.arenaAllocator());

                const name_node = try self.allocNode(.{
                    .tag = .identifier,
                    .line = start_line,
                    .data = .{ .identifier = first_name },
                });
                try names.append(self.arenaAllocator(), name_node);

                while (try self.tryConsume(.comma)) {
                    try names.append(self.arenaAllocator(), try self.nameNode());
                    try self.newLocals(1);
                }

                try self.expect(.kw_in);
                const in_line = self.current_line;

                var exprs: std.ArrayList(ast.NodeIndex) = .empty;
                defer exprs.deinit(self.arenaAllocator());
                try self.parseExprList(&exprs);

                const do_line = self.current_line;
                try self.expect(.kw_do);
                const block = try self.parseBlock();
                try self.checkMatch(.kw_end, .kw_for, start_line);

                const name_list = try self.allocNodeList(names.items);
                const expr_list = try self.allocNodeList(exprs.items);

                return self.allocNode(.{
                    .tag = .for_generic,
                    .line = start_line,
                    .data = .{ .for_generic = .{
                        .names = name_list,
                        .exprs = expr_list,
                        .block = block,
                        .do_line = do_line,
                        .in_line = in_line,
                    } },
                });
            },
            else => return self.syntaxError("'=' or 'in' expected", .{}),
        }
    }

    /// Parse repeat-until statement
    fn parseRepeat(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'repeat'

        const block = try self.parseBlock();
        try self.checkMatch(.kw_until, .kw_repeat, start_line);

        const condition = try self.parseExpression();

        return self.allocNode(.{
            .tag = .repeat_stmt,
            .line = start_line,
            .data = .{ .repeat_stmt = .{
                .block = block,
                .condition = condition,
            } },
        });
    }

    /// Parse function definition
    fn parseFunctionDef(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'function'

        // Parse function name (can be a chain like foo.bar.baz:method)
        var is_method = false;
        const name = try self.parseFunctionName(&is_method);

        const func = try self.parseFunctionBody(name, start_line, is_method);
        if (is_method) self.nodes.items[func].data.function_def.is_method = true;
        return func;
    }

    /// Parse function name (handles table.field.method:name syntax)
    fn parseFunctionName(self: *Parser, is_method: *bool) ParseError!ast.NodeIndex {
        var name = try self.nameNode();

        // Handle field accesses
        while (self.check(.dot)) {
            try self.advance();
            const field = try self.parseIdentifier();

            name = try self.allocNode(.{
                .tag = .field_access,
                .line = self.current_line,
                .data = .{ .field_access = .{
                    .object = name,
                    .field = field,
                } },
            });
        }

        // Handle method syntax (colon): recorded on the function node so the
        // compiler adds the implicit `self` parameter
        if (self.check(.colon)) {
            try self.advance();
            const method = try self.parseIdentifier();
            is_method.* = true;

            name = try self.allocNode(.{
                .tag = .field_access,
                .line = self.current_line,
                .data = .{ .field_access = .{
                    .object = name,
                    .field = method,
                } },
            });
        }

        return name;
    }

    /// Parse function body (parameters and block)
    fn parseFunctionBody(self: *Parser, name: ?ast.NodeIndex, start_line: u32, is_method: bool) ParseError!ast.NodeIndex {
        const saved_nactvar = self.nactvar;
        const saved_func_line = self.func_line;
        self.nactvar = 0;
        self.func_line = start_line;
        defer {
            self.nactvar = saved_nactvar;
            self.func_line = saved_func_line;
        }
        if (is_method) try self.newLocals(1); // 'self'
        try self.expect(.lparen);

        // Parse parameters (parlist)
        var params: std.ArrayList(ast.NodeIndex) = .empty;
        defer params.deinit(self.arenaAllocator());

        var is_vararg = false;

        if (!self.check(.rparen)) {
            while (true) {
                switch (self.current_token.token_type) {
                    .identifier => {
                        try params.append(self.arenaAllocator(), try self.nameNode());
                        try self.newLocals(1);
                    },
                    .varargs => {
                        try self.advance();
                        is_vararg = true;
                    },
                    else => return self.syntaxError("<name> or '...' expected", .{}),
                }
                if (is_vararg or !try self.tryConsume(.comma)) break;
            }
        }

        try self.expect(.rparen);

        // Parse body
        const body = try self.parseBlock();
        const end_line = self.current_line; // the line of the `end` itself
        try self.checkMatch(.kw_end, .kw_function, start_line);
        const follow_line = self.current_line; // where the lexer is once `end` is read

        const param_list = try self.allocNodeList(params.items);

        return self.allocNode(.{
            .tag = .function_def,
            .line = start_line,
            .data = .{ .function_def = .{
                .name = name,
                .params = param_list,
                .is_vararg = is_vararg,
                .block = body,
                .end_line = end_line,
                .follow_line = follow_line,
            } },
        });
    }

    /// Parse local statement (variable or function)
    fn parseLocal(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'local'

        if (try self.tryConsume(.kw_function)) {
            // Local function
            const name_node = try self.nameNode();
            try self.newLocals(1); // the function's own name is a local (localfunc)
            const func = try self.parseFunctionBody(name_node, start_line, false);

            // Retag as local_function (union tag and payload together)
            const func_node = &self.nodes.items[func];
            const def = func_node.data.function_def;
            func_node.* = .{ .tag = .local_function, .line = func_node.line, .last_line = func_node.last_line, .data = .{ .local_function = def } };

            return func;
        }

        // Local variables, each with an optional attribute (localstat)
        var names: std.ArrayList(ast.NodeIndex) = .empty;
        defer names.deinit(self.arenaAllocator());
        var attribs: std.ArrayList(ast.LocalAttrib) = .empty;
        defer attribs.deinit(self.arenaAllocator());
        var any_attrib = false;
        var has_close = false;

        while (true) {
            try names.append(self.arenaAllocator(), try self.nameNode());
            try self.newLocals(1);
            const attrib = try self.parseLocalAttrib();
            if (attrib != .none) any_attrib = true;
            if (attrib == .close) {
                if (has_close) return self.semError("multiple to-be-closed variables in local list", .{});
                has_close = true;
            }
            try attribs.append(self.arenaAllocator(), attrib);
            if (!try self.tryConsume(.comma)) break;
        }

        // Parse optional initializers
        var values: std.ArrayList(ast.NodeIndex) = .empty;
        defer values.deinit(self.arenaAllocator());

        if (try self.tryConsume(.eq)) {
            try self.parseExprList(&values);
        }

        const name_list = try self.allocNodeList(names.items);
        const value_list = try self.allocNodeList(values.items);
        const attrib_list: []const ast.LocalAttrib = if (any_attrib)
            try self.arenaAllocator().dupe(ast.LocalAttrib, attribs.items)
        else
            &.{};

        return self.allocNode(.{
            .tag = .local_assignment,
            .line = start_line,
            .data = .{ .local_assignment = .{
                .names = name_list,
                .values = value_list,
                .attribs = attrib_list,
            } },
        });
    }

    /// `< const >` or `< close >` after a local name (getlocalattribute).
    /// `const` and `close` are not reserved words; they only mean something
    /// between the angle brackets.
    fn parseLocalAttrib(self: *Parser) ParseError!ast.LocalAttrib {
        if (!try self.tryConsume(.less)) return .none;
        const name = try self.parseIdentifier();
        try self.expect(.greater);
        const text = self.strings.getString(name);
        if (std.mem.eql(u8, text, "const")) return .constant;
        if (std.mem.eql(u8, text, "close")) return .close;
        return self.semError("unknown attribute '{s}'", .{text});
    }

    /// Parse return statement
    fn parseReturn(self: *Parser) ParseError!ast.NodeIndex {
        // `statlist` reaches `retstat` through `statement`, so it is a level
        try self.enterLevel();
        defer self.leaveLevel();
        const start_line = self.current_line;
        try self.advance(); // skip 'return'

        var values: std.ArrayList(ast.NodeIndex) = .empty;
        defer values.deinit(self.arenaAllocator());

        // Return can have zero or more expressions
        if (!self.isBlockEnd() and !self.check(.semicolon)) {
            try self.parseExprList(&values);
        }
        _ = try self.tryConsume(.semicolon); // optional semicolon after return

        const value_list = try self.allocNodeList(values.items);

        return self.allocNode(.{
            .tag = .return_stmt,
            .line = start_line,
            .data = .{ .return_stmt = .{ .values = value_list } },
        });
    }

    /// Parse break statement. Whether it is inside a loop is decided by the
    /// compiler, which resolves it as a goto (and reports it as Lua does).
    fn parseBreak(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'break'

        return self.allocNode(.{
            .tag = .break_stmt,
            .line = start_line,
            .data = .{ .break_stmt = {} },
        });
    }

    /// Parse goto statement
    fn parseGoto(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip 'goto'

        const label = try self.parseIdentifier();

        return self.allocNode(.{
            .tag = .goto_stmt,
            .line = start_line,
            .data = .{ .goto_stmt = .{ .label = label } },
        });
    }

    /// Parse label statement
    fn parseLabel(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.advance(); // skip '::'

        const label = try self.parseIdentifier();
        try self.expect(.label_delim);

        // Lua records a label's line after reading the token that follows
        // it, and that is the line its diagnostics quote
        _ = start_line;
        return self.allocNode(.{
            .tag = .label_stmt,
            .line = self.current_line,
            .data = .{ .label_stmt = .{ .name = label } },
        });
    }

    /// Whether a node can be assigned to (vkisvar)
    fn isAssignable(self: *Parser, idx: ast.NodeIndex) bool {
        return switch (self.nodes.items[idx].tag) {
            .identifier, .field_access, .index_access => true,
            else => false,
        };
    }

    /// Parse assignment or expression statement (exprstat / restassign)
    fn parseExprStat(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;

        const first_expr = try self.parseSuffixedExp();

        if (self.check(.eq) or self.check(.comma)) {
            // Assignment: every target must be a variable
            var targets: std.ArrayList(ast.NodeIndex) = .empty;
            defer targets.deinit(self.arenaAllocator());

            if (!self.isAssignable(first_expr)) return self.syntaxError("syntax error", .{});
            try targets.append(self.arenaAllocator(), first_expr);

            // `restassign` is recursive in the reference, one level per
            // extra target, so the nesting limit applies here too
            var extra: u32 = 0;
            defer self.level -= extra;
            while (try self.tryConsume(.comma)) {
                try self.enterLevel();
                extra += 1;
                const target = try self.parseSuffixedExp();
                if (!self.isAssignable(target)) return self.syntaxError("syntax error", .{});
                try targets.append(self.arenaAllocator(), target);
            }

            try self.expect(.eq);

            var values: std.ArrayList(ast.NodeIndex) = .empty;
            defer values.deinit(self.arenaAllocator());
            try self.parseExprList(&values);

            const target_list = try self.allocNodeList(targets.items);
            const value_list = try self.allocNodeList(values.items);

            return self.allocNode(.{
                .tag = .assignment,
                .line = start_line,
                .data = .{ .assignment = .{
                    .targets = target_list,
                    .values = value_list,
                } },
            });
        }

        // Otherwise the expression must be a call
        const tag = self.nodes.items[first_expr].tag;
        if (tag != .function_call and tag != .method_call) {
            return self.syntaxError("syntax error", .{});
        }

        return self.allocNode(.{
            .tag = .expression_stmt,
            .line = start_line,
            .data = .{ .expression_stmt = first_expr },
        });
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    /// `exp {, exp}` into `out` (explist)
    fn parseExprList(self: *Parser, out: *std.ArrayList(ast.NodeIndex)) ParseError!void {
        try out.append(self.arenaAllocator(), try self.parseExpression());
        while (try self.tryConsume(.comma)) {
            try out.append(self.arenaAllocator(), try self.parseExpression());
        }
    }

    /// Parse expression using Pratt parsing
    fn parseExpression(self: *Parser) ParseError!ast.NodeIndex {
        return self.parseExpressionPrec(0);
    }

    /// Parse expression with minimum precedence (subexpr)
    fn parseExpressionPrec(self: *Parser, min_prec: u8) ParseError!ast.NodeIndex {
        try self.enterLevel(); // subexpr
        defer self.leaveLevel();
        var left: ast.NodeIndex = undefined;

        if (ast.unaryOpFromToken(self.current_token.token_type)) |op| {
            const start_line = self.current_line;
            try self.advance();
            const operand = try self.parseExpressionPrec(@intFromEnum(ast.Precedence.unary));
            left = try self.allocNode(.{
                .tag = .unary_op,
                .line = start_line,
                .data = .{ .unary_op = .{
                    .op = op,
                    .operand = operand,
                } },
            });
        } else {
            left = try self.parseSimpleExp();
        }

        // Parse infix operators
        while (true) {
            const op_token = self.current_token.token_type;
            const bin_op = ast.binaryOpFromToken(op_token) orelse break;

            const prec = @intFromEnum(ast.getOperatorPrecedence(bin_op));
            if (prec < min_prec) break;

            const op_line = self.current_line; // the operation is attributed to its operator
            try self.advance(); // consume operator

            // Handle right associativity
            const next_min_prec = if (ast.isRightAssociative(bin_op))
                prec
            else
                prec + 1;

            const right = try self.parseExpressionPrec(@intCast(next_min_prec));

            left = try self.allocNode(.{
                .tag = .binary_op,
                .line = op_line,
                .data = .{ .binary_op = .{
                    .op = bin_op,
                    .left = left,
                    .right = right,
                } },
            });
        }

        return left;
    }

    /// Literals, constructors and function expressions, or a suffixed
    /// expression (simpleexp)
    fn parseSimpleExp(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;

        switch (self.current_token.token_type) {
            .kw_nil => {
                try self.advance();
                return self.allocNode(.{
                    .tag = .nil_literal,
                    .line = start_line,
                    .data = .{ .nil_literal = {} },
                });
            },

            .kw_true => {
                try self.advance();
                return self.allocNode(.{
                    .tag = .bool_literal,
                    .line = start_line,
                    .data = .{ .bool_literal = true },
                });
            },

            .kw_false => {
                try self.advance();
                return self.allocNode(.{
                    .tag = .bool_literal,
                    .line = start_line,
                    .data = .{ .bool_literal = false },
                });
            },

            .number => {
                const value = self.current_token.seminfo.number;
                try self.advance();
                return self.allocNode(.{
                    .tag = .number_literal,
                    .line = start_line,
                    .data = .{ .number_literal = value },
                });
            },

            .integer => {
                const value = self.current_token.seminfo.integer;
                try self.advance();
                return self.allocNode(.{
                    .tag = .integer_literal,
                    .line = start_line,
                    .data = .{ .integer_literal = value },
                });
            },

            .string => {
                const str = self.current_token.seminfo.string;
                const interned = try self.strings.intern(str);
                try self.advance();
                return self.allocNode(.{
                    .tag = .string_literal,
                    .line = start_line,
                    .data = .{ .string_literal = interned },
                });
            },

            .varargs => {
                try self.advance();
                return self.allocNode(.{
                    .tag = .varargs,
                    .line = start_line,
                    .data = .{ .varargs = {} },
                });
            },

            .lbrace => return self.parseTableConstructor(),

            .kw_function => {
                try self.advance();
                return self.parseFunctionBody(null, start_line, false);
            },

            else => return self.parseSuffixedExp(),
        }
    }

    /// A name or a parenthesised expression (primaryexp)
    fn parsePrimaryExp(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;

        switch (self.current_token.token_type) {
            .identifier => return self.nameNode(),

            .lparen => {
                try self.advance();
                const expr = try self.parseExpression();
                try self.checkMatch(.rparen, .lparen, start_line);
                // Parentheses truncate a multi-value expression to one value
                // and make it ineligible as a statement or assignment target
                return self.allocNode(.{
                    .tag = .paren_expr,
                    .line = start_line,
                    .data = .{ .paren_expr = expr },
                });
            },

            else => return self.syntaxError("unexpected symbol", .{}),
        }
    }

    /// A primary expression with field accesses, indexing and calls
    /// (suffixedexp)
    fn parseSuffixedExp(self: *Parser) ParseError!ast.NodeIndex {
        var expr = try self.parsePrimaryExp();

        while (true) {
            switch (self.current_token.token_type) {
                .dot => {
                    try self.advance();
                    const field = try self.parseIdentifier();

                    expr = try self.allocNode(.{
                        .tag = .field_access,
                        .line = self.current_line,
                        .data = .{ .field_access = .{
                            .object = expr,
                            .field = field,
                        } },
                    });
                },

                .lbracket => {
                    try self.advance();
                    const index = try self.parseExpression();
                    try self.expect(.rbracket);

                    expr = try self.allocNode(.{
                        .tag = .index_access,
                        .line = self.current_line,
                        .data = .{ .index_access = .{
                            .object = expr,
                            .index = index,
                        } },
                    });
                },

                .colon => {
                    // Method call. The line is taken before the arguments are
                    // read, so a call spanning several lines is reported at
                    // the line it starts on rather than the one it ends on.
                    const call_line = self.current_line;
                    try self.advance();
                    const method = try self.parseIdentifier();
                    const args = try self.parseCallArgs(call_line);

                    expr = try self.allocNode(.{
                        .tag = .method_call,
                        .line = call_line,
                        .data = .{ .method_call = .{
                            .object = expr,
                            .method = method,
                            .args = args,
                        } },
                    });
                },

                .lparen, .lbrace, .string => {
                    // Function call, lined at its opening token for the same
                    // reason as a method call above
                    const call_line = self.current_line;
                    const args = try self.parseCallArgs(call_line);

                    expr = try self.allocNode(.{
                        .tag = .function_call,
                        .line = call_line,
                        .data = .{ .function_call = .{
                            .func = expr,
                            .args = args,
                        } },
                    });
                },

                else => return expr,
            }
        }
    }

    /// Parse function call arguments (funcargs)
    fn parseCallArgs(self: *Parser, line: u32) ParseError!ast.NodeList {
        var args: std.ArrayList(ast.NodeIndex) = .empty;
        defer args.deinit(self.arenaAllocator());

        switch (self.current_token.token_type) {
            .lparen => {
                try self.advance();
                if (!self.check(.rparen)) {
                    try self.parseExprList(&args);
                }
                try self.checkMatch(.rparen, .lparen, line);
            },

            .lbrace => {
                // Table constructor as single argument
                try args.append(self.arenaAllocator(), try self.parseTableConstructor());
            },

            .string => {
                // String literal as single argument
                const str = self.current_token.seminfo.string;
                const interned = try self.strings.intern(str);
                try self.advance();

                const node = try self.allocNode(.{
                    .tag = .string_literal,
                    .line = self.current_line,
                    .data = .{ .string_literal = interned },
                });
                try args.append(self.arenaAllocator(), node);
            },

            else => return self.syntaxError("function arguments expected", .{}),
        }

        return self.allocNodeList(args.items);
    }

    /// Parse table constructor
    fn parseTableConstructor(self: *Parser) ParseError!ast.NodeIndex {
        const start_line = self.current_line;
        try self.expect(.lbrace);

        var fields: std.ArrayList(ast.TableField) = .empty;
        defer fields.deinit(self.arenaAllocator());

        while (!self.check(.rbrace)) {
            const field = try self.parseTableField();
            try fields.append(self.arenaAllocator(), field);

            if (!try self.tryConsume(.comma) and !try self.tryConsume(.semicolon)) {
                break;
            }
        }

        try self.checkMatch(.rbrace, .lbrace, start_line);

        // Convert fields to nodes
        var field_nodes: std.ArrayList(ast.NodeIndex) = .empty;
        defer field_nodes.deinit(self.arenaAllocator());

        for (fields.items) |field| {
            const node = switch (field) {
                .list => |expr| expr,
                .record => |rec| try self.allocNode(.{
                    .tag = .expr_list,
                    .line = self.current_line,
                    .data = .{ .expr_list = try self.allocNodeList(&[_]ast.NodeIndex{ rec.key, rec.value }) },
                }),
            };
            try field_nodes.append(self.arenaAllocator(), node);
        }

        const field_list = try self.allocNodeList(field_nodes.items);

        return self.allocNode(.{
            .tag = .table_constructor,
            .line = start_line,
            .data = .{ .table_constructor = .{ .fields = field_list } },
        });
    }

    /// Parse table field
    fn parseTableField(self: *Parser) ParseError!ast.TableField {
        // Check for [expr] = expr syntax
        if (self.check(.lbracket)) {
            try self.advance();
            const key = try self.parseExpression();
            try self.expect(.rbracket);
            try self.expect(.eq);
            const value = try self.parseExpression();

            return .{ .record = .{ .key = key, .value = value } };
        }

        // `name = expr` or a positional expression. Parse an expression first:
        // a bare identifier followed by '=' is the record form (the lexer
        // cannot be rewound, so no token is put back).
        const expr = try self.parseExpression();
        if (self.nodes.items[expr].tag == .identifier and self.check(.eq)) {
            try self.advance();
            const value = try self.parseExpression(); // may grow `nodes`: re-index below
            const name = self.nodes.items[expr].data.identifier;
            self.nodes.items[expr] = .{
                .tag = .string_literal,
                .line = self.nodes.items[expr].line,
                .data = .{ .string_literal = name },
            };
            return .{ .record = .{ .key = expr, .value = value } };
        }
        return .{ .list = expr };
    }

    /// Parse identifier and return interned string (str_checkname)
    fn parseIdentifier(self: *Parser) ParseError!ast.InternedString {
        if (!self.check(.identifier)) return self.errorExpected(.identifier);

        const name = self.current_token.seminfo.string;
        const interned = try self.strings.intern(name);
        try self.advance();

        return interned;
    }
};

// Tests
test "parser initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "local x = 42";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();
}

test "parse simple assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "x = 42";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();
    // No need to deinit AST - arena will handle it

    // Verify root is a block
    const root = ast_tree.getNode(ast_tree.root);
    try std.testing.expect(root.tag == .block);
}

test "parse local variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "local x, y = 1, 2";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();

    const root = ast_tree.getNode(ast_tree.root);
    try std.testing.expect(root.tag == .block);

    const block = root.data.block;
    try std.testing.expect(block.statements.len == 1);

    const stmt = ast_tree.getNode(block.statements[0]);
    try std.testing.expect(stmt.tag == .local_assignment);
    try std.testing.expectEqual(@as(usize, 0), stmt.data.local_assignment.attribs.len);
}

test "parse local attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "local a <const>, b, c <close> = 1, 2, 3";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();
    const root = ast_tree.getNode(ast_tree.root);
    const stmt = ast_tree.getNode(root.data.block.statements[0]);
    const attribs = stmt.data.local_assignment.attribs;
    try std.testing.expectEqual(@as(usize, 3), attribs.len);
    try std.testing.expectEqual(ast.LocalAttrib.constant, attribs[0]);
    try std.testing.expectEqual(ast.LocalAttrib.none, attribs[1]);
    try std.testing.expectEqual(ast.LocalAttrib.close, attribs[2]);
}

test "parse function definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "function foo(x, y) return x + y end";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();

    const root = ast_tree.getNode(ast_tree.root);
    const block = root.data.block;
    try std.testing.expect(block.statements.len == 1);

    const stmt = ast_tree.getNode(block.statements[0]);
    try std.testing.expect(stmt.tag == .function_def);
}

test "parse if statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "if x > 0 then print(x) elseif x < 0 then print(-x) else print(0) end";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();

    const root = ast_tree.getNode(ast_tree.root);
    const block = root.data.block;
    const stmt = ast_tree.getNode(block.statements[0]);
    try std.testing.expect(stmt.tag == .if_stmt);
}

test "parse table constructor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "t = {1, 2, x = 3, [\"y\"] = 4}";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();

    const root = ast_tree.getNode(ast_tree.root);
    const block = root.data.block;
    const stmt = ast_tree.getNode(block.statements[0]);
    try std.testing.expect(stmt.tag == .assignment);
}

test "parse operator precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "x = 1 + 2 * 3";
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    const ast_tree = try parser.parse();

    // Should parse as 1 + (2 * 3)
    const root = ast_tree.getNode(ast_tree.root);
    const block = root.data.block;
    const stmt = ast_tree.getNode(block.statements[0]);
    try std.testing.expect(stmt.tag == .assignment);

    const assign = stmt.data.assignment;
    const expr = ast_tree.getNode(assign.values[0]);
    try std.testing.expect(expr.tag == .binary_op);
    try std.testing.expect(expr.data.binary_op.op == .add);

    // Right side should be multiplication
    const right = ast_tree.getNode(expr.data.binary_op.right);
    try std.testing.expect(right.tag == .binary_op);
    try std.testing.expect(right.data.binary_op.op == .mul);
}

test "parse for loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Numeric for
    {
        const source = "for i = 1, 10, 2 do print(i) end";
        var lexer = try lex.LexState.init(source, "test", allocator);
        defer lexer.deinit();

        var parser = try Parser.init(&lexer, allocator);
        defer parser.deinit();

        const ast_tree = try parser.parse();

        const root = ast_tree.getNode(ast_tree.root);
        const stmt = ast_tree.getNode(root.data.block.statements[0]);
        try std.testing.expect(stmt.tag == .for_numeric);
    }

    // Generic for
    {
        const source = "for k, v in pairs(t) do print(k, v) end";
        var lexer = try lex.LexState.init(source, "test", allocator);
        defer lexer.deinit();

        var parser = try Parser.init(&lexer, allocator);
        defer parser.deinit();

        const ast_tree = try parser.parse();

        const root = ast_tree.getNode(ast_tree.root);
        const stmt = ast_tree.getNode(root.data.block.statements[0]);
        try std.testing.expect(stmt.tag == .for_generic);
    }
}

/// Parse `source` expecting failure; returns the first recorded message
fn firstError(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var lexer = try lex.LexState.init(source, "test", allocator);
    var parser = try Parser.init(&lexer, allocator);
    if (parser.parse()) |_| {
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expect(parser.errors.items.len > 0);
    return parser.errors.items[0].msg;
}

test "parse errors are worded like the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("unexpected symbol near 'and'", try firstError(allocator, "and break"));
    try std.testing.expectEqualStrings("syntax error near ']'", try firstError(allocator, "test ]]"));
    try std.testing.expectEqualStrings("syntax error near 'y'", try firstError(allocator, "x y"));
    try std.testing.expectEqualStrings("'=' expected near 'y'", try firstError(allocator, "x, z y"));
    try std.testing.expectEqualStrings("'end' expected near <eof>", try firstError(allocator, "if x then"));
    try std.testing.expectEqualStrings("'end' expected (to close 'if' at line 1) near <eof>", try firstError(allocator, "if x then\n"));
    try std.testing.expectEqualStrings("<eof> expected near 'end'", try firstError(allocator, "x = 1 end"));
    try std.testing.expectEqualStrings("<name> expected near '1'", try firstError(allocator, "local 1"));
    try std.testing.expectEqualStrings("unexpected symbol near <eof>", try firstError(allocator, "x = "));
    try std.testing.expectEqualStrings("'=' or 'in' expected near 'do'", try firstError(allocator, "for i do end"));
    try std.testing.expectEqualStrings("function arguments expected near 'x'", try firstError(allocator, "a:b x"));
    try std.testing.expectEqualStrings("unknown attribute 'final'", try firstError(allocator, "local x <final> = 1"));
    try std.testing.expectEqualStrings("multiple to-be-closed variables in local list", try firstError(allocator, "local a <close>, b <close> = 1, 2"));
    // Lexer errors are recorded too, instead of being lost to recovery
    try std.testing.expectEqualStrings("unfinished string near '\"abc'", try firstError(allocator, "x = \"abc\nprint(1)"));
    try std.testing.expectEqualStrings("malformed number near '3x'", try firstError(allocator, "x = 3x"));
}

test "parse error column tracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "local x ="; // Missing value after =
    var lexer = try lex.LexState.init(source, "test", allocator);
    defer lexer.deinit();

    var parser = try Parser.init(&lexer, allocator);
    defer parser.deinit();

    _ = parser.parse() catch {};

    // Should have an error
    try std.testing.expect(parser.errors.items.len > 0);

    // Error should have proper column info
    const err = parser.errors.items[0];
    try std.testing.expect(err.line > 0);
    try std.testing.expect(err.column > 0); // Should not be 0 anymore

    // Column should point after the = sign (position 10)
    try std.testing.expect(err.column >= 10);
}
