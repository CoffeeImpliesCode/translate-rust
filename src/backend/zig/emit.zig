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
pub fn emitFile(allocator: std.mem.Allocator, file: *const ast.File) std.mem.Allocator.Error![]const u8 {
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
            try buf.appendSlice(allocator, " = @import(\"");
            try buf.appendSlice(allocator, imp.module_or_path);
            try buf.appendSlice(allocator, "\");\n");
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

        for (t.body.stmts) |stmt| {
            try emitStmt(allocator, &buf, stmt, 1);
        }
        if (t.body.expr) |tail_expr| {
            try emitIndent(allocator, &buf, 1);
            try emitExpr(allocator, &buf, tail_expr.*, 1);
            if (!isStatementLike(tail_expr.*) and
                tail_expr.* != .return_expr and
                tail_expr.* != .break_expr and
                tail_expr.* != .continue_expr)
            {
                try buf.appendSlice(allocator, ";");
            }
            try buf.appendSlice(allocator, "\n");
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

    // If the identifier contains dots (e.g. "std.AutoHashMap" or "std.hash.BuildHasherDefault"),
    // emit it as dotted identifiers without quoting the dots.
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
            0 => try buf.appendSlice(allocator, "\\0"),
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
    for (fd.params) |p| {
        if (!first_param) try buf.appendSlice(allocator, ", ");
        first_param = false;
        if (p.is_comptime) try buf.appendSlice(allocator, "comptime ");
        try emitIdent(allocator, buf, p.name);
        try buf.appendSlice(allocator, ": ");
        try emitType(allocator, buf, p.ty);
    }
    try buf.appendSlice(allocator, ") ");
    try emitType(allocator, buf, fd.ret_type);

    if (fd.body) |body| {
        if (body.stmts.len == 0 and body.expr == null) {
            try buf.appendSlice(allocator, " {}\n");
            return;
        }
        try buf.appendSlice(allocator, " {\n");
        for (body.stmts) |stmt| {
            try emitStmt(allocator, buf, stmt, depth + 1);
        }
        if (body.expr) |tail_expr| {
            try emitIndent(allocator, buf, depth + 1);
            if (tail_expr.* == .return_expr) {
                try emitExpr(allocator, buf, tail_expr.*, depth + 1);
                try buf.appendSlice(allocator, ";\n");
            } else if (isStatementLike(tail_expr.*)) {
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
    } else {
        try buf.appendSlice(allocator, " {}\n");
    }
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
            try emitExpr(allocator, buf, ls.init, depth);
            try buf.appendSlice(allocator, ";\n");
        },
        .assign => |as| {
            try emitIndent(allocator, buf, depth);
            try emitExpr(allocator, buf, as.target, depth);
            const op_str = switch (as.op) {
                .assign => " = ",
                .add_assign => " += ",
                .sub_assign => " -= ",
                .mul_assign => " *= ",
                .div_assign => " /= ",
                .mod_assign => " %= ",
                .bit_and_assign => " &= ",
                .bit_or_assign => " |= ",
                .bit_xor_assign => " ^= ",
                .shl_assign => " <<= ",
                .shr_assign => " >>= ",
            };
            try buf.appendSlice(allocator, op_str);
            try emitExpr(allocator, buf, as.val, depth);
            try buf.appendSlice(allocator, ";\n");
        },
        .expr_stmt => |es| {
            try emitIndent(allocator, buf, depth);
            try emitExpr(allocator, buf, es.*, depth);
            if (!isStatementLike(es.*) and
                es.* != .match_expr and
                es.* != .return_expr and
                es.* != .break_expr and
                es.* != .continue_expr)
            {
                try buf.appendSlice(allocator, ";");
            }
            try buf.appendSlice(allocator, "\n");
        },
    }
}

fn isStatementLike(expr: ast.Expr) bool {
    return switch (expr) {
        .while_expr, .for_expr => true,
        .if_expr => |ie| ie.then_body.* == .block and (ie.else_body == null or ie.else_body.?.* == .block or ie.else_body.?.* == .if_expr),
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Expression Emission
// ---------------------------------------------------------------------------

pub fn emitExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    expr: ast.Expr,
    depth: usize,
) std.mem.Allocator.Error!void {
    switch (expr) {
        .lit => |l| try emitLiteral(allocator, buf, l),
        .ident => |id| try emitIdent(allocator, buf, id),
        .field_access => |fa| {
            try emitExpr(allocator, buf, fa.target.*, depth);
            try buf.appendSlice(allocator, ".");
            try emitIdent(allocator, buf, fa.field_name);
        },
        .call => |c| {
            try emitExpr(allocator, buf, c.callee.*, depth);
            try buf.appendSlice(allocator, "(");
            for (c.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitExpr(allocator, buf, arg, depth);
            }
            try buf.appendSlice(allocator, ")");
        },
        .block => |b| {
            try emitBlock(allocator, buf, b, depth);
        },
        .match_expr => |match| try emitMatchExpr(allocator, buf, match, depth),
        .bin_op => |bo| {
            try buf.appendSlice(allocator, "(");
            try emitExpr(allocator, buf, bo.lhs.*, depth);
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
            try emitExpr(allocator, buf, bo.rhs.*, depth);
            try buf.appendSlice(allocator, ")");
        },
        .unary_op => |uo| {
            switch (uo.op) {
                .negate => {
                    try buf.appendSlice(allocator, "-");
                    try emitExpr(allocator, buf, uo.operand.*, depth);
                },
                .bit_not => {
                    try buf.appendSlice(allocator, "~");
                    try emitExpr(allocator, buf, uo.operand.*, depth);
                },
                .bool_not => {
                    try buf.appendSlice(allocator, "!");
                    try emitExpr(allocator, buf, uo.operand.*, depth);
                },
                .deref => {
                    try emitExpr(allocator, buf, uo.operand.*, depth);
                    try buf.appendSlice(allocator, ".*");
                },
                .addr_of => {
                    try buf.appendSlice(allocator, "&");
                    try emitExpr(allocator, buf, uo.operand.*, depth);
                },
                .try_op => {
                    try buf.appendSlice(allocator, "try ");
                    try emitExpr(allocator, buf, uo.operand.*, depth);
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
                    try emitExpr(allocator, buf, f.expr, depth);
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
                    try emitExpr(allocator, buf, elem, depth);
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
                    try emitExpr(allocator, buf, elem, depth);
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
            try emitExpr(allocator, buf, rp.elem.*, depth);
            try buf.appendSlice(allocator, " } ** ");
            var len_buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{rp.len}) catch unreachable;
            try buf.appendSlice(allocator, len_str);
        },
        .builtin => |bi| {
            if (std.mem.eql(u8, bi.name, "index") and bi.args.len == 2) {
                try emitExpr(allocator, buf, bi.args[0], depth);
                try buf.appendSlice(allocator, "[");
                try emitExpr(allocator, buf, bi.args[1], depth);
                try buf.appendSlice(allocator, "]");
            } else {
                try buf.appendSlice(allocator, "@");
                try buf.appendSlice(allocator, bi.name);
                try buf.appendSlice(allocator, "(");
                for (bi.args, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try emitExpr(allocator, buf, arg, depth);
                }
                try buf.appendSlice(allocator, ")");
            }
        },
        .unsupported => |u| {
            try buf.appendSlice(allocator, "@panic(\"unsupported: ");
            try emitEscapedString(allocator, buf, u);
            try buf.appendSlice(allocator, "\")");
        },
        .if_expr => |ie| {
            try buf.appendSlice(allocator, "if (");
            try emitExpr(allocator, buf, ie.cond.*, depth);
            try buf.appendSlice(allocator, ") ");
            try emitExpr(allocator, buf, ie.then_body.*, depth);
            if (ie.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitExpr(allocator, buf, eb.*, depth);
            }
        },
        .while_expr => |we| {
            try buf.appendSlice(allocator, "while (");
            try emitExpr(allocator, buf, we.cond.*, depth);
            try buf.appendSlice(allocator, ")");
            if (we.captures) |caps| {
                try buf.appendSlice(allocator, " |");
                for (caps, 0..) |cap, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, cap);
                }
                try buf.appendSlice(allocator, "|");
            }
            if (we.continue_expr) |ce| {
                try buf.appendSlice(allocator, " : (");
                try emitExpr(allocator, buf, ce.*, depth);
                try buf.appendSlice(allocator, ")");
            }
            try buf.appendSlice(allocator, " ");
            try emitBlock(allocator, buf, we.body, depth);
            if (we.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitExpr(allocator, buf, eb.*, depth);
            }
        },
        .for_expr => |fe| {
            try buf.appendSlice(allocator, "for (");
            for (fe.inputs, 0..) |inp, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitExpr(allocator, buf, inp, depth);
            }
            try buf.appendSlice(allocator, ") |");
            for (fe.captures, 0..) |cap, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitIdent(allocator, buf, cap);
            }
            try buf.appendSlice(allocator, "| ");
            try emitBlock(allocator, buf, fe.body, depth);
            if (fe.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitExpr(allocator, buf, eb.*, depth);
            }
        },
        .range => |r| {
            try emitExpr(allocator, buf, r.start.*, depth);
            try buf.appendSlice(allocator, "..");
            if (r.end) |en| try emitExpr(allocator, buf, en.*, depth);
        },
        .return_expr => |re| {
            if (re) |val| {
                try buf.appendSlice(allocator, "return ");
                try emitExpr(allocator, buf, val.*, depth);
            } else {
                try buf.appendSlice(allocator, "return");
            }
        },
        .break_expr => |be| {
            if (be) |val| {
                try buf.appendSlice(allocator, "break ");
                try emitExpr(allocator, buf, val.*, depth);
            } else {
                try buf.appendSlice(allocator, "break");
            }
        },
        .continue_expr => {
            try buf.appendSlice(allocator, "continue");
        },
    }
}

