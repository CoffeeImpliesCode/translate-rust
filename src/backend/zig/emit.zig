//! translate_rust.backend.zig.emit — Clean Zig 0.16 source code emitter.
//!
//! Formats the target-language AST DOM (ast.File, ast.Package, ast.Decl, etc.)
//! into idiomatic, compilable Zig 0.16 source code text.
//! Strictly decoupled: zero dependencies on `ir` or `frontend`.

const std = @import("std");
const ast = @import("ast.zig");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Emits a single `ast.File` as a complete Zig source code string.
/// The returned slice is owned by `allocator`.
pub fn emitFile(
    allocator: std.mem.Allocator,
    file: *const ast.File,
) (std.mem.Allocator.Error || ast.ValidationError || EmitError)![]const u8 {
    try ast.validateFileForTranslation(file);
    // Before a single byte is written, and for the reason in
    // `requireLabelledBlockPositions`: an emission that Zig cannot parse is
    // worth nothing, and this is the last point at which the file is still a
    // question rather than a package someone has to debug.
    try requireLabelledBlockPositions(file.*);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // 0. File documentation. Zig reads `//!` only ahead of every declaration
    // and import, so it must come first.
    if (file.documentation.len != 0) {
        try emitModuleDocLines(allocator, &buf, file.documentation);
        if (file.imports.len != 0 or file.decls.len != 0 or file.tests.len != 0) {
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 1. Imports
    if (file.imports.len > 0) {
        for (file.imports) |imp| {
            try emitDocLines(allocator, &buf, imp.documentation, 0);
            if (imp.is_pub) {
                try buf.appendSlice(allocator, "pub ");
            }
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, &buf, imp.local_name);
            if (std.mem.startsWith(u8, imp.module_or_path, "std.")) {
                try buf.appendSlice(allocator, " = ");
                try buf.appendSlice(allocator, imp.module_or_path);
            } else {
                try buf.appendSlice(allocator, " = @import(\"");
                try buf.appendSlice(allocator, imp.module_or_path);
                try buf.appendSlice(allocator, "\")");
            }
            try buf.appendSlice(allocator, ";\n");
        }
        try buf.appendSlice(allocator, "\n");
    }

    // 2. Declarations
    for (file.decls, 0..) |decl, i| {
        try emitDecl(allocator, &buf, decl, 0);
        if (i + 1 < file.decls.len or file.tests.len > 0) {
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 3. Tests
    for (file.tests, 0..) |t, i| {
        try buf.appendSlice(allocator, "test \"");
        try emitEscapedString(allocator, &buf, t.name);
        try buf.appendSlice(allocator, "\" {\n");

        for (t.body.stmts, 0..) |stmt, index| {
            try emitStmt(allocator, &buf, try unusedBindingAsDiscard(allocator, t.body, index, stmt), 1);
        }
        if (t.body.expr) |tail_expr| {
            try emitStmt(allocator, &buf, .{ .expr_stmt = tail_expr }, 1);
        }

        try buf.appendSlice(allocator, "}\n");
        if (i + 1 < file.tests.len) {
            try buf.appendSlice(allocator, "\n");
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Failures only this emitter can raise, as distinct from the AST's own
/// validation errors: shapes that validate and still cannot be written as Zig.
pub const EmitError = error{
    /// A labelled block reached a position with no carrier for its value. The
    /// name says the POSITION, which is the whole of the diagnosis: there is
    /// no spelling of `label: { … }` there, so the emitter is not going to
    /// invent one.
    LabelledBlockWithoutACarrier,
};

/// Where the emitter is about to write a labelled block. Every position the
/// AST can carry one is named here, and `labelledBlockIsLegalIn` answers for
/// all of them, so a new emission site cannot pick a verdict of its own: it
/// states where the block sits and the one predicate decides.
const LabelledBlockPosition = enum {
    /// An `if`/`else` BRANCH, including a branch of a nested `if` — the
    /// exemption comes from the STRUCTURE, because the walk below reaches
    /// this value only by stepping into an `if` arm, never from a flag a
    /// caller could set on an arbitrary node.
    if_branch,
    /// A position with something in front of the block to carry its value: a
    /// `const`/`var` initializer (`const answer = <label>: { … };`), a `return`
    /// payload, a `_ = ` discard, a call argument, a match prong value, a
    /// `break :other <label>: { … }` payload, a tuple or array element, a cast
    /// operand. These are the positions the emitted corpus is made of.
    expression,
    /// A STATEMENT of its own: nothing in front of the block and no `;` after
    /// it. Measured in Zig 0.16: `{ <label>: { … } }` as a block tail fails
    /// `expected ';' after statement`, and the parenthesised spelling
    /// `( <label>: { … } )` fails `value of type 'u8' ignored` — the
    /// parentheses help only as a direct `if` branch. No emitter choice makes
    /// this position parse, so it is refused rather than written.
    bare_statement,
};

/// The one predicate that decides whether a labelled block may be written
/// where it has landed. Nothing else in this file answers that question.
fn labelledBlockIsLegalIn(position: LabelledBlockPosition) bool {
    return switch (position) {
        .if_branch, .expression => true,
        .bare_statement => false,
    };
}

/// Which of the three ways a scope ends its tail decides the position that
/// tail is written in.
const TailKind = enum {
    /// `break :<label> <tail>` when the tail carries the value, nothing in
    /// front of it when it does not — `emitBlockScoped`.
    nested_block,
    /// The same question with a `return` in place of the `break` —
    /// `emitFnDecl`.
    fn_body,
    /// A test body writes its tail as a statement whatever it carries, so a
    /// labelled block there is always a bare statement.
    test_body,
};

fn blockTailPosition(kind: TailKind, tail: ast.Expr) LabelledBlockPosition {
    return switch (kind) {
        .test_body => .bare_statement,
        .nested_block, .fn_body => if (blockTailRole(tail) == .value)
            .expression
        else
            .bare_statement,
    };
}

/// Refuses a labelled block in a position Zig has no spelling for.
///
/// This runs over the AST before anything is emitted, so the answer cannot
/// depend on how a particular emission path happens to be written: a labelled
/// block that reaches `bare_statement` is refused whether it came in as a
/// statement, a function tail or a nested block tail. That is the property
/// worth having here, and it is why this is a walk over the AST rather than a
/// check at each emission site.
fn requireLabelledBlockPositions(file: ast.File) EmitError!void {
    for (file.decls) |decl| try requireLabelledBlockInDecl(decl);
    for (file.tests) |test_decl| {
        try requireLabelledBlockInBlock(test_decl.body, .test_body);
    }
}

fn requireLabelledBlockInDecl(decl: ast.Decl) EmitError!void {
    switch (decl) {
        .const_decl => |const_decl| {
            try requireLabelledBlockInExpr(const_decl.init, .expression);
        },
        .var_decl => |var_decl| {
            try requireLabelledBlockInExpr(var_decl.init, .expression);
        },
        .fn_decl => |fn_decl| {
            if (fn_decl.body) |body| try requireLabelledBlockInBlock(body, .fn_body);
        },
        .struct_decl => |struct_decl| {
            for (struct_decl.fields) |field| {
                if (field.default_val) |value| {
                    try requireLabelledBlockInExpr(value.*, .expression);
                }
            }
            for (struct_decl.decls) |inner| try requireLabelledBlockInDecl(inner);
        },
        .enum_decl => |enum_decl| {
            for (enum_decl.variants) |variant| {
                if (variant.value) |value| {
                    try requireLabelledBlockInExpr(value.*, .expression);
                }
            }
            for (enum_decl.decls) |inner| try requireLabelledBlockInDecl(inner);
        },
        .union_decl => |union_decl| {
            // A union field is a type rather than an initialiser, so there is
            // nothing here for a labelled block to hide in.
            for (union_decl.decls) |inner| try requireLabelledBlockInDecl(inner);
        },
        .trait_descriptor => |descriptor| {
            for (descriptor.cases) |case| {
                for (case.members) |member| {
                    switch (member) {
                        .const_ => |member_const| {
                            try requireLabelledBlockInExpr(member_const.value, .expression);
                        },
                        .type_ => {},
                    }
                }
            }
        },
        .comment => {},
    }
}

fn requireLabelledBlockInBlock(block: ast.Block, kind: TailKind) EmitError!void {
    for (block.stmts) |stmt| try requireLabelledBlockInStmt(stmt);
    if (block.expr) |tail| {
        try requireLabelledBlockInExpr(tail.*, blockTailPosition(kind, tail.*));
    }
}

fn requireLabelledBlockInStmt(stmt: ast.Stmt) EmitError!void {
    switch (stmt) {
        .let_stmt => |let_stmt| {
            try requireLabelledBlockInExpr(let_stmt.init, .expression);
        },
        .assign => |assignment| {
            try requireLabelledBlockInExpr(assignment.target, .expression);
            try requireLabelledBlockInExpr(assignment.val, .expression);
        },
        .defer_stmt => |defer_stmt| {
            try requireLabelledBlockInExpr(defer_stmt.expr, .expression);
        },
        .expr_stmt => |expression| {
            // `statementForm` is the emitter's own answer to "is anything in
            // front of this, or a `;` after it", so this position can never
            // disagree with the text that would have been written. A `bare`
            // form of a labelled block is a bare statement, and that is the
            // one position Zig measures as unspellable.
            const form = statementForm(expression.*);
            const position: LabelledBlockPosition = switch (form) {
                .bare => .bare_statement,
                .semicolon, .discard_value => .expression,
            };
            try requireLabelledBlockInExpr(expression.*, position);
        },
    }
}

fn requireLabelledBlockInExpr(
    expression: ast.Expr,
    position: LabelledBlockPosition,
) EmitError!void {
    switch (expression) {
        .block => |block| {
            if (block.label != null and !labelledBlockIsLegalIn(position)) {
                return error.LabelledBlockWithoutACarrier;
            }
            try requireLabelledBlockInBlock(block, .nested_block);
        },
        // The condition, the scrutinee, an operand and a payload all put
        // something in front of what they hold, so a labelled block anywhere
        // below them is in an expression position.
        .field_access => |field_access| {
            try requireLabelledBlockInExpr(field_access.target.*, .expression);
        },
        .call => |call| {
            try requireLabelledBlockInExpr(call.callee.*, .expression);
            for (call.args) |argument| {
                try requireLabelledBlockInExpr(argument, .expression);
            }
        },
        .match_expr => |match| {
            try requireLabelledBlockInExpr(match.target.*, .expression);
            for (match.arms) |arm| {
                try requireLabelledBlockInExpr(arm.body, .expression);
            }
        },
        .bin_op => |binary| {
            try requireLabelledBlockInExpr(binary.lhs.*, .expression);
            try requireLabelledBlockInExpr(binary.rhs.*, .expression);
        },
        .unary_op => |unary| {
            try requireLabelledBlockInExpr(unary.operand.*, .expression);
        },
        .cast => |cast| try requireLabelledBlockInExpr(cast.operand.*, .expression),
        .struct_init => |literal| {
            for (literal.fields) |field| {
                try requireLabelledBlockInExpr(field.expr, .expression);
            }
        },
        .array_init => |array| {
            for (array.elements) |element| {
                try requireLabelledBlockInExpr(element, .expression);
            }
        },
        .repeat => |repeat| try requireLabelledBlockInExpr(repeat.elem.*, .expression),
        .multi_array => |array| {
            for (array.elements) |element| {
                try requireLabelledBlockInExpr(element, .expression);
            }
        },
        .tuple => |elements| {
            for (elements) |element| {
                try requireLabelledBlockInExpr(element, .expression);
            }
        },
        .builtin => |builtin| {
            for (builtin.args) |argument| {
                try requireLabelledBlockInExpr(argument, .expression);
            }
        },
        .if_expr => |if_expression| {
            try requireLabelledBlockInExpr(if_expression.cond.*, .expression);
            // The one exemption, and it is reached by stepping into an arm of
            // this `if` and nowhere else.
            try requireLabelledBlockInExpr(if_expression.then_body.*, .if_branch);
            if (if_expression.else_body) |else_body| {
                try requireLabelledBlockInExpr(else_body.*, .if_branch);
            }
        },
        .while_expr => |while_expression| {
            try requireLabelledBlockInExpr(while_expression.cond.*, .expression);
            if (while_expression.continue_expr) |continue_expression| {
                try requireLabelledBlockInExpr(continue_expression.*, .expression);
            }
            try requireLabelledBlockInBlock(while_expression.body, .nested_block);
            if (while_expression.else_body) |else_body| {
                try requireLabelledBlockInExpr(else_body.*, .expression);
            }
        },
        .for_expr => |for_expression| {
            for (for_expression.inputs) |input| {
                try requireLabelledBlockInExpr(input, .expression);
            }
            try requireLabelledBlockInBlock(for_expression.body, .nested_block);
            if (for_expression.else_body) |else_body| {
                try requireLabelledBlockInExpr(else_body.*, .expression);
            }
        },
        .range => |range| {
            try requireLabelledBlockInExpr(range.start.*, .expression);
            if (range.end) |end| try requireLabelledBlockInExpr(end.*, .expression);
        },
        .return_expr => |value| {
            if (value) |inner| try requireLabelledBlockInExpr(inner.*, .expression);
        },
        .break_expr => |break_expr| {
            if (break_expr.value) |inner| {
                try requireLabelledBlockInExpr(inner.*, .expression);
            }
        },
        // Nothing below a `continue`, nothing an identifier can hold, and
        // nothing a type value can hold: a label cannot be reached through any
        // of them.
        .ident,
        .continue_expr,
        .type_value,
        .lit,
        .unit,
        .unsupported,
        .panic_,
        .unreachable_,
        => {},
    }
}

// ---------------------------------------------------------------------------
// Documentation
// ---------------------------------------------------------------------------

/// Emit `///` documentation lines at `depth`, one per authored line. Empty
/// documentation emits nothing, so no declaration is ever followed by a `///`
/// with no text; a blank line inside a multi-line block becomes a bare `///`,
/// which is how Zig spells a paragraph break.
pub fn emitDocLines(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    documentation: []const u8,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (documentation.len == 0) return;
    var lines = std.mem.splitScalar(u8, documentation, '\n');
    while (lines.next()) |line| {
        try emitIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "///");
        if (line.len != 0) {
            try buf.appendSlice(allocator, " ");
            try buf.appendSlice(allocator, line);
        }
        try buf.appendSlice(allocator, "\n");
    }
}

/// Emit `//!` file documentation lines. Zig reads these only ahead of every
/// declaration and import, so the caller places them at the top of the file.
pub fn emitModuleDocLines(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    documentation: []const u8,
) std.mem.Allocator.Error!void {
    if (documentation.len == 0) return;
    var lines = std.mem.splitScalar(u8, documentation, '\n');
    while (lines.next()) |line| {
        try buf.appendSlice(allocator, "//!");
        if (line.len != 0) {
            try buf.appendSlice(allocator, " ");
            try buf.appendSlice(allocator, line);
        }
        try buf.appendSlice(allocator, "\n");
    }
}

// ---------------------------------------------------------------------------
// Indentation & Identifiers
// ---------------------------------------------------------------------------

pub fn emitIndent(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), depth: usize) !void {
    const spaces = "    ";
    for (0..depth) |_| {
        try buf.appendSlice(allocator, spaces);
    }
}

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"},
    .{"align"},
    .{"allowzero"},
    .{"and"},
    .{"anyerror"},
    .{"anyframe"},
    .{"anyopaque"},
    .{"asm"},
    .{"async"},
    .{"await"},
    .{"break"},
    .{"callconv"},
    .{"cancel"},
    .{"catch"},
    .{"comptime"},
    .{"const"},
    .{"continue"},
    .{"defer"},
    .{"else"},
    .{"enum"},
    .{"errdefer"},
    .{"error"},
    .{"export"},
    .{"extern"},
    .{"fn"},
    .{"for"},
    .{"if"},
    .{"inline"},
    .{"noalias"},
    .{"noinline"},
    .{"nosuspend"},
    .{"opaque"},
    .{"or"},
    .{"orelse"},
    .{"packed"},
    .{"pub"},
    .{"resume"},
    .{"return"},
    .{"linksection"},
    .{"struct"},
    .{"suspend"},
    .{"switch"},
    .{"test"},
    .{"threadlocal"},
    .{"try"},
    .{"type"},
    .{"union"},
    .{"unreachable"},
    .{"usingnamespace"},
    .{"var"},
    .{"volatile"},
    .{"while"},
});

pub fn emitIdent(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    if (name.len == 0) {
        try buf.appendSlice(allocator, "_");
        return;
    }

    if (zig_keywords.has(name)) {
        try buf.appendSlice(allocator, "@\"");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "\"");
        return;
    }

    // Dotted identifiers are emitted as nested Zig declarations.
    if (std.mem.indexOfScalar(u8, name, '.') != null) {
        var it = std.mem.splitScalar(u8, name, '.');
        var first = true;
        while (it.next()) |part| {
            if (!first) try buf.appendSlice(allocator, ".");
            first = false;
            try emitIdent(allocator, buf, part);
        }
        return;
    }

    var needs_escape = false;
    if (name[0] >= '0' and name[0] <= '9') {
        needs_escape = true;
    } else {
        for (name) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) {
                needs_escape = true;
                break;
            }
        }
    }

    if (needs_escape) {
        try buf.appendSlice(allocator, "@\"");
        try emitEscapedString(allocator, buf, name);
        try buf.appendSlice(allocator, "\"");
    } else {
        try buf.appendSlice(allocator, name);
    }
}

