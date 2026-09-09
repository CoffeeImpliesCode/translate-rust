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

/// A dependency declared in the generated `build.zig.zon`.
pub const ZonDep = struct {
    name: []const u8,
    url: []const u8 = "",
    hash: []const u8 = "",
    path: ?[]const u8 = null,
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

pub const Decl = union(enum) {
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    union_decl: UnionDecl,
    fn_decl: FnDecl,
    const_decl: ConstDecl,
    var_decl: VarDecl,
    trait_descriptor: TraitDescriptorDecl,
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

pub const ProjectedType = struct {
    descriptor: []const u8,
    receiver: *const Type,
    member: []const u8,
};

pub const TraitDescriptorType = struct {
    name: []const u8,
    ty: Type,
};

pub const TraitDescriptorConst = struct {
    name: []const u8,
    value: Expr,
};

pub const TraitDescriptorMember = union(enum) {
    type_: TraitDescriptorType,
    const_: TraitDescriptorConst,
};

pub const TraitDescriptorCase = struct {
    receiver: Type,
    members: []const TraitDescriptorMember = &.{},
};

pub const TraitDescriptorDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    cases: []const TraitDescriptorCase = &.{},
};

/// Zig type representation.
pub const Type = union(enum) {
    prim: Prim,
    ptr: Ptr,
    slice: Slice,
    opt: *const Type,
    err_union: ErrUnion,
    projected: ProjectedType,
    named: []const u8,
    generic: GenericInst,
    array: Array,
    array_expr: ArrayExpr,
    tuple: []const Type,
    fn_ptr: FnPtr,
    anon_struct: AnonStruct,
    any_opaque,
    void_type,
};

pub const FnPtr = struct {
    params: []const Type,
    ret: *const Type,
};

pub const AnonStruct = struct {
    fields: []const StructField = &.{},
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
    alignment: ?u32 = null,
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

/// An expression-sized array type: `[<comptime expression>]T`.
pub const ArrayExpr = struct {
    elem: *const Type,
    len: *const Expr,
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
    unit: void,
    ident: []const u8,
    field_access: FieldAccess,
    call: Call,
    block: Block,
    match_expr: Match,
    bin_op: BinOp,
    unary_op: UnaryOp,
    cast: Cast,
    struct_init: StructInit,
    array_init: ArrayInit,
    repeat: Repeat,
    multi_array: MultiArray,
    tuple: []const Expr,
    builtin: BuiltinCall,
    panic_: []const u8,
    unsupported: []const u8,
    if_expr: IfExpr,
    while_expr: WhileExpr,
    for_expr: ForExpr,
    range: Range,
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
    /// Concrete type arguments are emitted before ordinary value arguments,
    /// matching the comptime parameters on generic Zig functions/methods.
    generic_args: []const Type = &.{},
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

pub const Capture = struct {
    name: []const u8,
    by_ref: bool = false,
};

pub const MatchArm = struct {
    patterns: []const Pattern = &.{},
    capture: ?Capture = null,
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

/// A comptime-repeated array literal: `[_]T{ elem } ** len` (`[e; N]`).
pub const Repeat = struct {
    /// Element type (`T` in `[_]T{ el } ** len`).
    type_name: ?Type = null,
    elem: *const Expr,
    len: usize,
};

/// An explicit element-list array literal: `[_]T{ e0, e1, ... }`.
pub const MultiArray = struct {
    /// Element type (`T` in `[_]T{ ... }`).
    type_name: ?Type = null,
    elements: []const Expr = &.{},
};

pub const BuiltinCall = struct {
    name: []const u8,
    args: []const Expr = &.{},
};

pub const Cast = struct {
    target: Type,
    operand: *const Expr,
    /// Raw-pointer casts retain source provenance for AST-boundary validation.
    source: ?Type = null,
};

pub const IfExpr = struct {
    cond: *const Expr,
    then_body: *const Expr,
    else_body: ?*const Expr = null,
};

pub const WhileExpr = struct {
    cond: *const Expr,
    continue_expr: ?*const Expr = null,
    /// Capture identifiers for `while (cond) |x| { body }`; null = no capture.
    captures: ?[]const []const u8 = null,
    body: Block,
    else_body: ?*const Expr = null,
};

pub const ForExpr = struct {
    inputs: []const Expr = &.{},
    captures: []const Capture = &.{},
    body: Block,
    else_body: ?*const Expr = null,
};

pub const Range = struct {
    start: *const Expr,
    end: ?*const Expr = null,
};

pub const AssignOp = enum {
    assign,
    add_assign,
    add_assign_wrap,
    sub_assign,
    sub_assign_wrap,
    mul_assign,
    mul_assign_wrap,
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

pub const DeferStmt = struct {
    expr: Expr,
    is_errdefer: bool = false,
};

pub const Stmt = union(enum) {
    let_stmt: LetStmt,
    assign: AssignStmt,
    defer_stmt: DeferStmt,
    expr_stmt: *const Expr,
};

pub const TestDecl = struct {
    name: []const u8,
    body: Block,
};

/// Errors raised when a package or file is not complete enough for translation
/// output. Canonical AST serialization remains lossless; these errors apply only
/// at output boundaries.
pub const ValidationError = error{
    MissingRootFile,
    DuplicateFilePath,
    InvalidFilePath,
    InvalidPackageName,
    DuplicateDependencyName,
    InvalidDependencyName,
    MissingFingerprint,
    DependencySourceUnavailable,
    MissingStdImport,
    EmptyTranslatedFunction,
    EmptyTranslatedBody,
    EmptyTranslatedContainer,
    UnnamedMatchSelector,
    MissingTypedLiteralIdentity,
    UnsupportedTranslationNode,
    DuplicateTraitDescriptorCase,
    AmbiguousMatchCapture,
    InvalidPointerAlignment,
    InvalidIdentifier,
};

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!((first >= 'a' and first <= 'z') or
        (first >= 'A' and first <= 'Z') or first == '_'))
    {
        return false;
    }
    for (name[1..]) |c| {
        if (!((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-'))
        {
            return false;
        }
    }
    return true;
}

fn normalizedNameEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_char, right_char| {
        const normalized_left = if (left_char == '-') '_' else left_char;
        const normalized_right = if (right_char == '-') '_' else right_char;
        if (normalized_left != normalized_right) return false;
    }
    return true;
}

fn validateName(name: []const u8) ValidationError!void {
    if (!isIdentifier(name)) return error.InvalidIdentifier;
}

fn validateQualifiedName(name: []const u8) ValidationError!void {
    if (name.len == 0) return error.InvalidIdentifier;
    var components = std.mem.splitScalar(u8, name, '.');
    while (components.next()) |component| try validateName(component);
}

fn validateFieldName(name: []const u8) ValidationError!void {
    if (name.len == 0) return error.InvalidIdentifier;
    var all_digits = true;
    for (name) |character| {
        if (character < '0' or character > '9') {
            all_digits = false;
            break;
        }
    }
    if (!all_digits) try validateName(name);
}

fn validateTypeName(name: []const u8) ValidationError!void {
    if (name.len == 0) return error.InvalidIdentifier;
    if (std.mem.eql(u8, name, "unsupported type")) {
        return error.UnsupportedTranslationNode;
    }
}

fn validatePackageName(name: []const u8) ValidationError!void {
    if (!isIdentifier(name)) return error.InvalidPackageName;
}

fn validManifestString(value: []const u8) bool {
    for (value) |character| {
        if (character == '"' or character == '\\' or character < 0x20) return false;
    }
    return true;
}

fn validateFilePath(path: []const u8) ValidationError!void {
    if (path.len == 0 or
        !std.mem.startsWith(u8, path, "src/") or
        path[0] == '/' or
        std.mem.indexOfScalar(u8, path, '\\') != null)
    {
        return error.InvalidFilePath;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) return error.InvalidFilePath;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidFilePath;
        }
    }
}

fn validateType(ty: Type) ValidationError!void {
    switch (ty) {
        .prim, .any_opaque, .void_type => {},
        .ptr => |ptr| {
            if (ptr.alignment) |alignment| {
                if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
                    return error.InvalidPointerAlignment;
                }
            }
            try validateType(ptr.elem.*);
        },
        .slice => |slice| try validateType(slice.elem.*),
        .opt => |inner| try validateType(inner.*),
        .err_union => |err_union| {
            if (err_union.err_set) |err_set| try validateQualifiedName(err_set);
            try validateType(err_union.payload.*);
        },
        .projected => |projected| {
            try validateQualifiedName(projected.descriptor);
            try validateType(projected.receiver.*);
            try validateName(projected.member);
        },
        .named => |name| try validateTypeName(name),
        .generic => |generic| {
            try validateTypeName(generic.name);
            for (generic.params) |param| try validateType(param);
        },
        .array => |array| try validateType(array.elem.*),
        .array_expr => |array| {
            try validateType(array.elem.*);
            try validateExpr(array.len.*);
        },
        .tuple => |tuple| for (tuple) |item| try validateType(item),
        .fn_ptr => |function| {
            for (function.params) |param| try validateType(param);
            try validateType(function.ret.*);
        },
        .anon_struct => |anon| {
            for (anon.fields) |field| {
                try validateFieldName(field.name);
                try validateType(field.ty);
                if (field.default_val) |value| try validateExpr(value.*);
            }
        },
    }
}

fn sameTypeSlice(left: []const Type, right: []const Type) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_type, right_type| {
        if (!sameType(left_type, right_type)) return false;
    }
    return true;
}

fn sameType(left: Type, right: Type) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .prim => |left_primitive| left_primitive == right.prim,
        .ptr => |left_pointer| {
            const right_pointer = right.ptr;
            return left_pointer.is_const == right_pointer.is_const and
                left_pointer.is_allowzero == right_pointer.is_allowzero and
                left_pointer.alignment == right_pointer.alignment and
                left_pointer.size == right_pointer.size and
                sameType(left_pointer.elem.*, right_pointer.elem.*);
        },
        .slice => |left_slice| {
            const right_slice = right.slice;
            return left_slice.is_const == right_slice.is_const and
                sameType(left_slice.elem.*, right_slice.elem.*);
        },
        .opt => |left_inner| sameType(left_inner.*, right.opt.*),
        .err_union => |left_union| {
            const right_union = right.err_union;
            if (left_union.err_set == null or right_union.err_set == null) {
                if (left_union.err_set != null or right_union.err_set != null) return false;
            } else if (!std.mem.eql(u8, left_union.err_set.?, right_union.err_set.?)) {
                return false;
            }
            return sameType(left_union.payload.*, right_union.payload.*);
        },
        .projected => |left_projected| {
            const right_projected = right.projected;
            return std.mem.eql(u8, left_projected.descriptor, right_projected.descriptor) and
                std.mem.eql(u8, left_projected.member, right_projected.member) and
                sameType(left_projected.receiver.*, right_projected.receiver.*);
        },
        .named => |left_name| std.mem.eql(u8, left_name, right.named),
        .generic => |left_generic| {
            const right_generic = right.generic;
            return std.mem.eql(u8, left_generic.name, right_generic.name) and
                sameTypeSlice(left_generic.params, right_generic.params);
        },
        .array => |left_array| {
            const right_array = right.array;
            return left_array.len == right_array.len and
                sameType(left_array.elem.*, right_array.elem.*);
        },
        .array_expr => |left_array| {
            const right_array = right.array_expr;
            return sameType(left_array.elem.*, right_array.elem.*) and
                sameExpr(left_array.len.*, right_array.len.*);
        },
        .tuple => |left_tuple| sameTypeSlice(left_tuple, right.tuple),
        .fn_ptr => |function| sameTypeSlice(function.params, right.fn_ptr.params) and
            sameType(function.ret.*, right.fn_ptr.ret.*),
        .anon_struct => |left_struct| {
            const right_struct = right.anon_struct;
            if (left_struct.fields.len != right_struct.fields.len) return false;
            for (left_struct.fields, right_struct.fields) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name) or
                    !sameType(left_field.ty, right_field.ty))
                {
                    return false;
                }
            }
            return true;
        },
        .any_opaque, .void_type => true,
    };
}

