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

        for (t.body.stmts) |stmt| {
            try emitStmt(allocator, &buf, stmt, 1);
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
            if (tail_expr.* == .return_expr or tail_expr.* == .panic_) {
                try emitExpr(allocator, buf, tail_expr.*, depth + 1);
                try buf.appendSlice(allocator, ";\n");
            } else if (isStatementLike(tail_expr.*) and
                (tail_expr.* != .block or !blockHasValue(tail_expr.block)))
            {
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
            try emitExprScoped(context, allocator, buf, es.*, depth);
            if (!isStatementLike(es.*) and es.* != .if_expr and es.* != .match_expr) {
                try buf.appendSlice(allocator, ";");
            }
            try buf.appendSlice(allocator, "\n");
        },
    }
}

fn isStatementLike(expr: ast.Expr) bool {
    return switch (expr) {
        .block, .while_expr, .for_expr => true,
        else => false,
    };
}

fn blockHasValue(block: ast.Block) bool {
    const tail = block.expr orelse return false;
    return switch (tail.*) {
        .return_expr, .break_expr, .continue_expr, .panic_ => false,
        else => true,
    };
}

const GeneratedMatchName = struct {
    base: []const u8,
    suffix: usize = 0,
};

const EmitContext = struct {
    active_names: []const GeneratedMatchName = &.{},
    active_capture_names: []const []const u8 = &.{},
};
const match_payload_base = "__r2z_match_payload";
const match_arm_base = "__r2z_match_arm";

fn generatedMatchNameText(
    buffer: *[64]u8,
    name: GeneratedMatchName,
) []const u8 {
    if (name.suffix == 0) return name.base;
    return std.fmt.bufPrint(buffer, "{s}_{d}", .{ name.base, name.suffix }) catch unreachable;
}