fn emitEscapedString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0 => try buf.appendSlice(allocator, "\\x00"),
            else => {
                if (c >= 0x20 and c <= 0x7e) {
                    try buf.append(allocator, c);
                } else {
                    try buf.print(allocator, "\\x{x:0>2}", .{c});
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Declaration Emission
// ---------------------------------------------------------------------------

/// The documentation attached to a declaration, or `""` for the declaration
/// kinds that carry none. Read before the declaration is written so the
/// `///` block lands at the declaration's own indentation.
fn declDocumentation(decl: ast.Decl) []const u8 {
    return switch (decl) {
        .struct_decl => |sd| sd.documentation,
        .enum_decl => |ed| ed.documentation,
        .union_decl => |ud| ud.documentation,
        .fn_decl => |fd| fd.documentation,
        .const_decl => |cd| cd.documentation,
        .var_decl => |vd| vd.documentation,
        .trait_descriptor, .comment => "",
    };
}

pub fn emitDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    decl: ast.Decl,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitDocLines(allocator, buf, declDocumentation(decl), depth);
    switch (decl) {
        .trait_descriptor => |descriptor| {
            try emitTraitDescriptorDecl(allocator, buf, descriptor, depth);
        },
        .comment => |c| {
            var it = std.mem.splitScalar(u8, c, '\n');
            while (it.next()) |line| {
                try emitIndent(allocator, buf, depth);
                if (std.mem.startsWith(u8, line, "//")) {
                    try buf.appendSlice(allocator, line);
                } else if (line.len == 0) {
                    try buf.appendSlice(allocator, "//");
                } else if (std.mem.startsWith(u8, line, " ")) {
                    try buf.appendSlice(allocator, "//");
                    try buf.appendSlice(allocator, line);
                } else {
                    try buf.appendSlice(allocator, "// ");
                    try buf.appendSlice(allocator, line);
                }
                try buf.appendSlice(allocator, "\n");
            }
        },
        .const_decl => |cd| {
            try emitIndent(allocator, buf, depth);
            if (cd.is_pub) try buf.appendSlice(allocator, "pub ");
            try buf.appendSlice(allocator, "const ");
            try emitIdent(allocator, buf, cd.name);
            if (cd.ty) |t| {
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, t);
            }
            try buf.appendSlice(allocator, " = ");
            try emitExpr(allocator, buf, cd.init, depth);
            try buf.appendSlice(allocator, ";\n");
        },
        .var_decl => |vd| {
            try emitIndent(allocator, buf, depth);
            if (vd.is_pub) try buf.appendSlice(allocator, "pub ");
            if (vd.is_mut) {
                try buf.appendSlice(allocator, "var ");
            } else {
                try buf.appendSlice(allocator, "const ");
            }
            try emitIdent(allocator, buf, vd.name);
            if (vd.ty) |t| {
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, t);
            }
            try buf.appendSlice(allocator, " = ");
            try emitExpr(allocator, buf, vd.init, depth);
            try buf.appendSlice(allocator, ";\n");
        },
        .fn_decl => |fd| {
            try emitFnDecl(allocator, buf, fd, depth);
        },
        .struct_decl => |sd| {
            try emitStructDecl(allocator, buf, sd, depth);
        },
        .enum_decl => |ed| {
            try emitEnumDecl(allocator, buf, ed, depth);
        },
        .union_decl => |ud| {
            try emitUnionDecl(allocator, buf, ud, depth);
        },
    }
}

fn emitTraitDescriptorDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    descriptor: ast.TraitDescriptorDecl,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitIndent(allocator, buf, depth);
    if (descriptor.is_pub) try buf.appendSlice(allocator, "pub ");
    try buf.appendSlice(allocator, "fn ");
    try emitIdent(allocator, buf, descriptor.name);
    try buf.appendSlice(allocator, "(comptime Self: type) type {\n");

    for (descriptor.cases) |descriptor_case| {
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "if (Self == ");
        try emitType(allocator, buf, descriptor_case.receiver);
        try buf.appendSlice(allocator, ") return struct {\n");
        for (descriptor_case.members) |member| {
            try emitIndent(allocator, buf, depth + 2);
            try buf.appendSlice(allocator, "pub const ");
            switch (member) {
                .type_ => |type_member| {
                    try emitIdent(allocator, buf, type_member.name);
                    try buf.appendSlice(allocator, " = ");
                    try emitType(allocator, buf, type_member.ty);
                },
                .const_ => |const_member| {
                    try emitIdent(allocator, buf, const_member.name);
                    try buf.appendSlice(allocator, " = ");
                    try emitExpr(allocator, buf, const_member.value, depth + 2);
                },
            }
            try buf.appendSlice(allocator, ";\n");
        }
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "};\n");
    }

    try emitIndent(allocator, buf, depth + 1);
    try buf.appendSlice(allocator, "@compileError(\"no implementation for ");
    try emitEscapedString(allocator, buf, descriptor.name);
    try buf.appendSlice(allocator, "\");\n");
    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}\n");
}
fn emitFnDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    fd: ast.FnDecl,
    depth: usize,
) std.mem.Allocator.Error!void {
    // `emitFile` validates before it emits, and `validateDecl` rejects a
    // translated function that carries no body, so a dropped body can never
    // reach here. Synthesising `{}` for one would emit a function that
    // compiles and silently does nothing, which is the exact loss the
    // validator exists to catch, so the invariant is unwrapped here — ahead of
    // the parameters, whose spelling depends on what the body reads.
    const body = fd.body.?;

    try emitIndent(allocator, buf, depth);
    if (fd.is_pub) try buf.appendSlice(allocator, "pub ");
    try buf.appendSlice(allocator, "fn ");
    try emitIdent(allocator, buf, fd.name);

    try buf.appendSlice(allocator, "(");
    var first_param = true;
    var ordinary_param_start: usize = 0;
    if (fd.params.len > 0 and std.mem.eql(u8, fd.params[0].name, "self")) {
        const self_param = fd.params[0];
        if (self_param.is_comptime) try buf.appendSlice(allocator, "comptime ");
        try emitIdent(allocator, buf, self_param.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, self_param.ty);
        first_param = false;
        ordinary_param_start = 1;
    }
    for (fd.generic_params) |gp| {
        if (!first_param) try buf.appendSlice(allocator, ", ");
        first_param = false;
        if (gp.is_comptime) try buf.appendSlice(allocator, "comptime ");
        try emitIdent(allocator, buf, gp.name);
        try buf.appendSlice(allocator, ": ");
        if (gp.ty) |t| {
            try emitType(allocator, buf, t);
        } else {
            try buf.appendSlice(allocator, "type");
        }
    }
    // Zig 0.16 accepts NO spelling for a parameter the body never reads: an
    // unnamed parameter is `error: missing parameter name` and a `_`-prefixed
    // one is still `error: unused function parameter`. The only form that
    // compiles is the parameter keeping its name and the body discarding it,
    // which is the same `_ = <name>;` this file already emits for an unread
    // `self` receiver and for an unread local. So the name is always written
    // verbatim — which also keeps the position and the spelling the generated
    // documentation quotes — and the discard goes in the body below.
    //
    // A `comptime T: type` parameter is a TYPE parameter and is exempt: its
    // references live in the SIGNATURE (`reader: T`), not the body, so a
    // body-only scan would discard a parameter the signature still needs. Those
    // arrive in `fd.params` with `is_comptime` set, not through
    // `fd.generic_params`.
    var discarded_params: std.ArrayListUnmanaged([]const u8) = .empty;
    defer discarded_params.deinit(allocator);
    for (fd.params[ordinary_param_start..]) |p| {
        if (!first_param) try buf.appendSlice(allocator, ", ");
        first_param = false;
        if (p.is_comptime) try buf.appendSlice(allocator, "comptime ");
        try emitIdent(allocator, buf, p.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, p.ty);
        // Every unread ordinary parameter is discarded, whatever it is called.
        // A source name that already begins with `_` is still a live parameter
        // to Zig — `_unit: u8` is `error: unused function parameter`, not a
        // discard — so it needs the body statement too. The `_`-prefix check
        // belongs to the switch-CAPTURE spelling and has no say here.
        if (!p.is_comptime and !bodyReadsParam(body, p.name)) {
            try discarded_params.append(allocator, p.name);
        }
    }
    try buf.appendSlice(allocator, ") ");
    try emitType(allocator, buf, fd.ret_type);

    try buf.appendSlice(allocator, " {\n");
    // Rust permits an unused receiver or an unused parameter; Zig requires an
    // explicit discard for each, and `fd.params` names them all.
    for (discarded_params.items) |name| {
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "_ = ");
        try emitIdent(allocator, buf, name);
        try buf.appendSlice(allocator, ";\n");
    }
    if (fd.params.len > 0 and std.mem.eql(u8, fd.params[0].name, "self") and
        !bodyReadsParam(body, "self"))
    {
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "_ = self;\n");
    }
    for (body.stmts, 0..) |stmt, index| {
        try emitStmt(
            allocator,
            buf,
            try unusedBindingAsDiscard(allocator, body, index, stmt),
            depth + 1,
        );
    }
    if (body.expr) |tail_expr| {
        try emitIndent(allocator, buf, depth + 1);
        // A tail leaves a function body exactly as it leaves a block, so both
        // ask `blockTailRole` rather than repeating its cases: a unit loop is
        // already a statement, a control exit needs no `return`, and only a
        // tail that carries a value has to hand one back.
        switch (blockTailRole(tail_expr.*)) {
            .value => {
                try buf.appendSlice(allocator, "return ");
                try emitExpr(allocator, buf, tail_expr.*, depth + 1);
                try buf.appendSlice(allocator, ";\n");
            },
            .statement => {
                try emitExpr(allocator, buf, tail_expr.*, depth + 1);
                try buf.appendSlice(allocator, "\n");
            },
            .exit => {
                try emitExpr(allocator, buf, tail_expr.*, depth + 1);
                try buf.appendSlice(allocator, ";\n");
            },
        }
    }
    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}\n");
}

fn emitStructDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    sd: ast.StructDecl,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (sd.generic_params.len > 0) {
        try emitIndent(allocator, buf, depth);
        if (sd.is_pub) try buf.appendSlice(allocator, "pub ");
        try buf.appendSlice(allocator, "fn ");
        try emitIdent(allocator, buf, sd.name);
        try buf.appendSlice(allocator, "(");
        for (sd.generic_params, 0..) |gp, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            if (gp.is_comptime) try buf.appendSlice(allocator, "comptime ");
            try emitIdent(allocator, buf, gp.name);
            try buf.appendSlice(allocator, ": ");
            if (gp.ty) |t| {
                try emitType(allocator, buf, t);
            } else {
                try buf.appendSlice(allocator, "type");
            }
        }
        try buf.appendSlice(allocator, ") type {\n");
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "return struct {\n");
        try emitStructBody(allocator, buf, sd, depth + 1);
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "};\n");
        try emitIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "}\n");
    } else {
        try emitIndent(allocator, buf, depth);
        if (sd.is_pub) try buf.appendSlice(allocator, "pub ");
        try buf.appendSlice(allocator, "const ");
        try emitIdent(allocator, buf, sd.name);
        try buf.appendSlice(allocator, " = struct {\n");
        try emitStructBody(allocator, buf, sd, depth);
        try emitIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "};\n");
    }
}

fn emitStructBody(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    sd: ast.StructDecl,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (sd.decls.len > 0 or sd.generic_params.len > 0) {
        try emitIndent(allocator, buf, depth + 1);
        try buf.appendSlice(allocator, "const Self = @This();\n\n");
    }
    for (sd.fields) |f| {
        try emitDocLines(allocator, buf, f.documentation, depth + 1);
        try emitIndent(allocator, buf, depth + 1);
        try emitIdent(allocator, buf, f.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, f.ty);
        if (f.default_val) |dv| {
            try buf.appendSlice(allocator, " = ");
            try emitExpr(allocator, buf, dv.*, depth + 1);
        }
        try buf.appendSlice(allocator, ",\n");
    }

    if (sd.fields.len > 0 and sd.decls.len > 0) {
        try buf.appendSlice(allocator, "\n");
    }

    for (sd.decls, 0..) |d, i| {
        try emitDecl(allocator, buf, d, depth + 1);
        if (i + 1 < sd.decls.len) {
            try buf.appendSlice(allocator, "\n");
        }
    }
}

fn emitEnumDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    ed: ast.EnumDecl,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitIndent(allocator, buf, depth);
    if (ed.is_pub) try buf.appendSlice(allocator, "pub ");
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, ed.name);
    try buf.appendSlice(allocator, " = enum");
    if (ed.tag_type) |tt| {
        try buf.appendSlice(allocator, "(");
        try emitType(allocator, buf, tt);
        try buf.appendSlice(allocator, ")");
    }
    try buf.appendSlice(allocator, " {\n");

    for (ed.variants) |v| {
        try emitDocLines(allocator, buf, v.documentation, depth + 1);
        try emitIndent(allocator, buf, depth + 1);
        try emitIdent(allocator, buf, v.name);
        if (v.value) |val| {
            try buf.appendSlice(allocator, " = ");
            try emitExpr(allocator, buf, val.*, depth + 1);
        }
        try buf.appendSlice(allocator, ",\n");
    }

    if (ed.variants.len > 0 and ed.decls.len > 0) {
        try buf.appendSlice(allocator, "\n");
    }

    for (ed.decls, 0..) |d, i| {
        try emitDecl(allocator, buf, d, depth + 1);
        if (i + 1 < ed.decls.len) {
            try buf.appendSlice(allocator, "\n");
        }
    }

    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "};\n");
}

fn emitUnionDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    ud: ast.UnionDecl,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitIndent(allocator, buf, depth);
    if (ud.is_pub) try buf.appendSlice(allocator, "pub ");
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, ud.name);
    try buf.appendSlice(allocator, " = union");
    if (ud.tag_type) |tt| {
        try buf.appendSlice(allocator, "(");
        try emitType(allocator, buf, tt);
        try buf.appendSlice(allocator, ")");
    } else if (ud.fields.len > 0) {
        try buf.appendSlice(allocator, "(enum)");
    }
    try buf.appendSlice(allocator, " {\n");

    for (ud.fields) |f| {
        try emitDocLines(allocator, buf, f.documentation, depth + 1);
        try emitIndent(allocator, buf, depth + 1);
        try emitIdent(allocator, buf, f.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, f.ty);
        try buf.appendSlice(allocator, ",\n");
    }

    if (ud.fields.len > 0 and ud.decls.len > 0) {
        try buf.appendSlice(allocator, "\n");
    }

    for (ud.decls, 0..) |d, i| {
        try emitDecl(allocator, buf, d, depth + 1);
        if (i + 1 < ud.decls.len) {
            try buf.appendSlice(allocator, "\n");
        }
    }

    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "};\n");
}

// ---------------------------------------------------------------------------
// Statement Emission
// ---------------------------------------------------------------------------

pub fn emitStmt(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    stmt: ast.Stmt,
    depth: usize,
) std.mem.Allocator.Error!void {
    const context: EmitContext = .{};
    try emitStmtScoped(&context, allocator, buf, stmt, depth);
}

fn emitStmtScoped(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    stmt: ast.Stmt,
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (stmt) {
        .let_stmt => |ls| {
            try emitIndent(allocator, buf, depth);
            if (ls.is_mut) {
                try buf.appendSlice(allocator, "var ");
            } else {
                try buf.appendSlice(allocator, "const ");
            }
            try emitIdent(allocator, buf, ls.name);
            if (ls.ty) |t| {
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, t);
            }
            try buf.appendSlice(allocator, " = ");
            try emitExprScoped(context, allocator, buf, ls.init, depth);
            try buf.appendSlice(allocator, ";\n");
        },
        .assign => |as| {
            try emitIndent(allocator, buf, depth);
            try emitExprScoped(context, allocator, buf, as.target, depth);
            const op_str = switch (as.op) {
                .assign => " = ",
                .add_assign => " += ",
                .add_assign_wrap => " +%= ",
                .sub_assign => " -= ",
                .sub_assign_wrap => " -%= ",
                .mul_assign => " *= ",
                .mul_assign_wrap => " *%= ",
                .div_assign => " /= ",
                .mod_assign => " %= ",
                .bit_and_assign => " &= ",
                .bit_or_assign => " |= ",
                .bit_xor_assign => " ^= ",
                .shl_assign => " <<= ",
                .shr_assign => " >>= ",
            };
            try buf.appendSlice(allocator, op_str);
            try emitExprScoped(context, allocator, buf, as.val, depth);
            try buf.appendSlice(allocator, ";\n");
        },
        .defer_stmt => |defer_stmt| {
            try emitIndent(allocator, buf, depth);
            const keyword = if (defer_stmt.is_errdefer) "errdefer " else "defer ";
            try buf.appendSlice(allocator, keyword);
            try emitExprScoped(context, allocator, buf, defer_stmt.expr, depth);
            if (defer_stmt.expr != .block) {
                try buf.appendSlice(allocator, ";");
            }
            try buf.appendSlice(allocator, "\n");
        },
        .expr_stmt => |es| {
            try emitIndent(allocator, buf, depth);
            const form = statementForm(es.*);
            if (form == .discard_value) try buf.appendSlice(allocator, "_ = ");
            try emitExprScoped(context, allocator, buf, es.*, depth);
            if (form == .semicolon or form == .discard_value) {
                try buf.appendSlice(allocator, ";");
            }
            try buf.appendSlice(allocator, "\n");
        },
    }
}

/// True when the emitted text is a Zig statement a function body may end on.
/// A tail `if` or `switch` is a statement as well, but it has to produce the
/// return value, so it does not belong here.
fn isStatementLike(expr: ast.Expr) bool {
    return switch (expr) {
        .block, .while_expr, .for_expr => true,
        else => false,
    };
}

/// How an expression has to be written in statement position.
const StatementForm = enum {
    /// Already a whole Zig statement: `{ ... }`, `if (...) ...`,
    /// `while ...`, `for ... ...`, `switch ...`.
    bare,
    /// A value expression: emit it and terminate it with `;`.
    semicolon,
    /// A loop that carries a value out of it. Zig rejects an unused non-void
    /// loop result, so the value is discarded explicitly.
    discard_value,
};

/// Whether one branch of an `if` is already a whole Zig statement, so the
/// `if` around it needs no `;` of its own.
fn ifBranchIsStatement(expr: ast.Expr) bool {
    return switch (expr) {
        .block, .while_expr, .for_expr, .match_expr => true,
        else => false,
    };
}

/// Whether every branch of this `if` is written as a statement already.
fn ifIsWholeStatement(if_expr: ast.IfExpr) bool {
    if (!ifBranchIsStatement(if_expr.then_body.*)) return false;
    if (if_expr.else_body) |else_body| {
        if (!ifBranchIsStatement(else_body.*)) return false;
    }
    return true;
}

fn statementForm(expr: ast.Expr) StatementForm {
    return switch (expr) {
        .while_expr => |while_expr| if (loopYieldsValue(while_expr)) .discard_value else .bare,
        .block, .for_expr, .match_expr => .bare,
        // `if (c) { ... }` is a whole statement, and `if (c) x;` is not: Zig
        // reads a bare value, a `break`, or a `continue` in a branch as the
        // `if`'s own expression and wants the `;` that terminates it. Without
        // one the emitted file stops parsing at the end of that branch.
        .if_expr => |if_expr| if (ifIsWholeStatement(if_expr)) .bare else .semicolon,
        else => .semicolon,
    };
}

/// True when the expression produces a value the position around it has to
/// consume. A Rust `loop` that returns one lowers to a value-bearing `while`,
/// which the statement forms alone cannot see.
fn exprCarriesValue(expr: ast.Expr) bool {
    return switch (expr) {
        .block => |block| blockHasValue(block),
        .while_expr => |while_expr| loopYieldsValue(while_expr),
        else => false,
    };
}