fn sameLiteral(left: Literal, right: Literal) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .int => |value| value == right.int,
        .uint => |value| value == right.uint,
        .float => |value| value == right.float,
        .bool_lit => |value| value == right.bool_lit,
        .char_lit => |value| value == right.char_lit,
        .str => |value| std.mem.eql(u8, value, right.str),
        .null_lit, .undefined_lit => true,
    };
}

fn sameOptionalType(left: ?Type, right: ?Type) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameType(left.?, right.?);
}

fn sameOptionalExpr(left: ?*const Expr, right: ?*const Expr) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameExpr(left.?.*, right.?.*);
}

fn sameOptionalString(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn sameStringSlice(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_string, right_string| {
        if (!std.mem.eql(u8, left_string, right_string)) return false;
    }
    return true;
}

fn sameOptionalStringSlice(
    left: ?[]const []const u8,
    right: ?[]const []const u8,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameStringSlice(left.?, right.?);
}

fn sameExprSlice(left: []const Expr, right: []const Expr) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_expr, right_expr| {
        if (!sameExpr(left_expr, right_expr)) return false;
    }
    return true;
}

fn samePatternSlice(left: []const Pattern, right: []const Pattern) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_pattern, right_pattern| {
        if (!samePattern(left_pattern, right_pattern)) return false;
    }
    return true;
}

