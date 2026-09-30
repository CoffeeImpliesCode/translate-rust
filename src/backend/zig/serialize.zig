//! translate_rust.backend.zig.serialize — JSON serialization and deserialization
//! for the Zig AST DOM (ast.Package).
//!
//! Enables lossless JSON encoding/decoding of Zig AST packages for snapshot testing,
//! inter-tool boundaries, and tooling inspection.

const std = @import("std");
const ast = @import("ast.zig");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

pub const format_version: u32 = 1;

// ---------------------------------------------------------------------------
// Free Helper for Memory Management of Json Objects
// ---------------------------------------------------------------------------

fn freeValue(allocator: std.mem.Allocator, v: *Json) void {
    switch (v.*) {
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |entry| freeValue(allocator, entry.value_ptr);
            o.deinit(allocator);
        },
        .array => |*ar| {
            for (ar.items) |*item| freeValue(allocator, item);
            ar.deinit();
        },
        // Only the encoder puts a `number_string` in a tree `freeValue` walks;
        // one parsed out of JSON lives in the parser's own arena.
        .number_string => allocator.free(v.number_string),
        else => {},
    }
}

fn mkInt(x: anytype) Json {
    return .{ .integer = @intCast(x) };
}

/// Preserve wide counts as unquoted decimal numbers, never through `f64`.
fn mkCount(allocator: std.mem.Allocator, n: usize) !Json {
    if (std.math.cast(i64, n)) |i| return .{ .integer = i };
    return .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{n}) };
}

fn encodeOptStr(s: ?[]const u8) Json {
    return if (s) |x| .{ .string = x } else .{ .null = {} };
}

// ---------------------------------------------------------------------------
// Decode Helpers
// ---------------------------------------------------------------------------

fn getObj(v: Json) !ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.BadWireFormat,
    };
}

fn req(o: ObjectMap, key: []const u8) !Json {
    return o.get(key) orelse error.MissingField;
}

fn reqU32(o: ObjectMap, key: []const u8) !u32 {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| @intCast(i),
        else => error.BadWireFormat,
    };
}

fn reqU64(o: ObjectMap, key: []const u8) !u64 {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| @intCast(i),
        .string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.BadWireFormat,
    };
}

fn optU64(o: ObjectMap, key: []const u8) !?u64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @intCast(i),
        .string => |s| try std.fmt.parseInt(u64, s, 10),
        .null => null,
        else => error.BadWireFormat,
    };
}

fn reqUsize(o: ObjectMap, key: []const u8) !usize {
    const v = try req(o, key);
    return switch (v) {
        .integer => |i| @intCast(i),
        .number_string => |s| std.fmt.parseInt(usize, s, 10),
        else => error.BadWireFormat,
    };
}

fn reqBool(o: ObjectMap, key: []const u8) !bool {
    const v = try req(o, key);
    return switch (v) {
        .bool => |b| b,
        else => error.BadWireFormat,
    };
}

fn reqStr(o: ObjectMap, key: []const u8) ![]const u8 {
    const v = try req(o, key);
    return switch (v) {
        .string => |s| s,
        else => error.BadWireFormat,
    };
}

fn optStr(o: ObjectMap, key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.BadWireFormat,
    };
}

fn reqFloat(o: ObjectMap, key: []const u8) !f64 {
    const v = try req(o, key);
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.BadWireFormat,
    };
}

fn freeDecodedBytes(allocator: std.mem.Allocator, bytes: []const u8) void {
    if (bytes.len != 0) allocator.free(bytes);
}

fn freeDecodedType(allocator: std.mem.Allocator, ty: ast.Type) void {
    switch (ty) {
        .ptr => |ptr| {
            freeDecodedType(allocator, ptr.elem.*);
            allocator.destroy(@constCast(ptr.elem));
        },
        .slice => |slice| {
            freeDecodedType(allocator, slice.elem.*);
            allocator.destroy(@constCast(slice.elem));
        },
        .opt => |elem| {
            freeDecodedType(allocator, elem.*);
            allocator.destroy(@constCast(elem));
        },
        .err_union => |err_union| {
            if (err_union.err_set) |err_set| freeDecodedBytes(allocator, err_set);
            freeDecodedType(allocator, err_union.payload.*);
            allocator.destroy(@constCast(err_union.payload));
        },
        .projected => |projected| {
            freeDecodedBytes(allocator, projected.descriptor);
            freeDecodedType(allocator, projected.receiver.*);
            allocator.destroy(@constCast(projected.receiver));
            freeDecodedBytes(allocator, projected.member);
        },
        .named => |name| freeDecodedBytes(allocator, name),
        .generic => |generic| {
            freeDecodedBytes(allocator, generic.name);
            freeDecodedTypeSlice(allocator, generic.params);
        },
        .array => |array| {
            freeDecodedType(allocator, array.elem.*);
            allocator.destroy(@constCast(array.elem));
        },
        .array_expr => |array| {
            freeDecodedType(allocator, array.elem.*);
            allocator.destroy(@constCast(array.elem));
            freeDecodedExpr(allocator, array.len.*);
            allocator.destroy(@constCast(array.len));
        },
        .tuple => |elements| freeDecodedTypeSlice(allocator, elements),
        .fn_ptr => |function| {
            freeDecodedTypeSlice(allocator, function.params);
            freeDecodedType(allocator, function.ret.*);
            allocator.destroy(@constCast(function.ret));
        },
        .anon_struct => |anon_struct| {
            freeDecodedStructFieldSlice(allocator, anon_struct.fields);
        },
        .prim, .any_opaque, .void_type => {},
    }
}

fn freeDecodedTraitDescriptorMember(
    allocator: std.mem.Allocator,
    member: ast.TraitDescriptorMember,
) void {
    switch (member) {
        .type_ => |type_member| {
            freeDecodedBytes(allocator, type_member.name);
            freeDecodedType(allocator, type_member.ty);
        },
        .const_ => |const_member| {
            freeDecodedBytes(allocator, const_member.name);
            freeDecodedExpr(allocator, const_member.value);
        },
    }
}

fn freeDecodedTraitDescriptorMemberSlice(
    allocator: std.mem.Allocator,
    members: []const ast.TraitDescriptorMember,
) void {
    for (members) |member| freeDecodedTraitDescriptorMember(allocator, member);
    if (members.len != 0) allocator.free(members);
}

fn freeDecodedTraitDescriptorCase(
    allocator: std.mem.Allocator,
    descriptor_case: ast.TraitDescriptorCase,
) void {
    freeDecodedType(allocator, descriptor_case.receiver);
    freeDecodedTraitDescriptorMemberSlice(allocator, descriptor_case.members);
}

fn freeDecodedTraitDescriptorCaseSlice(
    allocator: std.mem.Allocator,
    cases: []const ast.TraitDescriptorCase,
) void {
    for (cases) |descriptor_case| {
        freeDecodedTraitDescriptorCase(allocator, descriptor_case);
    }
    if (cases.len != 0) allocator.free(cases);
}

fn freeDecodedTraitDescriptorDecl(
    allocator: std.mem.Allocator,
    descriptor: ast.TraitDescriptorDecl,
) void {
    freeDecodedBytes(allocator, descriptor.name);
    freeDecodedTraitDescriptorCaseSlice(allocator, descriptor.cases);
}

fn freeDecodedTypeSlice(allocator: std.mem.Allocator, types: []const ast.Type) void {
    for (types) |ty| freeDecodedType(allocator, ty);
    if (types.len != 0) allocator.free(types);
}

fn freeDecodedLiteral(allocator: std.mem.Allocator, literal: ast.Literal) void {
    switch (literal) {
        .str, .error_tag => |value| freeDecodedBytes(allocator, value),
        .int, .uint, .float, .bool_lit, .char_lit, .null_lit, .undefined_lit => {},
    }
}

fn freeDecodedPattern(allocator: std.mem.Allocator, pattern: ast.Pattern) void {
    switch (pattern) {
        .binding, .enum_literal => |name| freeDecodedBytes(allocator, name),
        .lit => |literal| freeDecodedLiteral(allocator, literal),
        .tuple => |patterns| freeDecodedPatternSlice(allocator, patterns),
        .struct_pat => |struct_pat| {
            if (struct_pat.name) |name| freeDecodedBytes(allocator, name);
            for (struct_pat.fields) |field| {
                freeDecodedBytes(allocator, field.name);
                freeDecodedPattern(allocator, field.pat);
            }
            if (struct_pat.fields.len != 0) allocator.free(struct_pat.fields);
        },
        .range_pat => |range_pattern| {
            if (range_pattern.lo) |lo| freeDecodedLiteral(allocator, lo);
            if (range_pattern.hi) |hi| freeDecodedLiteral(allocator, hi);
        },
        .wildcard => {},
    }
}

fn freeDecodedPatternSlice(
    allocator: std.mem.Allocator,
    patterns: []const ast.Pattern,
) void {
    for (patterns) |pattern| freeDecodedPattern(allocator, pattern);
    if (patterns.len != 0) allocator.free(patterns);
}

fn freeDecodedPatternList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Pattern),
) void {
    for (list.items) |pattern| freeDecodedPattern(allocator, pattern);
    list.deinit(allocator);
}

fn freeDecodedStructPatternField(
    allocator: std.mem.Allocator,
    field: ast.StructPatternField,
) void {
    freeDecodedBytes(allocator, field.name);
    freeDecodedPattern(allocator, field.pat);
}

fn freeDecodedStructPatternFieldList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.StructPatternField),
) void {
    for (list.items) |field| freeDecodedStructPatternField(allocator, field);
    list.deinit(allocator);
}

fn freeDecodedCapture(allocator: std.mem.Allocator, capture: ast.Capture) void {
    freeDecodedBytes(allocator, capture.name);
}

fn freeDecodedCaptureSlice(
    allocator: std.mem.Allocator,
    captures: []const ast.Capture,
) void {
    for (captures) |capture| freeDecodedCapture(allocator, capture);
    if (captures.len != 0) allocator.free(captures);
}

fn freeDecodedMatchArm(allocator: std.mem.Allocator, arm: ast.MatchArm) void {
    freeDecodedPatternSlice(allocator, arm.patterns);
    if (arm.capture) |capture| freeDecodedCapture(allocator, capture);
    freeDecodedExpr(allocator, arm.body);
}

fn freeDecodedMatchArmList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.MatchArm),
) void {
    for (list.items) |arm| freeDecodedMatchArm(allocator, arm);
    list.deinit(allocator);
}

fn freeDecodedExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .lit => |literal| freeDecodedLiteral(allocator, literal),
        .ident, .unsupported, .panic_ => |name| freeDecodedBytes(allocator, name),
        .field_access => |field_access| {
            freeDecodedExpr(allocator, field_access.target.*);
            allocator.destroy(@constCast(field_access.target));
            freeDecodedBytes(allocator, field_access.field_name);
        },
        .call => |call| {
            freeDecodedExpr(allocator, call.callee.*);
            allocator.destroy(@constCast(call.callee));
            freeDecodedTypeSlice(allocator, call.generic_args);
            freeDecodedExprSlice(allocator, call.args);
        },
        .block => |block| freeDecodedBlock(allocator, block),
        .match_expr => |match_expr| {
            freeDecodedExpr(allocator, match_expr.target.*);
            allocator.destroy(@constCast(match_expr.target));
            for (match_expr.arms) |arm| freeDecodedMatchArm(allocator, arm);
            if (match_expr.arms.len != 0) allocator.free(match_expr.arms);
        },
        .bin_op => |bin_op| {
            freeDecodedExpr(allocator, bin_op.lhs.*);
            allocator.destroy(@constCast(bin_op.lhs));
            freeDecodedExpr(allocator, bin_op.rhs.*);
            allocator.destroy(@constCast(bin_op.rhs));
        },
        .unary_op => |unary_op| {
            freeDecodedExpr(allocator, unary_op.operand.*);
            allocator.destroy(@constCast(unary_op.operand));
        },
        .cast => |cast| {
            freeDecodedType(allocator, cast.target);
            if (cast.source) |source| freeDecodedType(allocator, source);
            freeDecodedExpr(allocator, cast.operand.*);
            allocator.destroy(@constCast(cast.operand));
        },
        .struct_init => |struct_init| {
            if (struct_init.type_name) |type_name| freeDecodedType(allocator, type_name);
            for (struct_init.fields) |field| {
                freeDecodedBytes(allocator, field.name);
                freeDecodedExpr(allocator, field.expr);
            }
            if (struct_init.fields.len != 0) allocator.free(struct_init.fields);
        },
        .array_init => |array_init| {
            if (array_init.type_name) |type_name| freeDecodedType(allocator, type_name);
            freeDecodedExprSlice(allocator, array_init.elements);
        },
        .repeat => |repeat| {
            if (repeat.type_name) |type_name| freeDecodedType(allocator, type_name);
            freeDecodedExpr(allocator, repeat.elem.*);
            allocator.destroy(@constCast(repeat.elem));
        },
        .multi_array => |multi_array| {
            if (multi_array.type_name) |type_name| freeDecodedType(allocator, type_name);
            freeDecodedExprSlice(allocator, multi_array.elements);
        },
        .tuple => |elements| freeDecodedExprSlice(allocator, elements),
        .builtin => |builtin| {
            freeDecodedBytes(allocator, builtin.name);
            freeDecodedExprSlice(allocator, builtin.args);
        },
        .if_expr => |if_expr| {
            freeDecodedExpr(allocator, if_expr.cond.*);
            allocator.destroy(@constCast(if_expr.cond));
            freeDecodedExpr(allocator, if_expr.then_body.*);
            allocator.destroy(@constCast(if_expr.then_body));
            if (if_expr.else_body) |else_body| {
                freeDecodedExpr(allocator, else_body.*);
                allocator.destroy(@constCast(else_body));
            }
            if (if_expr.then_capture) |capture| freeDecodedCapture(allocator, capture);
            if (if_expr.else_capture) |capture| freeDecodedCapture(allocator, capture);
        },
        .while_expr => |while_expr| {
            freeDecodedExpr(allocator, while_expr.cond.*);
            allocator.destroy(@constCast(while_expr.cond));
            if (while_expr.continue_expr) |continue_expr| {
                freeDecodedExpr(allocator, continue_expr.*);
                allocator.destroy(@constCast(continue_expr));
            }
            if (while_expr.captures) |captures| freeDecodedStringSlice(allocator, captures);
            if (while_expr.label) |label| freeDecodedBytes(allocator, label);
            freeDecodedBlock(allocator, while_expr.body);
            if (while_expr.else_body) |else_body| {
                freeDecodedExpr(allocator, else_body.*);
                allocator.destroy(@constCast(else_body));
            }
        },
        .for_expr => |for_expr| {
            freeDecodedExprSlice(allocator, for_expr.inputs);
            freeDecodedCaptureSlice(allocator, for_expr.captures);
            if (for_expr.label) |label| freeDecodedBytes(allocator, label);
            freeDecodedBlock(allocator, for_expr.body);
            if (for_expr.else_body) |else_body| {
                freeDecodedExpr(allocator, else_body.*);
                allocator.destroy(@constCast(else_body));
            }
        },
        .range => |range| {
            freeDecodedExpr(allocator, range.start.*);
            allocator.destroy(@constCast(range.start));
            if (range.end) |end| {
                freeDecodedExpr(allocator, end.*);
                allocator.destroy(@constCast(end));
            }
        },
        .return_expr => |value| {
            if (value) |expr_ptr| {
                freeDecodedExpr(allocator, expr_ptr.*);
                allocator.destroy(@constCast(expr_ptr));
            }
        },
        .break_expr => |break_expr| {
            if (break_expr.label) |label| freeDecodedBytes(allocator, label);
            if (break_expr.value) |expr_ptr| {
                freeDecodedExpr(allocator, expr_ptr.*);
                allocator.destroy(@constCast(expr_ptr));
            }
        },
        .continue_expr => |continue_expr| {
            if (continue_expr.label) |label| freeDecodedBytes(allocator, label);
        },
        .unit, .unreachable_ => {},
    }
}