/// Whether `emitExpr` writes the expression as a Zig statement instead of as a
/// value. This is the one question every site asks before it consumes an
/// expression, because the two spellings are not interchangeable: a unit loop
/// is a statement, and `emitChunkLoop` writes a prelude and a `while`, so a
/// `break` payload prefixed onto it lands in the middle of a line and the file
/// stops parsing there.
fn writesAsStatement(expr: ast.Expr) bool {
    return isStatementLike(expr) and !exprCarriesValue(expr);
}

/// True when two source labels name the same target. A null label is the
/// unlabeled exit, and it matches only another null.
fn sameSourceLabel(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// What a tail expression has to be written as. A function body, a block and a
/// loop body all answer the question the same way, so they ask it the same way.
///
/// A shape outside `isStatementLike` is a value tail whatever it looks like:
/// `break :label if (c) blk: { … } else blk: { … }` carries a value through a
/// `break` because `if` is one inline Zig expression whose arms are themselves
/// value blocks. A `break` payload is well formed exactly when it is a single
/// inline expression; only a form Zig can write *solely* as a statement — a
/// block, a unit `while`, a `for` — may never carry one.
const TailRole = enum {
    /// A control exit: `return`, `break`, `continue`, `unreachable`, `panic`.
    /// It stands alone once terminated.
    exit,
    /// A unit `while`, a `for`, or a block that carries no value. Zig writes
    /// these as statements, so nothing may be prefixed onto them.
    statement,
    /// The scope's own value. It leaves through the label that scope carries.
    value,
};

/// What a tail is worth, which is the whole of the statement/value split. A
/// Rust `for` is `()`, and so is a `while` no value `break` leaves, so neither
/// is ever the value of the scope it ends.
fn blockTailRole(tail: ast.Expr) TailRole {
    return switch (tail) {
        .return_expr, .break_expr, .continue_expr, .unreachable_, .panic_ => .exit,
        else => if (writesAsStatement(tail)) .statement else .value,
    };
}

fn blockHasValue(block: ast.Block) bool {
    if (blockHasLabelledValueExit(block)) return true;
    const tail = block.expr orelse return false;
    return blockTailRole(tail.*) == .value;
}

/// Which control exit a subtree scan counts as reaching the scope it was
/// asked about. The three questions differ only in the exit they accept, so
/// they share one walk.
const ExitQueryKind = enum {
    /// Any `break`. This is what decides whether the emitted `break :label`
    /// exists, so a loop that answers it has to keep the label.
    break_exit,
    /// Any `continue`. `continue` restarts a loop and never a block, so it
    /// keeps a loop label alive on its own.
    continue_exit,
    /// A `break` carrying a value. A Rust `loop` yields a value in Zig
    /// exactly when one of these reaches it; a valueless `break 'label`
    /// leaves the loop without one, so it never answers this.
    value_break,
};

/// One question a subtree scan answers: which exits reach the scope being
/// scanned.
const ExitQuery = struct {
    /// Source label the exit has to name to count.
    label: ?[]const u8,
    /// True when an exit naming nothing counts too. Rust's bare `break` and
    /// `continue` reach the innermost enclosing loop whatever the loops
    /// around it carry, so only the scope being scanned may claim one.
    unlabeled_ok: bool,
    kind: ExitQueryKind,

    /// The query one loop deeper. A nested loop claims an unlabeled exit
    /// before the loop around it can.
    fn nested(self: ExitQuery) ExitQuery {
        return .{ .label = self.label, .unlabeled_ok = false, .kind = self.kind };
    }

    /// True when an inner scope carries the label this query looks for, so an
    /// exit naming it lands there rather than on the scope being scanned. Rust
    /// lets a nested loop or block shadow a label, and an exit the emitter
    /// resolves to that scope never names the loop around it. The value query
    /// keeps the looser rule because it picks a loop shape, while a label
    /// query has to follow where the exit really lands or it keeps a label
    /// nothing names.
    fn shadowed(self: ExitQuery, label: ?[]const u8) bool {
        return self.kind != .value_break and sameSourceLabel(label, self.label);
    }

    /// Scans a nested loop's body, unless that loop took the label and holds
    /// the exits that name it.
    fn nestedLoopBody(self: ExitQuery, label: ?[]const u8, body: ast.Block) bool {
        return !self.shadowed(label) and blockHasLoopExitTo(body, self.nested());
    }

    /// Scans a nested block's body. A block claims no unlabeled exit, because
    /// a bare `break` inside a Rust block still belongs to the loop around it,
    /// so the query passes through unchanged.
    fn nestedBlockBody(self: ExitQuery, label: ?[]const u8, block: ast.Block) bool {
        return !self.shadowed(label) and blockHasLoopExitTo(block, self);
    }
};

/// True when the block hands a value out through a `break` that names the
/// block itself. The exit can sit in a statement as well as in the tail, so a
/// labelled block with no tail of its own still produces one.
fn blockHasLabelledValueExit(block: ast.Block) bool {
    const label = block.label orelse return false;
    const query: ExitQuery = .{ .label = label, .unlabeled_ok = false, .kind = .value_break };
    for (block.stmts) |stmt| {
        if (stmtHasLoopExitTo(stmt, query)) return true;
    }
    if (block.expr) |tail| return exprHasLoopExitTo(tail.*, query);
    return false;
}

/// True when the loop carries a value out of itself. Zig's `while` produces
/// one only through a `break` that carries a value, and Rust's `loop` lowers to
/// exactly that shape, so the exit has to be found before the loop can be
/// written as a statement.
///
/// The loop's own source label is what an exit has to name to reach it
/// through any nesting; an unlabeled exit reaches it only when no nested loop
/// claims that first.
fn loopYieldsValue(loop_expr: ast.WhileExpr) bool {
    return blockHasLoopExitTo(loop_expr.body, .{
        .label = loop_expr.label,
        .unlabeled_ok = true,
        .kind = .value_break,
    });
}

/// The source label the emitted loop has to carry, or null when nothing inside
/// it names that label. Zig rejects a loop label no `break` or `continue` uses,
/// so the prefix is written only when an exit landing in the loop's own body
/// emits it. The `else` arm runs once the loop is over and is not scanned,
/// because an exit there belongs to whatever surrounds the loop.
fn usedLoopLabel(body: ast.Block, target: ExitTarget) ?[]const u8 {
    const label = target.source_label orelse return null;
    // A `break` names the loop only when the loop's own Zig label is where a
    // break lands. A value-carrying loop hands its value out through a
    // generated wrapper block instead, so its breaks name that block and
    // leave the source label to `continue` alone.
    if (sameSourceLabel(target.break_label, label) and
        blockHasLoopExitTo(body, .{ .label = label, .unlabeled_ok = true, .kind = .break_exit }))
    {
        return label;
    }
    if (blockHasLoopExitTo(body, .{
        .label = label,
        .unlabeled_ok = true,
        .kind = .continue_exit,
    })) return label;
    return null;
}

fn blockHasLoopExitTo(block: ast.Block, query: ExitQuery) bool {
    for (block.stmts) |stmt| {
        if (stmtHasLoopExitTo(stmt, query)) return true;
    }
    if (block.expr) |tail| return exprHasLoopExitTo(tail.*, query);
    return false;
}

fn stmtHasLoopExitTo(stmt: ast.Stmt, query: ExitQuery) bool {
    return switch (stmt) {
        .let_stmt => |let_stmt| exprHasLoopExitTo(let_stmt.init, query),
        .assign => |assign| exprHasLoopExitTo(assign.target, query) or
            exprHasLoopExitTo(assign.val, query),
        .defer_stmt => |defer_stmt| exprHasLoopExitTo(defer_stmt.expr, query),
        .expr_stmt => |expr| exprHasLoopExitTo(expr.*, query),
    };
}

fn matchHasLoopExitTo(match: ast.Match, query: ExitQuery) bool {
    for (match.arms) |arm| {
        if (exprHasLoopExitTo(arm.body, query)) return true;
    }
    return false;
}

fn exprsHaveLoopExitTo(exprs: []const ast.Expr, query: ExitQuery) bool {
    for (exprs) |expr| {
        if (exprHasLoopExitTo(expr, query)) return true;
    }
    return false;
}

fn exprHasLoopExitTo(expr: ast.Expr, query: ExitQuery) bool {
    return switch (expr) {
        .type_value => false,
        // An unlabeled `break` leaves the innermost enclosing loop, so a
        // nested loop claims it before the loop around it can. An exit that
        // names the label says which loop it belongs to and passes through.
        .break_expr => |break_expr| switch (query.kind) {
            .value_break => {
                if (break_expr.value == null) return false;
                if (break_expr.label) |label| return sameSourceLabel(label, query.label);
                return query.unlabeled_ok;
            },
            .break_exit => if (break_expr.label) |label|
                sameSourceLabel(label, query.label)
            else
                query.unlabeled_ok,
            .continue_exit => false,
        },
        .continue_expr => |continue_expr| switch (query.kind) {
            .continue_exit => if (continue_expr.label) |label|
                sameSourceLabel(label, query.label)
            else
                query.unlabeled_ok,
            .break_exit, .value_break => false,
        },
        .while_expr => |while_expr| query.nestedLoopBody(while_expr.label, while_expr.body),
        .for_expr => |for_expr| query.nestedLoopBody(for_expr.label, for_expr.body),
        .block => |block| query.nestedBlockBody(block.label, block),
        .match_expr => |match| matchHasLoopExitTo(match, query),
        .if_expr => |if_expr| exprHasLoopExitTo(if_expr.cond.*, query) or
            exprHasLoopExitTo(if_expr.then_body.*, query) or
            (if_expr.else_body != null and exprHasLoopExitTo(if_expr.else_body.?.*, query)),
        .bin_op => |bin_op| exprHasLoopExitTo(bin_op.lhs.*, query) or
            exprHasLoopExitTo(bin_op.rhs.*, query),
        .unary_op => |unary_op| exprHasLoopExitTo(unary_op.operand.*, query),
        .cast => |cast| exprHasLoopExitTo(cast.operand.*, query),
        .call => |call| exprHasLoopExitTo(call.callee.*, query) or
            exprsHaveLoopExitTo(call.args, query),
        .field_access => |field_access| exprHasLoopExitTo(field_access.target.*, query),
        .builtin => |builtin| exprsHaveLoopExitTo(builtin.args, query),
        .array_init => |array| exprsHaveLoopExitTo(array.elements, query),
        .multi_array => |array| exprsHaveLoopExitTo(array.elements, query),
        .repeat => |repeat| exprHasLoopExitTo(repeat.elem.*, query),
        .tuple => |elements| exprsHaveLoopExitTo(elements, query),
        .struct_init => |struct_init| structInitHasLoopExitTo(struct_init, query),
        .range => |range| exprHasLoopExitTo(range.start.*, query) or
            (range.end != null and exprHasLoopExitTo(range.end.?.*, query)),
        // `return loop { ... }` owns the breaks inside the returned loop, but
        // a `break` in a returned conditional belongs to this one.
        .return_expr => |value| if (value) |inner|
            return exprHasLoopExitTo(inner.*, query)
        else
            false,
        .lit, .unit, .ident, .panic_, .unsupported, .unreachable_ => false,
    };
}

fn structInitHasLoopExitTo(struct_init: ast.StructInit, query: ExitQuery) bool {
    for (struct_init.fields) |field| {
        if (exprHasLoopExitTo(field.expr, query)) return true;
    }
    return false;
}

const GeneratedMatchName = struct {
    base: []const u8,
    suffix: usize = 0,
};

const EmitContext = struct {
    active_names: []const GeneratedMatchName = &.{},
    active_capture_names: []const []const u8 = &.{},
    /// Scopes a `break` or a `continue` in this position can land on,
    /// innermost first. Each entry lives in the frame of the loop or block
    /// that opened it, so the chain needs no allocation and unwinds with the
    /// emission that built it.
    exit_scope: ?*const ExitScope = null,
};
const match_payload_base = "__r2z_match_payload";
const match_arm_base = "__r2z_match_arm";
const value_loop_base = "__r2z_value_loop";
const value_block_base = "__r2z_value_block";

/// What kind of scope an exit target stands for. `continue` may only name a
/// loop, and a block target is never the innermost loop.
const ExitTargetKind = enum {
    loop,
    block,
};

/// One scope a control exit can land on. A value-carrying loop is two Zig
/// scopes standing for one Rust loop, so it needs separate names: the wrapper
/// block hands the value out and the `while` inside it is the one `continue`
/// restarts.
const ExitTarget = struct {
    /// Source label this target answers to, or null when it carries none.
    source_label: ?[]const u8,
    /// True when an unlabeled exit lands here. Rust's bare `break` and
    /// `continue` reach the innermost enclosing loop whatever labels the loops
    /// around it carry, so every loop sets it and only the innermost one is
    /// reached. A block never sets it: a bare `break` inside a Rust block
    /// still belongs to the loop around the block.
    innermost_loop: bool,
    /// Zig label a `break` into this target names; null needs no label.
    break_label: ?[]const u8,
    /// Zig label a `continue` into this target names; null needs no label.
    continue_label: ?[]const u8,
    kind: ExitTargetKind,
};

const ExitScope = struct {
    target: ExitTarget,
    parent: ?*const ExitScope,
};

fn findExitTarget(scope: ?*const ExitScope, source_label: ?[]const u8) ?ExitTarget {
    var current = scope;
    while (current) |node| : (current = node.parent) {
        if (sameSourceLabel(node.target.source_label, source_label)) return node.target;
    }
    return null;
}

fn findContinueTarget(scope: ?*const ExitScope, source_label: ?[]const u8) ?ExitTarget {
    var current = scope;
    while (current) |node| : (current = node.parent) {
        if (node.target.kind != .loop) continue;
        if (sameSourceLabel(node.target.source_label, source_label)) return node.target;
    }
    return null;
}

/// The innermost loop scope, which is where an unlabeled `break` and an
/// unlabeled `continue` both land. Blocks never set `innermost_loop`, so the
/// loop a generated value block sits inside is still the one reached.
fn findInnermostLoopTarget(scope: ?*const ExitScope) ?ExitTarget {
    var current = scope;
    while (current) |node| : (current = node.parent) {
        if (node.target.innermost_loop) return node.target;
    }
    return null;
}

fn generatedMatchNameText(
    buffer: *[64]u8,
    name: GeneratedMatchName,
) []const u8 {
    if (name.suffix == 0) return name.base;
    return std.fmt.bufPrint(buffer, "{s}_{d}", .{ name.base, name.suffix }) catch unreachable;
}

fn generatedMatchNameEquals(value: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, value, name);
}

fn generatedMatchNamesEqual(
    left: GeneratedMatchName,
    right: GeneratedMatchName,
) bool {
    return left.suffix == right.suffix and std.mem.eql(u8, left.base, right.base);
}

fn emitGeneratedMatchName(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayListUnmanaged(u8),
    name: GeneratedMatchName,
) std.mem.Allocator.Error!void {
    var name_buffer: [64]u8 = undefined;
    try emitIdent(allocator, buffer, generatedMatchNameText(&name_buffer, name));
}

fn emitCaptureBinding(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    capture: ast.Capture,
) std.mem.Allocator.Error!void {
    if (capture.by_ref) try buf.appendSlice(allocator, "*");
    try emitIdent(allocator, buf, capture.name);
}

/// The payload a captured `if` binds, written between the condition and the
/// branch: `if (cond) |x| ...`. A loop payload spells a capture the same way,
/// so the identifier is quoted the same way too.
fn emitIfCapture(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    capture: ?ast.Capture,
) std.mem.Allocator.Error!void {
    const binding = capture orelse return;
    try buf.appendSlice(allocator, "|");
    try emitCaptureBinding(allocator, buf, binding);
    try buf.appendSlice(allocator, "| ");
}

fn lexicalRoot(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
    return value[0..end];
}
/// What a mention of a name MEANS to the question being asked about it.
///
/// `.occurrence` is the GENERATED-name question: any mention collides, because
/// a fresh label that lands on a binding, a capture or a field name is as
/// unusable as one that lands on a read. `.read` is the PARAMETER question:
/// only a read keeps a parameter alive, and a BINDING that shadows the name
/// ends the count for the rest of its own scope.
const NameScanMode = enum {
    occurrence,
    read,
};

/// One name question in flight. `shadowed` is set once a binding in the scope
/// being walked has introduced `name` again, from which point a mention is the
/// local's and not the outer one's — which is why it is carried down rather
/// than re-decided per arm.
const NameScan = struct {
    name: []const u8,
    mode: NameScanMode,
    shadowed: bool = false,

    /// This question, one scope deeper, with `name` shadowed by a binding. The
    /// binding that did it is not recorded: `shadowed` is a property of the
    /// scope being walked, and every scope that sets it has already asked
    /// `shadowedByBinding` of the name that introduced it.
    fn shadowedBy(self: NameScan) NameScan {
        return .{ .name = self.name, .mode = self.mode, .shadowed = true };
    }

    /// Whether a mention of `value` counts for this question. A shadowed name
    /// is the local's, so nothing after the binding counts as a read of the
    /// parameter.
    fn mentions(self: NameScan, value: []const u8) bool {
        if (self.mode == .read and self.shadowed) return false;
        return generatedMatchNameEquals(lexicalRoot(value), self.name);
    }

    /// Whether a mention that is NOT a value read counts: a variant tag, a
    /// field name, a label, or a type name. Those positions name a variant, a
    /// field, an exit and a type — never the value in scope — so they are
    /// always a collision and never a read.
    ///
    /// The read case is what makes this worth stating: reporting one as a read
    /// would call an unread parameter live, the discard would be omitted, and
    /// the package would fail with `unused function parameter`. That is the
    /// same failure a shadowing binding caused, reached from the other side.
    fn namesSomethingElse(self: NameScan, value: []const u8) bool {
        if (self.mode != .occurrence) return false;
        return generatedMatchNameEquals(lexicalRoot(value), self.name);
    }

    /// Whether this binding SHADOWS the name, which is what ends the count.
    /// Rust introduces the local only after its initialiser is produced, so the
    /// initialiser and the type annotation are read while the outer name is
    /// still the only one in scope — which is why this is asked of the
    /// DECLARATION and the initialiser is scanned before it.
    fn shadowedByBinding(self: NameScan, binding: []const u8) bool {
        return self.mode == .read and
            generatedMatchNameEquals(lexicalRoot(binding), self.name);
    }
};

/// The GENERATED-name question about `name`, which is every collision.
fn occurrenceScan(name: []const u8) NameScan {
    return .{ .name = name, .mode = .occurrence };
}