const match_payload_name = "match payload";
const match_arm_label = "match arm";

fn emitMatchExpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    match: ast.Match,
    depth: usize,
) std.mem.Allocator.Error!void {
    try buf.appendSlice(allocator, "switch (");
    try emitExpr(allocator, buf, match.target.*, depth);
    try buf.appendSlice(allocator, ") {\n");

    for (match.arms) |arm| {
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

        const direct_binding = matchDirectBinding(arm);
        const struct_pattern = matchStructPattern(arm);
        const needs_destructure = if (struct_pattern) |pattern|
            matchNeedsDestructure(pattern)
        else
            false;

        try buf.appendSlice(allocator, " =>");
        if (direct_binding) |binding| {
            try buf.appendSlice(allocator, " |");
            try emitIdent(allocator, buf, binding);
            try buf.appendSlice(allocator, "|");
        } else if (needs_destructure) {
            try buf.appendSlice(allocator, " |");
            try emitIdent(allocator, buf, match_payload_name);
            try buf.appendSlice(allocator, "|");
        }
        try buf.appendSlice(allocator, " ");

        if (needs_destructure) {
            try emitMatchDestructureBody(
                allocator,
                buf,
                struct_pattern.?,
                arm.body,
                depth,
            );
        } else {
            try emitExpr(allocator, buf, arm.body, depth + 1);
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
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    pattern: ast.StructPattern,
    body: ast.Expr,
    depth: usize,
) std.mem.Allocator.Error!void {
    try emitIdent(allocator, buf, match_arm_label);
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
        try emitIdent(allocator, buf, match_payload_name);
        try buf.appendSlice(allocator, ".");
        try emitIdent(allocator, buf, field.name);
        try buf.appendSlice(allocator, ";\n");
    }

    try emitIndent(allocator, buf, depth + 2);
    switch (body) {
        .return_expr, .break_expr, .continue_expr => {
            try emitExpr(allocator, buf, body, depth + 2);
            try buf.appendSlice(allocator, ";\n");
        },
        else => {
            try buf.appendSlice(allocator, "break :");
            try emitIdent(allocator, buf, match_arm_label);
            try buf.appendSlice(allocator, " ");
            try emitExpr(allocator, buf, body, depth + 2);
            try buf.appendSlice(allocator, ";\n");
        },
    }
    try emitIndent(allocator, buf, depth + 1);
    try buf.appendSlice(allocator, "}");
}

fn emitBlock(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    b: ast.Block,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (b.label) |lbl| {
        try emitIdent(allocator, buf, lbl);
        try buf.appendSlice(allocator, ": ");
    }
    try buf.appendSlice(allocator, "{\n");
    for (b.stmts) |stmt| {
        try emitStmt(allocator, buf, stmt, depth + 1);
    }
    if (b.expr) |tail| {
        try emitIndent(allocator, buf, depth + 1);
        if (b.label) |lbl| {
            try buf.appendSlice(allocator, "break :");
            try emitIdent(allocator, buf, lbl);
            try buf.appendSlice(allocator, " ");
            try emitExpr(allocator, buf, tail.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
        } else {
            try emitExpr(allocator, buf, tail.*, depth + 1);
            if (!isStatementLike(tail.*) and
                tail.* != .match_expr and
                tail.* != .return_expr and
                tail.* != .break_expr and
                tail.* != .continue_expr)
            {
                // In Zig statement block, if expression is used as statement:
                try buf.appendSlice(allocator, ";");
            }
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
                try buf.appendSlice(allocator, "\\0");
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
            if (p.is_allowzero) {
                try buf.appendSlice(allocator, "[allowzero]");
            }
            switch (p.size) {
                .one => try buf.appendSlice(allocator, "*"),
                .many => try buf.appendSlice(allocator, "[*]"),
                .c => try buf.appendSlice(allocator, "[*c]"),
            }
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
        .tuple => |tup| {
            try buf.appendSlice(allocator, "struct { ");
            for (tup, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitType(allocator, buf, elem);
            }
            try buf.appendSlice(allocator, " }");
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