fn freeDecodedExprSlice(allocator: std.mem.Allocator, exprs: []const ast.Expr) void {
    for (exprs) |expr| freeDecodedExpr(allocator, expr);
    if (exprs.len != 0) allocator.free(exprs);
}

fn freeDecodedStringSlice(
    allocator: std.mem.Allocator,
    strings: []const []const u8,
) void {
    for (strings) |string| freeDecodedBytes(allocator, string);
    if (strings.len != 0) allocator.free(strings);
}

fn freeDecodedBlock(allocator: std.mem.Allocator, block: ast.Block) void {
    if (block.label) |label| freeDecodedBytes(allocator, label);
    freeDecodedStmtSlice(allocator, block.stmts);
    if (block.expr) |expr| {
        freeDecodedExpr(allocator, expr.*);
        allocator.destroy(@constCast(expr));
    }
}

fn freeDecodedStmt(allocator: std.mem.Allocator, stmt: ast.Stmt) void {
    switch (stmt) {
        .let_stmt => |let_stmt| {
            freeDecodedBytes(allocator, let_stmt.name);
            if (let_stmt.ty) |ty| freeDecodedType(allocator, ty);
            freeDecodedExpr(allocator, let_stmt.init);
        },
        .assign => |assign| {
            freeDecodedExpr(allocator, assign.target);
            freeDecodedExpr(allocator, assign.val);
        },
        .defer_stmt => |defer_stmt| {
            freeDecodedExpr(allocator, defer_stmt.expr);
        },
        .expr_stmt => |expr| {
            freeDecodedExpr(allocator, expr.*);
            allocator.destroy(@constCast(expr));
        },
    }
}

fn freeDecodedStmtSlice(allocator: std.mem.Allocator, stmts: []const ast.Stmt) void {
    for (stmts) |stmt| freeDecodedStmt(allocator, stmt);
    if (stmts.len != 0) allocator.free(stmts);
}

fn freeDecodedGenericParam(allocator: std.mem.Allocator, param: ast.GenericParam) void {
    freeDecodedBytes(allocator, param.name);
    if (param.ty) |ty| freeDecodedType(allocator, ty);
}

fn freeDecodedGenericParamSlice(
    allocator: std.mem.Allocator,
    params: []const ast.GenericParam,
) void {
    for (params) |param| freeDecodedGenericParam(allocator, param);
    if (params.len != 0) allocator.free(params);
}

fn freeDecodedStructField(allocator: std.mem.Allocator, field: ast.StructField) void {
    freeDecodedBytes(allocator, field.name);
    freeDecodedType(allocator, field.ty);
    if (field.default_val) |default_val| {
        freeDecodedExpr(allocator, default_val.*);
        allocator.destroy(@constCast(default_val));
    }
}

fn freeDecodedStructFieldSlice(
    allocator: std.mem.Allocator,
    fields: []const ast.StructField,
) void {
    for (fields) |field| freeDecodedStructField(allocator, field);
    if (fields.len != 0) allocator.free(fields);
}

fn freeDecodedEnumVariant(allocator: std.mem.Allocator, variant: ast.EnumVariant) void {
    freeDecodedBytes(allocator, variant.name);
    if (variant.value) |value| {
        freeDecodedExpr(allocator, value.*);
        allocator.destroy(@constCast(value));
    }
}

fn freeDecodedEnumVariantSlice(
    allocator: std.mem.Allocator,
    variants: []const ast.EnumVariant,
) void {
    for (variants) |variant| freeDecodedEnumVariant(allocator, variant);
    if (variants.len != 0) allocator.free(variants);
}

fn freeDecodedUnionField(allocator: std.mem.Allocator, field: ast.UnionField) void {
    freeDecodedBytes(allocator, field.name);
    freeDecodedType(allocator, field.ty);
}

fn freeDecodedUnionFieldSlice(
    allocator: std.mem.Allocator,
    fields: []const ast.UnionField,
) void {
    for (fields) |field| freeDecodedUnionField(allocator, field);
    if (fields.len != 0) allocator.free(fields);
}

fn freeDecodedFnParam(allocator: std.mem.Allocator, param: ast.FnParam) void {
    freeDecodedBytes(allocator, param.name);
    freeDecodedType(allocator, param.ty);
}

fn freeDecodedFnParamSlice(
    allocator: std.mem.Allocator,
    params: []const ast.FnParam,
) void {
    for (params) |param| freeDecodedFnParam(allocator, param);
    if (params.len != 0) allocator.free(params);
}

fn freeDecodedDecl(allocator: std.mem.Allocator, decl: ast.Decl) void {
    switch (decl) {
        .trait_descriptor => |descriptor| {
            freeDecodedTraitDescriptorDecl(allocator, descriptor);
        },
        .struct_decl => |struct_decl| {
            freeDecodedBytes(allocator, struct_decl.name);
            freeDecodedStructFieldSlice(allocator, struct_decl.fields);
            freeDecodedDeclSlice(allocator, struct_decl.decls);
            freeDecodedGenericParamSlice(allocator, struct_decl.generic_params);
        },
        .enum_decl => |enum_decl| {
            freeDecodedBytes(allocator, enum_decl.name);
            if (enum_decl.tag_type) |tag_type| freeDecodedType(allocator, tag_type);
            freeDecodedEnumVariantSlice(allocator, enum_decl.variants);
            freeDecodedDeclSlice(allocator, enum_decl.decls);
        },
        .union_decl => |union_decl| {
            freeDecodedBytes(allocator, union_decl.name);
            if (union_decl.tag_type) |tag_type| freeDecodedType(allocator, tag_type);
            freeDecodedUnionFieldSlice(allocator, union_decl.fields);
            freeDecodedDeclSlice(allocator, union_decl.decls);
        },
        .fn_decl => |fn_decl| {
            freeDecodedBytes(allocator, fn_decl.name);
            freeDecodedFnParamSlice(allocator, fn_decl.params);
            freeDecodedType(allocator, fn_decl.ret_type);
            if (fn_decl.body) |body| freeDecodedBlock(allocator, body);
            freeDecodedGenericParamSlice(allocator, fn_decl.generic_params);
        },
        .const_decl => |const_decl| {
            freeDecodedBytes(allocator, const_decl.name);
            if (const_decl.ty) |ty| freeDecodedType(allocator, ty);
            freeDecodedExpr(allocator, const_decl.init);
        },
        .var_decl => |var_decl| {
            freeDecodedBytes(allocator, var_decl.name);
            if (var_decl.ty) |ty| freeDecodedType(allocator, ty);
            freeDecodedExpr(allocator, var_decl.init);
        },
        .comment => |comment| freeDecodedBytes(allocator, comment),
    }
}

fn freeDecodedDeclSlice(allocator: std.mem.Allocator, decls: []const ast.Decl) void {
    for (decls) |decl| freeDecodedDecl(allocator, decl);
    if (decls.len != 0) allocator.free(decls);
}

fn freeDecodedImport(allocator: std.mem.Allocator, import: ast.Import) void {
    freeDecodedBytes(allocator, import.local_name);
    freeDecodedBytes(allocator, import.module_or_path);
}

fn freeDecodedImportSlice(
    allocator: std.mem.Allocator,
    imports: []const ast.Import,
) void {
    for (imports) |import| freeDecodedImport(allocator, import);
    if (imports.len != 0) allocator.free(imports);
}

fn freeDecodedTestDecl(allocator: std.mem.Allocator, test_decl: ast.TestDecl) void {
    freeDecodedBytes(allocator, test_decl.name);
    freeDecodedBlock(allocator, test_decl.body);
}

fn freeDecodedTestDeclSlice(
    allocator: std.mem.Allocator,
    tests: []const ast.TestDecl,
) void {
    for (tests) |test_decl| freeDecodedTestDecl(allocator, test_decl);
    if (tests.len != 0) allocator.free(tests);
}

fn freeDecodedFile(allocator: std.mem.Allocator, file: ast.File) void {
    freeDecodedBytes(allocator, file.path);
    freeDecodedImportSlice(allocator, file.imports);
    freeDecodedDeclSlice(allocator, file.decls);
    freeDecodedTestDeclSlice(allocator, file.tests);
}

fn freeDecodedFileSlice(allocator: std.mem.Allocator, files: []const ast.File) void {
    for (files) |file| freeDecodedFile(allocator, file);
    if (files.len != 0) allocator.free(files);
}

fn freeDecodedZonDep(allocator: std.mem.Allocator, dep: ast.ZonDep) void {
    freeDecodedBytes(allocator, dep.name);
    freeDecodedBytes(allocator, dep.url);
    freeDecodedBytes(allocator, dep.hash);
    if (dep.path) |path| freeDecodedBytes(allocator, path);
}

fn freeDecodedZonDepSlice(
    allocator: std.mem.Allocator,
    deps: []const ast.ZonDep,
) void {
    for (deps) |dep| freeDecodedZonDep(allocator, dep);
    if (deps.len != 0) allocator.free(deps);
}