fn typeContainsGeneratedMatchName(scan: NameScan, ty: ast.Type) bool {
    return switch (ty) {
        .prim, .any_opaque, .void_type => false,
        .ptr => |pointer| typeContainsGeneratedMatchName(scan, pointer.elem.*),
        .slice => |slice| typeContainsGeneratedMatchName(scan, slice.elem.*),
        .opt => |inner| typeContainsGeneratedMatchName(scan, inner.*),
        .err_union => |error_union| {
            if (error_union.err_set) |error_set| {
                if (scan.namesSomethingElse(error_set)) return true;
            }
            return typeContainsGeneratedMatchName(scan, error_union.payload.*);
        },
        .projected => |projected| typeContainsGeneratedMatchName(scan, projected.receiver.*),
        .named => |value| scan.namesSomethingElse(value),
        .generic => |generic| {
            if (scan.namesSomethingElse(generic.name)) return true;
            for (generic.params) |param| {
                if (typeContainsGeneratedMatchName(scan, param)) return true;
            }
            return false;
        },
        .array => |array| typeContainsGeneratedMatchName(scan, array.elem.*),
        .array_expr => |array| {
            if (typeContainsGeneratedMatchName(scan, array.elem.*)) return true;
            return exprContainsGeneratedMatchName(scan, array.len.*);
        },
        .expr => |expr| exprContainsGeneratedMatchName(scan, expr.*),
        .tuple => |tuple| {
            for (tuple) |element| {
                if (typeContainsGeneratedMatchName(scan, element)) return true;
            }
            return false;
        },
        .fn_ptr => |function| {
            for (function.params) |param| {
                if (typeContainsGeneratedMatchName(scan, param)) return true;
            }
            return typeContainsGeneratedMatchName(scan, function.ret.*);
        },
        .anon_struct => |anonymous| {
            for (anonymous.fields) |field| {
                if (typeContainsGeneratedMatchName(scan, field.ty)) return true;
                if (field.default_val) |value| {
                    if (exprContainsGeneratedMatchName(scan, value.*)) return true;
                }
            }
            return false;
        },
    };
}

/// Whether this pattern SHADOWS the scanned name, which is the whole of what a
/// pattern contributes to the read question: a `binding` introduces the name
/// for the arm's own body. A variant name and a field name introduce nothing,
/// so neither can shadow — they name a tag and a field, and the arm they guard
/// still sees the outer name.
fn patternShadowsName(scan: NameScan, pattern: ast.Pattern) bool {
    return switch (pattern) {
        .wildcard, .lit, .range_pat, .enum_literal => false,
        .binding => |value| scan.shadowedByBinding(value),
        .tuple => |patterns| {
            for (patterns) |child| {
                if (patternShadowsName(scan, child)) return true;
            }
            return false;
        },
        .struct_pat => |struct_pattern| {
            for (struct_pattern.fields) |field| {
                if (patternShadowsName(scan, field.pat)) return true;
            }
            return false;
        },
    };
}

/// Whether the pattern contributes a COUNT for this question. In read mode a
/// `binding` never does: it is a shadow, which stops the count rather than
/// answering it, and `patternShadowsName` is where that is noticed. In
/// occurrence mode it still counts, because a generated name that collides
/// with a binding is just as unusable as one that collides with a read.
fn patternContainsGeneratedMatchName(scan: NameScan, pattern: ast.Pattern) bool {
    return switch (pattern) {
        .wildcard, .lit, .range_pat => false,
        .binding => |value| scan.namesSomethingElse(value),
        .enum_literal => |value| scan.namesSomethingElse(value),
        .tuple => |patterns| {
            for (patterns) |child| {
                if (patternContainsGeneratedMatchName(scan, child)) return true;
            }
            return false;
        },
        .struct_pat => |struct_pattern| {
            if (struct_pattern.name) |value| {
                if (scan.namesSomethingElse(value)) return true;
            }
            for (struct_pattern.fields) |field| {
                if (scan.namesSomethingElse(field.name)) return true;
                if (patternContainsGeneratedMatchName(scan, field.pat)) return true;
            }
            return false;
        },
    };
}

fn stmtContainsGeneratedMatchName(scan: NameScan, stmt: ast.Stmt) bool {
    return switch (stmt) {
        .let_stmt => |let_statement| {
            // The name a `let` binds is a collision, not a read; the shadow
            // itself is `blockContainsGeneratedMatchName`'s business.
            if (scan.namesSomethingElse(let_statement.name)) return true;
            if (let_statement.ty) |ty| {
                if (typeContainsGeneratedMatchName(scan, ty)) return true;
            }
            return exprContainsGeneratedMatchName(scan, let_statement.init);
        },
        .assign => |assignment| {
            return exprContainsGeneratedMatchName(scan, assignment.target) or
                exprContainsGeneratedMatchName(scan, assignment.val);
        },
        .defer_stmt => |defer_statement| exprContainsGeneratedMatchName(scan, defer_statement.expr),
        .expr_stmt => |expression| exprContainsGeneratedMatchName(scan, expression.*),
    };
}

/// Walks one block's statements IN ORDER, which is what makes the shadowing
/// rule mean anything: a `let` is read through its own initialiser and type,
/// and everything after it in THIS block reads the local instead. The rule is
/// stated once, here, so it holds in a nested block and a match arm as well as
/// in the body of a function — the hand-rolled loop that used to live in
/// `bodyReadsParam` covered only the top-level statement list and reported the
/// read it could not prove absent, which cost a package Zig refuses.
fn blockContainsGeneratedMatchName(block: ast.Block, scan: NameScan) bool {
    // A label names an exit, never a value, so it is not a read; it is still a
    // collision worth avoiding when the question is about a generated name.
    if (block.label) |label| {
        if (scan.namesSomethingElse(label)) return true;
    }
    var inner = scan;
    for (block.stmts) |stmt| {
        if (stmtContainsGeneratedMatchName(inner, stmt)) return true;
        if (stmt == .let_stmt and inner.shadowedByBinding(stmt.let_stmt.name)) {
            inner = inner.shadowedBy();
        }
    }
    if (block.expr) |expression| return exprContainsGeneratedMatchName(inner, expression.*);
    return false;
}

fn matchContainsGeneratedMatchName(match: ast.Match, scan: NameScan) bool {
    if (exprContainsGeneratedMatchName(scan, match.target.*)) return true;
    for (match.arms) |arm| {
        // The scrutinee is read once, outside every arm: an arm that binds the
        // name shadows it for that arm's body and for nothing else.
        var arm_scan = scan;
        for (arm.patterns) |pattern| {
            if (patternContainsGeneratedMatchName(scan, pattern)) return true;
            if (patternShadowsName(scan, pattern)) arm_scan = arm_scan.shadowedBy();
        }
        if (arm.capture) |capture| {
            if (scan.namesSomethingElse(capture.name)) return true;
            if (scan.shadowedByBinding(capture.name)) arm_scan = arm_scan.shadowedBy();
        }
        if (exprContainsGeneratedMatchName(arm_scan, arm.body)) return true;
    }
    return false;
}

fn exprContainsGeneratedMatchName(scan: NameScan, expression: ast.Expr) bool {
    return switch (expression) {
        .lit, .unit, .unsupported, .panic_, .unreachable_ => false,
        .ident => |value| scan.mentions(value),
        .field_access => |field_access| exprContainsGeneratedMatchName(scan, field_access.target.*),
        .call => |call| {
            if (exprContainsGeneratedMatchName(scan, call.callee.*)) return true;
            for (call.generic_args) |argument| {
                if (typeContainsGeneratedMatchName(scan, argument)) return true;
            }
            for (call.args) |argument| {
                if (exprContainsGeneratedMatchName(scan, argument)) return true;
            }
            return false;
        },
        .block => |block| blockContainsGeneratedMatchName(block, scan),
        .match_expr => |match| matchContainsGeneratedMatchName(match, scan),
        .bin_op => |binary| exprContainsGeneratedMatchName(scan, binary.lhs.*) or
            exprContainsGeneratedMatchName(scan, binary.rhs.*),
        .unary_op => |unary| exprContainsGeneratedMatchName(scan, unary.operand.*),
        .cast => |cast| typeContainsGeneratedMatchName(scan, cast.target) or
            exprContainsGeneratedMatchName(scan, cast.operand.*),
        .struct_init => |literal| {
            if (literal.type_name) |ty| {
                if (typeContainsGeneratedMatchName(scan, ty)) return true;
            }
            for (literal.fields) |field| {
                if (scan.namesSomethingElse(field.name)) return true;
                if (exprContainsGeneratedMatchName(scan, field.expr)) return true;
            }
            return false;
        },
        .array_init => |array| {
            if (array.type_name) |ty| {
                if (typeContainsGeneratedMatchName(scan, ty)) return true;
            }
            for (array.elements) |element| {
                if (exprContainsGeneratedMatchName(scan, element)) return true;
            }
            return false;
        },
        .repeat => |repeat| {
            if (repeat.type_name) |ty| {
                if (typeContainsGeneratedMatchName(scan, ty)) return true;
            }
            return exprContainsGeneratedMatchName(scan, repeat.elem.*);
        },
        .multi_array => |array| {
            if (array.type_name) |ty| {
                if (typeContainsGeneratedMatchName(scan, ty)) return true;
            }
            for (array.elements) |element| {
                if (exprContainsGeneratedMatchName(scan, element)) return true;
            }
            return false;
        },
        .tuple => |elements| {
            for (elements) |element| {
                if (exprContainsGeneratedMatchName(scan, element)) return true;
            }
            return false;
        },
        .builtin => |builtin| {
            if (scan.namesSomethingElse(builtin.name)) return true;
            for (builtin.args) |argument| {
                if (exprContainsGeneratedMatchName(scan, argument)) return true;
            }
            return false;
        },
        .if_expr => |if_expression| {
            if (exprContainsGeneratedMatchName(scan, if_expression.cond.*)) return true;
            // A capture binds the payload for its own branch only, so the
            // `else` arm is scanned with the name still unshadowed.
            var then_scan = scan;
            if (if_expression.then_capture) |capture| {
                if (scan.namesSomethingElse(capture.name)) return true;
                if (scan.shadowedByBinding(capture.name)) then_scan = then_scan.shadowedBy();
            }
            if (exprContainsGeneratedMatchName(then_scan, if_expression.then_body.*)) return true;
            if (if_expression.else_body) |else_body| {
                var else_scan = scan;
                if (if_expression.else_capture) |capture| {
                    if (scan.namesSomethingElse(capture.name)) return true;
                    if (scan.shadowedByBinding(capture.name)) {
                        else_scan = else_scan.shadowedBy();
                    }
                }
                return exprContainsGeneratedMatchName(else_scan, else_body.*);
            }
            return false;
        },
        .while_expr => |while_expression| {
            if (while_expression.label) |label| {
                if (scan.namesSomethingElse(label)) return true;
            }
            if (exprContainsGeneratedMatchName(scan, while_expression.cond.*)) return true;
            var body_scan = scan;
            if (while_expression.captures) |captures| {
                for (captures) |capture| {
                    if (scan.namesSomethingElse(capture)) return true;
                    if (scan.shadowedByBinding(capture)) body_scan = body_scan.shadowedBy();
                }
            }
            if (while_expression.continue_expr) |continue_expression| {
                if (exprContainsGeneratedMatchName(body_scan, continue_expression.*)) return true;
            }
            if (blockContainsGeneratedMatchName(while_expression.body, body_scan)) return true;
            if (while_expression.else_body) |else_body| {
                return exprContainsGeneratedMatchName(scan, else_body.*);
            }
            return false;
        },
        .for_expr => |for_expression| {
            if (for_expression.label) |label| {
                if (scan.namesSomethingElse(label)) return true;
            }
            // The inputs are read before the loop binds anything, and the `else`
            // arm runs once the loop is over, outside the capture's scope.
            for (for_expression.inputs) |input| {
                if (exprContainsGeneratedMatchName(scan, input)) return true;
            }
            var body_scan = scan;
            for (for_expression.captures) |capture| {
                if (scan.namesSomethingElse(capture.name)) return true;
                if (scan.shadowedByBinding(capture.name)) {
                    body_scan = body_scan.shadowedBy();
                }
            }
            if (blockContainsGeneratedMatchName(for_expression.body, body_scan)) return true;
            if (for_expression.else_body) |else_body| {
                return exprContainsGeneratedMatchName(scan, else_body.*);
            }
            return false;
        },
        .range => |range| {
            if (exprContainsGeneratedMatchName(scan, range.start.*)) return true;
            if (range.end) |end| return exprContainsGeneratedMatchName(scan, end.*);
            return false;
        },
        .return_expr => |value| {
            if (value) |inner| return exprContainsGeneratedMatchName(scan, inner.*);
            return false;
        },
        .break_expr => |break_expr| {
            if (break_expr.label) |label| {
                if (scan.namesSomethingElse(label)) return true;
            }
            if (break_expr.value) |inner| {
                return exprContainsGeneratedMatchName(scan, inner.*);
            }
            return false;
        },
        .continue_expr => |continue_expr| {
            if (continue_expr.label) |label| {
                return scan.namesSomethingElse(label);
            }
            return false;
        },
        .type_value => |ty| typeContainsGeneratedMatchName(scan, ty),
    };
}

fn freshGeneratedMatchName(
    match: ast.Match,
    active_names: []const GeneratedMatchName,
    active_capture_names: []const []const u8,
    base: []const u8,
) GeneratedMatchName {
    var suffix: usize = 0;
    while (true) : (suffix += 1) {
        const candidate: GeneratedMatchName = .{ .base = base, .suffix = suffix };
        var active = false;
        for (active_names) |name| {
            if (generatedMatchNamesEqual(candidate, name)) {
                active = true;
                break;
            }
        }
        var candidate_buffer: [64]u8 = undefined;
        const candidate_text = generatedMatchNameText(&candidate_buffer, candidate);
        if (!active) {
            for (active_capture_names) |capture_name| {
                if (generatedMatchNameEquals(capture_name, candidate_text)) {
                    active = true;
                    break;
                }
            }
        }
        if (!active and !matchContainsGeneratedMatchName(match, occurrenceScan(candidate_text))) {
            return candidate;
        }
    }
}

/// Picks the label the emitter writes for `scope`, a loop or a block it is
/// about to label. The depth seeds the suffix because two scopes at the same
/// depth never overlap, so their labels can share a suffix; the search then
/// walks forward past anything the scope already uses.
///
/// The scope is searched as a whole, so a name the source itself binds, or a
/// source label it carries, is treated as taken. A Rust identifier is free to
/// spell `__r2z_value_loop_0`, and a generated label must not land on it.
fn freshGeneratedLabel(
    buffer: *[64]u8,
    scope: ast.Expr,
    base: []const u8,
    depth: usize,
) []const u8 {
    var suffix = depth;
    while (true) : (suffix += 1) {
        // The label is spelled with the suffix even at zero, so the text the
        // scope is searched for is the text the emitter writes.
        const candidate_text = std.fmt.bufPrint(buffer, "{s}_{d}", .{ base, suffix }) catch unreachable;
        if (!exprContainsGeneratedMatchName(occurrenceScan(candidate_text), scope)) {
            return candidate_text;
        }
    }
}

pub fn emitExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    expr: ast.Expr,
    depth: usize,
) std.mem.Allocator.Error!void {
    const context: EmitContext = .{};
    try emitExprScoped(&context, allocator, buf, expr, depth);
}

// ---------------------------------------------------------------------------
// Expression Emission
// ---------------------------------------------------------------------------

/// Lowers `for x in chunks.iter()` and the chunk forms to a runtime `while`
/// over an iterator or index. `ForExpr.is_inline` is not honoured here, and
/// cannot be: this path is taken only for a loop driven by a runtime iterator,
/// and Zig unrolls a loop only when its condition is comptime-known. An inline
/// loop always arrives on the plain path.
///
/// Each form's prelude is a statement, and the caller has already placed the
/// first line, so this writes whole lines rather than text to be continued.
/// That is what makes the result a Zig statement — what `writesAsStatement`
/// says a `for` is — and not something a `break` payload could be prefixed
/// onto, which is why no site may put one in front of it.
fn emitChunkLoop(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    loop: ast.ForExpr,
    label: ?[]const u8,
    depth: usize,
) !bool {
    const iterable = loop.inputs[0];
    const ChunkLoop = struct {
        target: ast.Expr,
        size: ?ast.Expr = null,
        iterator: bool = false,
        exact: bool = false,
    };
    const chunks: ChunkLoop = switch (iterable) {
        .builtin => |builtin| blk: {
            if (builtin.args.len == 1 and
                (std.mem.eql(u8, builtin.name, "sliceChunksExactIterator") or
                    std.mem.eql(u8, builtin.name, "iteratorValue")))
            {
                break :blk .{ .target = builtin.args[0], .iterator = true };
            }
            if (builtin.args.len != 2) return false;
            if (std.mem.eql(u8, builtin.name, "sliceChunks")) {
                break :blk .{ .target = builtin.args[0], .size = builtin.args[1] };
            }
            if (std.mem.eql(u8, builtin.name, "sliceChunksExact")) {
                break :blk .{
                    .target = builtin.args[0],
                    .size = builtin.args[1],
                    .exact = true,
                };
            }
            return false;
        },
        .call => |call| switch (call.callee.*) {
            .builtin => |builtin| blk: {
                if (builtin.args.len == 1 and
                    (std.mem.eql(u8, builtin.name, "sliceChunksExactIterator") or
                        std.mem.eql(u8, builtin.name, "iteratorValue")))
                {
                    break :blk .{ .target = builtin.args[0], .iterator = true };
                }
                if (builtin.args.len != 2) return false;
                if (std.mem.eql(u8, builtin.name, "sliceChunks")) {
                    break :blk .{ .target = builtin.args[0], .size = builtin.args[1] };
                }
                if (std.mem.eql(u8, builtin.name, "sliceChunksExact")) {
                    break :blk .{
                        .target = builtin.args[0],
                        .size = builtin.args[1],
                        .exact = true,
                    };
                }
                return false;
            },
            else => return false,
        },
        else => return false,
    };

    const capture: ast.Capture = if (loop.captures.len > 0)
        loop.captures[0]
    else
        .{ .name = "chunk" };
    if (chunks.iterator) {
        // `next` takes `*Self`, so the iterator must live in a mutable place.
        // A Rust `for x in expr` consumes `expr` by value, so binding a fresh
        // temporary also matches the move semantics.
        try buf.appendSlice(allocator, "var __r2z_iter = ");
        try emitExprScoped(context, allocator, buf, chunks.target, depth);
        try buf.appendSlice(allocator, ";\n");
        try emitIndent(allocator, buf, depth);
        try emitSourceLoopLabel(allocator, buf, label);
        try buf.appendSlice(allocator, "while (__r2z_iter.next()) |");
        try emitCaptureBinding(allocator, buf, capture);
        try buf.appendSlice(allocator, "| {\n");
        for (loop.body.stmts) |stmt| {
            try emitStmtScoped(context, allocator, buf, stmt, depth + 1);
        }
        try emitIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "}");
        return true;
    }

    const size = chunks.size.?;
    if (chunks.exact) {
        try buf.appendSlice(allocator, "var __r2z_chunks_exact = r2z.chunksExact(");
        try emitExprScoped(context, allocator, buf, chunks.target, depth);
        try buf.appendSlice(allocator, ", ");
        try emitExprScoped(context, allocator, buf, size, depth);
        try buf.appendSlice(allocator, ");\n");
        try emitIndent(allocator, buf, depth);
        try emitSourceLoopLabel(allocator, buf, label);
        try buf.appendSlice(allocator, "while (__r2z_chunks_exact.next()) |");
        try emitCaptureBinding(allocator, buf, capture);
        try buf.appendSlice(allocator, "| {\n");
        for (loop.body.stmts) |stmt| {
            try emitStmtScoped(context, allocator, buf, stmt, depth + 1);
        }
        try emitIndent(allocator, buf, depth);
        try buf.appendSlice(allocator, "}");
        return true;
    }

    try buf.appendSlice(allocator, "var __chunk_index: usize = 0;\n");
    try emitIndent(allocator, buf, depth);
    try emitSourceLoopLabel(allocator, buf, label);
    try buf.appendSlice(allocator, "while (");
    try emitReceiver(context, allocator, buf, chunks.target, depth);
    try buf.appendSlice(allocator, ".len > __chunk_index) : (__chunk_index += ");
    try emitExprScoped(context, allocator, buf, size, depth);
    try buf.appendSlice(allocator, ") {\n");
    try emitIndent(allocator, buf, depth + 1);
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, capture.name);
    try buf.appendSlice(allocator, " = ");
    try emitReceiver(context, allocator, buf, chunks.target, depth + 1);
    try buf.appendSlice(allocator, "[__chunk_index..@min(__chunk_index + ");
    try emitExprScoped(context, allocator, buf, size, depth + 1);
    try buf.appendSlice(allocator, ", ");
    try emitReceiver(context, allocator, buf, chunks.target, depth + 1);
    try buf.appendSlice(allocator, ".len)];\n");
    for (loop.body.stmts) |stmt| {
        try emitStmtScoped(context, allocator, buf, stmt, depth + 1);
    }
    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}");
    return true;
}