fn generatedMatchNameEquals(value: []const u8, name: GeneratedMatchName) bool {
    var buffer: [64]u8 = undefined;
    return std.mem.eql(u8, value, generatedMatchNameText(&buffer, name));
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

fn emitRepeatElementType(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    type_name: ast.Type,
) std.mem.Allocator.Error!void {
    switch (type_name) {
        .array => |array| try emitType(allocator, buf, array.elem.*),
        .array_expr => |array| try emitType(allocator, buf, array.elem.*),
        else => try emitType(allocator, buf, type_name),
    }
}

fn lexicalRoot(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
    return value[0..end];
}
fn typeContainsGeneratedMatchName(ty: ast.Type, name: GeneratedMatchName) bool {
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

fn patternContainsGeneratedMatchName(pattern: ast.Pattern, name: GeneratedMatchName) bool {
    return switch (pattern) {
        .wildcard, .lit => false,
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

fn stmtContainsGeneratedMatchName(stmt: ast.Stmt, name: GeneratedMatchName) bool {
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

fn blockContainsGeneratedMatchName(block: ast.Block, name: GeneratedMatchName) bool {
    if (block.label) |label| {
        if (generatedMatchNameEquals(lexicalRoot(label), name)) return true;
    }
    for (block.stmts) |stmt| {
        if (stmtContainsGeneratedMatchName(stmt, name)) return true;
    }
    if (block.expr) |expression| return exprContainsGeneratedMatchName(expression.*, name);
    return false;
}

fn matchContainsGeneratedMatchName(match: ast.Match, name: GeneratedMatchName) bool {
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

fn exprContainsGeneratedMatchName(expression: ast.Expr, name: GeneratedMatchName) bool {
    return switch (expression) {
        .lit, .unit, .unsupported, .panic_, .continue_expr => false,
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
        .return_expr, .break_expr => |value| {
            if (value) |inner| return exprContainsGeneratedMatchName(inner.*, name);
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
        if (!active) {
            for (active_capture_names) |capture_name| {
                if (generatedMatchNameEquals(capture_name, candidate)) {
                    active = true;
                    break;
                }
            }
        }
        if (!active and !matchContainsGeneratedMatchName(match, candidate)) return candidate;
    }
    @panic("exhausted generated match names");
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
    try buf.appendSlice(allocator, "while (");
    try emitExprScoped(context, allocator, buf, chunks.target, depth);
    try buf.appendSlice(allocator, ".len > __chunk_index) : (__chunk_index += ");
    try emitExprScoped(context, allocator, buf, size, depth);
    try buf.appendSlice(allocator, ") {\n");
    try emitIndent(allocator, buf, depth + 1);
    try buf.appendSlice(allocator, "const ");
    try emitIdent(allocator, buf, capture.name);
    try buf.appendSlice(allocator, " = ");
    try emitExprScoped(context, allocator, buf, chunks.target, depth + 1);
    try buf.appendSlice(allocator, "[__chunk_index..@min(__chunk_index + ");
    try emitExprScoped(context, allocator, buf, size, depth + 1);
    try buf.appendSlice(allocator, ", ");
    try emitExprScoped(context, allocator, buf, chunks.target, depth + 1);
    try buf.appendSlice(allocator, ".len)];\n");
    for (loop.body.stmts) |stmt| {
        try emitStmtScoped(context, allocator, buf, stmt, depth + 1);
    }
    try emitIndent(allocator, buf, depth);
    try buf.appendSlice(allocator, "}");
    return true;
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
            if (fa.target.* == .ident and std.mem.eql(u8, fa.target.ident, "error")) {
                try buf.appendSlice(allocator, "error");
            } else {
                try emitExprScoped(context, allocator, buf, fa.target.*, depth);
            }
            try buf.appendSlice(allocator, ".");
            try emitIdent(allocator, buf, fa.field_name);
        },
        .call => |c| {
            try emitExprScoped(context, allocator, buf, c.callee.*, depth);
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
            try buf.appendSlice(allocator, "(");
            try emitExprScoped(context, allocator, buf, bo.lhs.*, depth);
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
            try emitExprScoped(context, allocator, buf, bo.rhs.*, depth);
            try buf.appendSlice(allocator, ")");
        },
        .unary_op => |uo| {
            switch (uo.op) {
                .negate => {
                    try buf.appendSlice(allocator, "-");
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
                },
                .bit_not => {
                    try buf.appendSlice(allocator, "~");
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
                },
                .bool_not => {
                    try buf.appendSlice(allocator, "!");
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
                },
                .deref => {
                    const needs_parentheses = switch (uo.operand.*) {
                        .unary_op, .if_expr, .match_expr, .block => true,
                        else => false,
                    };
                    if (needs_parentheses) try buf.append(allocator, '(');
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
                    if (needs_parentheses) try buf.append(allocator, ')');
                    try buf.appendSlice(allocator, ".*");
                },
                .addr_of => {
                    try buf.appendSlice(allocator, "&");
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
                },
                .try_op => {
                    try buf.appendSlice(allocator, "try ");
                    try emitExprScoped(context, allocator, buf, uo.operand.*, depth);
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
                try emitRepeatElementType(allocator, buf, tn);
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
                try emitExprScoped(context, allocator, buf, bi.args[0], depth);
                try buf.appendSlice(allocator, "[");
                try emitExprScoped(context, allocator, buf, bi.args[1], depth);
                try buf.appendSlice(allocator, "]");
            } else if (std.mem.eql(u8, bi.name, "sliceChunks") and bi.args.len == 2) {
                try emitExprScoped(context, allocator, buf, bi.args[0], depth);
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
            try emitExprScoped(context, allocator, buf, ie.then_body.*, depth);
            if (ie.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitExprScoped(context, allocator, buf, eb.*, depth);
            }
        },
        .while_expr => |we| {
            try buf.appendSlice(allocator, "while (");
            try emitExprScoped(context, allocator, buf, we.cond.*, depth);
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
                try emitExprScoped(context, allocator, buf, ce.*, depth);
                try buf.appendSlice(allocator, ")");
            }
            try buf.appendSlice(allocator, " ");
            try emitBlockScoped(context, allocator, buf, we.body, depth);
            if (we.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitExprScoped(context, allocator, buf, eb.*, depth);
            }
        },
        .for_expr => |fe| {
            if (try emitChunkLoop(context, allocator, buf, fe, depth)) return;
            try buf.appendSlice(allocator, "for (");
            for (fe.inputs, 0..) |inp, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitExprScoped(context, allocator, buf, inp, depth);
            }
            try buf.appendSlice(allocator, ") |");
            for (fe.captures, 0..) |cap, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try emitCaptureBinding(allocator, buf, cap);
            }
            try buf.appendSlice(allocator, "| ");
            try emitBlockScoped(context, allocator, buf, fe.body, depth);
            if (fe.else_body) |eb| {
                try buf.appendSlice(allocator, " else ");
                try emitExprScoped(context, allocator, buf, eb.*, depth);
            }
        },
        .range => |r| {
            try emitExprScoped(context, allocator, buf, r.start.*, depth);
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
        .break_expr => |be| {
            if (be) |val| {
                try buf.appendSlice(allocator, "break ");
                try emitExprScoped(context, allocator, buf, val.*, depth);
            } else {
                try buf.appendSlice(allocator, "break");
            }
        },
        .continue_expr => {
            try buf.appendSlice(allocator, "continue");
        },
    }
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
            try buf.appendSlice(allocator, " |");
            if (capture.by_ref) try buf.appendSlice(allocator, "*");
            try emitIdent(allocator, buf, capture.name);
            try buf.appendSlice(allocator, "|");
        } else if (direct_binding) |binding| {
            try buf.appendSlice(allocator, " |");
            try emitIdent(allocator, buf, binding);
            try buf.appendSlice(allocator, "|");
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
            const arm_context: EmitContext = .{
                .active_names = active_names.items,
                .active_capture_names = arm_capture_names.items,
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
        .return_expr, .break_expr, .continue_expr, .panic_ => {
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
        std.fmt.bufPrint(
            &generated_label_buffer,
            "__r2z_value_block_{d}",
            .{depth},
        ) catch unreachable
    else
        null;
    if (value_label) |label| {
        try emitIdent(allocator, buf, label);
        try buf.appendSlice(allocator, ": ");
    }
    try buf.appendSlice(allocator, "{\n");
    for (block.stmts) |stmt| {
        try emitStmtScoped(context, allocator, buf, stmt, depth + 1);
    }
    if (block.expr) |tail| {
        try emitIndent(allocator, buf, depth + 1);
        if (tail.* == .return_expr or tail.* == .break_expr or
            tail.* == .continue_expr or tail.* == .panic_)
        {
            try emitExprScoped(context, allocator, buf, tail.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
        } else if (value_label) |label| {
            try buf.appendSlice(allocator, "break :");
            try emitIdent(allocator, buf, label);
            try buf.appendSlice(allocator, " ");
            try emitExprScoped(context, allocator, buf, tail.*, depth + 1);
            try buf.appendSlice(allocator, ";\n");
        } else {
            try emitExprScoped(context, allocator, buf, tail.*, depth + 1);
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
            .expr = &ast.Expr{ .continue_expr = {} },
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