fn appendDecodedType(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Type),
    value: Json,
) !void {
    const decoded = try decodeType(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedType(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedExpr(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Expr),
    value: Json,
) !void {
    const decoded = try decodeExpr(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedExpr(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedPattern(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Pattern),
    value: Json,
) !void {
    const decoded = try decodePattern(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedPattern(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedMatchArm(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.MatchArm),
    value: Json,
) !void {
    const decoded = try decodeMatchArm(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedMatchArm(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedStmt(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Stmt),
    value: Json,
) !void {
    const decoded = try decodeStmt(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedStmt(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedDecl(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Decl),
    value: Json,
) !void {
    const decoded = try decodeDecl(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedDecl(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedString(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    value: []const u8,
) !void {
    const decoded = try allocator.dupe(u8, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedBytes(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedCapture(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Capture),
    value: Json,
) !void {
    const decoded = try decodeCapture(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedCapture(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn freeDecodedTypeList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Type),
) void {
    for (list.items) |ty| freeDecodedType(allocator, ty);
    list.deinit(allocator);
}

fn freeDecodedStringList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
) void {
    for (list.items) |string| freeDecodedBytes(allocator, string);
    list.deinit(allocator);
}

fn freeDecodedCaptureList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Capture),
) void {
    for (list.items) |capture| freeDecodedCapture(allocator, capture);
    list.deinit(allocator);
}

fn freeDecodedExprList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Expr),
) void {
    for (list.items) |expr| freeDecodedExpr(allocator, expr);
    list.deinit(allocator);
}

fn freeDecodedStmtList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Stmt),
) void {
    for (list.items) |stmt| freeDecodedStmt(allocator, stmt);
    list.deinit(allocator);
}

fn freeDecodedDeclList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Decl),
) void {
    for (list.items) |decl| freeDecodedDecl(allocator, decl);
    list.deinit(allocator);
}

fn appendDecodedGenericParam(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.GenericParam),
    value: Json,
) !void {
    const decoded = try decodeGenericParam(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedGenericParam(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedStructField(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.StructField),
    value: Json,
) !void {
    const decoded = try decodeStructField(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedStructField(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedEnumVariant(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.EnumVariant),
    value: Json,
) !void {
    const decoded = try decodeEnumVariant(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedEnumVariant(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedUnionField(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.UnionField),
    value: Json,
) !void {
    const decoded = try decodeUnionField(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedUnionField(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn freeDecodedGenericParamList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.GenericParam),
) void {
    for (list.items) |param| freeDecodedGenericParam(allocator, param);
    list.deinit(allocator);
}

fn freeDecodedStructFieldList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.StructField),
) void {
    for (list.items) |field| freeDecodedStructField(allocator, field);
    list.deinit(allocator);
}

fn freeDecodedEnumVariantList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.EnumVariant),
) void {
    for (list.items) |variant| freeDecodedEnumVariant(allocator, variant);
    list.deinit(allocator);
}

fn freeDecodedUnionFieldList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.UnionField),
) void {
    for (list.items) |field| freeDecodedUnionField(allocator, field);
    list.deinit(allocator);
}
fn appendDecodedImport(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Import),
    value: Json,
) !void {
    const decoded = try decodeImport(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedImport(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedTestDecl(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.TestDecl),
    value: Json,
) !void {
    const decoded = try decodeTestDecl(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedTestDecl(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedFile(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.File),
    value: Json,
) !void {
    const decoded = try decodeFile(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedFile(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn appendDecodedZonDep(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.ZonDep),
    value: Json,
) !void {
    const decoded = try decodeZonDep(allocator, value);
    var owns_decoded = true;
    errdefer if (owns_decoded) freeDecodedZonDep(allocator, decoded);
    try list.append(allocator, decoded);
    owns_decoded = false;
}

fn freeDecodedImportList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.Import),
) void {
    for (list.items) |item| freeDecodedImport(allocator, item);
    list.deinit(allocator);
}

fn freeDecodedTestDeclList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.TestDecl),
) void {
    for (list.items) |item| freeDecodedTestDecl(allocator, item);
    list.deinit(allocator);
}

fn freeDecodedFileList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.File),
) void {
    for (list.items) |item| freeDecodedFile(allocator, item);
    list.deinit(allocator);
}

fn freeDecodedZonDepList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(ast.ZonDep),
) void {
    for (list.items) |item| freeDecodedZonDep(allocator, item);
    list.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Type Serialization
// ---------------------------------------------------------------------------

fn encodePrim(p: ast.Prim) []const u8 {
    return @tagName(p);
}

fn decodePrim(s: []const u8) !ast.Prim {
    inline for (std.meta.fields(ast.Prim)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownPrim;
}

fn encodePtrSize(ps: ast.PtrSize) []const u8 {
    return @tagName(ps);
}

fn decodePtrSize(s: []const u8) !ast.PtrSize {
    inline for (std.meta.fields(ast.PtrSize)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownPtrSize;
}

pub fn encodeType(allocator: std.mem.Allocator, ty: ast.Type) anyerror!Json {
    var o = ObjectMap.empty;
    switch (ty) {
        .prim => |p| {
            try o.put(allocator, "kind", .{ .string = "prim" });
            try o.put(allocator, "value", .{ .string = encodePrim(p) });
        },
        .ptr => |ptr| {
            try o.put(allocator, "kind", .{ .string = "ptr" });
            try o.put(allocator, "elem", try encodeType(allocator, ptr.elem.*));
            try o.put(allocator, "is_const", .{ .bool = ptr.is_const });
            try o.put(allocator, "is_allowzero", .{ .bool = ptr.is_allowzero });
            try o.put(allocator, "alignment", if (ptr.alignment) |alignment|
                .{ .integer = alignment }
            else
                .null);
            try o.put(allocator, "size", .{ .string = encodePtrSize(ptr.size) });
        },
        .slice => |sl| {
            try o.put(allocator, "kind", .{ .string = "slice" });
            try o.put(allocator, "elem", try encodeType(allocator, sl.elem.*));
            try o.put(allocator, "is_const", .{ .bool = sl.is_const });
        },
        .opt => |inner| {
            try o.put(allocator, "kind", .{ .string = "opt" });
            try o.put(allocator, "elem", try encodeType(allocator, inner.*));
        },
        .err_union => |eu| {
            try o.put(allocator, "kind", .{ .string = "err_union" });
            try o.put(allocator, "err_set", encodeOptStr(eu.err_set));
            try o.put(allocator, "payload", try encodeType(allocator, eu.payload.*));
        },
        .projected => |projected| {
            try o.put(allocator, "kind", .{ .string = "projected" });
            try o.put(allocator, "descriptor", .{ .string = projected.descriptor });
            try o.put(allocator, "receiver", try encodeType(allocator, projected.receiver.*));
            try o.put(allocator, "member", .{ .string = projected.member });
        },
        .named => |name| {
            try o.put(allocator, "kind", .{ .string = "named" });
            try o.put(allocator, "name", .{ .string = name });
        },
        .generic => |gi| {
            try o.put(allocator, "kind", .{ .string = "generic" });
            try o.put(allocator, "name", .{ .string = gi.name });
            var params_arr = Array.init(allocator);
            for (gi.params) |p| {
                try params_arr.append(try encodeType(allocator, p));
            }
            try o.put(allocator, "params", .{ .array = params_arr });
        },
        .array => |arr| {
            try o.put(allocator, "kind", .{ .string = "array" });
            try o.put(allocator, "elem", try encodeType(allocator, arr.elem.*));
            try o.put(allocator, "len", try mkCount(allocator, arr.len));
        },
        .array_expr => |arr| {
            try o.put(allocator, "kind", .{ .string = "array_expr" });
            try o.put(allocator, "elem", try encodeType(allocator, arr.elem.*));
            try o.put(allocator, "len", try encodeExpr(allocator, arr.len.*));
        },
        .tuple => |tup| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            var elements_arr = Array.init(allocator);
            for (tup) |t| {
                try elements_arr.append(try encodeType(allocator, t));
            }
            try o.put(allocator, "elements", .{ .array = elements_arr });
        },
        .fn_ptr => |function| {
            try o.put(allocator, "kind", .{ .string = "fn_ptr" });
            var params = Array.init(allocator);
            for (function.params) |param| {
                try params.append(try encodeType(allocator, param));
            }
            try o.put(allocator, "params", .{ .array = params });
            try o.put(allocator, "ret", try encodeType(allocator, function.ret.*));
        },
        .anon_struct => |as| {
            try o.put(allocator, "kind", .{ .string = "anon_struct" });
            var fields_arr = Array.init(allocator);
            for (as.fields) |f| {
                try fields_arr.append(try encodeStructField(allocator, f));
            }
            try o.put(allocator, "fields", .{ .array = fields_arr });
        },
        .any_opaque => {
            try o.put(allocator, "kind", .{ .string = "any_opaque" });
        },
        .void_type => {
            try o.put(allocator, "kind", .{ .string = "void_type" });
        },
    }
    return .{ .object = o };
}

pub fn decodeType(allocator: std.mem.Allocator, v: Json) anyerror!ast.Type {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "prim")) {
        const val = try reqStr(o, "value");
        return .{ .prim = try decodePrim(val) };
    } else if (std.mem.eql(u8, kind, "ptr")) {
        const elem_ptr = try allocator.create(ast.Type);
        errdefer allocator.destroy(elem_ptr);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        errdefer freeDecodedType(allocator, elem_ptr.*);
        const is_const = try reqBool(o, "is_const");
        const is_allowzero = if (o.get("is_allowzero")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;
        const size_str = try reqStr(o, "size");
        const size = try decodePtrSize(size_str);
        const alignment = if (o.get("alignment")) |value|
            if (value == .null) null else try reqU32(o, "alignment")
        else
            null;
        return .{
            .ptr = .{
                .elem = elem_ptr,
                .is_const = is_const,
                .is_allowzero = is_allowzero,
                .alignment = alignment,
                .size = size,
            },
        };
    } else if (std.mem.eql(u8, kind, "slice")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        const is_const = try reqBool(o, "is_const");
        return .{
            .slice = .{
                .elem = elem_ptr,
                .is_const = is_const,
            },
        };
    } else if (std.mem.eql(u8, kind, "opt")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        return .{ .opt = elem_ptr };
    } else if (std.mem.eql(u8, kind, "err_union")) {
        const payload_ptr = try allocator.create(ast.Type);
        payload_ptr.* = try decodeType(allocator, try req(o, "payload"));
        const err_set = if (try optStr(o, "err_set")) |es| try allocator.dupe(u8, es) else null;
        return .{
            .err_union = .{
                .err_set = err_set,
                .payload = payload_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "projected")) {
        const descriptor = try reqStr(o, "descriptor");
        const descriptor_owned = try allocator.dupe(u8, descriptor);
        errdefer allocator.free(descriptor_owned);
        const receiver_ptr = try allocator.create(ast.Type);
        receiver_ptr.* = .void_type;
        errdefer {
            freeDecodedType(allocator, receiver_ptr.*);
            allocator.destroy(receiver_ptr);
        }
        receiver_ptr.* = try decodeType(allocator, try req(o, "receiver"));
        const member = try reqStr(o, "member");
        const member_owned = try allocator.dupe(u8, member);
        errdefer allocator.free(member_owned);
        return .{ .projected = .{
            .descriptor = descriptor_owned,
            .receiver = receiver_ptr,
            .member = member_owned,
        } };
    } else if (std.mem.eql(u8, kind, "named")) {
        const name = try reqStr(o, "name");
        return .{ .named = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "generic")) {
        const name = try reqStr(o, "name");
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);

        const params_v = try req(o, "params");
        const params_arr = switch (params_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var params_list: std.ArrayListUnmanaged(ast.Type) = .empty;
        errdefer freeDecodedTypeList(allocator, &params_list);
        for (params_arr.items) |pv| {
            try appendDecodedType(allocator, &params_list, pv);
        }
        const params = try params_list.toOwnedSlice(allocator);
        errdefer freeDecodedTypeSlice(allocator, params);
        return .{
            .generic = .{
                .name = name_owned,
                .params = params,
            },
        };
    } else if (std.mem.eql(u8, kind, "array")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));
        const len = try reqUsize(o, "len");
        return .{
            .array = .{
                .elem = elem_ptr,
                .len = len,
            },
        };
    } else if (std.mem.eql(u8, kind, "array_expr")) {
        const elem_ptr = try allocator.create(ast.Type);
        elem_ptr.* = .void_type;
        errdefer {
            freeDecodedType(allocator, elem_ptr.*);
            allocator.destroy(elem_ptr);
        }
        elem_ptr.* = try decodeType(allocator, try req(o, "elem"));

        const len_ptr = try allocator.create(ast.Expr);
        len_ptr.* = .unit;
        errdefer {
            freeDecodedExpr(allocator, len_ptr.*);
            allocator.destroy(len_ptr);
        }
        len_ptr.* = try decodeExpr(allocator, try req(o, "len"));
        return .{
            .array_expr = .{
                .elem = elem_ptr,
                .len = len_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "tuple")) {
        const elem_v = try req(o, "elements");
        const elem_arr = switch (elem_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var elem_list: std.ArrayListUnmanaged(ast.Type) = .empty;
        for (elem_arr.items) |ev| {
            try elem_list.append(allocator, try decodeType(allocator, ev));
        }
        return .{ .tuple = try elem_list.toOwnedSlice(allocator) };
    } else if (std.mem.eql(u8, kind, "fn_ptr")) {
        const values = switch (try req(o, "params")) {
            .array => |array| array.items,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.Type) = .empty;
        errdefer freeDecodedTypeList(allocator, &list);
        try list.ensureTotalCapacity(allocator, values.len);
        for (values) |value| try appendDecodedType(allocator, &list, value);
        const params = try list.toOwnedSlice(allocator);
        errdefer freeDecodedTypeSlice(allocator, params);
        const ret = try allocator.create(ast.Type);
        errdefer allocator.destroy(ret);
        ret.* = try decodeType(allocator, try req(o, "ret"));
        return .{ .fn_ptr = .{ .params = params, .ret = ret } };
    } else if (std.mem.eql(u8, kind, "anon_struct")) {
        const fields_v = try req(o, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
        for (fields_arr.items) |fv| {
            try fields_list.append(allocator, try decodeStructField(allocator, fv));
        }
        return .{
            .anon_struct = .{
                .fields = try fields_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "any_opaque")) {
        return .any_opaque;
    } else if (std.mem.eql(u8, kind, "void_type")) {
        return .void_type;
    }

    return error.UnknownTypeKind;
}

// ---------------------------------------------------------------------------
// Literal Serialization
// ---------------------------------------------------------------------------

pub fn encodeLiteral(allocator: std.mem.Allocator, lit: ast.Literal) anyerror!Json {
    var o = ObjectMap.empty;
    switch (lit) {
        .int => |v| {
            try o.put(allocator, "kind", .{ .string = "int" });
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            try o.put(allocator, "value", .{ .string = s });
        },
        .uint => |v| {
            try o.put(allocator, "kind", .{ .string = "uint" });
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            try o.put(allocator, "value", .{ .string = s });
        },
        .float => |v| {
            try o.put(allocator, "kind", .{ .string = "float" });
            try o.put(allocator, "value", .{ .float = v });
        },
        .bool_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "bool_lit" });
            try o.put(allocator, "value", .{ .bool = v });
        },
        .char_lit => |v| {
            try o.put(allocator, "kind", .{ .string = "char_lit" });
            try o.put(allocator, "value", mkInt(v));
        },
        .str => |v| {
            try o.put(allocator, "kind", .{ .string = "str" });
            try o.put(allocator, "value", .{ .string = v });
        },
        .error_tag => |v| {
            try o.put(allocator, "kind", .{ .string = "error_tag" });
            try o.put(allocator, "name", .{ .string = v });
        },
        .null_lit => {
            try o.put(allocator, "kind", .{ .string = "null_lit" });
        },
        .undefined_lit => {
            try o.put(allocator, "kind", .{ .string = "undefined_lit" });
        },
    }
    return .{ .object = o };
}

pub fn decodeLiteral(allocator: std.mem.Allocator, v: Json) anyerror!ast.Literal {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "int")) {
        const val = try req(o, "value");
        return switch (val) {
            .integer => |i| .{ .int = i },
            .string => |s| .{ .int = try std.fmt.parseInt(i128, s, 10) },
            else => error.BadWireFormat,
        };
    } else if (std.mem.eql(u8, kind, "uint")) {
        const val = try req(o, "value");
        return switch (val) {
            .integer => |i| .{ .uint = @intCast(i) },
            .string => |s| .{ .uint = try std.fmt.parseInt(u128, s, 10) },
            else => error.BadWireFormat,
        };
    } else if (std.mem.eql(u8, kind, "float")) {
        return .{ .float = try reqFloat(o, "value") };
    } else if (std.mem.eql(u8, kind, "bool_lit")) {
        return .{ .bool_lit = try reqBool(o, "value") };
    } else if (std.mem.eql(u8, kind, "char_lit")) {
        return .{ .char_lit = @intCast(try reqU32(o, "value")) };
    } else if (std.mem.eql(u8, kind, "str")) {
        const s = try reqStr(o, "value");
        return .{ .str = try allocator.dupe(u8, s) };
    } else if (std.mem.eql(u8, kind, "error_tag")) {
        return .{ .error_tag = try allocator.dupe(u8, try reqStr(o, "name")) };
    } else if (std.mem.eql(u8, kind, "null_lit")) {
        return .null_lit;
    } else if (std.mem.eql(u8, kind, "undefined_lit")) {
        return .undefined_lit;
    }

    return error.UnknownLiteralKind;
}

fn encodeOptLiteral(allocator: std.mem.Allocator, lit: ?ast.Literal) anyerror!Json {
    return if (lit) |l| try encodeLiteral(allocator, l) else .{ .null = {} };
}

fn optLiteral(allocator: std.mem.Allocator, o: ObjectMap, key: []const u8) anyerror!?ast.Literal {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .null => null,
        else => try decodeLiteral(allocator, v),
    };
}

// ---------------------------------------------------------------------------
// Pattern Serialization
// ---------------------------------------------------------------------------

pub fn encodePattern(allocator: std.mem.Allocator, pat: ast.Pattern) anyerror!Json {
    var o = ObjectMap.empty;
    switch (pat) {
        .wildcard => {
            try o.put(allocator, "kind", .{ .string = "wildcard" });
        },
        .binding => |name| {
            try o.put(allocator, "kind", .{ .string = "binding" });
            try o.put(allocator, "name", .{ .string = name });
        },
        .lit => |l| {
            try o.put(allocator, "kind", .{ .string = "lit" });
            try o.put(allocator, "value", try encodeLiteral(allocator, l));
        },
        .enum_literal => |name| {
            try o.put(allocator, "kind", .{ .string = "enum_literal" });
            try o.put(allocator, "name", .{ .string = name });
        },
        .tuple => |pats| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            var arr = Array.init(allocator);
            for (pats) |p| {
                try arr.append(try encodePattern(allocator, p));
            }
            try o.put(allocator, "elements", .{ .array = arr });
        },
        .struct_pat => |sp| {
            try o.put(allocator, "kind", .{ .string = "struct_pat" });
            try o.put(allocator, "name", encodeOptStr(sp.name));
            var fields_arr = Array.init(allocator);
            for (sp.fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "name", .{ .string = f.name });
                try fo.put(allocator, "pat", try encodePattern(allocator, f.pat));
                try fields_arr.append(.{ .object = fo });
            }
            try o.put(allocator, "fields", .{ .array = fields_arr });
        },
        .range_pat => |rp| {
            try o.put(allocator, "kind", .{ .string = "range_pat" });
            try o.put(allocator, "lo", try encodeOptLiteral(allocator, rp.lo));
            try o.put(allocator, "hi", try encodeOptLiteral(allocator, rp.hi));
            try o.put(allocator, "inclusive", .{ .bool = rp.inclusive });
        },
    }
    return .{ .object = o };
}

pub fn decodePattern(allocator: std.mem.Allocator, v: Json) anyerror!ast.Pattern {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "wildcard")) {
        return .wildcard;
    } else if (std.mem.eql(u8, kind, "binding")) {
        const name = try reqStr(o, "name");
        return .{ .binding = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "lit")) {
        return .{ .lit = try decodeLiteral(allocator, try req(o, "value")) };
    } else if (std.mem.eql(u8, kind, "enum_literal")) {
        const name = try reqStr(o, "name");
        return .{ .enum_literal = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "tuple")) {
        const arr_v = try req(o, "elements");
        const arr = switch (arr_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.Pattern) = .empty;
        errdefer freeDecodedPatternList(allocator, &list);
        for (arr.items) |item| {
            try appendDecodedPattern(allocator, &list, item);
        }
        return .{ .tuple = try list.toOwnedSlice(allocator) };
    } else if (std.mem.eql(u8, kind, "struct_pat")) {
        const name = if (try optStr(o, "name")) |s| try allocator.dupe(u8, s) else null;
        errdefer if (name) |owned_name| freeDecodedBytes(allocator, owned_name);
        const fields_v = try req(o, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.StructPatternField) = .empty;
        errdefer freeDecodedStructPatternFieldList(allocator, &list);
        for (fields_arr.items) |item| {
            const fo = try getObj(item);
            const fname = try reqStr(fo, "name");
            const fpat = try decodePattern(allocator, try req(fo, "pat"));
            var owns_fpat = true;
            errdefer if (owns_fpat) freeDecodedPattern(allocator, fpat);
            const owned_fname = try allocator.dupe(u8, fname);
            var owns_fname = true;
            errdefer if (owns_fname) freeDecodedBytes(allocator, owned_fname);
            try list.append(allocator, .{
                .name = owned_fname,
                .pat = fpat,
            });
            owns_fname = false;
            owns_fpat = false;
        }
        const fields = try list.toOwnedSlice(allocator);
        return .{
            .struct_pat = .{
                .name = name,
                .fields = fields,
            },
        };
    } else if (std.mem.eql(u8, kind, "range_pat")) {
        const lo = try optLiteral(allocator, o, "lo");
        errdefer if (lo) |owned_lo| freeDecodedLiteral(allocator, owned_lo);
        const hi = try optLiteral(allocator, o, "hi");
        // An absent `inclusive` takes the ast.RangePattern default, mirroring
        // how decodeCapture defaults an absent `by_ref`.
        const inclusive = if (o.get("inclusive")) |encoded_inclusive| switch (encoded_inclusive) {
            .bool => |flag| flag,
            else => return error.BadWireFormat,
        } else true;
        return .{
            .range_pat = .{
                .lo = lo,
                .hi = hi,
                .inclusive = inclusive,
            },
        };
    }

    return error.UnknownPatternKind;
}