fn sameStructInitFieldSlice(
    left: []const StructInitField,
    right: []const StructInitField,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field.name, right_field.name)) return false;
        if (!sameExpr(left_field.expr, right_field.expr)) return false;
    }
    return true;
}

fn sameStructPatternFieldSlice(
    left: []const StructPatternField,
    right: []const StructPatternField,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field.name, right_field.name)) return false;
        if (!samePattern(left_field.pat, right_field.pat)) return false;
    }
    return true;
}

fn samePattern(left: Pattern, right: Pattern) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .wildcard => true,
        .binding => |name| std.mem.eql(u8, name, right.binding),
        .lit => |literal| sameLiteral(literal, right.lit),
        .enum_literal => |name| std.mem.eql(u8, name, right.enum_literal),
        .tuple => |patterns| samePatternSlice(patterns, right.tuple),
        .struct_pat => |struct_pattern| {
            const other = right.struct_pat;
            return sameOptionalString(struct_pattern.name, other.name) and
                sameStructPatternFieldSlice(struct_pattern.fields, other.fields);
        },
    };
}

fn sameCapture(left: Capture, right: Capture) bool {
    return left.by_ref == right.by_ref and std.mem.eql(u8, left.name, right.name);
}

fn sameCaptureSlice(left: []const Capture, right: []const Capture) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_capture, right_capture| {
        if (!sameCapture(left_capture, right_capture)) return false;
    }
    return true;
}

fn sameMatchArmSlice(left: []const MatchArm, right: []const MatchArm) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_arm, right_arm| {
        if (!samePatternSlice(left_arm.patterns, right_arm.patterns)) return false;
        if (left_arm.capture == null or right_arm.capture == null) {
            if (left_arm.capture != null or right_arm.capture != null) return false;
        } else if (!sameCapture(left_arm.capture.?, right_arm.capture.?)) {
            return false;
        }
        if (!sameExpr(left_arm.body, right_arm.body)) return false;
    }
    return true;
}

fn sameStmt(left: Stmt, right: Stmt) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .let_stmt => |left_let| {
            const right_let = right.let_stmt;
            return std.mem.eql(u8, left_let.name, right_let.name) and
                sameOptionalType(left_let.ty, right_let.ty) and
                sameExpr(left_let.init, right_let.init) and
                left_let.is_mut == right_let.is_mut;
        },
        .assign => |left_assign| {
            const right_assign = right.assign;
            return sameExpr(left_assign.target, right_assign.target) and
                sameExpr(left_assign.val, right_assign.val) and
                left_assign.op == right_assign.op;
        },
        .defer_stmt => |left_defer| {
            const right_defer = right.defer_stmt;
            return sameExpr(left_defer.expr, right_defer.expr) and
                left_defer.is_errdefer == right_defer.is_errdefer;
        },
        .expr_stmt => |left_expr| sameExpr(left_expr.*, right.expr_stmt.*),
    };
}

fn sameStmtSlice(left: []const Stmt, right: []const Stmt) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_stmt, right_stmt| {
        if (!sameStmt(left_stmt, right_stmt)) return false;
    }
    return true;
}

fn sameBlock(left: Block, right: Block) bool {
    return sameOptionalString(left.label, right.label) and
        sameStmtSlice(left.stmts, right.stmts) and
        sameOptionalExpr(left.expr, right.expr);
}

