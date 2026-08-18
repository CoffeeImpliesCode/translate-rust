//! translate_rust.backend.zig.ast — Structured DOM for Zig source packages.
//!
//! Provides the target-language AST for generating valid, idiomatic Zig packages.

const std = @import("std");

/// A complete standalone Zig package with metadata and files.
pub const Package = struct {
    name: []const u8,
    version: []const u8 = "0.0.0",
    fingerprint: ?u64 = null,
    files: []const File = &.{},
    zon_deps: []const ZonDep = &.{},
};

/// A dependency in build.zig.zon.
pub const ZonDep = struct {
    name: []const u8,
    url: []const u8 = "",
    hash: []const u8 = "",
};

/// A single source file in the package.
pub const File = struct {
    path: []const u8,
    imports: []const Import = &.{},
    decls: []const Decl = &.{},
    tests: []const TestDecl = &.{},
};

/// An @import declaration in a file.
pub const Import = struct {
    local_name: []const u8,
    module_or_path: []const u8,
    is_pub: bool = false,
};

/// Top-level or container declaration in Zig.
pub const Decl = union(enum) {
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    union_decl: UnionDecl,
    fn_decl: FnDecl,
    const_decl: ConstDecl,
    var_decl: VarDecl,
    comment: []const u8,
};

pub const GenericParam = struct {
    name: []const u8,
    is_comptime: bool = true,
    ty: ?Type = null,
};

pub const StructDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    fields: []const StructField = &.{},
    decls: []const Decl = &.{},
    is_tuple: bool = false,
    generic_params: []const GenericParam = &.{},
};

pub const StructField = struct {
    name: []const u8,
    ty: Type,
    default_val: ?*const Expr = null,
    is_pub: bool = true,
};

pub const EnumDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    tag_type: ?Type = null,
    variants: []const EnumVariant = &.{},
    decls: []const Decl = &.{},
};

pub const EnumVariant = struct {
    name: []const u8,
    value: ?*const Expr = null,
};

pub const UnionDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    tag_type: ?Type = null,
    fields: []const UnionField = &.{},
    decls: []const Decl = &.{},
};

pub const UnionField = struct {
    name: []const u8,
    ty: Type,
    is_pub: bool = true,
};

pub const FnDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    is_test: bool = false,
    params: []const FnParam = &.{},
    ret_type: Type,
    body: ?Block = null,
    generic_params: []const GenericParam = &.{},
};

pub const FnParam = struct {
    name: []const u8,
    ty: Type,
    is_comptime: bool = false,
};

pub const ConstDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    ty: ?Type = null,
    init: Expr,
};

pub const VarDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    is_mut: bool = true,
    ty: ?Type = null,
    init: Expr,
};

/// Zig type representation.
pub const Type = union(enum) {
    prim: Prim,
    ptr: Ptr,
    slice: Slice,
    opt: *const Type,
    err_union: ErrUnion,
    named: []const u8,
    generic: GenericInst,
    array: Array,
    tuple: []const Type,
    any_opaque,
    void_type,
};

pub const Prim = enum {
    u8,
    u16,
    u21,
    u32,
    u64,
    u128,
    usize,
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    f32,
    f64,
    bool,
    void_type,
    noreturn_type,
    type_type,
    anyerror_type,
};

pub const PtrSize = enum {
    one,
    many,
    c,
};

pub const Ptr = struct {
    elem: *const Type,
    is_const: bool = false,
    is_allowzero: bool = false,
    size: PtrSize = .one,
};

pub const Slice = struct {
    elem: *const Type,
    is_const: bool = false,
};

pub const ErrUnion = struct {
    err_set: ?[]const u8 = null,
    payload: *const Type,
};

pub const GenericInst = struct {
    name: []const u8,
    params: []const Type = &.{},
};

pub const Array = struct {
    elem: *const Type,
    len: usize,
};

/// Literal expressions.
pub const Literal = union(enum) {
    int: i128,
    uint: u128,
    float: f64,
    bool_lit: bool,
    char_lit: u21,
    str: []const u8,
    null_lit,
    undefined_lit,
};

/// Zig expressions.
pub const Expr = union(enum) {
    lit: Literal,
    ident: []const u8,
    field_access: FieldAccess,
    call: Call,
    block: Block,
    match_expr: Match,
    bin_op: BinOp,
    unary_op: UnaryOp,
    struct_init: StructInit,
    array_init: ArrayInit,
    builtin: BuiltinCall,
    unsupported: []const u8,
    if_expr: IfExpr,
    while_expr: WhileExpr,
    for_expr: ForExpr,
    return_expr: ?*const Expr,
    break_expr: ?*const Expr,
    continue_expr: void,
};

pub const FieldAccess = struct {
    target: *const Expr,
    field_name: []const u8,
};

pub const Call = struct {
    callee: *const Expr,
    args: []const Expr = &.{},
};