fn encodeCapture(allocator: std.mem.Allocator, capture: ast.Capture) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = capture.name });
    try o.put(allocator, "by_ref", .{ .bool = capture.by_ref });
    return .{ .object = o };
}

fn decodeCapture(allocator: std.mem.Allocator, value: Json) anyerror!ast.Capture {
    const object = try getObj(value);
    const name = try reqStr(object, "name");
    const owned_name = try allocator.dupe(u8, name);
    errdefer freeDecodedBytes(allocator, owned_name);
    const by_ref = if (object.get("by_ref")) |encoded_by_ref| switch (encoded_by_ref) {
        .bool => |value_by_ref| value_by_ref,
        else => return error.BadWireFormat,
    } else false;
    return .{ .name = owned_name, .by_ref = by_ref };
}

// ---------------------------------------------------------------------------
// Operators Serialization
// ---------------------------------------------------------------------------

fn encodeBinOpKind(b: ast.BinOpKind) []const u8 {
    return @tagName(b);
}

fn decodeBinOpKind(s: []const u8) !ast.BinOpKind {
    inline for (std.meta.fields(ast.BinOpKind)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownBinOpKind;
}

fn encodeUnaryOpKind(u: ast.UnaryOpKind) []const u8 {
    return @tagName(u);
}

fn decodeUnaryOpKind(s: []const u8) !ast.UnaryOpKind {
    inline for (std.meta.fields(ast.UnaryOpKind)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownUnaryOpKind;
}

fn encodeAssignOp(a: ast.AssignOp) []const u8 {
    return @tagName(a);
}

fn decodeAssignOp(s: []const u8) !ast.AssignOp {
    inline for (std.meta.fields(ast.AssignOp)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return error.UnknownAssignOp;
}

// ---------------------------------------------------------------------------
// Expr Serialization
// ---------------------------------------------------------------------------

pub fn encodeExpr(allocator: std.mem.Allocator, expr: ast.Expr) anyerror!Json {
    var o = ObjectMap.empty;
    switch (expr) {
        .lit => |l| {
            try o.put(allocator, "kind", .{ .string = "lit" });
            try o.put(allocator, "value", try encodeLiteral(allocator, l));
        },
        .ident => |id| {
            try o.put(allocator, "kind", .{ .string = "ident" });
            try o.put(allocator, "name", .{ .string = id });
        },
        .field_access => |fa| {
            try o.put(allocator, "kind", .{ .string = "field_access" });
            try o.put(allocator, "target", try encodeExpr(allocator, fa.target.*));
            try o.put(allocator, "field_name", .{ .string = fa.field_name });
        },
        .call => |c| {
            try o.put(allocator, "kind", .{ .string = "call" });
            try o.put(allocator, "callee", try encodeExpr(allocator, c.callee.*));
            var generic_args = Array.init(allocator);
            for (c.generic_args) |argument| {
                try generic_args.append(try encodeType(allocator, argument));
            }
            try o.put(allocator, "generic_args", .{ .array = generic_args });
            var args_arr = Array.init(allocator);
            for (c.args) |a| {
                try args_arr.append(try encodeExpr(allocator, a));
            }
            try o.put(allocator, "args", .{ .array = args_arr });
        },
        .block => |b| {
            try o.put(allocator, "kind", .{ .string = "block" });
            try o.put(allocator, "block", try encodeBlock(allocator, b));
        },
        .match_expr => |m| {
            try o.put(allocator, "kind", .{ .string = "match_expr" });
            try o.put(allocator, "target", try encodeExpr(allocator, m.target.*));
            var arms_arr = Array.init(allocator);
            for (m.arms) |arm| {
                var ao = ObjectMap.empty;
                var pat_arr = Array.init(allocator);
                for (arm.patterns) |p| {
                    try pat_arr.append(try encodePattern(allocator, p));
                }
                try ao.put(allocator, "patterns", .{ .array = pat_arr });
                if (arm.capture) |capture| {
                    try ao.put(allocator, "capture", try encodeCapture(allocator, capture));
                } else {
                    try ao.put(allocator, "capture", .{ .null = {} });
                }
                try ao.put(allocator, "body", try encodeExpr(allocator, arm.body));
                try arms_arr.append(.{ .object = ao });
            }
            try o.put(allocator, "arms", .{ .array = arms_arr });
        },
        .cast => |cast| {
            try o.put(allocator, "kind", .{ .string = "cast" });
            try o.put(allocator, "target", try encodeType(allocator, cast.target));
            if (cast.source) |source| {
                try o.put(allocator, "source", try encodeType(allocator, source));
            } else {
                try o.put(allocator, "source", .{ .null = {} });
            }
            try o.put(allocator, "operand", try encodeExpr(allocator, cast.operand.*));
        },
        .bin_op => |b| {
            try o.put(allocator, "kind", .{ .string = "bin_op" });
            try o.put(allocator, "op", .{ .string = encodeBinOpKind(b.op) });
            try o.put(allocator, "lhs", try encodeExpr(allocator, b.lhs.*));
            try o.put(allocator, "rhs", try encodeExpr(allocator, b.rhs.*));
        },
        .unary_op => |u| {
            try o.put(allocator, "kind", .{ .string = "unary_op" });
            try o.put(allocator, "op", .{ .string = encodeUnaryOpKind(u.op) });
            try o.put(allocator, "operand", try encodeExpr(allocator, u.operand.*));
        },
        .struct_init => |si| {
            try o.put(allocator, "kind", .{ .string = "struct_init" });
            if (si.type_name) |tn| {
                try o.put(allocator, "type_name", try encodeType(allocator, tn));
            } else {
                try o.put(allocator, "type_name", .{ .null = {} });
            }
            var fields_arr = Array.init(allocator);
            for (si.fields) |f| {
                var fo = ObjectMap.empty;
                try fo.put(allocator, "name", .{ .string = f.name });
                try fo.put(allocator, "expr", try encodeExpr(allocator, f.expr));
                try fields_arr.append(.{ .object = fo });
            }
            try o.put(allocator, "fields", .{ .array = fields_arr });
        },
        .array_init => |ai| {
            try o.put(allocator, "kind", .{ .string = "array_init" });
            if (ai.type_name) |tn| {
                try o.put(allocator, "type_name", try encodeType(allocator, tn));
            } else {
                try o.put(allocator, "type_name", .{ .null = {} });
            }
            var elem_arr = Array.init(allocator);
            for (ai.elements) |e| {
                try elem_arr.append(try encodeExpr(allocator, e));
            }
            try o.put(allocator, "elements", .{ .array = elem_arr });
        },
        .multi_array => |ma| {
            try o.put(allocator, "kind", .{ .string = "multi_array" });
            if (ma.type_name) |tn| {
                try o.put(allocator, "type_name", try encodeType(allocator, tn));
            } else {
                try o.put(allocator, "type_name", .{ .null = {} });
            }
            var elem_arr = Array.init(allocator);
            for (ma.elements) |e| {
                try elem_arr.append(try encodeExpr(allocator, e));
            }
            try o.put(allocator, "elements", .{ .array = elem_arr });
        },
        .tuple => |elements| {
            try o.put(allocator, "kind", .{ .string = "tuple" });
            var element_array = Array.init(allocator);
            for (elements) |element| {
                try element_array.append(try encodeExpr(allocator, element));
            }
            try o.put(allocator, "elements", .{ .array = element_array });
        },
        .repeat => |rp| {
            try o.put(allocator, "kind", .{ .string = "repeat" });
            if (rp.type_name) |tn| {
                try o.put(allocator, "type_name", try encodeType(allocator, tn));
            } else {
                try o.put(allocator, "type_name", .{ .null = {} });
            }
            try o.put(allocator, "elem", try encodeExpr(allocator, rp.elem.*));
            try o.put(allocator, "len", try mkCount(allocator, rp.len));
        },
        .builtin => |bc| {
            try o.put(allocator, "kind", .{ .string = "builtin" });
            try o.put(allocator, "name", .{ .string = bc.name });
            var args_arr = Array.init(allocator);
            for (bc.args) |a| {
                try args_arr.append(try encodeExpr(allocator, a));
            }
            try o.put(allocator, "args", .{ .array = args_arr });
        },
        .unit => {
            try o.put(allocator, "kind", .{ .string = "unit" });
        },
        .unreachable_ => {
            try o.put(allocator, "kind", .{ .string = "unreachable" });
        },
        .panic_ => |message| {
            try o.put(allocator, "kind", .{ .string = "panic" });
            try o.put(allocator, "message", .{ .string = message });
        },
        .unsupported => |reason| {
            try o.put(allocator, "kind", .{ .string = "unsupported" });
            try o.put(allocator, "reason", .{ .string = reason });
        },
        .if_expr => |ife| {
            try o.put(allocator, "kind", .{ .string = "if_expr" });
            try o.put(allocator, "cond", try encodeExpr(allocator, ife.cond.*));
            try o.put(allocator, "then_body", try encodeExpr(allocator, ife.then_body.*));
            if (ife.else_body) |eb| {
                try o.put(allocator, "else_body", try encodeExpr(allocator, eb.*));
            } else {
                try o.put(allocator, "else_body", .{ .null = {} });
            }
            // A capture is written only when there is one: a conditional that
            // captures nothing keeps the exact wire it had before payloads.
            if (ife.then_capture) |capture| {
                try o.put(allocator, "then_capture", try encodeCapture(allocator, capture));
            }
            if (ife.else_capture) |capture| {
                try o.put(allocator, "else_capture", try encodeCapture(allocator, capture));
            }
        },
        .while_expr => |we| {
            try o.put(allocator, "kind", .{ .string = "while_expr" });
            try o.put(allocator, "cond", try encodeExpr(allocator, we.cond.*));
            if (we.continue_expr) |ce| {
                try o.put(allocator, "continue_expr", try encodeExpr(allocator, ce.*));
            } else {
                try o.put(allocator, "continue_expr", .{ .null = {} });
            }
            if (we.captures) |caps| {
                var cap_arr = Array.init(allocator);
                for (caps) |cap| {
                    try cap_arr.append(.{ .string = cap });
                }
                try o.put(allocator, "captures", .{ .array = cap_arr });
            } else {
                try o.put(allocator, "captures", .{ .null = {} });
            }
            try o.put(allocator, "body", try encodeBlock(allocator, we.body));
            try o.put(allocator, "label", encodeOptStr(we.label));
            if (we.else_body) |eb| {
                try o.put(allocator, "else_body", try encodeExpr(allocator, eb.*));
            } else {
                try o.put(allocator, "else_body", .{ .null = {} });
            }
        },
        .for_expr => |fe| {
            try o.put(allocator, "kind", .{ .string = "for_expr" });
            var in_arr = Array.init(allocator);
            for (fe.inputs) |in_e| {
                try in_arr.append(try encodeExpr(allocator, in_e));
            }
            try o.put(allocator, "inputs", .{ .array = in_arr });

            var cap_arr = Array.init(allocator);
            for (fe.captures) |cap| {
                try cap_arr.append(try encodeCapture(allocator, cap));
            }
            try o.put(allocator, "captures", .{ .array = cap_arr });

            try o.put(allocator, "body", try encodeBlock(allocator, fe.body));
            try o.put(allocator, "label", encodeOptStr(fe.label));
            if (fe.else_body) |eb| {
                try o.put(allocator, "else_body", try encodeExpr(allocator, eb.*));
            } else {
                try o.put(allocator, "else_body", .{ .null = {} });
            }
        },
        .range => |r| {
            try o.put(allocator, "kind", .{ .string = "range" });
            try o.put(allocator, "start", try encodeExpr(allocator, r.start.*));
            if (r.end) |en| {
                try o.put(allocator, "end", try encodeExpr(allocator, en.*));
            } else {
                try o.put(allocator, "end", .{ .null = {} });
            }
        },
        .return_expr => |re| {
            try o.put(allocator, "kind", .{ .string = "return_expr" });
            if (re) |val| {
                try o.put(allocator, "value", try encodeExpr(allocator, val.*));
            } else {
                try o.put(allocator, "value", .{ .null = {} });
            }
        },
        .break_expr => |break_expr| {
            try o.put(allocator, "kind", .{ .string = "break_expr" });
            if (break_expr.value) |val| {
                try o.put(allocator, "value", try encodeExpr(allocator, val.*));
            } else {
                try o.put(allocator, "value", .{ .null = {} });
            }
            try o.put(allocator, "label", encodeOptStr(break_expr.label));
        },
        .continue_expr => |continue_expr| {
            try o.put(allocator, "kind", .{ .string = "continue_expr" });
            try o.put(allocator, "label", encodeOptStr(continue_expr.label));
        },
    }
    return .{ .object = o };
}

fn decodeMatchArm(allocator: std.mem.Allocator, value: Json) anyerror!ast.MatchArm {
    const object = try getObj(value);
    const patterns_value = try req(object, "patterns");
    const patterns_array = switch (patterns_value) {
        .array => |array| array,
        else => return error.BadWireFormat,
    };
    var patterns_list: std.ArrayListUnmanaged(ast.Pattern) = .empty;
    errdefer freeDecodedPatternList(allocator, &patterns_list);
    for (patterns_array.items) |pattern_value| {
        try appendDecodedPattern(allocator, &patterns_list, pattern_value);
    }
    const patterns = try patterns_list.toOwnedSlice(allocator);
    errdefer freeDecodedPatternSlice(allocator, patterns);

    const capture = if (object.get("capture")) |capture_value|
        if (capture_value == .null) null else try decodeCapture(allocator, capture_value)
    else
        null;
    errdefer if (capture) |decoded_capture| freeDecodedCapture(allocator, decoded_capture);

    const body = try decodeExpr(allocator, try req(object, "body"));
    return .{
        .patterns = patterns,
        .capture = capture,
        .body = body,
    };
}

pub fn decodeExpr(allocator: std.mem.Allocator, v: Json) anyerror!ast.Expr {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "lit")) {
        return .{ .lit = try decodeLiteral(allocator, try req(o, "value")) };
    } else if (std.mem.eql(u8, kind, "ident")) {
        const name = try reqStr(o, "name");
        return .{ .ident = try allocator.dupe(u8, name) };
    } else if (std.mem.eql(u8, kind, "field_access")) {
        const target_ptr = try allocator.create(ast.Expr);
        target_ptr.* = try decodeExpr(allocator, try req(o, "target"));
        const fname = try reqStr(o, "field_name");
        return .{
            .field_access = .{
                .target = target_ptr,
                .field_name = try allocator.dupe(u8, fname),
            },
        };
    } else if (std.mem.eql(u8, kind, "call")) {
        const callee_ptr = try allocator.create(ast.Expr);
        callee_ptr.* = .unit;
        errdefer {
            freeDecodedExpr(allocator, callee_ptr.*);
            allocator.destroy(callee_ptr);
        }
        callee_ptr.* = try decodeExpr(allocator, try req(o, "callee"));
        const args_v = try req(o, "args");
        const args_arr = switch (args_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        errdefer freeDecodedExprList(allocator, &list);
        for (args_arr.items) |item| {
            try appendDecodedExpr(allocator, &list, item);
        }
        const args = try list.toOwnedSlice(allocator);
        errdefer freeDecodedExprSlice(allocator, args);
        const generic_values = switch (try req(o, "generic_args")) {
            .array => |array| array.items,
            else => return error.BadWireFormat,
        };
        var generic_list: std.ArrayListUnmanaged(ast.Type) = .empty;
        errdefer freeDecodedTypeList(allocator, &generic_list);
        try generic_list.ensureTotalCapacity(allocator, generic_values.len);
        for (generic_values) |value| try appendDecodedType(allocator, &generic_list, value);
        const generic_args = try generic_list.toOwnedSlice(allocator);
        errdefer freeDecodedTypeSlice(allocator, generic_args);
        return .{
            .call = .{
                .callee = callee_ptr,
                .generic_args = generic_args,
                .args = args,
            },
        };
    } else if (std.mem.eql(u8, kind, "block")) {
        const blk = try decodeBlock(allocator, try req(o, "block"));
        return .{ .block = blk };
    } else if (std.mem.eql(u8, kind, "match_expr")) {
        const target_ptr = try allocator.create(ast.Expr);
        target_ptr.* = .unit;
        var owns_target = true;
        errdefer if (owns_target) {
            freeDecodedExpr(allocator, target_ptr.*);
            allocator.destroy(target_ptr);
        };
        target_ptr.* = try decodeExpr(allocator, try req(o, "target"));
        const arms_v = try req(o, "arms");
        const arms_arr = switch (arms_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var arms_list: std.ArrayListUnmanaged(ast.MatchArm) = .empty;
        errdefer freeDecodedMatchArmList(allocator, &arms_list);
        for (arms_arr.items) |item| {
            try appendDecodedMatchArm(allocator, &arms_list, item);
        }
        const arms = try arms_list.toOwnedSlice(allocator);
        owns_target = false;
        return .{
            .match_expr = .{
                .target = target_ptr,
                .arms = arms,
            },
        };
    } else if (std.mem.eql(u8, kind, "cast")) {
        const target = try decodeType(allocator, try req(o, "target"));
        errdefer freeDecodedType(allocator, target);
        const source = if (o.get("source")) |source_value| switch (source_value) {
            .null => null,
            else => try decodeType(allocator, source_value),
        } else null;
        errdefer if (source) |source_type| freeDecodedType(allocator, source_type);
        const operand_ptr = try allocator.create(ast.Expr);
        errdefer allocator.destroy(operand_ptr);
        operand_ptr.* = try decodeExpr(allocator, try req(o, "operand"));
        return .{ .cast = .{
            .target = target,
            .source = source,
            .operand = operand_ptr,
        } };
    } else if (std.mem.eql(u8, kind, "bin_op")) {
        const op_str = try reqStr(o, "op");
        const op = try decodeBinOpKind(op_str);
        const lhs_ptr = try allocator.create(ast.Expr);
        lhs_ptr.* = try decodeExpr(allocator, try req(o, "lhs"));
        const rhs_ptr = try allocator.create(ast.Expr);
        rhs_ptr.* = try decodeExpr(allocator, try req(o, "rhs"));
        return .{
            .bin_op = .{
                .op = op,
                .lhs = lhs_ptr,
                .rhs = rhs_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "unary_op")) {
        const op_str = try reqStr(o, "op");
        const op = try decodeUnaryOpKind(op_str);
        const operand_ptr = try allocator.create(ast.Expr);
        operand_ptr.* = try decodeExpr(allocator, try req(o, "operand"));
        return .{
            .unary_op = .{
                .op = op,
                .operand = operand_ptr,
            },
        };
    } else if (std.mem.eql(u8, kind, "struct_init")) {
        const type_name = if (o.get("type_name")) |tn| (switch (tn) {
            .null => null,
            else => try decodeType(allocator, tn),
        }) else null;
        const fields_v = try req(o, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.StructInitField) = .empty;
        for (fields_arr.items) |item| {
            const fo = try getObj(item);
            const fname = try reqStr(fo, "name");
            const fexpr = try decodeExpr(allocator, try req(fo, "expr"));
            try fields_list.append(allocator, .{
                .name = try allocator.dupe(u8, fname),
                .expr = fexpr,
            });
        }
        return .{
            .struct_init = .{
                .type_name = type_name,
                .fields = try fields_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "array_init")) {
        const type_name = if (o.get("type_name")) |tn| (switch (tn) {
            .null => null,
            else => try decodeType(allocator, tn),
        }) else null;
        const elem_v = try req(o, "elements");
        const elem_arr = switch (elem_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var elem_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        for (elem_arr.items) |item| {
            try elem_list.append(allocator, try decodeExpr(allocator, item));
        }
        return .{
            .array_init = .{
                .type_name = type_name,
                .elements = try elem_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "multi_array")) {
        const type_name = if (o.get("type_name")) |tn| (switch (tn) {
            .null => null,
            else => try decodeType(allocator, tn),
        }) else null;
        const elem_v = try req(o, "elements");
        const elem_arr = switch (elem_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var elem_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        for (elem_arr.items) |item| {
            try elem_list.append(allocator, try decodeExpr(allocator, item));
        }
        return .{
            .multi_array = .{
                .type_name = type_name,
                .elements = try elem_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "tuple")) {
        const elements_value = try req(o, "elements");
        const elements = switch (elements_value) {
            .array => |array| array.items,
            else => return error.BadWireFormat,
        };
        var decoded: std.ArrayListUnmanaged(ast.Expr) = .empty;
        errdefer freeDecodedExprList(allocator, &decoded);
        for (elements) |element| try appendDecodedExpr(allocator, &decoded, element);
        return .{ .tuple = try decoded.toOwnedSlice(allocator) };
    } else if (std.mem.eql(u8, kind, "repeat")) {
        const type_name = if (o.get("type_name")) |tn| (switch (tn) {
            .null => null,
            else => try decodeType(allocator, tn),
        }) else null;
        const elem_ptr = try allocator.create(ast.Expr);
        elem_ptr.* = try decodeExpr(allocator, try req(o, "elem"));
        const len: usize = switch (try req(o, "len")) {
            .integer => |i| @intCast(@max(i, 0)),
            .number_string => |s| try std.fmt.parseInt(usize, s, 10),
            else => return error.BadWireFormat,
        };
        return .{
            .repeat = .{
                .type_name = type_name,
                .elem = elem_ptr,
                .len = len,
            },
        };
    } else if (std.mem.eql(u8, kind, "builtin")) {
        const bname = try reqStr(o, "name");
        const args_v = try req(o, "args");
        const args_arr = switch (args_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var args_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        errdefer freeDecodedExprList(allocator, &args_list);
        for (args_arr.items) |item| {
            try appendDecodedExpr(allocator, &args_list, item);
        }
        const args = try args_list.toOwnedSlice(allocator);
        errdefer freeDecodedExprSlice(allocator, args);
        const name = try allocator.dupe(u8, bname);
        errdefer allocator.free(name);
        return .{
            .builtin = .{
                .name = name,
                .args = args,
            },
        };
    } else if (std.mem.eql(u8, kind, "unit")) {
        return .{ .unit = {} };
    } else if (std.mem.eql(u8, kind, "panic")) {
        const message = try reqStr(o, "message");
        return .{ .panic_ = try allocator.dupe(u8, message) };
    } else if (std.mem.eql(u8, kind, "unsupported")) {
        const reason = try reqStr(o, "reason");
        return .{ .unsupported = try allocator.dupe(u8, reason) };
    } else if (std.mem.eql(u8, kind, "if_expr")) {
        const cond_expr = try decodeExpr(allocator, try req(o, "cond"));
        errdefer freeDecodedExpr(allocator, cond_expr);
        const then_expr = try decodeExpr(allocator, try req(o, "then_body"));
        errdefer freeDecodedExpr(allocator, then_expr);
        const else_ptr: ?*const ast.Expr = if (o.get("else_body")) |eb| (switch (eb) {
            .null => null,
            else => blk: {
                const else_expr = try decodeExpr(allocator, eb);
                errdefer freeDecodedExpr(allocator, else_expr);
                const ep = try allocator.create(ast.Expr);
                ep.* = else_expr;
                break :blk ep;
            },
        }) else null;
        errdefer if (else_ptr) |owned_else| {
            freeDecodedExpr(allocator, owned_else.*);
            allocator.destroy(@constCast(owned_else));
        };
        const then_capture: ?ast.Capture = if (o.get("then_capture")) |encoded_capture|
            try decodeCapture(allocator, encoded_capture)
        else
            null;
        errdefer if (then_capture) |capture| freeDecodedCapture(allocator, capture);
        const else_capture: ?ast.Capture = if (o.get("else_capture")) |encoded_capture|
            try decodeCapture(allocator, encoded_capture)
        else
            null;
        errdefer if (else_capture) |capture| freeDecodedCapture(allocator, capture);
        // An else payload binds the branch it names, so a wire that carries
        // one without that branch is not a conditional this AST can hold.
        if (else_capture != null and else_ptr == null) return error.BadWireFormat;
        const cond_ptr = try allocator.create(ast.Expr);
        errdefer allocator.destroy(cond_ptr);
        cond_ptr.* = cond_expr;
        const then_ptr = try allocator.create(ast.Expr);
        errdefer allocator.destroy(then_ptr);
        then_ptr.* = then_expr;
        return .{
            .if_expr = .{
                .cond = cond_ptr,
                .then_body = then_ptr,
                .else_body = else_ptr,
                .then_capture = then_capture,
                .else_capture = else_capture,
            },
        };
    } else if (std.mem.eql(u8, kind, "while_expr")) {
        const cond_ptr = try allocator.create(ast.Expr);
        cond_ptr.* = try decodeExpr(allocator, try req(o, "cond"));
        const cont_ptr: ?*const ast.Expr = if (o.get("continue_expr")) |ce| (switch (ce) {
            .null => null,
            else => blk: {
                const cp = try allocator.create(ast.Expr);
                cp.* = try decodeExpr(allocator, ce);
                break :blk cp;
            },
        }) else null;
        const body = try decodeBlock(allocator, try req(o, "body"));
        const else_ptr: ?*const ast.Expr = if (o.get("else_body")) |eb| (switch (eb) {
            .null => null,
            else => blk: {
                const ep = try allocator.create(ast.Expr);
                ep.* = try decodeExpr(allocator, eb);
                break :blk ep;
            },
        }) else null;
        var caps_list: std.ArrayListUnmanaged([]const u8) = .empty;
        if (o.get("captures")) |cv| {
            if (cv == .array) {
                for (cv.array.items) |item| {
                    const s = switch (item) {
                        .string => |st| st,
                        else => return error.BadWireFormat,
                    };
                    try caps_list.append(allocator, try allocator.dupe(u8, s));
                }
            }
        }
        const label = if (try optStr(o, "label")) |text| try allocator.dupe(u8, text) else null;
        return .{
            .while_expr = .{
                .cond = cond_ptr,
                .continue_expr = cont_ptr,
                .captures = if (caps_list.items.len > 0) try caps_list.toOwnedSlice(allocator) else null,
                .body = body,
                .else_body = else_ptr,
                .label = label,
            },
        };
    } else if (std.mem.eql(u8, kind, "for_expr")) {
        const in_v = try req(o, "inputs");
        const in_arr = switch (in_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var in_list: std.ArrayListUnmanaged(ast.Expr) = .empty;
        errdefer freeDecodedExprList(allocator, &in_list);
        for (in_arr.items) |item| {
            try appendDecodedExpr(allocator, &in_list, item);
        }

        const cap_v = try req(o, "captures");
        const cap_arr = switch (cap_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var cap_list: std.ArrayListUnmanaged(ast.Capture) = .empty;
        errdefer freeDecodedCaptureList(allocator, &cap_list);
        for (cap_arr.items) |item| {
            try appendDecodedCapture(allocator, &cap_list, item);
        }

        const body = try decodeBlock(allocator, try req(o, "body"));
        errdefer freeDecodedBlock(allocator, body);
        const else_ptr: ?*const ast.Expr = if (o.get("else_body")) |eb| (switch (eb) {
            .null => null,
            else => blk: {
                const ep = try allocator.create(ast.Expr);
                ep.* = try decodeExpr(allocator, eb);
                break :blk ep;
            },
        }) else null;
        errdefer if (else_ptr) |ptr| {
            freeDecodedExpr(allocator, ptr.*);
            allocator.destroy(@constCast(ptr));
        };

        const inputs = try in_list.toOwnedSlice(allocator);
        errdefer freeDecodedExprSlice(allocator, inputs);
        const captures = try cap_list.toOwnedSlice(allocator);
        errdefer freeDecodedCaptureSlice(allocator, captures);
        const label = if (try optStr(o, "label")) |text| try allocator.dupe(u8, text) else null;
        return .{
            .for_expr = .{
                .inputs = inputs,
                .captures = captures,
                .body = body,
                .else_body = else_ptr,
                .label = label,
            },
        };
    } else if (std.mem.eql(u8, kind, "range")) {
        const start_ptr = try allocator.create(ast.Expr);
        start_ptr.* = try decodeExpr(allocator, try req(o, "start"));
        const end_ptr: ?*const ast.Expr = if (o.get("end")) |en| (switch (en) {
            .null => null,
            else => blk: {
                const p = try allocator.create(ast.Expr);
                p.* = try decodeExpr(allocator, en);
                break :blk p;
            },
        }) else null;
        return .{ .range = .{ .start = start_ptr, .end = end_ptr } };
    } else if (std.mem.eql(u8, kind, "return_expr")) {
        const val_ptr: ?*const ast.Expr = if (o.get("value")) |v_node| (switch (v_node) {
            .null => null,
            else => blk: {
                const p = try allocator.create(ast.Expr);
                p.* = try decodeExpr(allocator, v_node);
                break :blk p;
            },
        }) else null;
        return .{ .return_expr = val_ptr };
    } else if (std.mem.eql(u8, kind, "break_expr")) {
        const val_ptr: ?*const ast.Expr = if (o.get("value")) |v_node| (switch (v_node) {
            .null => null,
            else => blk: {
                const p = try allocator.create(ast.Expr);
                p.* = try decodeExpr(allocator, v_node);
                break :blk p;
            },
        }) else null;
        return .{ .break_expr = .{
            .value = val_ptr,
            .label = if (try optStr(o, "label")) |text| try allocator.dupe(u8, text) else null,
        } };
    } else if (std.mem.eql(u8, kind, "continue_expr")) {
        return .{ .continue_expr = .{
            .label = if (try optStr(o, "label")) |text| try allocator.dupe(u8, text) else null,
        } };
    } else if (std.mem.eql(u8, kind, "unreachable")) {
        return .{ .unreachable_ = {} };
    }

    return error.UnknownExprKind;
}

// ---------------------------------------------------------------------------
// Block & Stmt Serialization
// ---------------------------------------------------------------------------

pub fn encodeBlock(allocator: std.mem.Allocator, b: ast.Block) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "label", encodeOptStr(b.label));

    var stmts_arr = Array.init(allocator);
    for (b.stmts) |s| {
        try stmts_arr.append(try encodeStmt(allocator, s));
    }
    try o.put(allocator, "stmts", .{ .array = stmts_arr });

    if (b.expr) |ex| {
        try o.put(allocator, "expr", try encodeExpr(allocator, ex.*));
    } else {
        try o.put(allocator, "expr", .{ .null = {} });
    }

    return .{ .object = o };
}

pub fn decodeBlock(allocator: std.mem.Allocator, v: Json) anyerror!ast.Block {
    const o = try getObj(v);
    const label = if (try optStr(o, "label")) |l| try allocator.dupe(u8, l) else null;
    errdefer if (label) |owned_label| freeDecodedBytes(allocator, owned_label);

    const stmts_v = try req(o, "stmts");
    const stmts_arr = switch (stmts_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var stmts_list: std.ArrayListUnmanaged(ast.Stmt) = .empty;
    errdefer freeDecodedStmtList(allocator, &stmts_list);
    for (stmts_arr.items) |sv| {
        try appendDecodedStmt(allocator, &stmts_list, sv);
    }

    var expr_ptr: ?*const ast.Expr = null;
    errdefer if (expr_ptr) |expr| {
        freeDecodedExpr(allocator, expr.*);
        allocator.destroy(@constCast(expr));
    };
    if (o.get("expr")) |ev| {
        switch (ev) {
            .null => {},
            else => {
                const ep = try allocator.create(ast.Expr);
                errdefer allocator.destroy(ep);
                ep.* = try decodeExpr(allocator, ev);
                expr_ptr = ep;
            },
        }
    }

    const stmts = try stmts_list.toOwnedSlice(allocator);
    errdefer freeDecodedStmtSlice(allocator, stmts);
    return .{
        .label = label,
        .stmts = stmts,
        .expr = expr_ptr,
    };
}

pub fn encodeStmt(allocator: std.mem.Allocator, stmt: ast.Stmt) anyerror!Json {
    var o = ObjectMap.empty;
    switch (stmt) {
        .let_stmt => |let| {
            try o.put(allocator, "kind", .{ .string = "let_stmt" });
            try o.put(allocator, "name", .{ .string = let.name });
            if (let.ty) |ty| {
                try o.put(allocator, "ty", try encodeType(allocator, ty));
            } else {
                try o.put(allocator, "ty", .{ .null = {} });
            }
            try o.put(allocator, "init", try encodeExpr(allocator, let.init));
            try o.put(allocator, "is_mut", .{ .bool = let.is_mut });
        },
        .assign => |asg| {
            try o.put(allocator, "kind", .{ .string = "assign" });
            try o.put(allocator, "target", try encodeExpr(allocator, asg.target));
            try o.put(allocator, "val", try encodeExpr(allocator, asg.val));
            try o.put(allocator, "op", .{ .string = encodeAssignOp(asg.op) });
        },
        .defer_stmt => |defer_stmt| {
            try o.put(allocator, "kind", .{ .string = "defer_stmt" });
            try o.put(allocator, "expr", try encodeExpr(allocator, defer_stmt.expr));
            try o.put(allocator, "is_errdefer", .{ .bool = defer_stmt.is_errdefer });
        },
        .expr_stmt => |ex| {
            try o.put(allocator, "kind", .{ .string = "expr_stmt" });
            try o.put(allocator, "expr", try encodeExpr(allocator, ex.*));
        },
    }
    return .{ .object = o };
}

pub fn decodeStmt(allocator: std.mem.Allocator, v: Json) anyerror!ast.Stmt {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");

    if (std.mem.eql(u8, kind, "let_stmt")) {
        const name = try reqStr(o, "name");
        const ty = if (o.get("ty")) |ty_val| (switch (ty_val) {
            .null => null,
            else => try decodeType(allocator, ty_val),
        }) else null;
        const init = try decodeExpr(allocator, try req(o, "init"));
        const is_mut = if (o.get("is_mut")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;

        return .{
            .let_stmt = .{
                .name = try allocator.dupe(u8, name),
                .ty = ty,
                .init = init,
                .is_mut = is_mut,
            },
        };
    } else if (std.mem.eql(u8, kind, "assign")) {
        const target = try decodeExpr(allocator, try req(o, "target"));
        const val = try decodeExpr(allocator, try req(o, "val"));
        const op_str = if (try optStr(o, "op")) |s| s else "assign";
        const op = try decodeAssignOp(op_str);
        return .{
            .assign = .{
                .target = target,
                .val = val,
                .op = op,
            },
        };
    } else if (std.mem.eql(u8, kind, "defer_stmt")) {
        const is_errdefer = if (o.get("is_errdefer")) |value| switch (value) {
            .bool => |flag| flag,
            else => return error.BadWireFormat,
        } else false;
        const expr = try decodeExpr(allocator, try req(o, "expr"));
        return .{
            .defer_stmt = .{
                .expr = expr,
                .is_errdefer = is_errdefer,
            },
        };
    } else if (std.mem.eql(u8, kind, "expr_stmt")) {
        const ep = try allocator.create(ast.Expr);
        ep.* = try decodeExpr(allocator, try req(o, "expr"));
        return .{ .expr_stmt = ep };
    }

    return error.UnknownStmtKind;
}

// ---------------------------------------------------------------------------
// GenericParam, StructField, Variant, Param Serialization
// ---------------------------------------------------------------------------

pub fn encodeGenericParam(allocator: std.mem.Allocator, gp: ast.GenericParam) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = gp.name });
    try o.put(allocator, "is_comptime", .{ .bool = gp.is_comptime });
    if (gp.ty) |ty| {
        try o.put(allocator, "ty", try encodeType(allocator, ty));
    } else {
        try o.put(allocator, "ty", .{ .null = {} });
    }
    return .{ .object = o };
}

pub fn decodeGenericParam(allocator: std.mem.Allocator, v: Json) anyerror!ast.GenericParam {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const is_comptime = if (o.get("is_comptime")) |b| (switch (b) {
        .bool => |x| x,
        else => true,
    }) else true;
    const ty = if (o.get("ty")) |ty_v| (switch (ty_v) {
        .null => null,
        else => try decodeType(allocator, ty_v),
    }) else null;
    return .{
        .name = try allocator.dupe(u8, name),
        .is_comptime = is_comptime,
        .ty = ty,
    };
}

pub fn encodeStructField(allocator: std.mem.Allocator, sf: ast.StructField) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = sf.name });
    try o.put(allocator, "ty", try encodeType(allocator, sf.ty));
    if (sf.default_val) |dv| {
        try o.put(allocator, "default_val", try encodeExpr(allocator, dv.*));
    } else {
        try o.put(allocator, "default_val", .{ .null = {} });
    }
    try o.put(allocator, "is_pub", .{ .bool = sf.is_pub });
    return .{ .object = o };
}

pub fn decodeStructField(allocator: std.mem.Allocator, v: Json) anyerror!ast.StructField {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const ty = try decodeType(allocator, try req(o, "ty"));
    const dv_ptr: ?*const ast.Expr = if (o.get("default_val")) |dv| (switch (dv) {
        .null => null,
        else => blk: {
            const p = try allocator.create(ast.Expr);
            p.* = try decodeExpr(allocator, dv);
            break :blk p;
        },
    }) else null;
    const is_pub = if (o.get("is_pub")) |b| (switch (b) {
        .bool => |x| x,
        else => true,
    }) else true;

    return .{
        .name = try allocator.dupe(u8, name),
        .ty = ty,
        .default_val = dv_ptr,
        .is_pub = is_pub,
    };
}

pub fn encodeEnumVariant(allocator: std.mem.Allocator, ev: ast.EnumVariant) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = ev.name });
    if (ev.value) |val| {
        try o.put(allocator, "value", try encodeExpr(allocator, val.*));
    } else {
        try o.put(allocator, "value", .{ .null = {} });
    }
    return .{ .object = o };
}

pub fn decodeEnumVariant(allocator: std.mem.Allocator, v: Json) anyerror!ast.EnumVariant {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const val_ptr: ?*const ast.Expr = if (o.get("value")) |val| (switch (val) {
        .null => null,
        else => blk: {
            const p = try allocator.create(ast.Expr);
            p.* = try decodeExpr(allocator, val);
            break :blk p;
        },
    }) else null;
    return .{
        .name = try allocator.dupe(u8, name),
        .value = val_ptr,
    };
}

pub fn encodeUnionField(allocator: std.mem.Allocator, uf: ast.UnionField) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = uf.name });
    try o.put(allocator, "ty", try encodeType(allocator, uf.ty));
    try o.put(allocator, "is_pub", .{ .bool = uf.is_pub });
    return .{ .object = o };
}