fn sameExpr(left: Expr, right: Expr) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .lit => |literal| sameLiteral(literal, right.lit),
        .unit, .continue_expr => true,
        .ident => |name| std.mem.eql(u8, name, right.ident),
        .field_access => |field_access| {
            const other = right.field_access;
            return std.mem.eql(u8, field_access.field_name, other.field_name) and
                sameExpr(field_access.target.*, other.target.*);
        },
        .call => |call| {
            const other = right.call;
            return sameExpr(call.callee.*, other.callee.*) and
                sameTypeSlice(call.generic_args, other.generic_args) and
                sameExprSlice(call.args, other.args);
        },
        .block => |block| sameBlock(block, right.block),
        .match_expr => |match| {
            const other = right.match_expr;
            return sameExpr(match.target.*, other.target.*) and
                sameMatchArmSlice(match.arms, other.arms);
        },
        .bin_op => |binary| {
            const other = right.bin_op;
            return binary.op == other.op and
                sameExpr(binary.lhs.*, other.lhs.*) and
                sameExpr(binary.rhs.*, other.rhs.*);
        },
        .unary_op => |unary| {
            const other = right.unary_op;
            return unary.op == other.op and sameExpr(unary.operand.*, other.operand.*);
        },
        .cast => |cast| {
            const other = right.cast;
            return sameType(cast.target, other.target) and
                sameOptionalType(cast.source, other.source) and
                sameExpr(cast.operand.*, other.operand.*);
        },
        .struct_init => |struct_init| {
            const other = right.struct_init;
            return sameOptionalType(struct_init.type_name, other.type_name) and
                sameStructInitFieldSlice(struct_init.fields, other.fields);
        },
        .array_init => |array_init| {
            const other = right.array_init;
            return sameOptionalType(array_init.type_name, other.type_name) and
                sameExprSlice(array_init.elements, other.elements);
        },
        .repeat => |repeat| {
            const other = right.repeat;
            return sameOptionalType(repeat.type_name, other.type_name) and
                sameExpr(repeat.elem.*, other.elem.*) and repeat.len == other.len;
        },
        .multi_array => |multi_array| {
            const other = right.multi_array;
            return sameOptionalType(multi_array.type_name, other.type_name) and
                sameExprSlice(multi_array.elements, other.elements);
        },
        .tuple => |elements| sameExprSlice(elements, right.tuple),
        .builtin => |builtin| {
            const other = right.builtin;
            return std.mem.eql(u8, builtin.name, other.name) and
                sameExprSlice(builtin.args, other.args);
        },
        .panic_ => |message| std.mem.eql(u8, message, right.panic_),
        .unsupported => |message| std.mem.eql(u8, message, right.unsupported),
        .if_expr => |if_expr| {
            const other = right.if_expr;
            return sameExpr(if_expr.cond.*, other.cond.*) and
                sameExpr(if_expr.then_body.*, other.then_body.*) and
                sameOptionalExpr(if_expr.else_body, other.else_body);
        },
        .while_expr => |while_expr| {
            const other = right.while_expr;
            return sameExpr(while_expr.cond.*, other.cond.*) and
                sameOptionalExpr(while_expr.continue_expr, other.continue_expr) and
                sameOptionalStringSlice(while_expr.captures, other.captures) and
                sameBlock(while_expr.body, other.body) and
                sameOptionalExpr(while_expr.else_body, other.else_body);
        },
        .for_expr => |for_expr| {
            const other = right.for_expr;
            return sameExprSlice(for_expr.inputs, other.inputs) and
                sameCaptureSlice(for_expr.captures, other.captures) and
                sameBlock(for_expr.body, other.body) and
                sameOptionalExpr(for_expr.else_body, other.else_body);
        },
        .range => |range| {
            const other = right.range;
            return sameExpr(range.start.*, other.start.*) and
                sameOptionalExpr(range.end, other.end);
        },
        .return_expr => |value| sameOptionalExpr(value, right.return_expr),
        .break_expr => |value| sameOptionalExpr(value, right.break_expr),
    };
}

const ScalarPointeeLayout = enum {
    byte_1,
    byte_2,
    byte_4,
    byte_8,
    byte_16,
    pointer,
};

fn scalarPointeeLayout(primitive: Prim) ?ScalarPointeeLayout {
    return switch (primitive) {
        .u8, .i8, .bool => .byte_1,
        .u16, .i16 => .byte_2,
        .u21, .u32, .i32, .f32 => .byte_4,
        .u64, .i64, .f64 => .byte_8,
        .u128, .i128 => .byte_16,
        .usize, .isize => .pointer,
        .void_type, .noreturn_type, .type_type, .anyerror_type => null,
    };
}

fn pointerPointeesCompatible(source: Type, target: Type) bool {
    return switch (source) {
        .prim => |source_primitive| switch (target) {
            .prim => |target_primitive| {
                const source_layout = scalarPointeeLayout(source_primitive) orelse return false;
                const target_layout = scalarPointeeLayout(target_primitive) orelse return false;
                return source_layout == target_layout;
            },
            else => false,
        },
        else => false,
    };
}
fn validPointerCastShape(source: Ptr, target: Ptr, operand: Expr) bool {
    const pointer_cast = switch (operand) {
        .builtin => |builtin| blk: {
            if (!std.mem.eql(u8, builtin.name, "ptrCast")) return false;
            if (builtin.args.len != 1) return false;
            break :blk builtin;
        },
        else => return false,
    };
    const pointer_operand = pointer_cast.args[0];
    const const_cast = switch (pointer_operand) {
        .builtin => |builtin| if (std.mem.eql(u8, builtin.name, "constCast"))
            builtin
        else
            null,
        else => null,
    };
    const removes_const = source.is_const and !target.is_const;
    if (removes_const != (const_cast != null)) return false;
    if (const_cast) |builtin| {
        if (builtin.args.len != 1) return false;
    }
    return true;
}

fn patternContainsBinding(pattern: Pattern) bool {
    return switch (pattern) {
        .wildcard, .lit, .enum_literal => false,
        .binding => true,
        .tuple => |patterns| {
            for (patterns) |child| {
                if (patternContainsBinding(child)) return true;
            }
            return false;
        },
        .struct_pat => |struct_pattern| {
            for (struct_pattern.fields) |field| {
                if (patternContainsBinding(field.pat)) return true;
            }
            return false;
        },
    };
}

