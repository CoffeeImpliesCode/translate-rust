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
) (std.mem.Allocator.Error || ast.ValidationError)![]const u8 {
    try ast.validateFileForTranslation(file);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // 1. Imports
    if (file.imports.len > 0) {
        for (file.imports) |imp| {
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
                    var hex_buf: [4]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\x{x:0>2}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, hex);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Declaration Emission
// ---------------------------------------------------------------------------

pub fn emitDecl(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    decl: ast.Decl,
    depth: usize,
) std.mem.Allocator.Error!void {
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
    for (fd.params[ordinary_param_start..]) |p| {
        if (!first_param) try buf.appendSlice(allocator, ", ");
        first_param = false;
        if (p.is_comptime) try buf.appendSlice(allocator, "comptime ");
        try emitIdent(allocator, buf, p.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, p.ty);
    }
    try buf.appendSlice(allocator, ") ");
    try emitType(allocator, buf, fd.ret_type);

    // `emitFile` validates before it emits, and `validateDecl` rejects a
    // translated function that carries no body, so a dropped body can never
    // reach here. Synthesising `{}` for one would emit a function that
    // compiles and silently does nothing, which is the exact loss the
    // validator exists to catch, so the invariant is unwrapped here.
    const body = fd.body.?;
    try buf.appendSlice(allocator, " {\n");
    // Rust permits an unused receiver; Zig requires an explicit discard.
    if (fd.params.len > 0 and std.mem.eql(u8, fd.params[0].name, "self") and
        !blockReadsNameOutside(body, body.stmts.len, "self"))
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
        if (tail_expr.* == .return_expr or tail_expr.* == .panic_) {
            try emitExpr(allocator, buf, tail_expr.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
        } else if (isStatementLike(tail_expr.*) and !exprCarriesValue(tail_expr.*)) {
            try emitExpr(allocator, buf, tail_expr.*, depth + 1);
            try buf.appendSlice(allocator, "\n");
        } else {
            try buf.appendSlice(allocator, "return ");
            try emitExpr(allocator, buf, tail_expr.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
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
            try buf.appendSlice(allocator, ";\n");
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

/// True when two source labels name the same target. A null label is the
/// unlabeled exit, and it matches only another null.
fn sameSourceLabel(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn blockHasValue(block: ast.Block) bool {
    if (blockHasLabelledValueExit(block)) return true;
    const tail = block.expr orelse return false;
    return switch (tail.*) {
        .return_expr, .break_expr, .continue_expr, .unreachable_, .panic_ => false,
        else => true,
    };
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
fn typeContainsGeneratedMatchName(ty: ast.Type, name: []const u8) bool {
    return switch (ty) {
        .prim, .any_opaque, .void_type => false,
        .ptr => |pointer| typeContainsGeneratedMatchName(pointer.elem.*, name),
        .slice => |slice| typeContainsGeneratedMatchName(slice.elem.*, name),
        .opt => |inner| typeContainsGeneratedMatchName(inner.*, name),
        .err_union => |error_union| {
            if (error_union.err_set) |error_set| {
                if (generatedMatchNameEquals(lexicalRoot(error_set), name)) return true;
            }
            return typeContainsGeneratedMatchName(error_union.payload.*, name);
        },
        .projected => |projected| typeContainsGeneratedMatchName(projected.receiver.*, name),
        .named => |value| generatedMatchNameEquals(lexicalRoot(value), name),
        .generic => |generic| {
            if (generatedMatchNameEquals(lexicalRoot(generic.name), name)) return true;
            for (generic.params) |param| {
                if (typeContainsGeneratedMatchName(param, name)) return true;
            }
            return false;
        },
        .array => |array| typeContainsGeneratedMatchName(array.elem.*, name),
        .array_expr => |array| {
            if (typeContainsGeneratedMatchName(array.elem.*, name)) return true;
            return exprContainsGeneratedMatchName(array.len.*, name);
        },
        .tuple => |tuple| {
            for (tuple) |element| {
                if (typeContainsGeneratedMatchName(element, name)) return true;
            }
            return false;
        },
        .fn_ptr => |function| {
            for (function.params) |param| {
                if (typeContainsGeneratedMatchName(param, name)) return true;
            }
            return typeContainsGeneratedMatchName(function.ret.*, name);
        },
        .anon_struct => |anonymous| {
            for (anonymous.fields) |field| {
                if (typeContainsGeneratedMatchName(field.ty, name)) return true;
                if (field.default_val) |value| {
                    if (exprContainsGeneratedMatchName(value.*, name)) return true;
                }
            }
            return false;
        },
    };
}

fn patternContainsGeneratedMatchName(pattern: ast.Pattern, name: []const u8) bool {
    return switch (pattern) {
        .wildcard, .lit, .range_pat => false,
        .binding, .enum_literal => |value| generatedMatchNameEquals(lexicalRoot(value), name),
        .tuple => |patterns| {
            for (patterns) |child| {
                if (patternContainsGeneratedMatchName(child, name)) return true;
            }
            return false;
        },
        .struct_pat => |struct_pattern| {
            if (struct_pattern.name) |value| {
                if (generatedMatchNameEquals(lexicalRoot(value), name)) return true;
            }
            for (struct_pattern.fields) |field| {
                if (generatedMatchNameEquals(lexicalRoot(field.name), name)) return true;
                if (patternContainsGeneratedMatchName(field.pat, name)) return true;
            }
            return false;
        },
    };
}

fn stmtContainsGeneratedMatchName(stmt: ast.Stmt, name: []const u8) bool {
    return switch (stmt) {
        .let_stmt => |let_statement| {
            if (generatedMatchNameEquals(lexicalRoot(let_statement.name), name)) return true;
            if (let_statement.ty) |ty| {
                if (typeContainsGeneratedMatchName(ty, name)) return true;
            }
            return exprContainsGeneratedMatchName(let_statement.init, name);
        },
        .assign => |assignment| {
            return exprContainsGeneratedMatchName(assignment.target, name) or
                exprContainsGeneratedMatchName(assignment.val, name);
        },
        .defer_stmt => |defer_statement| exprContainsGeneratedMatchName(defer_statement.expr, name),
        .expr_stmt => |expression| exprContainsGeneratedMatchName(expression.*, name),
    };
}

fn blockContainsGeneratedMatchName(block: ast.Block, name: []const u8) bool {
    if (block.label) |label| {
        if (generatedMatchNameEquals(lexicalRoot(label), name)) return true;
    }
    for (block.stmts) |stmt| {
        if (stmtContainsGeneratedMatchName(stmt, name)) return true;
    }
    if (block.expr) |expression| return exprContainsGeneratedMatchName(expression.*, name);
    return false;
}

fn matchContainsGeneratedMatchName(match: ast.Match, name: []const u8) bool {
    if (exprContainsGeneratedMatchName(match.target.*, name)) return true;
    for (match.arms) |arm| {
        for (arm.patterns) |pattern| {
            if (patternContainsGeneratedMatchName(pattern, name)) return true;
        }
        if (arm.capture) |capture| {
            if (generatedMatchNameEquals(capture.name, name)) return true;
        }
        if (exprContainsGeneratedMatchName(arm.body, name)) return true;
    }
    return false;
}

fn exprContainsGeneratedMatchName(expression: ast.Expr, name: []const u8) bool {
    return switch (expression) {
        .lit, .unit, .unsupported, .panic_, .unreachable_ => false,
        .ident => |value| generatedMatchNameEquals(lexicalRoot(value), name),
        .field_access => |field_access| exprContainsGeneratedMatchName(field_access.target.*, name),
        .call => |call| {
            if (exprContainsGeneratedMatchName(call.callee.*, name)) return true;
            for (call.generic_args) |argument| {
                if (typeContainsGeneratedMatchName(argument, name)) return true;
            }
            for (call.args) |argument| {
                if (exprContainsGeneratedMatchName(argument, name)) return true;
            }
            return false;
        },
        .block => |block| blockContainsGeneratedMatchName(block, name),
        .match_expr => |match| matchContainsGeneratedMatchName(match, name),
        .bin_op => |binary| exprContainsGeneratedMatchName(binary.lhs.*, name) or
            exprContainsGeneratedMatchName(binary.rhs.*, name),
        .unary_op => |unary| exprContainsGeneratedMatchName(unary.operand.*, name),
        .cast => |cast| typeContainsGeneratedMatchName(cast.target, name) or
            exprContainsGeneratedMatchName(cast.operand.*, name),
        .struct_init => |literal| {
            if (literal.type_name) |ty| {
                if (typeContainsGeneratedMatchName(ty, name)) return true;
            }
            for (literal.fields) |field| {
                if (generatedMatchNameEquals(lexicalRoot(field.name), name)) return true;
                if (exprContainsGeneratedMatchName(field.expr, name)) return true;
            }
            return false;
        },
        .array_init => |array| {
            if (array.type_name) |ty| {
                if (typeContainsGeneratedMatchName(ty, name)) return true;
            }
            for (array.elements) |element| {
                if (exprContainsGeneratedMatchName(element, name)) return true;
            }
            return false;
        },
        .repeat => |repeat| {
            if (repeat.type_name) |ty| {
                if (typeContainsGeneratedMatchName(ty, name)) return true;
            }
            return exprContainsGeneratedMatchName(repeat.elem.*, name);
        },
        .multi_array => |array| {
            if (array.type_name) |ty| {
                if (typeContainsGeneratedMatchName(ty, name)) return true;
            }
            for (array.elements) |element| {
                if (exprContainsGeneratedMatchName(element, name)) return true;
            }
            return false;
        },
        .tuple => |elements| {
            for (elements) |element| {
                if (exprContainsGeneratedMatchName(element, name)) return true;
            }
            return false;
        },
        .builtin => |builtin| {
            if (generatedMatchNameEquals(lexicalRoot(builtin.name), name)) return true;
            for (builtin.args) |argument| {
                if (exprContainsGeneratedMatchName(argument, name)) return true;
            }
            return false;
        },
        .if_expr => |if_expression| {
            if (exprContainsGeneratedMatchName(if_expression.cond.*, name)) return true;
            if (exprContainsGeneratedMatchName(if_expression.then_body.*, name)) return true;
            if (if_expression.else_body) |else_body| {
                return exprContainsGeneratedMatchName(else_body.*, name);
            }
            return false;
        },
        .while_expr => |while_expression| {
            if (while_expression.label) |label| {
                if (generatedMatchNameEquals(lexicalRoot(label), name)) return true;
            }
            if (exprContainsGeneratedMatchName(while_expression.cond.*, name)) return true;
            if (while_expression.captures) |captures| {
                for (captures) |capture| {
                    if (generatedMatchNameEquals(lexicalRoot(capture), name)) return true;
                }
            }
            if (while_expression.continue_expr) |continue_expression| {
                if (exprContainsGeneratedMatchName(continue_expression.*, name)) return true;
            }
            if (blockContainsGeneratedMatchName(while_expression.body, name)) return true;
            if (while_expression.else_body) |else_body| {
                return exprContainsGeneratedMatchName(else_body.*, name);
            }
            return false;
        },
        .for_expr => |for_expression| {
            if (for_expression.label) |label| {
                if (generatedMatchNameEquals(lexicalRoot(label), name)) return true;
            }
            for (for_expression.inputs) |input| {
                if (exprContainsGeneratedMatchName(input, name)) return true;
            }
            for (for_expression.captures) |capture| {
                if (generatedMatchNameEquals(lexicalRoot(capture.name), name)) return true;
            }
            if (blockContainsGeneratedMatchName(for_expression.body, name)) return true;
            if (for_expression.else_body) |else_body| {
                return exprContainsGeneratedMatchName(else_body.*, name);
            }
            return false;
        },
        .range => |range| {
            if (exprContainsGeneratedMatchName(range.start.*, name)) return true;
            if (range.end) |end| return exprContainsGeneratedMatchName(end.*, name);
            return false;
        },
        .return_expr => |value| {
            if (value) |inner| return exprContainsGeneratedMatchName(inner.*, name);
            return false;
        },
        .break_expr => |break_expr| {
            if (break_expr.label) |label| {
                if (generatedMatchNameEquals(lexicalRoot(label), name)) return true;
            }
            if (break_expr.value) |inner| {
                return exprContainsGeneratedMatchName(inner.*, name);
            }
            return false;
        },
        .continue_expr => |continue_expr| {
            if (continue_expr.label) |label| {
                return generatedMatchNameEquals(lexicalRoot(label), name);
            }
            return false;
        },
    };
}

fn freshGeneratedMatchName(
    match: ast.Match,
    active_names: []const GeneratedMatchName,
    active_capture_names: []const []const u8,
    base: []const u8,
) GeneratedMatchName {
    var suffix: usize = 0;
    while (suffix < 1024) : (suffix += 1) {
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
        if (!active and !matchContainsGeneratedMatchName(match, candidate_text)) {
            return candidate;
        }
    }
    @panic("exhausted generated match names");
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
    while (suffix < depth + 1024) : (suffix += 1) {
        // The label is spelled with the suffix even at zero, so the text the
        // scope is searched for is the text the emitter writes.
        const candidate_text = std.fmt.bufPrint(buffer, "{s}_{d}", .{ base, suffix }) catch unreachable;
        if (!exprContainsGeneratedMatchName(scope, candidate_text)) return candidate_text;
    }
    @panic("exhausted generated label names");
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
            var len_buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{rp.len}) catch unreachable;
            try buf.appendSlice(allocator, len_str);
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
            if (exprContainsGeneratedMatchName(arm.body, capture.name)) {
                try buf.appendSlice(allocator, " |");
                if (capture.by_ref) try buf.appendSlice(allocator, "*");
                try emitIdent(allocator, buf, capture.name);
                try buf.appendSlice(allocator, "|");
            }
        } else if (direct_binding) |binding| {
            if (exprContainsGeneratedMatchName(arm.body, binding)) {
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

fn emitBlock(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    block: ast.Block,
    depth: usize,
) std.mem.Allocator.Error!void {
    const context: EmitContext = .{};
    try emitBlockScoped(&context, allocator, buf, block, depth);
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
    if (name.len == 0 or std.mem.startsWith(u8, name, "_")) return stmt;
    // A `.unit` initialiser is either "no initialiser" — the source bound the
    // name and assigned it later, and that assignment is the use this scan
    // cannot see — or a real unit value, which `_ =` would not accept.
    if (let_stmt.init == .unit) return stmt;
    if (blockReadsNameOutside(block, index, name)) return stmt;
    return .{ .assign = .{ .target = .{ .ident = "_" }, .val = let_stmt.init } };
}

/// Whether any statement other than `index`, or the block's tail, names
/// `name`.
fn blockReadsNameOutside(block: ast.Block, index: usize, name: []const u8) bool {
    for (block.stmts, 0..) |stmt, other| {
        if (other == index) continue;
        if (stmtContainsGeneratedMatchName(stmt, name)) return true;
    }
    if (block.expr) |tail| {
        if (exprContainsGeneratedMatchName(tail.*, name)) return true;
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
        if (tail.* == .return_expr or tail.* == .break_expr or
            tail.* == .continue_expr or tail.* == .unreachable_ or
            tail.* == .panic_)
        {
            try emitExprScoped(&block_context, allocator, buf, tail.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
        } else if (value_label) |label| {
            try buf.appendSlice(allocator, "break :");
            try emitIdent(allocator, buf, label);
            try buf.appendSlice(allocator, " ");
            try emitExprScoped(&block_context, allocator, buf, tail.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
        } else {
            try emitExprScoped(&block_context, allocator, buf, tail.*, depth + 1);
            try buf.appendSlice(allocator, "\n");
        }
    }
    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}");
}

fn emitLiteral(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), lit: ast.Literal) !void {
    switch (lit) {
        .int => |i| {
            var num_buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .uint => |u| {
            var num_buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{u}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            if (std.math.isNan(f)) {
                try buf.appendSlice(allocator, "@as(f64, std.math.nan(f64))");
            } else if (std.math.isPositiveInf(f)) {
                try buf.appendSlice(allocator, "@as(f64, std.math.inf(f64))");
            } else if (std.math.isNegativeInf(f)) {
                try buf.appendSlice(allocator, "-@as(f64, std.math.inf(f64))");
            } else {
                var num_buf: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch unreachable;
                try buf.appendSlice(allocator, s);
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
                var hex_buf: [16]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "\\u{{{x}}}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, hex);
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
                var alignment_buffer: [32]u8 = undefined;
                const qualifier = std.fmt.bufPrint(&alignment_buffer, "align({d}) ", .{alignment}) catch unreachable;
                try buf.appendSlice(allocator, qualifier);
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
            var len_buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "[{d}]", .{a.len}) catch unreachable;
            try buf.appendSlice(allocator, len_str);
            try emitType(allocator, buf, a.elem.*);
        },
        .array_expr => |a| {
            try buf.appendSlice(allocator, "[");
            try emitExpr(allocator, buf, a.len.*, 0);
            try buf.appendSlice(allocator, "]");
            try emitType(allocator, buf, a.elem.*);
        },
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