pub fn decodeUnionField(allocator: std.mem.Allocator, v: Json) anyerror!ast.UnionField {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const ty = try decodeType(allocator, try req(o, "ty"));
    const is_pub = if (o.get("is_pub")) |b| (switch (b) {
        .bool => |x| x,
        else => true,
    }) else true;
    return .{
        .name = try allocator.dupe(u8, name),
        .ty = ty,
        .is_pub = is_pub,
    };
}

pub fn encodeFnParam(allocator: std.mem.Allocator, fp: ast.FnParam) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = fp.name });
    try o.put(allocator, "ty", try encodeType(allocator, fp.ty));
    try o.put(allocator, "is_comptime", .{ .bool = fp.is_comptime });
    return .{ .object = o };
}

pub fn decodeFnParam(allocator: std.mem.Allocator, v: Json) anyerror!ast.FnParam {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const ty = try decodeType(allocator, try req(o, "ty"));
    const is_comptime = if (o.get("is_comptime")) |b| (switch (b) {
        .bool => |x| x,
        else => false,
    }) else false;
    return .{
        .name = try allocator.dupe(u8, name),
        .ty = ty,
        .is_comptime = is_comptime,
    };
}

fn encodeTraitDescriptorMember(
    allocator: std.mem.Allocator,
    member: ast.TraitDescriptorMember,
) anyerror!Json {
    var o = ObjectMap.empty;
    switch (member) {
        .type_ => |type_member| {
            try o.put(allocator, "kind", .{ .string = "type" });
            try o.put(allocator, "name", .{ .string = type_member.name });
            try o.put(allocator, "ty", try encodeType(allocator, type_member.ty));
        },
        .const_ => |const_member| {
            try o.put(allocator, "kind", .{ .string = "const" });
            try o.put(allocator, "name", .{ .string = const_member.name });
            try o.put(allocator, "value", try encodeExpr(allocator, const_member.value));
        },
    }
    return .{ .object = o };
}