fn matchArmContainsBinding(arm: MatchArm) bool {
    for (arm.patterns) |pattern| {
        if (patternContainsBinding(pattern)) return true;
    }
    return false;
}

fn validateLiteral(_: Literal) ValidationError!void {}

fn validatePattern(pattern: Pattern) ValidationError!void {
    switch (pattern) {
        .wildcard => {},
        .binding => |name| try validateName(name),
        .lit => |literal| try validateLiteral(literal),
        .enum_literal => |name| {
            if (name.len == 0) return error.MissingTypedLiteralIdentity;
            try validateName(name);
        },
        .tuple => |patterns| for (patterns) |item| try validatePattern(item),
        .struct_pat => |struct_pat| {
            const name = struct_pat.name orelse return error.UnnamedMatchSelector;
            if (name.len == 0) return error.UnnamedMatchSelector;
            try validateName(name);
            for (struct_pat.fields) |field| {
                try validateFieldName(field.name);
                try validatePattern(field.pat);
            }
        },
    }
}

fn validateBlock(block: Block) ValidationError!void {
    if (block.stmts.len == 0 and block.expr == null) return error.EmptyTranslatedBody;
    if (block.label) |label| try validateName(label);
    for (block.stmts) |stmt| {
        switch (stmt) {
            .let_stmt => |let_stmt| {
                try validateName(let_stmt.name);
                if (let_stmt.ty) |ty| try validateType(ty);
                try validateExpr(let_stmt.init);
            },
            .assign => |assign| {
                try validateExpr(assign.target);
                try validateExpr(assign.val);
            },
            .defer_stmt => |defer_stmt| try validateExpr(defer_stmt.expr),
            .expr_stmt => |expr| try validateExpr(expr.*),
        }
    }
    if (block.expr) |expr| try validateExpr(expr.*);
}

fn validateExpr(expr: Expr) ValidationError!void {
    switch (expr) {
        .lit => |literal| try validateLiteral(literal),
        .ident => |name| try validateQualifiedName(name),
        .field_access => |field_access| {
            try validateExpr(field_access.target.*);
            try validateFieldName(field_access.field_name);
        },
        .call => |call| {
            try validateExpr(call.callee.*);
            for (call.generic_args) |arg| try validateType(arg);
            for (call.args) |arg| try validateExpr(arg);
        },
        .block => |block| try validateBlock(block),
        .match_expr => |match| {
            try validateExpr(match.target.*);
            if (match.arms.len == 0) return error.EmptyTranslatedBody;
            for (match.arms) |arm| {
                if (arm.patterns.len == 0) return error.UnnamedMatchSelector;
                for (arm.patterns) |pattern| try validatePattern(pattern);
                if (arm.capture) |capture| {
                    try validateName(capture.name);
                    if (matchArmContainsBinding(arm)) return error.AmbiguousMatchCapture;
                }
                try validateExpr(arm.body);
            }
        },
        .cast => |cast| {
            switch (cast.target) {
                .prim => |primitive| switch (primitive) {
                    .u8, .u16, .u21, .u32, .u64, .u128, .usize, .i8, .i16, .i32, .i64, .i128, .isize, .f32, .f64 => {},
                    .bool, .void_type, .noreturn_type, .type_type, .anyerror_type => return error.UnsupportedTranslationNode,
                },
                .ptr => |target_pointer| {
                    if (target_pointer.size != .many) return error.UnsupportedTranslationNode;
                    const source = cast.source orelse return error.UnsupportedTranslationNode;
                    const source_pointer = switch (source) {
                        .ptr => |pointer| pointer,
                        else => return error.UnsupportedTranslationNode,
                    };
                    if (source_pointer.size != .many or
                        !pointerPointeesCompatible(source_pointer.elem.*, target_pointer.elem.*))
                    {
                        return error.UnsupportedTranslationNode;
                    }
                    if (!validPointerCastShape(source_pointer, target_pointer, cast.operand.*)) {
                        return error.UnsupportedTranslationNode;
                    }
                    try validateType(source);
                    try validateType(cast.target);
                },
                .slice => |target_slice| {
                    const source = cast.source orelse return error.UnsupportedTranslationNode;
                    const source_element = switch (source) {
                        .ptr => |pointer| blk: {
                            if (pointer.size != .one or (pointer.is_const and !target_slice.is_const))
                                return error.UnsupportedTranslationNode;
                            break :blk switch (pointer.elem.*) {
                                .array => |array| array.elem,
                                .array_expr => |array| array.elem,
                                else => return error.UnsupportedTranslationNode,
                            };
                        },
                        .slice => |slice| blk: {
                            if (slice.is_const and !target_slice.is_const)
                                return error.UnsupportedTranslationNode;
                            break :blk slice.elem;
                        },
                        else => return error.UnsupportedTranslationNode,
                    };
                    if (!sameType(source_element.*, target_slice.elem.*))
                        return error.UnsupportedTranslationNode;
                    try validateType(source);
                    try validateType(cast.target);
                },
                .opt => try validateType(cast.target),
                else => return error.UnsupportedTranslationNode,
            }
            try validateExpr(cast.operand.*);
        },
        .bin_op => |bin_op| {
            try validateExpr(bin_op.lhs.*);
            try validateExpr(bin_op.rhs.*);
        },
        .unary_op => |unary_op| try validateExpr(unary_op.operand.*),
        .struct_init => |struct_init| {
            if (struct_init.fields.len > 0 and struct_init.type_name == null) {
                return error.MissingTypedLiteralIdentity;
            }
            if (struct_init.type_name) |type_name| try validateType(type_name);
            for (struct_init.fields) |field| {
                try validateFieldName(field.name);
                try validateExpr(field.expr);
            }
        },
        .array_init => |array_init| {
            if (array_init.type_name == null) return error.MissingTypedLiteralIdentity;
            if (array_init.type_name) |type_name| try validateType(type_name);
            for (array_init.elements) |element| try validateExpr(element);
        },
        .repeat => |repeat| {
            if (repeat.type_name == null) return error.MissingTypedLiteralIdentity;
            if (repeat.type_name) |type_name| try validateType(type_name);
            try validateExpr(repeat.elem.*);
        },
        .multi_array => |multi_array| {
            if (multi_array.type_name == null) return error.MissingTypedLiteralIdentity;
            if (multi_array.type_name) |type_name| try validateType(type_name);
            for (multi_array.elements) |element| try validateExpr(element);
        },
        .tuple => |elements| for (elements) |element| try validateExpr(element),
        .builtin => |builtin| {
            try validateQualifiedName(builtin.name);
            for (builtin.args) |arg| try validateExpr(arg);
        },
        .unit, .panic_ => {},
        .unsupported => return error.UnsupportedTranslationNode,
        .if_expr => |if_expr| {
            try validateExpr(if_expr.cond.*);
            try validateExpr(if_expr.then_body.*);
            if (if_expr.else_body) |else_body| try validateExpr(else_body.*);
        },
        .while_expr => |while_expr| {
            try validateExpr(while_expr.cond.*);
            if (while_expr.continue_expr) |continue_expr| try validateExpr(continue_expr.*);
            if (while_expr.captures) |captures| for (captures) |capture| try validateName(capture);
            try validateBlock(while_expr.body);
            if (while_expr.else_body) |else_body| try validateExpr(else_body.*);
        },
        .for_expr => |for_expr| {
            if (for_expr.inputs.len == 0 or for_expr.captures.len == 0) {
                return error.EmptyTranslatedBody;
            }
            for (for_expr.inputs) |input| try validateExpr(input);
            for (for_expr.captures) |capture| try validateName(capture.name);
            try validateBlock(for_expr.body);
            if (for_expr.else_body) |else_body| try validateExpr(else_body.*);
        },
        .range => |range| {
            try validateExpr(range.start.*);
            if (range.end) |end| try validateExpr(end.*);
        },
        .return_expr => |value| if (value) |expr_ptr| try validateExpr(expr_ptr.*),
        .break_expr => |value| if (value) |expr_ptr| try validateExpr(expr_ptr.*),
        .continue_expr => {},
    }
}