/// True for expressions that bind tighter than `.` and `[`. Prefix unary
/// operators need a group: `(try f()).method()` must not become
/// `try f().method()`. Dereference is postfix and needs no group here.
fn isAtomicExpr(expr: ast.Expr) bool {
    return switch (expr) {
        .lit, .ident, .field_access, .call, .cast, .builtin => true,
        .unary_op => |unary| unary.op == .deref,
        else => false,
    };
}

/// Binding tightness of a binary operator, loosest first. Decides whether a
/// nested bin_op needs parentheses at a given consumption site. The order
/// mirrors Zig's own expression groups: `or` < `and` < the comparisons < `|`
/// < `^` < `&` < the shifts < `+` < `*`. The wrapping and saturating
/// variants share a group with their plain operator.
fn binOpPrecedence(op: ast.BinOpKind) u8 {
    return switch (op) {
        .bool_or => 1,
        .bool_and => 2,
        .equal,
        .not_equal,
        .less_than,
        .less_than_equal,
        .greater_than,
        .greater_than_equal,
        => 3,
        .bit_or => 4,
        .bit_xor => 5,
        .bit_and => 6,
        .shl, .shr => 7,
        .add, .sub, .add_wrap, .sub_wrap, .add_sat, .sub_sat => 8,
        .mul, .div, .mod, .mul_wrap => 9,
    };
}

/// Prefix operators bind tighter than every binary operator, and a range
/// start must be a single primary expression, so both positions use this as
/// the parent binding: every binary child below it needs its own group.
const tight_precedence = 10;

/// True when `child` must be wrapped to keep its own meaning in a slot whose
/// surroundings bind at `parent_precedence`. A looser child would be pulled
/// into the parent's group. An equally tight child does the same on the right
/// of a left-associative operator, which is why `is_right` is only consulted
/// for the equal case: `a - (b - c)` is not `a - b - c`, while `(a - b) - c`
/// needs nothing.
fn needsOperandParens(child: ast.Expr, parent_precedence: u8, is_right: bool) bool {
    return switch (child) {
        .bin_op => |bo| blk: {
            const child_precedence = binOpPrecedence(bo.op);
            break :blk child_precedence < parent_precedence or
                (is_right and child_precedence == parent_precedence);
        },
        // Whole-expression forms, not operands: `if (c) x else y`, `{ ... }`
        // and `S{ ... }` are not values an operator can apply to.
        .if_expr, .block, .match_expr, .struct_init => true,
        else => false,
    };
}

/// Emits `child` in an operand slot under a parent that binds at
/// `parent_precedence`, wrapping it only when precedence demands it.
fn emitOperand(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    child: ast.Expr,
    parent_precedence: u8,
    is_right: bool,
    depth: usize,
) std.mem.Allocator.Error!void {
    const parenthesize = needsOperandParens(child, parent_precedence, is_right);
    if (parenthesize) try buf.append(allocator, '(');
    try emitExprScoped(context, allocator, buf, child, depth);
    if (parenthesize) try buf.append(allocator, ')');
}

/// Emits the operand of a prefix operator. Every prefix operator binds tighter
/// than every binary one, so a binary operand always needs its own group:
/// `&a + b` would take the address of `a`, and `try a + b` is `(try a) + b`.
fn emitPrefixOperand(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    operand: ast.Expr,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitOperand(context, allocator, buf, operand, tight_precedence, false, depth);
}

/// Emits `expr` where Zig wants a single atomic receiver: the target of a
/// field access or an index. A struct literal is the case that needs it,
/// `Range{ .start = 0 }.step_by(2)` does not parse, and neither does
/// `a + b.len`.
fn emitReceiver(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    expr: ast.Expr,
    depth: usize,
) std.mem.Allocator.Error!void {
    const atomic = isAtomicExpr(expr);
    if (!atomic) try buf.append(allocator, '(');
    try emitExprScoped(context, allocator, buf, expr, depth);
    if (!atomic) try buf.append(allocator, ')');
}

fn emitExprScoped(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    expr: ast.Expr,
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (expr) {
        .lit => |l| try emitLiteral(allocator, buf, l),
        .ident => |id| try emitIdent(allocator, buf, id),
        .field_access => |fa| {
            try emitReceiver(context, allocator, buf, fa.target.*, depth);
            try buf.appendSlice(allocator, ".");
            try emitIdent(allocator, buf, fa.field_name);
        },
        .call => |c| {
            try emitReceiver(context, allocator, buf, c.callee.*, depth);
            try buf.appendSlice(allocator, "(");
            var first_arg = true;
            for (c.generic_args) |generic_arg| {
                if (!first_arg) try buf.appendSlice(allocator, ", ");
                first_arg = false;
                try emitType(allocator, buf, generic_arg);
            }
            for (c.args) |arg| {
                if (!first_arg) try buf.appendSlice(allocator, ", ");
                first_arg = false;
                try emitExprScoped(context, allocator, buf, arg, depth);
            }
            try buf.appendSlice(allocator, ")");
        },
        .block => |b| {
            try emitBlockScoped(context, allocator, buf, b, depth);
        },
        .match_expr => |match| try emitMatchExpr(context, allocator, buf, match, depth),
        .cast => |cast| {
            try buf.appendSlice(allocator, "@as(");
            try emitType(allocator, buf, cast.target);
            try buf.appendSlice(allocator, ", ");
            try emitExprScoped(context, allocator, buf, cast.operand.*, depth);
            try buf.appendSlice(allocator, ")");
        },
        .bin_op => |bo| {
            const precedence = binOpPrecedence(bo.op);
            try emitOperand(context, allocator, buf, bo.lhs.*, precedence, false, depth);
            const op_sym = switch (bo.op) {
                .add => " + ",
                .sub => " - ",
                .mul => " * ",
                .div => " / ",
                .mod => " % ",
                .bit_and => " & ",
                .bit_or => " | ",
                .bit_xor => " ^ ",
                .shl => " << ",
                .shr => " >> ",
                .equal => " == ",
                .not_equal => " != ",
                .less_than => " < ",
                .less_than_equal => " <= ",
                .greater_than => " > ",
                .greater_than_equal => " >= ",
                .bool_and => " and ",
                .bool_or => " or ",
                .add_wrap => " +% ",
                .sub_wrap => " -% ",
                .mul_wrap => " *% ",
                .add_sat => " +| ",
                .sub_sat => " -| ",
            };
            try buf.appendSlice(allocator, op_sym);
            try emitOperand(context, allocator, buf, bo.rhs.*, precedence, true, depth);
        },
        .unary_op => |uo| {
            switch (uo.op) {
                .negate => {
                    try buf.appendSlice(allocator, "-");
                    try emitPrefixOperand(context, allocator, buf, uo.operand.*, depth);
                },
                .bit_not => {
                    try buf.appendSlice(allocator, "~");
                    try emitPrefixOperand(context, allocator, buf, uo.operand.*, depth);
                },
                .bool_not => {
                    try buf.appendSlice(allocator, "!");
                    try emitPrefixOperand(context, allocator, buf, uo.operand.*, depth);
                },
                .deref => {
                    // A nested prefix operand loses its group without the
                    // wrap: `&x.*` reads as `&(x.*)`, not `(&x).*`.
                    const parenthesize = switch (uo.operand.*) {
                        .unary_op => true,
                        else => needsOperandParens(uo.operand.*, tight_precedence, false),
                    };
                    if (parenthesize) try buf.append(allocator, '(');
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
                    if (parenthesize) try buf.append(allocator, ')');
                    try buf.appendSlice(allocator, ".*");
                },
                .addr_of => {
                    try buf.appendSlice(allocator, "&");
                    try emitPrefixOperand(context, allocator, buf, uo.operand.*, depth);
                },
                .try_op => {
                    try buf.appendSlice(allocator, "try ");
                    try emitPrefixOperand(context, allocator, buf, uo.operand.*, depth);
                },
            }
        },
        .struct_init => |si| {
            if (si.type_name) |tn| {
                try emitType(allocator, buf, tn);
            } else {
                try buf.appendSlice(allocator, ".");
            }
            try buf.appendSlice(allocator, "{");
            if (si.fields.len > 0) {
                try buf.appendSlice(allocator, " ");
                for (si.fields, 0..) |f, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, ".");
                    try emitIdent(allocator, buf, f.name);
                    try buf.appendSlice(allocator, " = ");
                    try emitExprScoped(context, allocator, buf, f.expr, depth);
                }
                try buf.appendSlice(allocator, " ");
            }
            try buf.appendSlice(allocator, "}");
        },
        .array_init => |ai| {
            if (ai.type_name) |tn| {
                try emitType(allocator, buf, tn);
            } else {
                try buf.appendSlice(allocator, ".");
            }
            try buf.appendSlice(allocator, "{");
            if (ai.elements.len > 0) {
                try buf.appendSlice(allocator, " ");
                for (ai.elements, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try emitExprScoped(context, allocator, buf, elem, depth);
                }
                try buf.appendSlice(allocator, " ");
            }
            try buf.appendSlice(allocator, "}");
        },
        .multi_array => |ma| {
            if (ma.type_name) |tn| {
                try buf.appendSlice(allocator, "[_]");
                try emitType(allocator, buf, tn);
            } else {
                try buf.appendSlice(allocator, ".");
            }
            try buf.appendSlice(allocator, "{");
            if (ma.elements.len > 0) {
                try buf.appendSlice(allocator, " ");
                for (ma.elements, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try emitExprScoped(context, allocator, buf, elem, depth);
                }
                try buf.appendSlice(allocator, " ");
            }
            try buf.appendSlice(allocator, "}");
        },
        .tuple => |elements| {
            try buf.appendSlice(allocator, ".{");
            if (elements.len > 0) {
                try buf.appendSlice(allocator, " ");
                for (elements, 0..) |element, index| {
                    if (index > 0) try buf.appendSlice(allocator, ", ");
                    try emitExprScoped(context, allocator, buf, element, depth);
                }
                try buf.appendSlice(allocator, " ");
            }
            try buf.appendSlice(allocator, "}");
        },
        .repeat => |rp| {
            if (rp.type_name) |tn| {
                try buf.appendSlice(allocator, "[_]");
                try emitType(allocator, buf, tn);
            } else {
                try buf.appendSlice(allocator, ".");
            }
            try buf.appendSlice(allocator, "{ ");
            try emitExprScoped(context, allocator, buf, rp.elem.*, depth);
            try buf.appendSlice(allocator, " } ** ");
            try buf.print(allocator, "{d}", .{rp.len});
        },
        .builtin => |bi| {
            if (std.mem.eql(u8, bi.name, "index") and bi.args.len == 2) {
                try emitReceiver(context, allocator, buf, bi.args[0], depth);
                try buf.appendSlice(allocator, "[");
                try emitExprScoped(context, allocator, buf, bi.args[1], depth);
                try buf.appendSlice(allocator, "]");
            } else if (std.mem.eql(u8, bi.name, "sliceChunks") and bi.args.len == 2) {
                try emitReceiver(context, allocator, buf, bi.args[0], depth);
                try buf.appendSlice(allocator, ".chunks(");
                try emitExprScoped(context, allocator, buf, bi.args[1], depth);
                try buf.appendSlice(allocator, ")");
            } else if ((std.mem.eql(u8, bi.name, "splitAt") and bi.args.len == 2) or
                (std.mem.eql(u8, bi.name, "sliceChunksExact") and bi.args.len == 2) or
                (std.mem.eql(u8, bi.name, "chunksExactRemainder") and bi.args.len == 1))
            {
                const runtime_name = if (std.mem.eql(u8, bi.name, "splitAt"))
                    "splitAt"
                else if (std.mem.eql(u8, bi.name, "sliceChunksExact"))
                    "chunksExact"
                else
                    "chunksExactRemainder";
                try buf.appendSlice(allocator, "r2z.");
                try buf.appendSlice(allocator, runtime_name);
                try buf.appendSlice(allocator, "(");
                for (bi.args, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try emitExprScoped(context, allocator, buf, arg, depth);
                }
                try buf.appendSlice(allocator, ")");
            } else {
                try buf.appendSlice(allocator, "@");
                try buf.appendSlice(allocator, bi.name);
                try buf.appendSlice(allocator, "(");
                for (bi.args, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try emitExprScoped(context, allocator, buf, arg, depth);
                }
                try buf.appendSlice(allocator, ")");
            }
        },
        .unit => try buf.appendSlice(allocator, "@as(void, {})"),
        .panic_ => |message| {
            try buf.appendSlice(allocator, "@panic(\"");
            try emitEscapedString(allocator, buf, message);
            try buf.appendSlice(allocator, "\")");
        },
        .unsupported => |u| {
            try buf.appendSlice(allocator, "@panic(\"unsupported: ");
            try emitEscapedString(allocator, buf, u);
            try buf.appendSlice(allocator, "\")");
        },
        .if_expr => |ie| {
            try buf.appendSlice(allocator, "if (");
            try emitExprScoped(context, allocator, buf, ie.cond.*, depth);
            try buf.appendSlice(allocator, ") ");
            try emitIfCapture(allocator, buf, ie.then_capture);
            try emitExprScoped(context, allocator, buf, ie.then_body.*, depth);
            if (ie.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitIfCapture(allocator, buf, ie.else_capture);
                try emitExprScoped(context, allocator, buf, eb.*, depth);
            }
        },
        .while_expr => |we| {
            if (loopYieldsValue(we)) {
                try emitValueLoopScoped(context, allocator, buf, we, depth);
                return;
            }
            try emitWhileScoped(context, allocator, buf, we, depth);
        },
        .for_expr => |fe| {
            const target: ExitTarget = .{
                .source_label = fe.label,
                .innermost_loop = true,
                .break_label = fe.label,
                .continue_label = fe.label,
                .kind = .loop,
            };
            var loop_scope: ExitScope = .{
                .target = target,
                .parent = context.exit_scope,
            };
            var loop_context = context.*;
            loop_context.exit_scope = &loop_scope;
            const label = usedLoopLabel(fe.body, target);
            if (try emitChunkLoop(&loop_context, allocator, buf, fe, label, depth)) return;
            try emitSourceLoopLabel(allocator, buf, label);
            // Zig reads a block label, then an optional `inline`, then `for`,
            // so the keyword goes after whatever label was just written.
            if (fe.is_inline) try buf.appendSlice(allocator, "inline ");
            try buf.appendSlice(allocator, "for (");
            for (fe.inputs, 0..) |inp, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitExprScoped(&loop_context, allocator, buf, inp, depth);
            }
            try buf.appendSlice(allocator, ") |");
            for (fe.captures, 0..) |cap, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitCaptureBinding(allocator, buf, cap);
            }
            try buf.appendSlice(allocator, "| ");
            try emitBlockScoped(&loop_context, allocator, buf, fe.body, depth);
            if (fe.else_body) |eb| {
                // The `else` arm runs once the loop is over, so an exit in it
                // belongs to whatever is outside the loop.
                try buf.appendSlice(allocator, " else ");
                try emitExprScoped(context, allocator, buf, eb.*, depth);
            }
        },
        .range => |r| {
            // A range start has to be one primary expression: `a + b..c` does
            // not parse, the addition swallows the declaration.
            try emitOperand(context, allocator, buf, r.start.*, tight_precedence, false, depth);
            try buf.appendSlice(allocator, "..");
            if (r.end) |en| try emitExprScoped(context, allocator, buf, en.*, depth);
        },
        .return_expr => |re| {
            if (re) |val| {
                try buf.appendSlice(allocator, "return ");
                try emitExprScoped(context, allocator, buf, val.*, depth);
            } else {
                try buf.appendSlice(allocator, "return");
            }
        },
        .break_expr => |break_expr| {
            // A labeled exit names the source target it belongs to. An
            // unlabeled one leaves the innermost enclosing loop, whatever
            // labels the loops around it carry, so it resolves to the loop
            // target and not to any block the emitter generated inside it.
            const target = if (break_expr.label) |label|
                findExitTarget(context.exit_scope, label)
            else
                findInnermostLoopTarget(context.exit_scope);
            const named_label: ?[]const u8 = if (target) |exit| exit.break_label else null;
            if (break_expr.value) |val| {
                try buf.appendSlice(allocator, "break ");
                if (named_label) |label| {
                    try buf.appendSlice(allocator, ":");
                    try emitIdent(allocator, buf, label);
                    try buf.appendSlice(allocator, " ");
                }
                try emitExprScoped(context, allocator, buf, val.*, depth);
            } else {
                try buf.appendSlice(allocator, "break");
                if (named_label) |label| {
                    try buf.appendSlice(allocator, " :");
                    try emitIdent(allocator, buf, label);
                }
            }
        },
        .continue_expr => |continue_expr| {
            // `continue` restarts a loop and never a block, so the chain skips
            // every block target and lands on the loop that answers to this
            // label.
            const target = if (continue_expr.label) |label|
                findContinueTarget(context.exit_scope, label)
            else
                findInnermostLoopTarget(context.exit_scope);
            try buf.appendSlice(allocator, "continue");
            if (target) |exit| {
                if (exit.continue_label) |label| {
                    try buf.appendSlice(allocator, " :");
                    try emitIdent(allocator, buf, label);
                }
            }
        },
        .unreachable_ => try buf.appendSlice(allocator, "unreachable"),
        .type_value => |ty| try emitType(allocator, buf, ty),
    }
}