fn decodeTraitDescriptorMember(
    allocator: std.mem.Allocator,
    value: Json,
) anyerror!ast.TraitDescriptorMember {
    const o = try getObj(value);
    const kind = try reqStr(o, "kind");
    const name = try reqStr(o, "name");
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    if (std.mem.eql(u8, kind, "type")) {
        const ty = try decodeType(allocator, try req(o, "ty"));
        errdefer freeDecodedType(allocator, ty);
        return .{ .type_ = .{
            .name = name_owned,
            .ty = ty,
        } };
    }
    if (std.mem.eql(u8, kind, "const")) {
        const value_expr = try decodeExpr(allocator, try req(o, "value"));
        errdefer freeDecodedExpr(allocator, value_expr);
        return .{ .const_ = .{
            .name = name_owned,
            .value = value_expr,
        } };
    }
    return error.UnknownTraitDescriptorMemberKind;
}

fn encodeTraitDescriptorCase(
    allocator: std.mem.Allocator,
    descriptor_case: ast.TraitDescriptorCase,
) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "receiver", try encodeType(allocator, descriptor_case.receiver));
    var members = Array.init(allocator);
    for (descriptor_case.members) |member| {
        try members.append(try encodeTraitDescriptorMember(allocator, member));
    }
    try o.put(allocator, "members", .{ .array = members });
    return .{ .object = o };
}