fn validateTraitDescriptor(descriptor: TraitDescriptorDecl) ValidationError!void {
    try validateName(descriptor.name);
    if (descriptor.cases.len == 0) return error.EmptyTranslatedContainer;
    for (descriptor.cases, 0..) |case, case_index| {
        try validateType(case.receiver);
        if (case.members.len == 0) return error.EmptyTranslatedContainer;
        for (descriptor.cases[0..case_index]) |prior| {
            if (sameType(prior.receiver, case.receiver)) {
                return error.DuplicateTraitDescriptorCase;
            }
        }
        for (case.members, 0..) |member, member_index| {
            const member_name = switch (member) {
                .type_ => |value| value.name,
                .const_ => |value| value.name,
            };
            try validateName(member_name);
            for (case.members[0..member_index]) |prior| {
                const prior_name = switch (prior) {
                    .type_ => |value| value.name,
                    .const_ => |value| value.name,
                };
                if (std.mem.eql(u8, prior_name, member_name)) {
                    return error.InvalidIdentifier;
                }
            }
            switch (member) {
                .type_ => |value| try validateType(value.ty),
                .const_ => |value| try validateExpr(value.value),
            }
        }
    }
}

fn validateDecl(decl: Decl) ValidationError!void {
    switch (decl) {
        .trait_descriptor => |descriptor| try validateTraitDescriptor(descriptor),
        .comment => {},
        .const_decl => |const_decl| {
            try validateName(const_decl.name);
            if (const_decl.ty) |ty| try validateType(ty);
            try validateExpr(const_decl.init);
        },
        .var_decl => |var_decl| {
            try validateName(var_decl.name);
            if (var_decl.ty) |ty| try validateType(ty);
            try validateExpr(var_decl.init);
        },
        .fn_decl => |fn_decl| {
            try validateName(fn_decl.name);
            if (fn_decl.body == null) return error.EmptyTranslatedFunction;
            if (fn_decl.body.?.stmts.len == 0 and fn_decl.body.?.expr == null) {
                return error.EmptyTranslatedBody;
            }
            for (fn_decl.params) |param| {
                try validateName(param.name);
                try validateType(param.ty);
            }
            for (fn_decl.generic_params) |param| {
                try validateName(param.name);
                if (param.ty) |ty| try validateType(ty);
            }
            try validateType(fn_decl.ret_type);
            try validateBlock(fn_decl.body.?);
        },
        .struct_decl => |struct_decl| {
            try validateName(struct_decl.name);
            if (struct_decl.fields.len == 0 and struct_decl.decls.len == 0) {
                return error.EmptyTranslatedContainer;
            }
            for (struct_decl.fields) |field| {
                try validateFieldName(field.name);
                try validateType(field.ty);
                if (field.default_val) |value| try validateExpr(value.*);
            }
            for (struct_decl.generic_params) |param| {
                try validateName(param.name);
                if (param.ty) |ty| try validateType(ty);
            }
            for (struct_decl.decls) |inner| try validateDecl(inner);
        },
        .enum_decl => |enum_decl| {
            try validateName(enum_decl.name);
            if (enum_decl.variants.len == 0 and enum_decl.decls.len == 0) {
                return error.EmptyTranslatedContainer;
            }
            if (enum_decl.tag_type) |tag_type| try validateType(tag_type);
            for (enum_decl.variants) |variant| {
                try validateName(variant.name);
                if (variant.value) |value| try validateExpr(value.*);
            }
            for (enum_decl.decls) |inner| try validateDecl(inner);
        },
        .union_decl => |union_decl| {
            try validateName(union_decl.name);
            if (union_decl.fields.len == 0 and union_decl.decls.len == 0) {
                return error.EmptyTranslatedContainer;
            }
            if (union_decl.tag_type) |tag_type| try validateType(tag_type);
            for (union_decl.fields) |field| {
                try validateName(field.name);
                try validateType(field.ty);
            }
            for (union_decl.decls) |inner| try validateDecl(inner);
        },
    }
}