/// Writes the `label: ` prefix a Zig loop carries, or nothing when the source
/// loop has no label.
fn emitSourceLoopLabel(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    label: ?[]const u8,
) std.mem.Allocator.Error!void {
    const text = label orelse return;
    try emitIdent(allocator, buf, text);
    try buf.appendSlice(allocator, ": ");
}

/// Writes the loop header, up to but not including its body. The target is
/// passed in because it decides the label: only the label an exit really
/// lands on may be written.
fn emitWhileHeader(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    loop_expr: ast.WhileExpr,
    target: ExitTarget,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitSourceLoopLabel(allocator, buf, usedLoopLabel(loop_expr.body, target));
    try buf.appendSlice(allocator, "while (");
    try emitExprScoped(context, allocator, buf, loop_expr.cond.*, depth);
    try buf.appendSlice(allocator, ")");
    if (loop_expr.captures) |caps| {
        try buf.appendSlice(allocator, " |");
        for (caps, 0..) |cap, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, cap);
        }
        try buf.appendSlice(allocator, "|");
    }
    if (loop_expr.continue_expr) |ce| {
        try buf.appendSlice(allocator, " : (");
        try emitExprScoped(context, allocator, buf, ce.*, depth);
        try buf.appendSlice(allocator, ")");
    }
    try buf.appendSlice(allocator, " ");
}

/// Emits the body and the `else` arm of a loop whose header is already out.
/// The exit target is pushed here, so it covers the body and nothing else.
fn emitLoopBodyScoped(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    loop_expr: ast.WhileExpr,
    target: ExitTarget,
    depth: usize,
) std.mem.Allocator.Error!void {
    // The target outlives the body because the body is emitted below, still
    // inside this frame.
    var loop_scope: ExitScope = .{ .target = target, .parent = context.exit_scope };
    var loop_context = context.*;
    loop_context.exit_scope = &loop_scope;
    try emitBlockScoped(&loop_context, allocator, buf, loop_expr.body, depth);
    if (loop_expr.else_body) |eb| {
        // The `else` arm runs once the loop is over, so an exit in it belongs
        // to whatever is outside the loop rather than to the loop.
        try buf.appendSlice(allocator, " else ");
        try emitExprScoped(context, allocator, buf, eb.*, depth);
    }
}

/// Emits a plain `while`. Entering the loop happens here, so every nested
/// `break` inside the body resolves against it.
fn emitWhileScoped(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    loop_expr: ast.WhileExpr,
    depth: usize,
) std.mem.Allocator.Error!void {
    const target: ExitTarget = .{
        .source_label = loop_expr.label,
        .innermost_loop = true,
        .break_label = loop_expr.label,
        .continue_label = loop_expr.label,
        .kind = .loop,
    };
    try emitWhileHeader(context, allocator, buf, loop_expr, target, depth);
    try emitLoopBodyScoped(context, allocator, buf, loop_expr, target, depth);
}

/// Emits a loop that carries a value out of itself. Zig's `while` takes its
/// value from a `break` that names it, but a loop can only be labelled from
/// the outside, so the loop goes inside a labelled block and its own
/// value-carrying breaks name that block. Labelling the loop *body* instead
/// does not work: Zig then wants one type from every path through that block,
/// and the loop result stays void.
///
/// The two scopes stand for one Rust loop, so the chain records both: `break`
/// names the wrapper block that carries the value and `continue` names the
/// `while` itself, which is the scope Zig actually restarts.
fn emitValueLoopScoped(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    loop_expr: ast.WhileExpr,
    depth: usize,
) std.mem.Allocator.Error!void {
    var label_buffer: [64]u8 = undefined;
    const label = freshGeneratedLabel(
        &label_buffer,
        .{ .while_expr = loop_expr },
        value_loop_base,
        depth,
    );
    try emitIdent(allocator, buf, label);
    try buf.appendSlice(allocator, ": {\n");
    const target: ExitTarget = .{
        .source_label = loop_expr.label,
        .innermost_loop = true,
        .break_label = label,
        .continue_label = loop_expr.label,
        .kind = .loop,
    };
    try emitWhileHeader(context, allocator, buf, loop_expr, target, depth);
    try emitLoopBodyScoped(context, allocator, buf, loop_expr, target, depth);
    try buf.appendSlice(allocator, "}");
}

fn emitMatchExpr(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    match: ast.Match,
    depth: usize,
) std.mem.Allocator.Error!void {
    var active_names: std.ArrayListUnmanaged(GeneratedMatchName) = .empty;
    defer active_names.deinit(allocator);
    try active_names.appendSlice(allocator, context.active_names);

    try buf.appendSlice(allocator, "switch (");
    try emitExprScoped(context, allocator, buf, match.target.*, depth);
    try buf.appendSlice(allocator, ") {\n");

    for (match.arms) |arm| {
        var arm_capture_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer arm_capture_names.deinit(allocator);
        try arm_capture_names.appendSlice(allocator, context.active_capture_names);
        if (arm.capture) |capture| {
            try arm_capture_names.append(allocator, capture.name);
        }

        try emitIndent(allocator, buf, depth + 1);

        var has_wildcard = arm.patterns.len == 0;
        var selector_count: usize = 0;
        for (arm.patterns) |pattern| {
            switch (pattern) {
                .wildcard => has_wildcard = true,
                .binding => {},
                else => selector_count += 1,
            }
        }

        if (has_wildcard or selector_count == 0) {
            try buf.appendSlice(allocator, "else");
        } else {
            var selector_index: usize = 0;
            for (arm.patterns) |pattern| {
                if (pattern == .binding) continue;
                if (selector_index > 0) try buf.appendSlice(allocator, ", ");
                selector_index += 1;
                try emitMatchSelector(allocator, buf, pattern);
            }
        }

        const body_is_unsupported = arm.body == .unsupported;
        const explicit_capture = if (body_is_unsupported) null else arm.capture;
        const direct_binding = if (explicit_capture != null)
            null
        else if (body_is_unsupported)
            null
        else
            matchDirectBinding(arm);
        const struct_pattern = matchStructPattern(arm);
        const needs_destructure = if (explicit_capture != null)
            false
        else if (body_is_unsupported)
            false
        else if (struct_pattern) |pattern|
            matchNeedsDestructure(pattern)
        else
            false;

        try buf.appendSlice(allocator, " =>");
        if (explicit_capture) |capture| {
            // Zig refuses a capture nothing reads: naming one is `error: unused
            // capture`, and discarding it as `_` is `error: discard of
            // capture`. An arm that only tests the tag writes no capture.
            if (exprContainsGeneratedMatchName(occurrenceScan(capture.name), arm.body)) {
                try buf.appendSlice(allocator, " |");
                if (capture.by_ref) try buf.appendSlice(allocator, "*");
                try emitIdent(allocator, buf, capture.name);
                try buf.appendSlice(allocator, "|");
            }
        } else if (direct_binding) |binding| {
            if (exprContainsGeneratedMatchName(occurrenceScan(binding), arm.body)) {
                try buf.appendSlice(allocator, " |");
                try emitIdent(allocator, buf, binding);
                try buf.appendSlice(allocator, "|");
            }
        }
        if (needs_destructure) {
            const payload_name = freshGeneratedMatchName(
                match,
                active_names.items,
                arm_capture_names.items,
                match_payload_base,
            );
            try active_names.append(allocator, payload_name);
            const arm_name = freshGeneratedMatchName(
                match,
                active_names.items,
                arm_capture_names.items,
                match_arm_base,
            );
            try active_names.append(allocator, arm_name);
            // The prong is still inside every scope around it: a `break` an arm
            // body carries leaves through the label of the block or loop that
            // opened it, which is what the generated match chain and a
            // collection's own exit block rely on.
            const arm_context: EmitContext = .{
                .active_names = active_names.items,
                .active_capture_names = arm_capture_names.items,
                .exit_scope = context.exit_scope,
            };

            try buf.appendSlice(allocator, " |");
            try emitGeneratedMatchName(allocator, buf, payload_name);
            try buf.appendSlice(allocator, "| ");
            try emitMatchDestructureBody(
                &arm_context,
                allocator,
                buf,
                struct_pattern.?,
                arm.body,
                payload_name,
                arm_name,
                depth,
            );
        } else {
            try buf.appendSlice(allocator, " ");
            if (explicit_capture != null) {
                const arm_context: EmitContext = .{
                    .active_names = active_names.items,
                    .active_capture_names = arm_capture_names.items,
                    .exit_scope = context.exit_scope,
                };
                try emitExprScoped(&arm_context, allocator, buf, arm.body, depth + 1);
            } else {
                try emitExprScoped(context, allocator, buf, arm.body, depth + 1);
            }
        }
        try buf.appendSlice(allocator, ",\n");
    }

    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}");
}

fn emitMatchSelector(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    pattern: ast.Pattern,
) std.mem.Allocator.Error!void {
    switch (pattern) {
        .struct_pat => |struct_pattern| {
            const name = struct_pattern.name orelse {
                try buf.appendSlice(allocator, "else");
                return;
            };
            try buf.appendSlice(allocator, ".");
            try emitIdent(allocator, buf, name);
        },
        else => try emitPattern(allocator, buf, pattern),
    }
}

fn matchStructPattern(arm: ast.MatchArm) ?ast.StructPattern {
    for (arm.patterns) |pattern| {
        if (pattern == .struct_pat) return pattern.struct_pat;
    }
    return null;
}

fn matchDirectBinding(arm: ast.MatchArm) ?[]const u8 {
    for (arm.patterns) |pattern| {
        if (pattern == .binding) return pattern.binding;
    }

    const struct_pattern = matchStructPattern(arm) orelse return null;
    if (struct_pattern.fields.len != 1) return null;
    const field = struct_pattern.fields[0];
    if (!std.mem.eql(u8, field.name, "0")) return null;
    return switch (field.pat) {
        .binding => |binding| binding,
        else => null,
    };
}

fn matchNeedsDestructure(pattern: ast.StructPattern) bool {
    if (pattern.fields.len == 1 and
        std.mem.eql(u8, pattern.fields[0].name, "0") and
        pattern.fields[0].pat == .binding)
    {
        return false;
    }
    for (pattern.fields) |field| {
        if (field.pat == .binding) return true;
    }
    return false;
}

fn emitMatchDestructureBody(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    pattern: ast.StructPattern,
    body: ast.Expr,
    payload_name: GeneratedMatchName,
    arm_name: GeneratedMatchName,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitGeneratedMatchName(allocator, buf, arm_name);
    try buf.appendSlice(allocator, ": {\n");
    for (pattern.fields) |field| {
        const binding = switch (field.pat) {
            .binding => |name| name,
            else => continue,
        };
        try emitIndent(allocator, buf, depth + 2);
        try buf.appendSlice(allocator, "const ");
        try emitIdent(allocator, buf, binding);
        try buf.appendSlice(allocator, " = ");
        try emitGeneratedMatchName(allocator, buf, payload_name);
        try buf.appendSlice(allocator, ".");
        try emitIdent(allocator, buf, field.name);
        try buf.appendSlice(allocator, ";\n");
    }

    try emitIndent(allocator, buf, depth + 2);
    switch (body) {
        .return_expr, .break_expr, .continue_expr, .unreachable_, .panic_ => {
            try emitExprScoped(context, allocator, buf, body, depth + 2);
            try buf.appendSlice(allocator, ";\n");
        },
        else => {
            try buf.appendSlice(allocator, "break :");
            try emitGeneratedMatchName(allocator, buf, arm_name);
            try buf.appendSlice(allocator, " ");
            try emitExprScoped(context, allocator, buf, body, depth + 2);
            try buf.appendSlice(allocator, ";\n");
        },
    }
    try emitIndent(allocator, buf, depth + 1);
    try buf.appendSlice(allocator, "}");
}

/// Zig refuses a local nothing reads; Rust allows an unused binding. A
/// declaration no other statement in its block names is therefore emitted as
/// `_ = <init>;`: the initialiser still runs for its effects and the
/// unused-local error does not. A name that DOES occur keeps its binding,
/// because a false positive here would discard a value that is live.
fn unusedBindingAsDiscard(
    allocator: std.mem.Allocator,
    block: ast.Block,
    index: usize,
    stmt: ast.Stmt,
) !ast.Stmt {
    _ = allocator;
    const let_stmt = switch (stmt) {
        .let_stmt => |value| value,
        else => return stmt,
    };
    const name = let_stmt.name;
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return stmt;
    // A `.unit` initialiser is either "no initialiser" — the source bound the
    // name and assigned it later, and that assignment is the use this scan
    // cannot see — or a real unit value, which `_ =` would not accept.
    if (let_stmt.init == .unit) return stmt;
    if (blockReadsNameOutside(block, index, name)) return stmt;
    return .{ .assign = .{ .target = .{ .ident = "_" }, .val = let_stmt.init } };
}

/// Whether a function body reads the parameter `name`. The `self` receiver and
/// every ordinary parameter ask this one question, so the two rules cannot
/// disagree about what "read" means.
///
/// The scan descends through every block, loop, match arm and inlined closure
/// body the AST can carry, so a read that happens only inside one of those
/// still counts. Nothing can hide a read behind an opaque node: the Zig AST has
/// no closure and no macro variant, because the lowerer inlines a closure at
/// its call site and the frontend has already expanded a macro, so both reach
/// the emitter as ordinary statements.
///
/// What it asks is the READ question, not the occurrence question: a binding
/// that shadows `name` is not a read of it, and the rest of the scope that
/// binding opens stops counting. Every kind of binding is covered by that one
/// rule, in whatever scope it appears — a `let`, a match pattern, an arm
/// capture, a `for` or `while` payload, an `if` capture — because
/// `blockContainsGeneratedMatchName` carries a `shadowed` flag down through
/// each of them rather than re-deciding the question per arm. A closure
/// parameter arrives as one of those (the lowerer inlines the closure and its
/// parameters become a payload or a `let`), so it needs no case of its own.
///
/// The other direction is what makes the rule safe to apply: Rust introduces a
/// local only after its initialiser is produced, so a shadowing `let`'s
/// initialiser and type annotation still read the parameter and a read BEFORE
/// the shadow still counts. Both are scanned before the shadow is set.
fn bodyReadsParam(body: ast.Block, name: []const u8) bool {
    return blockContainsGeneratedMatchName(body, .{ .name = name, .mode = .read });
}

/// Whether any statement other than `index`, or the block's tail, names
/// `name`. This is the LOCAL-binding rule, and it asks the OCCURRENCE
/// question on purpose: it cannot tell a shadowing `let` from a read, and a
/// name that occurs anywhere else in the block has to keep its binding,
/// because a false positive here would discard a value that is live.
fn blockReadsNameOutside(block: ast.Block, index: usize, name: []const u8) bool {
    const scan = occurrenceScan(name);
    for (block.stmts, 0..) |stmt, other| {
        if (other == index) continue;
        if (stmtContainsGeneratedMatchName(scan, stmt)) return true;
    }
    if (block.expr) |tail| {
        if (exprContainsGeneratedMatchName(scan, tail.*)) return true;
    }
    return false;
}

fn emitBlockScoped(
    context: *const EmitContext,
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    block: ast.Block,
    depth: usize,
) std.mem.Allocator.Error!void {
    var generated_label_buffer: [64]u8 = undefined;
    const value_label: ?[]const u8 = if (block.label) |label|
        label
    else if (blockHasValue(block))
        freshGeneratedLabel(
            &generated_label_buffer,
            .{ .block = block },
            value_block_base,
            depth,
        )
    else
        null;
    // A labelled block is its own exit target. It never claims an unlabeled
    // `break`: in Rust that still belongs to the loop around the block, so
    // only an exit naming this block's label stops here.
    var block_context = context.*;
    if (value_label) |label| {
        var block_scope: ExitScope = .{
            .target = .{
                .source_label = block.label,
                .innermost_loop = false,
                .break_label = label,
                .continue_label = null,
                .kind = .block,
            },
            .parent = context.exit_scope,
        };
        block_context.exit_scope = &block_scope;
        try emitIdent(allocator, buf, label);
        try buf.appendSlice(allocator, ": ");
    }
    try buf.appendSlice(allocator, "{\n");
    for (block.stmts, 0..) |stmt, index| {
        try emitStmtScoped(
            &block_context,
            allocator,
            buf,
            try unusedBindingAsDiscard(allocator, block, index, stmt),
            depth + 1,
        );
    }
    if (block.expr) |tail| {
        try emitIndent(allocator, buf, depth + 1);
        // The same rule a function body tail follows. The label above is
        // written when `blockHasValue` holds, and that is exactly when the
        // tail is a value, so a `value` tail always has a label to leave
        // through — while a unit `for` tail, which Zig spells as a statement,
        // must not have one prefixed onto it.
        switch (blockTailRole(tail.*)) {
            .value => {
                try buf.appendSlice(allocator, "break :");
                try emitIdent(allocator, buf, value_label.?);
                try buf.appendSlice(allocator, " ");
                try emitExprScoped(&block_context, allocator, buf, tail.*, depth + 1);
                try buf.appendSlice(allocator, ";\n");
            },
            .statement => {
                try emitExprScoped(&block_context, allocator, buf, tail.*, depth + 1);
                try buf.appendSlice(allocator, "\n");
            },
            .exit => {
                try emitExprScoped(&block_context, allocator, buf, tail.*, depth + 1);
                try buf.appendSlice(allocator, ";\n");
            },
        }
    }
    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}");
}