fn decodeTraitDescriptorCase(
    allocator: std.mem.Allocator,
    value: Json,
) anyerror!ast.TraitDescriptorCase {
    const o = try getObj(value);
    const receiver = try decodeType(allocator, try req(o, "receiver"));
    errdefer freeDecodedType(allocator, receiver);
    const members_value = try req(o, "members");
    const members_array = switch (members_value) {
        .array => |array| array,
        else => return error.BadWireFormat,
    };
    var members_list: std.ArrayListUnmanaged(ast.TraitDescriptorMember) = .empty;
    errdefer {
        for (members_list.items) |member| {
            freeDecodedTraitDescriptorMember(allocator, member);
        }
        members_list.deinit(allocator);
    }
    for (members_array.items) |item| {
        try members_list.append(allocator, try decodeTraitDescriptorMember(allocator, item));
    }
    return .{
        .receiver = receiver,
        .members = try members_list.toOwnedSlice(allocator),
    };
}

fn encodeTraitDescriptorDecl(
    allocator: std.mem.Allocator,
    descriptor: ast.TraitDescriptorDecl,
) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "kind", .{ .string = "trait_descriptor" });
    var value = ObjectMap.empty;
    try value.put(allocator, "name", .{ .string = descriptor.name });
    try value.put(allocator, "is_pub", .{ .bool = descriptor.is_pub });
    var cases = Array.init(allocator);
    for (descriptor.cases) |descriptor_case| {
        try cases.append(try encodeTraitDescriptorCase(allocator, descriptor_case));
    }
    try value.put(allocator, "cases", .{ .array = cases });
    try o.put(allocator, "value", .{ .object = value });
    return .{ .object = o };
}