pub fn validateFileForTranslation(file: *const File) ValidationError!void {
    try validateFilePath(file.path);
    var has_std = false;
    for (file.imports) |import| {
        try validateName(import.local_name);
        if (import.module_or_path.len == 0) return error.InvalidIdentifier;
        if (std.mem.eql(u8, import.local_name, "std") and
            std.mem.eql(u8, import.module_or_path, "std"))
        {
            has_std = true;
        }
    }
    if (file.tests.len > 0 and !has_std) return error.MissingStdImport;
    for (file.decls) |decl| try validateDecl(decl);
    for (file.tests) |test_decl| {
        if (test_decl.name.len == 0) return error.InvalidIdentifier;
        try validateBlock(test_decl.body);
    }
}

pub fn validateForTranslation(pkg: *const Package) ValidationError!void {
    try validatePackageName(pkg.name);
    if (pkg.fingerprint == null) return error.MissingFingerprint;

    var root_count: usize = 0;
    for (pkg.files, 0..) |file, index| {
        try validateFileForTranslation(&file);
        if (std.mem.eql(u8, file.path, "src/root.zig")) root_count += 1;
        for (pkg.files[index + 1 ..]) |other| {
            if (std.mem.eql(u8, file.path, other.path)) return error.DuplicateFilePath;
        }
    }
    if (root_count != 1) return error.MissingRootFile;
    if (normalizedNameEqual(pkg.name, "r2z-core")) {
        return error.DuplicateDependencyName;
    }
    for (pkg.zon_deps, 0..) |dependency, index| {
        if (!isIdentifier(dependency.name)) return error.InvalidDependencyName;
        if (normalizedNameEqual(pkg.name, dependency.name)) {
            return error.DuplicateDependencyName;
        }
        if (dependency.path) |path| {
            if (path.len == 0 or !validManifestString(path)) {
                return error.DependencySourceUnavailable;
            }
        } else {
            if (dependency.url.len == 0 or dependency.hash.len == 0) {
                return error.DependencySourceUnavailable;
            }
            if (!validManifestString(dependency.url) or !validManifestString(dependency.hash)) {
                return error.DependencySourceUnavailable;
            }
        }
        for (pkg.zon_deps[index + 1 ..]) |other| {
            if (normalizedNameEqual(dependency.name, other.name)) {
                return error.DuplicateDependencyName;
            }
        }
    }
}

test "ast validation: distinguishes zero tests from empty test bodies" {
    const no_tests: File = .{ .path = "src/root.zig" };
    try validateFileForTranslation(&no_tests);

    const empty_test: File = .{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .tests = &.{.{ .name = "empty", .body = .{} }},
    };
    try std.testing.expectError(error.EmptyTranslatedBody, validateFileForTranslation(&empty_test));
}

test "ast validation: rejects missing std import for generated tests" {
    const file: File = .{
        .path = "src/root.zig",
        .tests = &.{.{ .name = "test", .body = .{ .expr = &Expr{ .continue_expr = {} } } }},
    };
    try std.testing.expectError(error.MissingStdImport, validateFileForTranslation(&file));
}

test "ast validation: rejects empty functions, containers, match selectors, and typed literals" {
    const empty_fn: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "empty",
            .ret_type = .{ .void_type = {} },
            .body = .{},
        } }},
    };
    try std.testing.expectError(error.EmptyTranslatedBody, validateFileForTranslation(&empty_fn));

    const empty_container: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .struct_decl = .{ .name = "Empty" } }},
    };
    try std.testing.expectError(
        error.EmptyTranslatedContainer,
        validateFileForTranslation(&empty_container),
    );

    const unnamed_match: Expr = .{ .match_expr = .{
        .target = &Expr{ .ident = "value" },
        .arms = &.{.{ .patterns = &.{.{ .struct_pat = .{} }}, .body = .{ .continue_expr = {} } }},
    } };
    try std.testing.expectError(error.UnnamedMatchSelector, validateExpr(unnamed_match));

    const untyped_literal: Expr = .{ .struct_init = .{
        .fields = &.{.{ .name = "value", .expr = .{ .lit = .{ .int = 1 } } }},
    } };
    try std.testing.expectError(
        error.MissingTypedLiteralIdentity,
        validateExpr(untyped_literal),
    );

    const untyped_array: Expr = .{ .multi_array = .{
        .elements = &.{.{ .lit = .{ .int = 1 } }},
    } };
    try std.testing.expectError(
        error.MissingTypedLiteralIdentity,
        validateExpr(untyped_array),
    );
}

test "ast validation: accepts defer and errdefer calls at file and package boundaries" {
    const release_call: Expr = .{ .call = .{
        .callee = &Expr{ .ident = "release" },
    } };
    const rollback_call: Expr = .{ .call = .{
        .callee = &Expr{ .ident = "rollback" },
    } };
    const normal_cleanup: Stmt = .{ .defer_stmt = .{ .expr = release_call } };
    const error_cleanup: Stmt = .{
        .defer_stmt = .{
            .expr = rollback_call,
            .is_errdefer = true,
        },
    };
    try std.testing.expect(!normal_cleanup.defer_stmt.is_errdefer);
    try std.testing.expect(error_cleanup.defer_stmt.is_errdefer);

    const file: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "work",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &.{ normal_cleanup, error_cleanup } },
        } }},
    };
    try validateFileForTranslation(&file);

    const pkg: Package = .{
        .name = "cleanup_contract",
        .fingerprint = 0x1234,
        .files = &.{file},
    };
    try validateForTranslation(&pkg);
}