fn emitLiteral(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), lit: ast.Literal) !void {
    switch (lit) {
        .int => |i| {
            try buf.print(allocator, "{d}", .{i});
        },
        .uint => |u| {
            try buf.print(allocator, "{d}", .{u});
        },
        .float => |f| {
            if (std.math.isNan(f)) {
                try buf.appendSlice(allocator, "@as(f64, std.math.nan(f64))");
            } else if (std.math.isPositiveInf(f)) {
                try buf.appendSlice(allocator, "@as(f64, std.math.inf(f64))");
            } else if (std.math.isNegativeInf(f)) {
                try buf.appendSlice(allocator, "-@as(f64, std.math.inf(f64))");
            } else {
                const start = buf.items.len;
                try buf.print(allocator, "{d}", .{f});
                const s = buf.items[start..];
                if (!std.mem.containsAtLeast(u8, s, 1, ".") and
                    !std.mem.containsAtLeast(u8, s, 1, "e") and
                    !std.mem.containsAtLeast(u8, s, 1, "E"))
                {
                    try buf.appendSlice(allocator, ".0");
                }
            }
        },
        .bool_lit => |b| {
            try buf.appendSlice(allocator, if (b) "true" else "false");
        },
        .char_lit => |c| {
            try buf.appendSlice(allocator, "'");
            if (c == '\'') {
                try buf.appendSlice(allocator, "\\'");
            } else if (c == '\\') {
                try buf.appendSlice(allocator, "\\\\");
            } else if (c == '\n') {
                try buf.appendSlice(allocator, "\\n");
            } else if (c == '\r') {
                try buf.appendSlice(allocator, "\\r");
            } else if (c == '\t') {
                try buf.appendSlice(allocator, "\\t");
            } else if (c == 0) {
                try buf.appendSlice(allocator, "\\x00");
            } else if (c >= 0x20 and c <= 0x7e) {
                try buf.append(allocator, @intCast(c));
            } else {
                try buf.print(allocator, "\\u{{{x}}}", .{c});
            }
            try buf.appendSlice(allocator, "'");
        },
        .str => |s| {
            try buf.appendSlice(allocator, "\"");
            try emitEscapedString(allocator, buf, s);
            try buf.appendSlice(allocator, "\"");
        },
        // A Zig error-set value is `error.<tag>`, never a field of a user
        // binding, so the tag is the only part that needs escaping.
        .error_tag => |tag| {
            try buf.appendSlice(allocator, "error.");
            try emitIdent(allocator, buf, tag);
        },
        .null_lit => try buf.appendSlice(allocator, "null"),
        .undefined_lit => try buf.appendSlice(allocator, "undefined"),
    }
}

// ---------------------------------------------------------------------------
// Pattern Emission
// ---------------------------------------------------------------------------

pub fn emitPattern(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    pat: ast.Pattern,
) std.mem.Allocator.Error!void {
    switch (pat) {
        .wildcard => try buf.appendSlice(allocator, "_"),
        .binding => |b| try emitIdent(allocator, buf, b),
        .lit => |l| try emitLiteral(allocator, buf, l),
        .enum_literal => |el| {
            try buf.appendSlice(allocator, ".");
            try emitIdent(allocator, buf, el);
        },
        .tuple => |tp| {
            try buf.appendSlice(allocator, ".{");
            for (tp, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitPattern(allocator, buf, p);
            }
            try buf.appendSlice(allocator, "}");
        },
        .struct_pat => |sp| {
            if (sp.name) |name| {
                try buf.appendSlice(allocator, ".");
                try emitIdent(allocator, buf, name);
            } else {
                try buf.appendSlice(allocator, "_");
            }
        },
        // Zig 0.16 accepts only `lo...hi` in a switch prong: `lo..hi` and the
        // open-ended `...hi` / `lo...` are all syntax errors, so an exclusive
        // bound shifts to `hi - 1` and an unbounded side has no valid spelling
        // and degrades to the wildcard rather than emitting uncompilable Zig.
        .range_pat => |rp| {
            if (rp.lo != null and rp.hi != null) {
                try emitLiteral(allocator, buf, rp.lo.?);
                try buf.appendSlice(allocator, "...");
                if (rp.inclusive) {
                    try emitLiteral(allocator, buf, rp.hi.?);
                } else {
                    try buf.appendSlice(allocator, "(");
                    try emitLiteral(allocator, buf, rp.hi.?);
                    try buf.appendSlice(allocator, " - 1)");
                }
            } else {
                try buf.appendSlice(allocator, "_");
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Type Emission
// ---------------------------------------------------------------------------

/// Zig's type grammar, narrowed to the shapes this AST can spell: a name, a
/// qualified name, a generic call, a builtin, and a compile-time `if` whose
/// branches are types. That last one is how a conditional borrow is written:
/// `if (rustHashRefIsFat(D)) RustHashRef(D, true) else RustHashRef(D, false)`.
/// Every other expression is a value, and splicing one behind the `*`, `[]`,
/// or `?` it is nested in would let that surrounding type bind part of it and
/// read as a different type, so it is wrapped instead of read.
fn isTypeExpr(expr: ast.Expr) bool {
    return switch (expr) {
        .ident, .field_access, .call, .builtin, .if_expr, .type_value => true,
        else => false,
    };
}

/// Emits the expression that names a `Type.expr`. Depth and the empty context
/// are the ones `array_expr` uses for its length: a type value stands where a
/// length expression does, and neither carries a loop scope of its own.
fn emitTypeExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    expr: ast.Expr,
) std.mem.Allocator.Error!void {
    const is_type = isTypeExpr(expr);
    if (!is_type) try buf.append(allocator, '(');
    try emitExpr(allocator, buf, expr, 0);
    if (!is_type) try buf.append(allocator, ')');
}

pub fn emitType(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    ty: ast.Type,
) std.mem.Allocator.Error!void {
    switch (ty) {
        .prim => |p| {
            const p_str = switch (p) {
                .u8 => "u8",
                .u16 => "u16",
                .u21 => "u21",
                .u32 => "u32",
                .u64 => "u64",
                .u128 => "u128",
                .usize => "usize",
                .i8 => "i8",
                .i16 => "i16",
                .i32 => "i32",
                .i64 => "i64",
                .i128 => "i128",
                .isize => "isize",
                .f32 => "f32",
                .f64 => "f64",
                .bool => "bool",
                .void_type => "void",
                .noreturn_type => "noreturn",
                .type_type => "type",
                .anyerror_type => "anyerror",
            };
            try buf.appendSlice(allocator, p_str);
        },
        .ptr => |p| {
            switch (p.size) {
                .one => try buf.appendSlice(allocator, "*"),
                .many => try buf.appendSlice(allocator, "[*]"),
                .c => try buf.appendSlice(allocator, "[*c]"),
            }
            if (p.alignment) |alignment| {
                try buf.print(allocator, "align({d}) ", .{alignment});
            }
            if (p.is_allowzero) try buf.appendSlice(allocator, "allowzero ");
            if (p.is_const) {
                try buf.appendSlice(allocator, "const ");
            }
            try emitType(allocator, buf, p.elem.*);
        },
        .slice => |s| {
            try buf.appendSlice(allocator, "[]");
            if (s.is_const) {
                try buf.appendSlice(allocator, "const ");
            }
            try emitType(allocator, buf, s.elem.*);
        },
        .opt => |o| {
            try buf.appendSlice(allocator, "?");
            try emitType(allocator, buf, o.*);
        },
        .err_union => |eu| {
            if (eu.err_set) |es| {
                try buf.appendSlice(allocator, es);
            }
            try buf.appendSlice(allocator, "!");
            try emitType(allocator, buf, eu.payload.*);
        },
        .projected => |projected| {
            try emitIdent(allocator, buf, projected.descriptor);
            try buf.appendSlice(allocator, "(");
            try emitType(allocator, buf, projected.receiver.*);
            try buf.appendSlice(allocator, ").");
            try emitIdent(allocator, buf, projected.member);
        },
        .named => |n| {
            if (std.mem.eql(u8, n, "unsupported type")) {
                try buf.appendSlice(allocator, "anyopaque");
            } else {
                try buf.appendSlice(allocator, n);
            }
        },
        .generic => |g| {
            try buf.appendSlice(allocator, g.name);
            try buf.appendSlice(allocator, "(");
            for (g.params, 0..) |param, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitType(allocator, buf, param);
            }
            try buf.appendSlice(allocator, ")");
        },
        .array => |a| {
            try buf.print(allocator, "[{d}]", .{a.len});
            try emitType(allocator, buf, a.elem.*);
        },
        .array_expr => |a| {
            try buf.appendSlice(allocator, "[");
            try emitExpr(allocator, buf, a.len.*, 0);
            try buf.appendSlice(allocator, "]");
            try emitType(allocator, buf, a.elem.*);
        },
        .expr => |expr| try emitTypeExpr(allocator, buf, expr.*),
        .tuple => |tup| {
            try buf.appendSlice(allocator, "struct { ");
            for (tup, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitType(allocator, buf, elem);
            }
            try buf.appendSlice(allocator, " }");
        },
        .fn_ptr => |function| {
            try buf.appendSlice(allocator, "*const fn (");
            for (function.params, 0..) |param, index| {
                if (index != 0) try buf.appendSlice(allocator, ", ");
                try emitType(allocator, buf, param);
            }
            try buf.appendSlice(allocator, ") ");
            try emitType(allocator, buf, function.ret.*);
        },
        .anon_struct => |as| {
            try buf.appendSlice(allocator, "struct { ");
            for (as.fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitIdent(allocator, buf, f.name);
                try buf.appendSlice(allocator, ": ");
                try emitType(allocator, buf, f.ty);
            }
            try buf.appendSlice(allocator, " }");
        },
        .any_opaque => try buf.appendSlice(allocator, "anyopaque"),
        .void_type => try buf.appendSlice(allocator, "void"),
    }
}

test "emitFile: rejects generated tests without std and empty test bodies" {
    const no_std: ast.File = .{
        .path = "src/root.zig",
        .tests = &.{.{ .name = "missing std", .body = .{
            .expr = &ast.Expr{ .continue_expr = .{} },
        } }},
    };
    try std.testing.expectError(
        error.MissingStdImport,
        emitFile(std.testing.allocator, &no_std),
    );

    const empty_test: ast.File = .{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .tests = &.{.{ .name = "empty", .body = .{} }},
    };
    try std.testing.expectError(
        error.EmptyTranslatedBody,
        emitFile(std.testing.allocator, &empty_test),
    );
}

test "emitFile: accepts a file with zero generated tests" {
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "answer",
            .ty = .{ .prim = .u8 },
            .init = .{ .lit = .{ .int = 42 } },
        } }},
    };
    const output = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "answer") != null);
}

test "emitFile: rejects explicit unsupported expressions" {
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "missing",
            .init = .{ .unsupported = "fixture" },
        } }},
    };
    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        emitFile(std.testing.allocator, &file),
    );
}
test "emitFile: emits validated scalar casts" {
    const operand: ast.Expr = .{ .ident = "byte" };
    const cast: ast.Expr = .{ .cast = .{
        .target = .{ .prim = .u64 },
        .operand = &operand,
    } };
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "value",
            .ty = .{ .prim = .u64 },
            .init = cast,
        } }},
    };
    const output = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "@as(u64, byte)") != null);
}

test "emitFile: accepts tuple-position field names" {
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .struct_decl = .{
            .name = "Pair",
            .fields = &.{
                .{ .name = "0", .ty = .{ .prim = .u8 } },
                .{ .name = "1", .ty = .{ .prim = .u8 } },
            },
        } }},
    };
    const source = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"0\": u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"1\": u8") != null);
}

test "emitFile: emits defer and errdefer cleanup statements" {
    const owner: ast.Expr = .{ .ident = "owner" };
    const deinit_callee: ast.Expr = .{ .field_access = .{
        .target = &owner,
        .field_name = "deinit",
    } };
    const cleanup_call: ast.Expr = .{ .call = .{
        .callee = &deinit_callee,
        .args = &.{.{ .ident = "allocator" }},
    } };
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "cleanup",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &.{
                .{ .defer_stmt = .{ .expr = cleanup_call } },
                .{ .defer_stmt = .{
                    .expr = cleanup_call,
                    .is_errdefer = true,
                } },
            } },
        } }},
    };
    const source = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        \\pub fn cleanup() void {
        \\    defer owner.deinit(allocator);
        \\    errdefer owner.deinit(allocator);
        \\}
        \\
    ,
        source,
    );
}

test "emitFile: source expectEqual declarations do not collide with helpers" {
    const operand: ast.Expr = .{ .lit = .{ .int = 1 } };
    const file: ast.File = .{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .decls = &.{.{ .const_decl = .{
            .name = "expectEqual",
            .ty = .{ .prim = .u8 },
            .init = operand,
        } }},
        .tests = &.{.{ .name = "collision", .body = .{
            .stmts = &.{.{ .expr_stmt = &ast.Expr{ .call = .{
                .callee = &ast.Expr{ .field_access = .{
                    .target = &ast.Expr{ .field_access = .{
                        .target = &ast.Expr{ .ident = "std" },
                        .field_name = "testing",
                    } },
                    .field_name = "expect",
                } },
                .args = &.{.{ .lit = .{ .bool_lit = true } }},
            } } }},
        } }},
    };
    const source = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "const expectEqual =") == null);
}

test "emitExpr: custom chunks methods are not rewritten as slice loops" {
    const target: ast.Expr = .{ .ident = "custom" };
    const method: ast.Expr = .{ .field_access = .{
        .target = &target,
        .field_name = "chunks",
    } };
    const iterable: ast.Expr = .{ .call = .{
        .callee = &method,
        .args = &.{.{ .lit = .{ .int = 4 } }},
    } };
    const body_expr: ast.Expr = .{ .struct_init = .{ .fields = &.{} } };
    const loop: ast.Expr = .{ .for_expr = .{
        .inputs = &.{iterable},
        .captures = &.{.{ .name = "chunk" }},
        .body = .{ .stmts = &.{.{ .expr_stmt = &body_expr }} },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, loop, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "custom.chunks(4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "__chunk_index") == null);
}

test "emitExpr: resolved slice chunks use the chunk loop lowering" {
    const target: ast.Expr = .{ .ident = "bytes" };
    const chunks: ast.Expr = .{ .builtin = .{
        .name = "sliceChunks",
        .args = &.{ target, .{ .lit = .{ .int = 4 } } },
    } };
    const body_expr: ast.Expr = .{ .struct_init = .{ .fields = &.{} } };
    const loop: ast.Expr = .{ .for_expr = .{
        .inputs = &.{chunks},
        .captures = &.{.{ .name = "chunk" }},
        .body = .{ .stmts = &.{.{ .expr_stmt = &body_expr }} },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, loop, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "__chunk_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "while (bytes.len") != null);
}

test "emitExpr: nested value blocks use distinct labels" {
    const inner_value: ast.Expr = .{ .lit = .{ .int = 1 } };
    const inner: ast.Expr = .{ .block = .{ .expr = &inner_value } };
    const outer: ast.Expr = .{ .block = .{ .expr = &inner } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, outer, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "__r2z_value_block_0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "__r2z_value_block_1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "block:") == null);
}

test "emitExpr: prefix unary receivers preserve field access precedence" {
    const operand: ast.Expr = .{ .ident = "value" };
    const cases = [_]struct { op: ast.UnaryOpKind, expected: []const u8 }{
        .{ .op = .try_op, .expected = "(try value).field" },
        .{ .op = .addr_of, .expected = "(&value).field" },
        .{ .op = .negate, .expected = "(-value).field" },
        .{ .op = .bit_not, .expected = "(~value).field" },
        .{ .op = .bool_not, .expected = "(!value).field" },
        .{ .op = .deref, .expected = "value.*.field" },
    };
    for (cases) |case| {
        const receiver: ast.Expr = .{ .unary_op = .{
            .op = case.op,
            .operand = &operand,
        } };
        const field: ast.Expr = .{ .field_access = .{
            .target = &receiver,
            .field_name = "field",
        } };
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(std.testing.allocator);
        try emitExpr(std.testing.allocator, &buffer, field, 0);
        try std.testing.expectEqualStrings(case.expected, buffer.items);
    }
}

// A Rust `loop` that returns a value lowers to a `while` whose only exit
// carries one, and Zig takes the loop's value from exactly that exit. So the
// question the emitter has to answer first is whether the loop carries one at
// all, and the answer has to come from the loop's own exits: a value-carrying
// break deeper in the tree belongs to whatever loop encloses it there.
test "loopYieldsValue: only the loop's own value-carrying exit counts" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const unit_exit: ast.Expr = .{ .break_expr = .{} };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };

    const unit_loop: ast.WhileExpr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &unit_exit }} },
    };
    const value_loop: ast.WhileExpr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    };
    const nested_value_loop: ast.Expr = .{ .while_expr = value_loop };
    const nested_for_loop: ast.Expr = .{ .for_expr = .{
        .inputs = &.{.{ .ident = "items" }},
        .captures = &.{.{ .name = "item" }},
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };

    try std.testing.expect(!loopYieldsValue(unit_loop));
    try std.testing.expect(loopYieldsValue(value_loop));
    try std.testing.expect(!loopYieldsValue(.{
        .cond = &condition,
        .body = .{ .stmts = &.{
            .{ .expr_stmt = &nested_value_loop },
            .{ .expr_stmt = &nested_for_loop },
            .{ .expr_stmt = &unit_exit },
        } },
    }));

    // A `break` behind a conditional, a block or a match arm still exits the
    // loop that owns it.
    const then_exit: ast.Expr = .{ .block = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} } };
    const conditional: ast.Expr = .{ .if_expr = .{
        .cond = &subject,
        .then_body = &then_exit,
    } };
    const matched: ast.Expr = .{ .match_expr = .{
        .target = &subject,
        .arms = &.{.{ .patterns = &.{.wildcard}, .body = value_exit }},
    } };
    try std.testing.expect(loopYieldsValue(.{
        .cond = &condition,
        .body = .{ .stmts = &.{
            .{ .expr_stmt = &conditional },
            .{ .expr_stmt = &matched },
        } },
    }));
}

test "emitExpr: a value-carrying loop exits through its own label" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, loop, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "while (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "__r2z_value_loop_0: {") != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, buffer.items, "break :__r2z_value_loop_0 value;"),
    );
}

test "emitExpr: a nested unit loop keeps the break that belongs to it" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const unit_exit: ast.Expr = .{ .break_expr = .{} };
    const inner: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &unit_exit }} },
    } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const outer: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{
            .{ .expr_stmt = &inner },
            .{ .expr_stmt = &value_exit },
        } },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, outer, 0);
    // Only the outer loop's own value-carrying exit names the label; the unit
    // loop nested in it leaves with a plain `break`.
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "break;") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, buffer.items, "break :"));
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_loop_0 value;") != null,
    );
}