fn decodeTraitDescriptorDecl(
    allocator: std.mem.Allocator,
    value: Json,
) anyerror!ast.TraitDescriptorDecl {
    const o = try getObj(value);
    const descriptor_value = try req(o, "value");
    const descriptor_object = try getObj(descriptor_value);
    const name = try reqStr(descriptor_object, "name");
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    const is_pub = if (descriptor_object.get("is_pub")) |flag| switch (flag) {
        .bool => |value_bool| value_bool,
        else => true,
    } else true;
    const cases_value = try req(descriptor_object, "cases");
    const cases_array = switch (cases_value) {
        .array => |array| array,
        else => return error.BadWireFormat,
    };
    var cases_list: std.ArrayListUnmanaged(ast.TraitDescriptorCase) = .empty;
    errdefer {
        for (cases_list.items) |descriptor_case| {
            freeDecodedTraitDescriptorCase(allocator, descriptor_case);
        }
        cases_list.deinit(allocator);
    }
    for (cases_array.items) |item| {
        try cases_list.append(allocator, try decodeTraitDescriptorCase(allocator, item));
    }
    return .{
        .name = name_owned,
        .is_pub = is_pub,
        .cases = try cases_list.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------------
// Decl Serialization
// ---------------------------------------------------------------------------

pub fn encodeDecl(allocator: std.mem.Allocator, decl: ast.Decl) anyerror!Json {
    var o = ObjectMap.empty;
    switch (decl) {
        .trait_descriptor => |descriptor| {
            return encodeTraitDescriptorDecl(allocator, descriptor);
        },
        .struct_decl => |sd| {
            try o.put(allocator, "kind", .{ .string = "struct_decl" });
            var so = ObjectMap.empty;
            try so.put(allocator, "name", .{ .string = sd.name });
            try so.put(allocator, "is_pub", .{ .bool = sd.is_pub });
            try so.put(allocator, "is_tuple", .{ .bool = sd.is_tuple });

            var fields_arr = Array.init(allocator);
            for (sd.fields) |f| {
                try fields_arr.append(try encodeStructField(allocator, f));
            }
            try so.put(allocator, "fields", .{ .array = fields_arr });

            var decls_arr = Array.init(allocator);
            for (sd.decls) |d| {
                try decls_arr.append(try encodeDecl(allocator, d));
            }
            try so.put(allocator, "decls", .{ .array = decls_arr });

            var gps_arr = Array.init(allocator);
            for (sd.generic_params) |gp| {
                try gps_arr.append(try encodeGenericParam(allocator, gp));
            }
            try so.put(allocator, "generic_params", .{ .array = gps_arr });

            try o.put(allocator, "value", .{ .object = so });
        },
        .enum_decl => |ed| {
            try o.put(allocator, "kind", .{ .string = "enum_decl" });
            var eo = ObjectMap.empty;
            try eo.put(allocator, "name", .{ .string = ed.name });
            try eo.put(allocator, "is_pub", .{ .bool = ed.is_pub });
            if (ed.tag_type) |tt| {
                try eo.put(allocator, "tag_type", try encodeType(allocator, tt));
            } else {
                try eo.put(allocator, "tag_type", .{ .null = {} });
            }

            var vars_arr = Array.init(allocator);
            for (ed.variants) |vr| {
                try vars_arr.append(try encodeEnumVariant(allocator, vr));
            }
            try eo.put(allocator, "variants", .{ .array = vars_arr });

            var decls_arr = Array.init(allocator);
            for (ed.decls) |d| {
                try decls_arr.append(try encodeDecl(allocator, d));
            }
            try eo.put(allocator, "decls", .{ .array = decls_arr });

            try o.put(allocator, "value", .{ .object = eo });
        },
        .union_decl => |ud| {
            try o.put(allocator, "kind", .{ .string = "union_decl" });
            var uo = ObjectMap.empty;
            try uo.put(allocator, "name", .{ .string = ud.name });
            try uo.put(allocator, "is_pub", .{ .bool = ud.is_pub });
            if (ud.tag_type) |tt| {
                try uo.put(allocator, "tag_type", try encodeType(allocator, tt));
            } else {
                try uo.put(allocator, "tag_type", .{ .null = {} });
            }

            var fields_arr = Array.init(allocator);
            for (ud.fields) |f| {
                try fields_arr.append(try encodeUnionField(allocator, f));
            }
            try uo.put(allocator, "fields", .{ .array = fields_arr });

            var decls_arr = Array.init(allocator);
            for (ud.decls) |d| {
                try decls_arr.append(try encodeDecl(allocator, d));
            }
            try uo.put(allocator, "decls", .{ .array = decls_arr });

            try o.put(allocator, "value", .{ .object = uo });
        },
        .fn_decl => |fd| {
            try o.put(allocator, "kind", .{ .string = "fn_decl" });
            var fo = ObjectMap.empty;
            try fo.put(allocator, "name", .{ .string = fd.name });
            try fo.put(allocator, "is_pub", .{ .bool = fd.is_pub });
            try fo.put(allocator, "is_test", .{ .bool = fd.is_test });

            var params_arr = Array.init(allocator);
            for (fd.params) |p| {
                try params_arr.append(try encodeFnParam(allocator, p));
            }
            try fo.put(allocator, "params", .{ .array = params_arr });

            try fo.put(allocator, "ret_type", try encodeType(allocator, fd.ret_type));
            if (fd.body) |body| {
                try fo.put(allocator, "body", try encodeBlock(allocator, body));
            } else {
                try fo.put(allocator, "body", .{ .null = {} });
            }

            var gps_arr = Array.init(allocator);
            for (fd.generic_params) |gp| {
                try gps_arr.append(try encodeGenericParam(allocator, gp));
            }
            try fo.put(allocator, "generic_params", .{ .array = gps_arr });

            try o.put(allocator, "value", .{ .object = fo });
        },
        .const_decl => |cd| {
            try o.put(allocator, "kind", .{ .string = "const_decl" });
            var co = ObjectMap.empty;
            try co.put(allocator, "name", .{ .string = cd.name });
            try co.put(allocator, "is_pub", .{ .bool = cd.is_pub });
            if (cd.ty) |ty| {
                try co.put(allocator, "ty", try encodeType(allocator, ty));
            } else {
                try co.put(allocator, "ty", .{ .null = {} });
            }
            try co.put(allocator, "init", try encodeExpr(allocator, cd.init));
            try o.put(allocator, "value", .{ .object = co });
        },
        .var_decl => |vd| {
            try o.put(allocator, "kind", .{ .string = "var_decl" });
            var vo = ObjectMap.empty;
            try vo.put(allocator, "name", .{ .string = vd.name });
            try vo.put(allocator, "is_pub", .{ .bool = vd.is_pub });
            try vo.put(allocator, "is_mut", .{ .bool = vd.is_mut });
            if (vd.ty) |ty| {
                try vo.put(allocator, "ty", try encodeType(allocator, ty));
            } else {
                try vo.put(allocator, "ty", .{ .null = {} });
            }
            try vo.put(allocator, "init", try encodeExpr(allocator, vd.init));
            try o.put(allocator, "value", .{ .object = vo });
        },
        .comment => |c| {
            try o.put(allocator, "kind", .{ .string = "comment" });
            try o.put(allocator, "value", .{ .string = c });
        },
    }
    return .{ .object = o };
}

pub fn decodeDecl(allocator: std.mem.Allocator, v: Json) anyerror!ast.Decl {
    const o = try getObj(v);
    const kind = try reqStr(o, "kind");
    if (std.mem.eql(u8, kind, "trait_descriptor")) {
        return .{ .trait_descriptor = try decodeTraitDescriptorDecl(allocator, v) };
    }

    if (std.mem.eql(u8, kind, "struct_decl")) {
        const so = try getObj(try req(o, "value"));
        const name = try reqStr(so, "name");
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const is_pub = if (so.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const is_tuple = if (so.get("is_tuple")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;

        const fields_v = try req(so, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
        errdefer freeDecodedStructFieldList(allocator, &fields_list);
        for (fields_arr.items) |item| {
            try appendDecodedStructField(allocator, &fields_list, item);
        }

        const decls_v = try req(so, "decls");
        const decls_arr = switch (decls_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        errdefer freeDecodedDeclList(allocator, &decls_list);
        for (decls_arr.items) |item| {
            try appendDecodedDecl(allocator, &decls_list, item);
        }

        const gps_arr = if (so.get("generic_params")) |gp_v| (switch (gp_v) {
            .array => |a| a,
            else => Array.init(allocator),
        }) else Array.init(allocator);
        var gps_list: std.ArrayListUnmanaged(ast.GenericParam) = .empty;
        errdefer freeDecodedGenericParamList(allocator, &gps_list);
        for (gps_arr.items) |item| {
            try appendDecodedGenericParam(allocator, &gps_list, item);
        }

        const fields = try fields_list.toOwnedSlice(allocator);
        errdefer freeDecodedStructFieldSlice(allocator, fields);
        const decls = try decls_list.toOwnedSlice(allocator);
        errdefer freeDecodedDeclSlice(allocator, decls);
        const generic_params = try gps_list.toOwnedSlice(allocator);
        errdefer freeDecodedGenericParamSlice(allocator, generic_params);
        return .{
            .struct_decl = .{
                .name = name_owned,
                .is_pub = is_pub,
                .is_tuple = is_tuple,
                .fields = fields,
                .decls = decls,
                .generic_params = generic_params,
            },
        };
    } else if (std.mem.eql(u8, kind, "enum_decl")) {
        const eo = try getObj(try req(o, "value"));
        const name = try reqStr(eo, "name");
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const is_pub = if (eo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const tag_type = if (eo.get("tag_type")) |tt| (switch (tt) {
            .null => null,
            else => try decodeType(allocator, tt),
        }) else null;
        errdefer if (tag_type) |ty| freeDecodedType(allocator, ty);

        const vars_v = try req(eo, "variants");
        const vars_arr = switch (vars_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var vars_list: std.ArrayListUnmanaged(ast.EnumVariant) = .empty;
        errdefer freeDecodedEnumVariantList(allocator, &vars_list);
        for (vars_arr.items) |item| {
            try appendDecodedEnumVariant(allocator, &vars_list, item);
        }

        const decls_v = try req(eo, "decls");
        const decls_arr = switch (decls_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        errdefer freeDecodedDeclList(allocator, &decls_list);
        for (decls_arr.items) |item| {
            try appendDecodedDecl(allocator, &decls_list, item);
        }

        const variants = try vars_list.toOwnedSlice(allocator);
        errdefer freeDecodedEnumVariantSlice(allocator, variants);
        const decls = try decls_list.toOwnedSlice(allocator);
        errdefer freeDecodedDeclSlice(allocator, decls);
        return .{
            .enum_decl = .{
                .name = name_owned,
                .is_pub = is_pub,
                .tag_type = tag_type,
                .variants = variants,
                .decls = decls,
            },
        };
    } else if (std.mem.eql(u8, kind, "union_decl")) {
        const uo = try getObj(try req(o, "value"));
        const name = try reqStr(uo, "name");
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const is_pub = if (uo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const tag_type = if (uo.get("tag_type")) |tt| (switch (tt) {
            .null => null,
            else => try decodeType(allocator, tt),
        }) else null;
        errdefer if (tag_type) |ty| freeDecodedType(allocator, ty);

        const fields_v = try req(uo, "fields");
        const fields_arr = switch (fields_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var fields_list: std.ArrayListUnmanaged(ast.UnionField) = .empty;
        errdefer freeDecodedUnionFieldList(allocator, &fields_list);
        for (fields_arr.items) |item| {
            try appendDecodedUnionField(allocator, &fields_list, item);
        }

        const decls_v = try req(uo, "decls");
        const decls_arr = switch (decls_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        errdefer freeDecodedDeclList(allocator, &decls_list);
        for (decls_arr.items) |item| {
            try appendDecodedDecl(allocator, &decls_list, item);
        }

        const fields = try fields_list.toOwnedSlice(allocator);
        errdefer freeDecodedUnionFieldSlice(allocator, fields);
        const decls = try decls_list.toOwnedSlice(allocator);
        errdefer freeDecodedDeclSlice(allocator, decls);
        return .{
            .union_decl = .{
                .name = name_owned,
                .is_pub = is_pub,
                .tag_type = tag_type,
                .fields = fields,
                .decls = decls,
            },
        };
    } else if (std.mem.eql(u8, kind, "fn_decl")) {
        const fo = try getObj(try req(o, "value"));
        const name = try reqStr(fo, "name");
        const is_pub = if (fo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const is_test = if (fo.get("is_test")) |b| (switch (b) {
            .bool => |x| x,
            else => false,
        }) else false;

        const params_v = try req(fo, "params");
        const params_arr = switch (params_v) {
            .array => |a| a,
            else => return error.BadWireFormat,
        };
        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;
        for (params_arr.items) |item| {
            try params_list.append(allocator, try decodeFnParam(allocator, item));
        }

        const ret_type = try decodeType(allocator, try req(fo, "ret_type"));
        const body = if (fo.get("body")) |bv| (switch (bv) {
            .null => null,
            else => try decodeBlock(allocator, bv),
        }) else null;

        const gps_arr = if (fo.get("generic_params")) |gp_v| (switch (gp_v) {
            .array => |a| a,
            else => Array.init(allocator),
        }) else Array.init(allocator);
        var gps_list: std.ArrayListUnmanaged(ast.GenericParam) = .empty;
        for (gps_arr.items) |item| {
            try gps_list.append(allocator, try decodeGenericParam(allocator, item));
        }

        return .{
            .fn_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .is_test = is_test,
                .params = try params_list.toOwnedSlice(allocator),
                .ret_type = ret_type,
                .body = body,
                .generic_params = try gps_list.toOwnedSlice(allocator),
            },
        };
    } else if (std.mem.eql(u8, kind, "const_decl")) {
        const co = try getObj(try req(o, "value"));
        const name = try reqStr(co, "name");
        const is_pub = if (co.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const ty = if (co.get("ty")) |ty_v| (switch (ty_v) {
            .null => null,
            else => try decodeType(allocator, ty_v),
        }) else null;
        const init = try decodeExpr(allocator, try req(co, "init"));

        return .{
            .const_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .ty = ty,
                .init = init,
            },
        };
    } else if (std.mem.eql(u8, kind, "var_decl")) {
        const vo = try getObj(try req(o, "value"));
        const name = try reqStr(vo, "name");
        const is_pub = if (vo.get("is_pub")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const is_mut = if (vo.get("is_mut")) |b| (switch (b) {
            .bool => |x| x,
            else => true,
        }) else true;
        const ty = if (vo.get("ty")) |ty_v| (switch (ty_v) {
            .null => null,
            else => try decodeType(allocator, ty_v),
        }) else null;
        const init = try decodeExpr(allocator, try req(vo, "init"));

        return .{
            .var_decl = .{
                .name = try allocator.dupe(u8, name),
                .is_pub = is_pub,
                .is_mut = is_mut,
                .ty = ty,
                .init = init,
            },
        };
    } else if (std.mem.eql(u8, kind, "comment")) {
        const c = try reqStr(o, "value");
        return .{ .comment = try allocator.dupe(u8, c) };
    }

    return error.UnknownDeclKind;
}

// ---------------------------------------------------------------------------
// Import, TestDecl, File, ZonDep, Package Serialization
// ---------------------------------------------------------------------------

pub fn encodeImport(allocator: std.mem.Allocator, imp: ast.Import) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "local_name", .{ .string = imp.local_name });
    try o.put(allocator, "module_or_path", .{ .string = imp.module_or_path });
    try o.put(allocator, "is_pub", .{ .bool = imp.is_pub });
    return .{ .object = o };
}

pub fn decodeImport(allocator: std.mem.Allocator, v: Json) anyerror!ast.Import {
    const o = try getObj(v);
    const local_name = try reqStr(o, "local_name");
    const module_or_path = try reqStr(o, "module_or_path");
    const is_pub = if (o.get("is_pub")) |b| (switch (b) {
        .bool => |x| x,
        else => false,
    }) else false;
    const local_name_owned = try allocator.dupe(u8, local_name);
    errdefer allocator.free(local_name_owned);
    const module_or_path_owned = try allocator.dupe(u8, module_or_path);
    errdefer allocator.free(module_or_path_owned);
    return .{
        .local_name = local_name_owned,
        .module_or_path = module_or_path_owned,
        .is_pub = is_pub,
    };
}

pub fn encodeTestDecl(allocator: std.mem.Allocator, td: ast.TestDecl) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = td.name });
    try o.put(allocator, "body", try encodeBlock(allocator, td.body));
    return .{ .object = o };
}

pub fn decodeTestDecl(allocator: std.mem.Allocator, v: Json) anyerror!ast.TestDecl {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const body = try decodeBlock(allocator, try req(o, "body"));
    return .{
        .name = try allocator.dupe(u8, name),
        .body = body,
    };
}

pub fn encodeFile(allocator: std.mem.Allocator, f: ast.File) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "path", .{ .string = f.path });

    var imps_arr = Array.init(allocator);
    for (f.imports) |imp| {
        try imps_arr.append(try encodeImport(allocator, imp));
    }
    try o.put(allocator, "imports", .{ .array = imps_arr });

    var decls_arr = Array.init(allocator);
    for (f.decls) |d| {
        try decls_arr.append(try encodeDecl(allocator, d));
    }
    try o.put(allocator, "decls", .{ .array = decls_arr });

    var tests_arr = Array.init(allocator);
    for (f.tests) |t| {
        try tests_arr.append(try encodeTestDecl(allocator, t));
    }
    try o.put(allocator, "tests", .{ .array = tests_arr });

    return .{ .object = o };
}

pub fn decodeFile(allocator: std.mem.Allocator, v: Json) anyerror!ast.File {
    const o = try getObj(v);
    const path = try reqStr(o, "path");
    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);

    const imps_v = try req(o, "imports");
    const imps_arr = switch (imps_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var imps_list: std.ArrayListUnmanaged(ast.Import) = .empty;
    errdefer freeDecodedImportList(allocator, &imps_list);
    for (imps_arr.items) |item| {
        try appendDecodedImport(allocator, &imps_list, item);
    }

    const decls_v = try req(o, "decls");
    const decls_arr = switch (decls_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
    errdefer freeDecodedDeclList(allocator, &decls_list);
    for (decls_arr.items) |item| {
        try appendDecodedDecl(allocator, &decls_list, item);
    }

    const tests_v = try req(o, "tests");
    const tests_arr = switch (tests_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var tests_list: std.ArrayListUnmanaged(ast.TestDecl) = .empty;
    errdefer freeDecodedTestDeclList(allocator, &tests_list);
    for (tests_arr.items) |item| {
        try appendDecodedTestDecl(allocator, &tests_list, item);
    }

    const imports = try imps_list.toOwnedSlice(allocator);
    errdefer freeDecodedImportSlice(allocator, imports);
    const decls = try decls_list.toOwnedSlice(allocator);
    errdefer freeDecodedDeclSlice(allocator, decls);
    const tests = try tests_list.toOwnedSlice(allocator);
    errdefer freeDecodedTestDeclSlice(allocator, tests);
    return .{
        .path = path_owned,
        .imports = imports,
        .decls = decls,
        .tests = tests,
    };
}

pub fn encodeZonDep(allocator: std.mem.Allocator, zd: ast.ZonDep) anyerror!Json {
    var o = ObjectMap.empty;
    try o.put(allocator, "name", .{ .string = zd.name });
    try o.put(allocator, "url", .{ .string = zd.url });
    try o.put(allocator, "hash", .{ .string = zd.hash });
    try o.put(allocator, "path", encodeOptStr(zd.path));
    return .{ .object = o };
}

pub fn decodeZonDep(allocator: std.mem.Allocator, v: Json) anyerror!ast.ZonDep {
    const o = try getObj(v);
    const name = try reqStr(o, "name");
    const url = if (try optStr(o, "url")) |u| try allocator.dupe(u8, u) else "";
    errdefer freeDecodedBytes(allocator, url);
    const hash = if (try optStr(o, "hash")) |h| try allocator.dupe(u8, h) else "";
    errdefer freeDecodedBytes(allocator, hash);
    const path = if (try optStr(o, "path")) |p| try allocator.dupe(u8, p) else null;
    errdefer if (path) |value| allocator.free(value);
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    return .{
        .name = name_owned,
        .url = url,
        .hash = hash,
        .path = path,
    };
}

pub fn encodePackage(allocator: std.mem.Allocator, pkg: ast.Package) anyerror!Json {
    var root_map = ObjectMap.empty;
    try root_map.put(allocator, "format_version", mkInt(format_version));
    try root_map.put(allocator, "name", .{ .string = pkg.name });
    try root_map.put(allocator, "version", .{ .string = pkg.version });
    if (pkg.fingerprint) |fp| {
        const fp_str = try std.fmt.allocPrint(allocator, "{d}", .{fp});
        try root_map.put(allocator, "fingerprint", .{ .string = fp_str });
    } else {
        try root_map.put(allocator, "fingerprint", .{ .null = {} });
    }

    var files_arr = Array.init(allocator);
    for (pkg.files) |f| {
        try files_arr.append(try encodeFile(allocator, f));
    }
    try root_map.put(allocator, "files", .{ .array = files_arr });

    var deps_arr = Array.init(allocator);
    for (pkg.zon_deps) |zd| {
        try deps_arr.append(try encodeZonDep(allocator, zd));
    }
    try root_map.put(allocator, "zon_deps", .{ .array = deps_arr });

    return .{ .object = root_map };
}

pub fn decodePackage(allocator: std.mem.Allocator, v: Json) anyerror!ast.Package {
    const o = try getObj(v);
    const ver = try reqU32(o, "format_version");
    if (ver != format_version) return error.InvalidFormatVersion;

    const name = try reqStr(o, "name");
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    const version_value = if (try optStr(o, "version")) |ver_str|
        try allocator.dupe(u8, ver_str)
    else
        null;
    errdefer if (version_value) |version_owned| allocator.free(version_owned);
    const version = version_value orelse "0.0.0";
    const fingerprint = try optU64(o, "fingerprint");

    const files_v = try req(o, "files");
    const files_arr = switch (files_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var files_list: std.ArrayListUnmanaged(ast.File) = .empty;
    errdefer freeDecodedFileList(allocator, &files_list);
    for (files_arr.items) |item| {
        try appendDecodedFile(allocator, &files_list, item);
    }

    const deps_v = if (o.get("zon_deps")) |zd_val| zd_val else Json{
        .array = Array.init(allocator),
    };
    const deps_arr = switch (deps_v) {
        .array => |a| a,
        else => return error.BadWireFormat,
    };
    var deps_list: std.ArrayListUnmanaged(ast.ZonDep) = .empty;
    errdefer freeDecodedZonDepList(allocator, &deps_list);
    for (deps_arr.items) |item| {
        try appendDecodedZonDep(allocator, &deps_list, item);
    }

    const files = try files_list.toOwnedSlice(allocator);
    errdefer freeDecodedFileSlice(allocator, files);
    const deps = try deps_list.toOwnedSlice(allocator);
    errdefer freeDecodedZonDepSlice(allocator, deps);
    return .{
        .name = name_owned,
        .version = version,
        .fingerprint = fingerprint,
        .files = files,
        .zon_deps = deps,
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a `Package` AST instance into a JSON string.
/// The returned slice is allocated with `allocator` and must be freed by caller.
pub fn encode(allocator: std.mem.Allocator, pkg: *const ast.Package) ![]const u8 {
    var root_val = try encodePackage(allocator, pkg.*);
    defer freeValue(allocator, &root_val);

    return std.json.Stringify.valueAlloc(allocator, root_val, .{ .whitespace = .indent_2 });
}

/// Convenience value-taking encode.
pub fn encodeVal(allocator: std.mem.Allocator, pkg: ast.Package) ![]const u8 {
    return encode(allocator, &pkg);
}

/// Decode a JSON string into an `ast.Package` instance.
/// Allocations made during decoding use `allocator`.
pub fn decode(allocator: std.mem.Allocator, json_bytes: []const u8) !ast.Package {
    var parsed = std.json.parseFromSlice(Json, allocator, json_bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    return decodePackage(allocator, parsed.value);
}

pub const serialize = encodeVal;
pub const deserialize = decode;