test "ast validation: rejects malformed defer and errdefer cleanup expressions" {
    const malformed_cleanup: Expr = .{ .unsupported = "invalid cleanup" };
    const malformed_defer: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "malformed_defer",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &.{.{
                .defer_stmt = .{ .expr = malformed_cleanup },
            }} },
        } }},
    };
    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        validateFileForTranslation(&malformed_defer),
    );

    const malformed_errdefer: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "malformed_errdefer",
            .ret_type = .{ .void_type = {} },
            .body = .{ .stmts = &.{.{
                .defer_stmt = .{
                    .expr = malformed_cleanup,
                    .is_errdefer = true,
                },
            }} },
        } }},
    };
    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        validateFileForTranslation(&malformed_errdefer),
    );
}

test "ast validation: accepts numeric tuple fields and rejects invalid names" {
    const numeric_tuple: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .struct_decl = .{
            .name = "Pair",
            .fields = &.{
                .{ .name = "0", .ty = .{ .prim = .u8 } },
                .{ .name = "1", .ty = .{ .prim = .u8 } },
            },
        } }},
    };
    try validateFileForTranslation(&numeric_tuple);

    const invalid_field: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .struct_decl = .{
            .name = "Pair",
            .fields = &.{.{ .name = "0x", .ty = .{ .prim = .u8 } }},
        } }},
    };
    try std.testing.expectError(
        error.InvalidIdentifier,
        validateFileForTranslation(&invalid_field),
    );

    const empty_field: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .struct_decl = .{
            .name = "Pair",
            .fields = &.{.{ .name = "", .ty = .{ .prim = .u8 } }},
        } }},
    };
    try std.testing.expectError(
        error.InvalidIdentifier,
        validateFileForTranslation(&empty_field),
    );
}

test "ast validation: validates explicit captures and rejects ambiguous bindings" {
    const valid_value_capture: Expr = .{ .match_expr = .{
        .target = &Expr{ .ident = "input" },
        .arms = &.{.{
            .patterns = &.{.{ .enum_literal = "value" }},
            .capture = .{ .name = "payload" },
            .body = .{ .ident = "payload" },
        }},
    } };
    try validateExpr(valid_value_capture);

    const valid_pointer_capture: Expr = .{ .match_expr = .{
        .target = &Expr{ .ident = "input" },
        .arms = &.{.{
            .patterns = &.{.{ .enum_literal = "value" }},
            .capture = .{ .name = "payload", .by_ref = true },
            .body = .{ .ident = "payload" },
        }},
    } };
    try validateExpr(valid_pointer_capture);

    for ([_][]const u8{ "", "0payload", "payload*" }) |name| {
        const malformed: Expr = .{ .match_expr = .{
            .target = &Expr{ .ident = "input" },
            .arms = &.{.{
                .patterns = &.{.{ .enum_literal = "value" }},
                .capture = .{ .name = name },
                .body = .{ .ident = "payload" },
            }},
        } };
        try std.testing.expectError(error.InvalidIdentifier, validateExpr(malformed));
    }

    const ambiguous: Expr = .{ .match_expr = .{
        .target = &Expr{ .ident = "input" },
        .arms = &.{.{
            .patterns = &.{
                .{ .enum_literal = "value" },
                .{ .binding = "legacy_payload" },
            },
            .capture = .{ .name = "payload" },
            .body = .{ .ident = "payload" },
        }},
    } };
    try std.testing.expectError(error.AmbiguousMatchCapture, validateExpr(ambiguous));
}

test "ast: instantiate AST DOM shapes" {
    const u8_ty: Type = .{ .prim = .u8 };
    const slice_ty: Type = .{ .slice = .{ .elem = &u8_ty, .is_const = true } };
    const opt_slice_ty: Type = .{ .opt = &slice_ty };

    const lit_expr: Expr = .{ .lit = .{ .str = "hello world" } };
    const const_d: Decl = .{
        .const_decl = .{
            .name = "greeting",
            .ty = slice_ty,
            .init = lit_expr,
        },
    };

    const fn_d: Decl = .{
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

    const struct_d: Decl = .{
        .struct_decl = .{
            .name = "Greeter",
            .fields = &.{
                .{ .name = "id", .ty = Type{ .prim = .u64 } },
            },
            .decls = &.{fn_d},
        },
    };

    const file: File = .{
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

    const pkg: Package = .{
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

test "slice casts preserve borrowed element type and mutability" {
    const byte: Type = .{ .prim = .u8 };
    const word: Type = .{ .prim = .u16 };
    const array: Type = .{ .array = .{ .elem = &byte, .len = 4 } };
    const operand: Expr = .{ .ident = "buffer" };
    var expression: Expr = .{ .cast = .{
        .target = .{ .slice = .{ .elem = &byte, .is_const = false } },
        .source = .{ .ptr = .{ .elem = &array, .size = .one, .is_const = false } },
        .operand = &operand,
    } };
    try validateExpr(expression);
    expression.cast.source.?.ptr.is_const = true;
    try std.testing.expectError(error.UnsupportedTranslationNode, validateExpr(expression));
    expression.cast.target.slice.is_const = true;
    try validateExpr(expression);
    expression.cast.target.slice.elem = &word;
    try std.testing.expectError(error.UnsupportedTranslationNode, validateExpr(expression));
}