test "emitExpr: a value loop nested in a unit loop is discarded, the outer stays a loop" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const inner: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    const unit_exit: ast.Expr = .{ .break_expr = .{} };
    const outer: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{
            .{ .expr_stmt = &inner },
            .{ .expr_stmt = &unit_exit },
        } },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, outer, 0);
    // The outer loop carries no value of its own, so it stays a bare loop and
    // the inner one, whose value the statement throws away, is labelled.
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "_ = __r2z_value_loop_1: {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_loop_1 value;") != null,
    );
}

test "emitExpr: a value-carrying loop keeps its value as a block tail" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    const block: ast.Expr = .{ .block = .{ .expr = &loop } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, block, 0);
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_block_0 __r2z_value_loop_1: {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_loop_1 value;") != null,
    );
}

test "emitExpr: a value-carrying loop keeps its value as a call argument" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    const callee: ast.Expr = .{ .ident = "take" };
    const call: ast.Expr = .{ .call = .{ .callee = &callee, .args = &.{loop} } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitExpr(std.testing.allocator, &buffer, call, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "take(__r2z_value_loop_0: {") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_loop_0 value;") != null,
    );
}

test "emitStmt: a let binding keeps the value of a value-carrying loop" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    const binding: ast.Stmt = .{ .let_stmt = .{ .name = "total", .init = loop } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitStmt(std.testing.allocator, &buffer, binding, 1);
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "const total = __r2z_value_loop_1: {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_loop_1 value;") != null,
    );
}

test "emitStmt: a value-carrying loop used as a statement discards its value" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const subject: ast.Expr = .{ .ident = "value" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &subject } };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitStmt(std.testing.allocator, &buffer, .{ .expr_stmt = &loop }, 1);
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "_ = __r2z_value_loop_1: {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, buffer.items, "break :__r2z_value_loop_1 value;") != null,
    );
}

test "emitStmt: a unit loop statement stays a bare statement" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const unit_exit: ast.Expr = .{ .break_expr = .{} };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &unit_exit }} },
    } };
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try emitStmt(std.testing.allocator, &buffer, .{ .expr_stmt = &loop }, 1);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "while (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "__r2z_value_loop_") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "_ = ") == null);
}

test "emitFile: a value-carrying loop tail is returned instead of dropped" {
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const counter: ast.Expr = .{ .ident = "i" };
    const value_exit: ast.Expr = .{ .break_expr = .{ .value = &counter } };
    const loop: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .body = .{ .stmts = &.{.{ .expr_stmt = &value_exit }} },
    } };
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "square",
            .ret_type = .{ .prim = .u32 },
            .body = .{ .expr = &loop },
        } }},
    };
    const source = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "return __r2z_value_loop_1: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "break :__r2z_value_loop_1 i;") != null);
}

test "generated names remain fresh beyond 1024 source bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bindings = try allocator.alloc(ast.Stmt, 1030);
    const capture_names = try allocator.alloc([]const u8, bindings.len);
    for (bindings, capture_names, 0..) |*binding, *capture, index| {
        binding.* = .{ .let_stmt = .{
            .name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ value_block_base, index }),
            .init = .{ .lit = .{ .uint = 0 } },
        } };
        capture.* = if (index == 0)
            match_payload_base
        else
            try std.fmt.allocPrint(allocator, "{s}_{d}", .{ match_payload_base, index });
    }
    const scope: ast.Expr = .{ .block = .{ .stmts = bindings } };
    var label_buffer: [64]u8 = undefined;
    const label = freshGeneratedLabel(&label_buffer, scope, value_block_base, 0);
    try std.testing.expect(!exprContainsGeneratedMatchName(occurrenceScan(label), scope));

    const target: ast.Expr = .{ .lit = .{ .uint = 0 } };
    const payload = freshGeneratedMatchName(.{ .target = &target }, &.{}, capture_names, match_payload_base);
    var payload_buffer: [64]u8 = undefined;
    const payload_name = generatedMatchNameText(&payload_buffer, payload);
    for (capture_names) |capture| {
        try std.testing.expect(!std.mem.eql(u8, capture, payload_name));
    }
}

// ---------------------------------------------------------------------------
// The parameter discard, and every way a binding SHADOWS the parameter
// ---------------------------------------------------------------------------

/// Emits a `void` function whose one parameter is `unit`, with `body` as its
/// body, and hands back the generated source. The `_ = unit;` Zig refuses a
/// function to go without is decided by `bodyReadsParam`, so the only thing
/// these tests vary is the body.
fn shadowProbe(body: ast.Block) ![]const u8 {
    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "probe",
            .params = &.{.{ .name = "unit", .ty = .{ .prim = .u8 } }},
            .ret_type = .{ .void_type = {} },
            .body = body,
        } }},
    };
    return emitFile(std.testing.allocator, &file);
}

/// A statement that reads `unit`, which is the one shape that keeps the
/// parameter live. `callee` is the caller's own stable home for the callee,
/// because `Expr` holds that operand behind a pointer.
fn readUnitThrough(callee: *const ast.Expr) ast.Expr {
    return .{ .call = .{
        .callee = callee,
        .args = &[_]ast.Expr{.{ .ident = "unit" }},
    } };
}

// A match pattern that BINDS the parameter's name introduces it for that arm,
// so the arm body is not reading the parameter and the parameter needs its
// discard. The other direction is in the same test: the scrutinee is the
// parameter, read before any binding can shadow it, so there the discard must
// NOT appear — a rule that cannot tell the two apart drops a discard Zig
// requires exactly as surely as it adds one Zig forbids.
test "bodyReadsParam: a match pattern that binds the parameter's name shadows it" {
    const void_value: ast.Expr = .{ .unit = {} };
    const shadowing_arms = [_]ast.MatchArm{.{
        .patterns = &[_]ast.Pattern{.{ .binding = "unit" }},
        .body = void_value,
    }};
    const other: ast.Expr = .{ .ident = "kind" };
    const shadowed: ast.Expr = .{ .match_expr = .{
        .target = &other,
        .arms = &shadowing_arms,
    } };
    const shadowed_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(shadowed_out);
    try std.testing.expect(std.mem.indexOf(u8, shadowed_out, "_ = unit;\n") != null);

    const unit_target: ast.Expr = .{ .ident = "unit" };
    const live: ast.Expr = .{ .match_expr = .{
        .target = &unit_target,
        .arms = &shadowing_arms,
    } };
    const live_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &live },
    } });
    defer std.testing.allocator.free(live_out);
    try std.testing.expect(std.mem.indexOf(u8, live_out, "_ = unit;") == null);
}

// The same rule one position over: the arm CAPTURE, rather than the pattern,
// is what introduces the name.
test "bodyReadsParam: a match arm capture that binds the parameter's name shadows it" {
    const void_value: ast.Expr = .{ .unit = {} };
    const capturing_arms = [_]ast.MatchArm{.{
        .patterns = &[_]ast.Pattern{.{ .enum_literal = "Found" }},
        .capture = .{ .name = "unit" },
        .body = void_value,
    }};
    const other: ast.Expr = .{ .ident = "kind" };
    const shadowed: ast.Expr = .{ .match_expr = .{
        .target = &other,
        .arms = &capturing_arms,
    } };
    const shadowed_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(shadowed_out);
    try std.testing.expect(std.mem.indexOf(u8, shadowed_out, "_ = unit;\n") != null);

    // The read is a statement of its own, so it happens while `unit` can only
    // be the parameter; the capture below it shadows the name from there down.
    const consume: ast.Expr = .{ .ident = "consume" };
    const read = readUnitThrough(&consume);
    const live_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &read },
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(live_out);
    try std.testing.expect(std.mem.indexOf(u8, live_out, "_ = unit;") == null);
}

// A `for` payload binds the element for the loop's own body, and the inputs
// beside it are read before anything binds — so a name that is only in the
// body is the local's, and one in an input is the parameter's.
test "bodyReadsParam: a for payload that binds the parameter's name shadows it" {
    const items: ast.Expr = .{ .ident = "items" };
    const void_value: ast.Expr = .{ .unit = {} };
    const body_stmt: ast.Stmt = .{ .expr_stmt = &void_value };
    const shadowed: ast.Expr = .{ .for_expr = .{
        .inputs = &[_]ast.Expr{items},
        .captures = &[_]ast.Capture{.{ .name = "unit" }},
        .body = .{ .stmts = &[_]ast.Stmt{body_stmt} },
    } };
    const shadowed_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(shadowed_out);
    try std.testing.expect(std.mem.indexOf(u8, shadowed_out, "_ = unit;\n") != null);

    const consume: ast.Expr = .{ .ident = "consume" };
    const read = readUnitThrough(&consume);
    const live_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &read },
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(live_out);
    try std.testing.expect(std.mem.indexOf(u8, live_out, "_ = unit;") == null);
}

// The nested `let`: a block one scope down that rebinds the name shadows it
// for the REST OF THAT BLOCK and nothing else. This is the shape the old
// top-level-only rule reported as a read, and the report cost a package Zig
// refuses with `unused function parameter`. The shadowing block also READS the
// name it bound, which is what proves the rule is about scope and not about
// counting occurrences: a read of the local is not a read of the parameter.
test "bodyReadsParam: a let in a nested block that binds the parameter's name shadows it" {
    const consume: ast.Expr = .{ .ident = "consume" };
    const read = readUnitThrough(&consume);
    const shadowing_let: ast.Stmt = .{ .let_stmt = .{
        .name = "unit",
        .init = .{ .lit = .{ .uint = 3 } },
    } };
    const shadowed: ast.Expr = .{ .block = .{
        .stmts = &[_]ast.Stmt{ shadowing_let, .{ .expr_stmt = &read } },
    } };
    const shadowed_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(shadowed_out);
    try std.testing.expect(std.mem.indexOf(u8, shadowed_out, "_ = unit;\n") != null);

    // Read first, shadowed second: the read is of the parameter and keeps it
    // live, so the nested block below changes nothing about it.
    const outer_read = readUnitThrough(&consume);
    const live_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &outer_read },
        .{ .expr_stmt = &shadowed },
    } });
    defer std.testing.allocator.free(live_out);
    try std.testing.expect(std.mem.indexOf(u8, live_out, "_ = unit;") == null);
}

// The two payload shapes the match arm and the loop do not cover: an `if`
// capture and a `while` payload. Both bind for their own body only, so the
// `else` arm of that `if` still sees the parameter — which is the scope half of
// the rule, stated where the shadow has to stop.
test "bodyReadsParam: an if capture and a while payload bind the parameter's name too" {
    const void_value: ast.Expr = .{ .unit = {} };
    const ready: ast.Expr = .{ .ident = "ready" };
    const shadowing_if: ast.Expr = .{ .if_expr = .{
        .cond = &ready,
        .then_capture = .{ .name = "unit" },
        .then_body = &void_value,
    } };
    const if_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &shadowing_if },
    } });
    defer std.testing.allocator.free(if_out);
    try std.testing.expect(std.mem.indexOf(u8, if_out, "_ = unit;\n") != null);

    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const body_stmt: ast.Stmt = .{ .expr_stmt = &void_value };
    const shadowing_while: ast.Expr = .{ .while_expr = .{
        .cond = &condition,
        .captures = &[_][]const u8{"unit"},
        .body = .{ .stmts = &[_]ast.Stmt{body_stmt} },
    } };
    const while_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &shadowing_while },
    } });
    defer std.testing.allocator.free(while_out);
    try std.testing.expect(std.mem.indexOf(u8, while_out, "_ = unit;\n") != null);

    // The shadow stops at the branch it opens: the `else` arm is a sibling
    // scope, so a read there is a read of the parameter.
    const consume: ast.Expr = .{ .ident = "consume" };
    const read = readUnitThrough(&consume);
    const else_reads: ast.Expr = .{ .if_expr = .{
        .cond = &ready,
        .then_capture = .{ .name = "unit" },
        .then_body = &void_value,
        .else_body = &read,
    } };
    const else_out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        .{ .expr_stmt = &else_reads },
    } });
    defer std.testing.allocator.free(else_out);
    try std.testing.expect(std.mem.indexOf(u8, else_out, "_ = unit;") == null);
}

// A shadowing `let`'s own INITIALISER is read while the parameter is still the
// only `unit` in scope, and Rust introduces the local only after it has been
// produced. This is the direction the rule exists to keep: reading through the
// declaration is a read of the parameter, and dropping the discard there would
// leave a live parameter with nothing keeping it alive.
test "bodyReadsParam: a shadowing initialiser still reads the parameter" {
    const consume: ast.Expr = .{ .ident = "consume" };
    const read = readUnitThrough(&consume);
    const shadowing_let: ast.Stmt = .{ .let_stmt = .{
        .name = "unit",
        .init = .{ .ident = "unit" },
    } };
    // The shadowing local is read below its own declaration, so it keeps its
    // binding instead of being written as `_ = unit;` — the same text the
    // parameter's discard would be, which would make the assertion below
    // unable to tell the two apart. Only the parameter can be discarded here.
    const out = try shadowProbe(.{ .stmts = &[_]ast.Stmt{
        shadowing_let,
        .{ .expr_stmt = &read },
    } });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = unit;\n") == null);
}

// ---------------------------------------------------------------------------
// Where a labelled block may be written
// ---------------------------------------------------------------------------

/// The labelled chain a guarded `match` lowers to: a label, exits that name
/// it, and the `unreachable` that closes an ordered chain.
///
/// Both labels are `comptime` so the whole fixture is evaluated at comptime:
/// every node it names then lives in static storage, which is what lets the
/// expression be handed to a test that keeps it for longer than this frame.
fn labelledChainFixture(comptime label: []const u8, comptime exit_label: []const u8) ast.Expr {
    const payload: ast.Expr = .{ .ident = "payload" };
    const exit: ast.Expr = .{ .break_expr = .{ .value = &payload, .label = exit_label } };
    const void_value: ast.Expr = .{ .unit = {} };
    const exit_stmt: ast.Stmt = .{ .expr_stmt = &exit };
    const dispatch: ast.Expr = .{ .match_expr = .{
        .target = &.{ .ident = "input" },
        .arms = &[_]ast.MatchArm{.{ .patterns = &[_]ast.Pattern{.{ .wildcard = {} }}, .body = void_value }},
    } };
    const dispatch_stmt: ast.Stmt = .{ .expr_stmt = &dispatch };
    const done: ast.Expr = .{ .unreachable_ = {} };
    const done_stmt: ast.Stmt = .{ .expr_stmt = &done };
    return .{ .block = .{
        .label = label,
        .stmts = &[_]ast.Stmt{ exit_stmt, dispatch_stmt, done_stmt },
    } };
}

test "every labelled-block position has a verdict, and only a bare statement has no carrier" {
    // The table is the position list, and its length is checked against the
    // enum: a position added without a verdict here fails this test rather
    // than inheriting one by accident.
    const verdicts = [_]struct { position: LabelledBlockPosition, legal: bool }{
        .{ .position = .if_branch, .legal = true },
        .{ .position = .expression, .legal = true },
        .{ .position = .bare_statement, .legal = false },
    };
    try std.testing.expectEqual(
        @typeInfo(LabelledBlockPosition).@"enum".fields.len,
        verdicts.len,
    );
    for (verdicts) |verdict| {
        try std.testing.expectEqual(
            verdict.legal,
            labelledBlockIsLegalIn(verdict.position),
        );
    }
}

test "a labelled block with no carrier is refused by name, not written" {
    const chain = labelledChainFixture("__r2z_match_block", "__r2z_match_block");

    // A statement of its own: nothing in front of the block and no `;` after
    // it. This is the position Zig measures as unspellable, and the refusal
    // happens before a byte is written.
    const bare: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "bare",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &[_]ast.Stmt{.{ .expr_stmt = &chain }} },
        } }},
    };
    try std.testing.expectError(
        error.LabelledBlockWithoutACarrier,
        emitFile(std.testing.allocator, &bare),
    );

    // The same block as a `const` initializer, which is a carrier, so the very
    // same shape that was refused a line above is emitted here.
    const bound: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "bound",
            .ret_type = .{ .prim = .u8 },
            .body = .{
                .stmts = &[_]ast.Stmt{.{ .let_stmt = .{
                    .name = "__r2z_chain",
                    .init = chain,
                } }},
                .expr = &.{ .ident = "__r2z_chain" },
            },
        } }},
    };
    const bound_out = try emitFile(std.testing.allocator, &bound);
    defer std.testing.allocator.free(bound_out);
    try std.testing.expect(
        std.mem.indexOf(u8, bound_out, "const __r2z_chain = __r2z_match_block: {") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, bound_out, "break :__r2z_match_block payload;") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, bound_out, "return __r2z_chain;") != null);
}

test "a labelled block in an if branch is exempt, and the exemption is structural" {
    const then_chain = labelledChainFixture("__r2z_match_block", "__r2z_match_block");
    const else_chain = labelledChainFixture("__r2z_other_block", "__r2z_other_block");
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };
    const conditional: ast.Expr = .{ .if_expr = .{
        .cond = &condition,
        .then_body = &then_chain,
        .else_body = &else_chain,
    } };

    // Both arms are blocks, so the `if` is a whole Zig statement — which is
    // the `bare` statement FORM, and is exactly why the exemption cannot come
    // from the statement form: it comes from being an arm of this `if`.
    try std.testing.expectEqual(StatementForm.bare, statementForm(conditional));

    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "guarded",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &[_]ast.Stmt{.{ .expr_stmt = &conditional }} },
        } }},
    };
    const out = try emitFile(std.testing.allocator, &file);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (true) __r2z_match_block: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "} else __r2z_other_block: {") != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, out, "__r2z_match_block: {"),
    );
}

test "a labelled block in a loop body or a test tail has no carrier either" {
    const loop_chain = labelledChainFixture("__r2z_loop_block", "__r2z_loop_block");
    const body: ast.Block = .{ .stmts = &[_]ast.Stmt{.{ .expr_stmt = &loop_chain }} };
    const condition: ast.Expr = .{ .lit = .{ .bool_lit = true } };

    const file: ast.File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "looped",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &[_]ast.Stmt{.{ .expr_stmt = &.{ .while_expr = .{
                .cond = &condition,
                .body = body,
            } } }} },
        } }},
    };
    try std.testing.expectError(
        error.LabelledBlockWithoutACarrier,
        emitFile(std.testing.allocator, &file),
    );

    // A test body writes its tail as a statement whatever it carries, so a
    // labelled block there is refused for the same reason.
    const test_file: ast.File = .{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .tests = &.{.{ .name = "tail", .body = .{ .expr = &loop_chain } }},
    };
    try std.testing.expectError(
        error.LabelledBlockWithoutACarrier,
        emitFile(std.testing.allocator, &test_file),
    );
}