pub const Block = struct {
    label: ?[]const u8 = null,
    stmts: []const Stmt = &.{},
    expr: ?*const Expr = null,
};

pub const Match = struct {
    target: *const Expr,
    arms: []const MatchArm = &.{},
};

pub const MatchArm = struct {
    patterns: []const Pattern = &.{},
    body: Expr,
};

pub const Pattern = union(enum) {
    wildcard,
    binding: []const u8,
    lit: Literal,
    enum_literal: []const u8,
    tuple: []const Pattern,
    struct_pat: StructPattern,
};

pub const StructPattern = struct {
    name: ?[]const u8 = null,
    fields: []const StructPatternField = &.{},
};

pub const StructPatternField = struct {
    name: []const u8,
    pat: Pattern,
};

pub const BinOpKind = enum {
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    equal,
    not_equal,
    less_than,
    less_than_equal,
    greater_than,
    greater_than_equal,
    bool_and,
    bool_or,
    add_wrap,
    sub_wrap,
    mul_wrap,
    add_sat,
    sub_sat,
};

pub const BinOp = struct {
    op: BinOpKind,
    lhs: *const Expr,
    rhs: *const Expr,
};

pub const UnaryOpKind = enum {
    negate,
    bit_not,
    bool_not,
    deref,
    addr_of,
    try_op,
};

pub const UnaryOp = struct {
    op: UnaryOpKind,
    operand: *const Expr,
};

pub const StructInit = struct {
    type_name: ?Type = null,
    fields: []const StructInitField = &.{},
};

pub const StructInitField = struct {
    name: []const u8,
    expr: Expr,
};

pub const ArrayInit = struct {
    type_name: ?Type = null,
    elements: []const Expr = &.{},
};

pub const BuiltinCall = struct {
    name: []const u8,
    args: []const Expr = &.{},
};

pub const IfExpr = struct {
    cond: *const Expr,
    then_body: *const Expr,
    else_body: ?*const Expr = null,
};

pub const WhileExpr = struct {
    cond: *const Expr,
    continue_expr: ?*const Expr = null,
    body: Block,
    else_body: ?*const Expr = null,
};

pub const ForExpr = struct {
    inputs: []const Expr = &.{},
    captures: []const []const u8 = &.{},
    body: Block,
    else_body: ?*const Expr = null,
};

pub const AssignOp = enum {
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    mod_assign,
    bit_and_assign,
    bit_or_assign,
    bit_xor_assign,
    shl_assign,
    shr_assign,
};

pub const AssignStmt = struct {
    target: Expr,
    val: Expr,
    op: AssignOp = .assign,
};

pub const LetStmt = struct {
    name: []const u8,
    ty: ?Type = null,
    init: Expr,
    is_mut: bool = false,
};

pub const Stmt = union(enum) {
    let_stmt: LetStmt,
    assign: AssignStmt,
    expr_stmt: *const Expr,
};

pub const TestDecl = struct {
    name: []const u8,
    body: Block,
};

test "ast: instantiate AST DOM shapes" {
    const u8_ty = Type{ .prim = .u8 };
    const slice_ty = Type{ .slice = .{ .elem = &u8_ty, .is_const = true } };
    const opt_slice_ty = Type{ .opt = &slice_ty };

    const lit_expr = Expr{ .lit = .{ .str = "hello world" } };
    const const_d = Decl{
        .const_decl = .{
            .name = "greeting",
            .ty = slice_ty,
            .init = lit_expr,
        },
    };

    const fn_d = Decl{
        .fn_decl = .{
            .name = "get_greeting",
            .ret_type = opt_slice_ty,
            .params = &.{
                .{ .name = "flag", .ty = Type{ .prim = .bool } },
            },
            .body = .{
                .stmts = &.{
                    .{
                        .let_stmt = .{
                            .name = "res",
                            .ty = opt_slice_ty,
                            .init = lit_expr,
                            .is_mut = false,
                        },
                    },
                },
                .expr = &Expr{ .ident = "res" },
            },
        },
    };

    const struct_d = Decl{
        .struct_decl = .{
            .name = "Greeter",
            .fields = &.{
                .{ .name = "id", .ty = Type{ .prim = .u64 } },
            },
            .decls = &.{fn_d},
        },
    };

    const file = File{
        .path = "src/greeter.zig",
        .imports = &.{
            .{ .local_name = "std", .module_or_path = "std" },
        },
        .decls = &.{ const_d, struct_d },
        .tests = &.{
            .{
                .name = "basic greeter test",
                .body = .{
                    .stmts = &.{},
                },
            },
        },
    };

    const pkg = Package{
        .name = "greeter_pkg",
        .version = "0.1.0",
        .fingerprint = 0x12345678,
        .files = &.{file},
    };

    try std.testing.expectEqualStrings("greeter_pkg", pkg.name);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    try std.testing.expectEqualStrings("src/greeter.zig", pkg.files[0].path);
    try std.testing.expectEqual(@as(usize, 2), pkg.files[0].decls.len);
}
