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
    /// Authored documentation for the file itself, emitted as `//!` lines
    /// ahead of every import and declaration. Empty means the source carried
    /// no module documentation.
    documentation: []const u8 = "",
    imports: []const Import = &.{},
    decls: []const Decl = &.{},
    tests: []const TestDecl = &.{},
};

/// An @import declaration in a file.
pub const Import = struct {
    local_name: []const u8,
    module_or_path: []const u8,
    is_pub: bool = false,
    /// Authored documentation for this import, emitted as `///` lines above
    /// it. Empty means the source carried no documentation.
    documentation: []const u8 = "",
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
    /// Authored documentation for this declaration. Empty means absent.
    documentation: []const u8 = "",
};

pub const StructField = struct {
    name: []const u8,
    ty: Type,
    default_val: ?*const Expr = null,
    is_pub: bool = true,
    /// Authored documentation for this field. Empty means absent.
    documentation: []const u8 = "",
};

pub const EnumDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    tag_type: ?Type = null,
    variants: []const EnumVariant = &.{},
    decls: []const Decl = &.{},
    /// Authored documentation for this declaration. Empty means absent.
    documentation: []const u8 = "",
};

pub const EnumVariant = struct {
    name: []const u8,
    value: ?*const Expr = null,
    /// Authored documentation for this tag. Empty means absent.
    documentation: []const u8 = "",
};

pub const UnionDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    tag_type: ?Type = null,
    fields: []const UnionField = &.{},
    decls: []const Decl = &.{},
    /// Authored documentation for this declaration. Empty means absent.
    documentation: []const u8 = "",
};

pub const UnionField = struct {
    name: []const u8,
    ty: Type,
    is_pub: bool = true,
    /// Authored documentation for this field. Empty means absent.
    documentation: []const u8 = "",
};

pub const FnDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    is_test: bool = false,
    params: []const FnParam = &.{},
    ret_type: Type,
    body: ?Block = null,
    generic_params: []const GenericParam = &.{},
    /// Authored documentation for this declaration. Empty means absent.
    documentation: []const u8 = "",
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
    /// Authored documentation for this declaration. Empty means absent.
    documentation: []const u8 = "",
};

pub const VarDecl = struct {
    name: []const u8,
    is_pub: bool = true,
    is_mut: bool = true,
    ty: ?Type = null,
    init: Expr,
    /// Authored documentation for this declaration. Empty means absent.
    documentation: []const u8 = "",
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

    /// A Zig type named by an expression that evaluates to one. The inverse
    /// of `Expr.type_value`: where that carries a type into expression
    /// position, this carries the expression a type position needs, so a
    /// shape no other variant spells — a descriptor built from a generic
    /// call over a tagged payload — stays real nodes instead of source text
    /// hidden inside a `named`.
    expr: *const Expr,
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

/// A fixed-length array type: `[N]T`.
/// Lengths describe the output target, not translator-host storage.
pub const Array = struct {
    elem: *const Type,
    len: u64,
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
    /// A Zig error-set value, distinct from a member of a user identifier.
    error_tag: []const u8,
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
    break_expr: BreakExpr,
    continue_expr: ContinueExpr,
    /// The Zig `unreachable` keyword, for an exhaustive ordered match whose
    /// last prong is never reached. It is control flow, not an identifier.
    unreachable_: void,
    /// A Zig type used in expression position. A `type` alias whose spelled
    /// form no expression variant can carry — a C pointer, an optional, a
    /// nested tuple — is a type value, not source text to be re-emitted as an
    /// identifier. It renders, validates, and frees exactly like the `Type`
    /// it holds.
    type_value: Type,
};

/// A control exit from a loop or a labelled block.
pub const BreakExpr = struct {
    /// Value handed to the exit target. Null = exit carrying unit.
    value: ?*const Expr = null,
    /// Source label naming the target, or null for the innermost one.
    label: ?[]const u8 = null,
};

/// A restart of a loop.
pub const ContinueExpr = struct {
    /// Source label naming the loop to restart, or null for the innermost one.
    label: ?[]const u8 = null,
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
    range_pat: RangePattern,
};

/// A `lo..hi` or `lo..=hi` pattern, emitted as a Zig `switch` prong.
/// A null bound is unbounded on that side.
pub const RangePattern = struct {
    lo: ?Literal = null,
    hi: ?Literal = null,
    inclusive: bool = true,
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
    /// Target-side element count; independent of the translator's pointer width.
    len: u64,
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
    /// Payload bound by the `then` branch: `if (cond) |x| ...`. Zig captures
    /// whatever the condition evaluated to, so this one binding covers both a
    /// split optional and a split error union; null = no capture.
    then_capture: ?Capture = null,
    /// Payload bound by the `else` branch: `if (cond) |x| ... else |err| ...`.
    /// Only meaningful together with an `else_body`.
    else_capture: ?Capture = null,
};

pub const WhileExpr = struct {
    cond: *const Expr,
    continue_expr: ?*const Expr = null,
    /// Capture identifiers for `while (cond) |x| { body }`; null = no capture.
    captures: ?[]const []const u8 = null,
    body: Block,
    else_body: ?*const Expr = null,
    /// Source label on the loop itself. Zig labels a loop from outside, and a
    /// labelled exit names the loop, never its body block.
    label: ?[]const u8 = null,
};

pub const ForExpr = struct {
    inputs: []const Expr = &.{},
    captures: []const Capture = &.{},
    body: Block,
    else_body: ?*const Expr = null,
    /// Source label on the loop itself. Zig labels a loop from outside, and a
    /// labelled exit names the loop, never its body block.
    label: ?[]const u8 = null,

    /// Whether the body is unrolled at compile time. Zig spells this
    /// `inline for`, and it is the only way to bind a comptime-known value per
    /// element: `RustHashLayout.tuple` is `[]const type`, and a plain `for`
    /// binds each child at runtime, where it can no longer satisfy a
    /// `comptime` type parameter or name a field. False keeps the runtime
    /// meaning every source loop has, and is what a source `for` gets.
    is_inline: bool = false,
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
    DuplicatePatternBinding,
    LabelledDeclarationBody,
    InvalidPointerAlignment,
    InvalidIdentifier,
    ElseCaptureWithoutElseBody,
};

/// A name with no bytes spells no identifier. The whole slice is scanned
/// rather than its first byte read and the rest sliced: an index is a memory
/// access whose validity a caller-supplied string decides, and a validator
/// that faults on the way to reporting a bad name has reported nothing.
fn isIdentifier(name: []const u8) bool {
    for (name, 0..) |character, index| {
        const head_character = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            character == '_';
        const tail_character = head_character or
            (character >= '0' and character <= '9') or
            character == '-';
        if (!(if (index == 0) head_character else tail_character)) return false;
    }
    // Nothing above ran, so there is no name here for this to be the
    // identifier of, and an unnamed binding is not a valid one.
    return name.len != 0;
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

/// Names arrive from the lowerer unchecked, so the emptiness is rejected
/// here by name: an unnamed binding is no more an identifier than `0payload`
/// is, and both are the same error.
fn validateName(name: []const u8) ValidationError!void {
    if (name.len == 0) return error.InvalidIdentifier;
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

/// The name a `Type.named` or `Type.generic` carries is deliberately NOT held
/// to a bare identifier path: `emitType` writes it verbatim, and a strategy
/// hands back `[]const u8` and `std.AutoHashMap`, so a name is this AST's
/// carrier for a type the lowerer has already spelled in Zig's own grammar.
/// Rejecting a spelling here would refuse types this translator spells on
/// purpose, so the only name that is not a type at all is the one the emitter
/// maps to `anyopaque`, and that stays its own error.
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

/// A self-referential row has no finite shape to walk. `Type.expr` and
/// `Expr.type_value` are inverse pairs that can point at each other, so a
/// cyclic row would recurse until the stack gave out rather than report
/// anything. Every shape the lowerer writes nests far below this bound, so
/// what the guard turns away is a row that names itself and nothing else.
///
/// The bound is the IR's own `traversal_depth_max`, the same 256 the type
/// walkers in `ir/types.zig` stop at: one codebase, one depth bound, and a
/// row the IR already refuses to walk is refused here too rather than
/// walked twice under two disagreeing rules.
///
/// 64 was measured, not chosen. Every fixture in `test/crates` was translated
/// with the guard raised out of the way and the deepest `depth` reached was
/// recorded: `percent-encoding` peaks at 68, `itoa` at 27, `hex` at 21, and
/// `fnv` — the crate a 64 bound was blamed on — at 9. The deepest real crate
/// needs 68, so a bound under that refuses valid Rust, and 256 leaves the
/// measured maximum a factor of 3.7 clear of the bound while staying small
/// enough that a cyclic row still ends in this error rather than in the
/// stack: each of these frames is a few dozen bytes, so 256 levels is a
/// handful of kilobytes against a multi-megabyte stack.
const recursion_depth_limit: usize = 256;

fn validateType(ty: Type) ValidationError!void {
    return validateTypeAt(ty, 0);
}

fn validateTypeAt(ty: Type, depth: usize) ValidationError!void {
    if (depth >= recursion_depth_limit) return error.UnsupportedTranslationNode;
    switch (ty) {
        .prim, .any_opaque, .void_type => {},
        .ptr => |ptr| {
            if (ptr.alignment) |alignment| {
                if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
                    return error.InvalidPointerAlignment;
                }
            }
            try validateTypeAt(ptr.elem.*, depth + 1);
        },
        .slice => |slice| try validateTypeAt(slice.elem.*, depth + 1),
        .opt => |inner| try validateTypeAt(inner.*, depth + 1),
        .err_union => |err_union| {
            if (err_union.err_set) |err_set| try validateQualifiedName(err_set);
            try validateTypeAt(err_union.payload.*, depth + 1);
        },
        .projected => |projected| {
            try validateQualifiedName(projected.descriptor);
            try validateTypeAt(projected.receiver.*, depth + 1);
            try validateName(projected.member);
        },
        .named => |name| try validateTypeName(name),
        .generic => |generic| {
            try validateTypeName(generic.name);
            for (generic.params) |param| try validateTypeAt(param, depth + 1);
        },
        .array => |array| try validateTypeAt(array.elem.*, depth + 1),
        .array_expr => |array| {
            try validateTypeAt(array.elem.*, depth + 1);
            try validateExprAt(array.len.*, depth + 1);
        },
        .expr => |expr| try validateExprAt(expr.*, depth + 1),
        .tuple => |tuple| for (tuple) |item| try validateTypeAt(item, depth + 1),
        .fn_ptr => |function| {
            for (function.params) |param| try validateTypeAt(param, depth + 1);
            try validateTypeAt(function.ret.*, depth + 1);
        },
        .anon_struct => |anon| {
            for (anon.fields) |field| {
                try validateFieldName(field.name);
                try validateTypeAt(field.ty, depth + 1);
                if (field.default_val) |value| try validateExprAt(value.*, depth + 1);
            }
        },
    }
}

fn sameTypeSlice(left: []const Type, right: []const Type) bool {
    return sameTypeSliceAt(left, right, 0);
}

fn sameTypeSliceAt(left: []const Type, right: []const Type, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (left.len != right.len) return false;
    for (left, right) |left_type, right_type| {
        if (!sameTypeAt(left_type, right_type, depth + 1)) return false;
    }
    return true;
}

fn sameType(left: Type, right: Type) bool {
    return sameTypeAt(left, right, 0);
}

/// A cyclic pair compares unequal rather than recursing: a row that names
/// itself has no shape to decide, and the answer that keeps the walk finite
/// is the one that says the two are not the same thing.
fn sameTypeAt(left: Type, right: Type, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .prim => |left_primitive| left_primitive == right.prim,
        .ptr => |left_pointer| {
            const right_pointer = right.ptr;
            return left_pointer.is_const == right_pointer.is_const and
                left_pointer.is_allowzero == right_pointer.is_allowzero and
                left_pointer.alignment == right_pointer.alignment and
                left_pointer.size == right_pointer.size and
                sameTypeAt(left_pointer.elem.*, right_pointer.elem.*, depth + 1);
        },
        .slice => |left_slice| {
            const right_slice = right.slice;
            return left_slice.is_const == right_slice.is_const and
                sameTypeAt(left_slice.elem.*, right_slice.elem.*, depth + 1);
        },
        .opt => |left_inner| sameTypeAt(left_inner.*, right.opt.*, depth + 1),
        .err_union => |left_union| {
            const right_union = right.err_union;
            if (left_union.err_set == null or right_union.err_set == null) {
                if (left_union.err_set != null or right_union.err_set != null) return false;
            } else if (!std.mem.eql(u8, left_union.err_set.?, right_union.err_set.?)) {
                return false;
            }
            return sameTypeAt(left_union.payload.*, right_union.payload.*, depth + 1);
        },
        .projected => |left_projected| {
            const right_projected = right.projected;
            return std.mem.eql(u8, left_projected.descriptor, right_projected.descriptor) and
                std.mem.eql(u8, left_projected.member, right_projected.member) and
                sameTypeAt(left_projected.receiver.*, right_projected.receiver.*, depth + 1);
        },
        .named => |left_name| std.mem.eql(u8, left_name, right.named),
        .generic => |left_generic| {
            const right_generic = right.generic;
            return std.mem.eql(u8, left_generic.name, right_generic.name) and
                sameTypeSliceAt(left_generic.params, right_generic.params, depth + 1);
        },
        .array => |left_array| {
            const right_array = right.array;
            return left_array.len == right_array.len and
                sameTypeAt(left_array.elem.*, right_array.elem.*, depth + 1);
        },
        .array_expr => |left_array| {
            const right_array = right.array_expr;
            return sameTypeAt(left_array.elem.*, right_array.elem.*, depth + 1) and
                sameExprAt(left_array.len.*, right_array.len.*, depth + 1);
        },
        .expr => |left_expr| sameExprAt(left_expr.*, right.expr.*, depth + 1),
        .tuple => |left_tuple| sameTypeSliceAt(left_tuple, right.tuple, depth + 1),
        .fn_ptr => |function| sameTypeSliceAt(function.params, right.fn_ptr.params, depth + 1) and
            sameTypeAt(function.ret.*, right.fn_ptr.ret.*, depth + 1),
        .anon_struct => |left_struct| {
            const right_struct = right.anon_struct;
            if (left_struct.fields.len != right_struct.fields.len) return false;
            for (left_struct.fields, right_struct.fields) |left_field, right_field| {
                if (!std.mem.eql(u8, left_field.name, right_field.name) or
                    !sameTypeAt(left_field.ty, right_field.ty, depth + 1))
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
        .error_tag => |value| std.mem.eql(u8, value, right.error_tag),
        .null_lit, .undefined_lit => true,
    };
}

fn sameOptionalType(left: ?Type, right: ?Type) bool {
    return sameOptionalTypeAt(left, right, 0);
}

fn sameOptionalTypeAt(left: ?Type, right: ?Type, depth: usize) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameTypeAt(left.?, right.?, depth + 1);
}

fn sameOptionalExpr(left: ?*const Expr, right: ?*const Expr) bool {
    return sameOptionalExprAt(left, right, 0);
}

fn sameOptionalExprAt(left: ?*const Expr, right: ?*const Expr, depth: usize) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameExprAt(left.?.*, right.?.*, depth + 1);
}

fn sameOptionalString(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn sameOptionalLiteral(left: ?Literal, right: ?Literal) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameLiteral(left.?, right.?);
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
    return sameExprSliceAt(left, right, 0);
}

fn sameExprSliceAt(left: []const Expr, right: []const Expr, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (left.len != right.len) return false;
    for (left, right) |left_expr, right_expr| {
        if (!sameExprAt(left_expr, right_expr, depth + 1)) return false;
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
    return sameStructInitFieldSliceAt(left, right, 0);
}

fn sameStructInitFieldSliceAt(
    left: []const StructInitField,
    right: []const StructInitField,
    depth: usize,
) bool {
    if (depth >= recursion_depth_limit) return false;
    if (left.len != right.len) return false;
    for (left, right) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field.name, right_field.name)) return false;
        if (!sameExprAt(left_field.expr, right_field.expr, depth + 1)) return false;
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
        .range_pat => |range_pattern| {
            const other = right.range_pat;
            return range_pattern.inclusive == other.inclusive and
                sameOptionalLiteral(range_pattern.lo, other.lo) and
                sameOptionalLiteral(range_pattern.hi, other.hi);
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
    return sameMatchArmSliceAt(left, right, 0);
}

fn sameMatchArmSliceAt(left: []const MatchArm, right: []const MatchArm, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (left.len != right.len) return false;
    for (left, right) |left_arm, right_arm| {
        if (!samePatternSlice(left_arm.patterns, right_arm.patterns)) return false;
        if (left_arm.capture == null or right_arm.capture == null) {
            if (left_arm.capture != null or right_arm.capture != null) return false;
        } else if (!sameOptionalCapture(left_arm.capture, right_arm.capture)) {
            return false;
        }
        if (!sameExprAt(left_arm.body, right_arm.body, depth + 1)) return false;
    }
    return true;
}

fn sameOptionalCapture(left: ?Capture, right: ?Capture) bool {
    if (left == null or right == null) return left == null and right == null;
    return sameCapture(left.?, right.?);
}

fn sameStmt(left: Stmt, right: Stmt) bool {
    return sameStmtAt(left, right, 0);
}

fn sameStmtAt(left: Stmt, right: Stmt, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .let_stmt => |left_let| {
            const right_let = right.let_stmt;
            return std.mem.eql(u8, left_let.name, right_let.name) and
                sameOptionalTypeAt(left_let.ty, right_let.ty, depth + 1) and
                sameExprAt(left_let.init, right_let.init, depth + 1) and
                left_let.is_mut == right_let.is_mut;
        },
        .assign => |left_assign| {
            const right_assign = right.assign;
            return sameExprAt(left_assign.target, right_assign.target, depth + 1) and
                sameExprAt(left_assign.val, right_assign.val, depth + 1) and
                left_assign.op == right_assign.op;
        },
        .defer_stmt => |left_defer| {
            const right_defer = right.defer_stmt;
            return sameExprAt(left_defer.expr, right_defer.expr, depth + 1) and
                left_defer.is_errdefer == right_defer.is_errdefer;
        },
        .expr_stmt => |left_expr| sameExprAt(left_expr.*, right.expr_stmt.*, depth + 1),
    };
}

fn sameStmtSlice(left: []const Stmt, right: []const Stmt) bool {
    return sameStmtSliceAt(left, right, 0);
}

fn sameStmtSliceAt(left: []const Stmt, right: []const Stmt, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (left.len != right.len) return false;
    for (left, right) |left_stmt, right_stmt| {
        if (!sameStmtAt(left_stmt, right_stmt, depth + 1)) return false;
    }
    return true;
}

fn sameBlock(left: Block, right: Block) bool {
    return sameBlockAt(left, right, 0);
}

fn sameBlockAt(left: Block, right: Block, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    return sameOptionalString(left.label, right.label) and
        sameStmtSliceAt(left.stmts, right.stmts, depth + 1) and
        sameOptionalExprAt(left.expr, right.expr, depth + 1);
}

fn sameExpr(left: Expr, right: Expr) bool {
    return sameExprAt(left, right, 0);
}

fn sameExprAt(left: Expr, right: Expr, depth: usize) bool {
    if (depth >= recursion_depth_limit) return false;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .lit => |literal| sameLiteral(literal, right.lit),
        .unit => true,
        .ident => |name| std.mem.eql(u8, name, right.ident),
        .field_access => |field_access| {
            const other = right.field_access;
            return std.mem.eql(u8, field_access.field_name, other.field_name) and
                sameExprAt(field_access.target.*, other.target.*, depth + 1);
        },
        .call => |call| {
            const other = right.call;
            return sameExprAt(call.callee.*, other.callee.*, depth + 1) and
                sameTypeSliceAt(call.generic_args, other.generic_args, depth + 1) and
                sameExprSliceAt(call.args, other.args, depth + 1);
        },
        .block => |block| sameBlockAt(block, right.block, depth + 1),
        .match_expr => |match| {
            const other = right.match_expr;
            return sameExprAt(match.target.*, other.target.*, depth + 1) and
                sameMatchArmSliceAt(match.arms, other.arms, depth + 1);
        },
        .bin_op => |binary| {
            const other = right.bin_op;
            return binary.op == other.op and
                sameExprAt(binary.lhs.*, other.lhs.*, depth + 1) and
                sameExprAt(binary.rhs.*, other.rhs.*, depth + 1);
        },
        .unary_op => |unary| {
            const other = right.unary_op;
            return unary.op == other.op and
                sameExprAt(unary.operand.*, other.operand.*, depth + 1);
        },
        .cast => |cast| {
            const other = right.cast;
            return sameTypeAt(cast.target, other.target, depth + 1) and
                sameOptionalTypeAt(cast.source, other.source, depth + 1) and
                sameExprAt(cast.operand.*, other.operand.*, depth + 1);
        },
        .struct_init => |struct_init| {
            const other = right.struct_init;
            return sameOptionalTypeAt(struct_init.type_name, other.type_name, depth + 1) and
                sameStructInitFieldSliceAt(struct_init.fields, other.fields, depth + 1);
        },
        .array_init => |array_init| {
            const other = right.array_init;
            return sameOptionalTypeAt(array_init.type_name, other.type_name, depth + 1) and
                sameExprSliceAt(array_init.elements, other.elements, depth + 1);
        },
        .repeat => |repeat| {
            const other = right.repeat;
            return sameOptionalTypeAt(repeat.type_name, other.type_name, depth + 1) and
                sameExprAt(repeat.elem.*, other.elem.*, depth + 1) and repeat.len == other.len;
        },
        .multi_array => |multi_array| {
            const other = right.multi_array;
            return sameOptionalTypeAt(multi_array.type_name, other.type_name, depth + 1) and
                sameExprSliceAt(multi_array.elements, other.elements, depth + 1);
        },
        .tuple => |elements| sameExprSliceAt(elements, right.tuple, depth + 1),
        .builtin => |builtin| {
            const other = right.builtin;
            return std.mem.eql(u8, builtin.name, other.name) and
                sameExprSliceAt(builtin.args, other.args, depth + 1);
        },
        .panic_ => |message| std.mem.eql(u8, message, right.panic_),
        .unsupported => |message| std.mem.eql(u8, message, right.unsupported),
        .if_expr => |if_expr| {
            const other = right.if_expr;
            return sameExprAt(if_expr.cond.*, other.cond.*, depth + 1) and
                sameOptionalCapture(if_expr.then_capture, other.then_capture) and
                sameExprAt(if_expr.then_body.*, other.then_body.*, depth + 1) and
                sameOptionalExprAt(if_expr.else_body, other.else_body, depth + 1) and
                sameOptionalCapture(if_expr.else_capture, other.else_capture);
        },
        .while_expr => |while_expr| {
            const other = right.while_expr;
            return sameExprAt(while_expr.cond.*, other.cond.*, depth + 1) and
                sameOptionalExprAt(while_expr.continue_expr, other.continue_expr, depth + 1) and
                sameOptionalStringSlice(while_expr.captures, other.captures) and
                sameBlockAt(while_expr.body, other.body, depth + 1) and
                sameOptionalExprAt(while_expr.else_body, other.else_body, depth + 1) and
                sameOptionalString(while_expr.label, other.label);
        },
        .for_expr => |for_expr| {
            const other = right.for_expr;
            // The flag decides whether the body is unrolled at comptime or run
            // per element at runtime, so two loops that differ only in it
            // compile to different Zig and are not the same expression. This
            // is the same treatment `Capture.by_ref` gets.
            return for_expr.is_inline == other.is_inline and
                sameExprSliceAt(for_expr.inputs, other.inputs, depth + 1) and
                sameCaptureSlice(for_expr.captures, other.captures) and
                sameBlockAt(for_expr.body, other.body, depth + 1) and
                sameOptionalExprAt(for_expr.else_body, other.else_body, depth + 1) and
                sameOptionalString(for_expr.label, other.label);
        },
        .range => |range| {
            const other = right.range;
            return sameExprAt(range.start.*, other.start.*, depth + 1) and
                sameOptionalExprAt(range.end, other.end, depth + 1);
        },
        .return_expr => |value| sameOptionalExprAt(value, right.return_expr, depth + 1),
        .break_expr => |break_expr| {
            const other = right.break_expr;
            return sameOptionalExprAt(break_expr.value, other.value, depth + 1) and
                sameOptionalString(break_expr.label, other.label);
        },
        .continue_expr => |continue_expr| sameOptionalString(continue_expr.label, right.continue_expr.label),
        .unreachable_ => true,
        .type_value => |ty| sameTypeAt(ty, right.type_value, depth + 1),
    };
}

/// A raw-pointer cast reinterprets one address under a different pointee; it
/// never allocates or narrows. `lowerType` spells thin raw pointers
/// `[*]allowzero align(1) T`, so neither side can raise alignment and the
/// `@ptrCast` around the operand is legal at any pointee width.
///
/// The one combination Zig refuses is a change of pointer *width*: a pointer
/// to an unsized type is fat, and a thin pointer cannot `@ptrCast` into one
/// (`cannot infer length of slice from many pointer`).
///
/// This mirrors `lower.pointerPointeesCompatible`, which admits exactly the
/// same casts. The two must stay in step: this one runs at emit time, so a
/// cast admitted by the lowerer and refused here would translate to a
/// validation failure instead of source.
fn pointerPointeeIsSized(pointee: Type) bool {
    return switch (pointee) {
        .slice => false,
        // An expression type is opaque here: nothing in the AST says what
        // type it evaluates to, and one that turns out to be unsized makes
        // the pointer fat, which is the shape Zig refuses to `@ptrCast`
        // into. Reporting "not known to be sized" refuses the cast here, at
        // validation, instead of emitting source that may not compile. No
        // pointee's size or provenance is guessed to admit one.
        .expr => false,
        else => true,
    };
}

fn pointerPointeesCompatible(source: Type, target: Type) bool {
    return pointerPointeeIsSized(source) and pointerPointeeIsSized(target);
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
        // A range prong can only ever be a range: it binds nothing.
        .range_pat => false,
    };
}

fn matchArmContainsBinding(arm: MatchArm) bool {
    for (arm.patterns) |pattern| {
        if (patternContainsBinding(pattern)) return true;
    }
    return false;
}

/// True when `pattern` introduces `name` as a binding, at any depth.
fn patternBindsName(pattern: Pattern, name: []const u8) bool {
    return switch (pattern) {
        .wildcard, .lit, .enum_literal, .range_pat => false,
        .binding => |bound| std.mem.eql(u8, bound, name),
        .tuple => |patterns| for (patterns) |child| {
            if (patternBindsName(child, name)) return true;
        } else false,
        .struct_pat => |struct_pattern| for (struct_pattern.fields) |field| {
            if (patternBindsName(field.pat, name)) return true;
        } else false,
    };
}

/// True when `outer` and `inner` — two parts of ONE pattern — introduce the
/// same binding name.
fn patternsShareBindingName(outer: Pattern, inner: Pattern) bool {
    return switch (inner) {
        .wildcard, .lit, .enum_literal, .range_pat => false,
        .binding => |name| patternBindsName(outer, name),
        .tuple => |patterns| for (patterns) |child| {
            if (patternsShareBindingName(outer, child)) return true;
        } else false,
        .struct_pat => |struct_pattern| for (struct_pattern.fields) |field| {
            if (patternsShareBindingName(outer, field.pat)) return true;
        } else false,
    };
}

/// Two parts of one pattern that bind the same name.
///
/// Zig reads a pattern's bindings as DECLARATIONS in the single scope the
/// destructure writes them into: `emitMatchDestructureBody` writes one `const`
/// per binding, and they all land side by side in the arm's own block. Two
/// fields of one struct pattern — or two elements of one tuple pattern — that
/// bind the same name are therefore two `const` declarations of one name in
/// one scope, which is a redefinition the Zig compiler refuses. The parts are
/// compared pairwise rather than collected, so the check allocates nothing and
/// runs at every depth a nested pattern reaches.
fn patternBindsSameNameTwice(patterns: []const Pattern) bool {
    for (patterns, 0..) |pattern, index| {
        for (patterns[0..index]) |prior| {
            if (patternsShareBindingName(prior, pattern)) return true;
        }
    }
    return false;
}

fn structPatternBindsSameNameTwice(fields: []const StructPatternField) bool {
    for (fields, 0..) |field, index| {
        for (fields[0..index]) |prior| {
            if (patternsShareBindingName(prior.pat, field.pat)) return true;
        }
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
        .tuple => |patterns| {
            if (patternBindsSameNameTwice(patterns)) return error.DuplicatePatternBinding;
            for (patterns) |item| try validatePattern(item);
        },
        .struct_pat => |struct_pat| {
            const name = struct_pat.name orelse return error.UnnamedMatchSelector;
            if (name.len == 0) return error.UnnamedMatchSelector;
            try validateName(name);
            if (structPatternBindsSameNameTwice(struct_pat.fields)) {
                return error.DuplicatePatternBinding;
            }
            // The per-field destructure reaches each field as `payload.<name>`
            // and declares it as `const <binding>`, so a field name has to be
            // one Zig reads as a field. A name that opens with a digit is a
            // tuple POSITION, which Zig spells `payload[0]`; there is no
            // spelling of that here. The single positional `0` is the one
            // exception the emitter itself makes: a pattern of exactly that
            // shape is never read field-wise, because it takes the direct
            // capture route instead.
            for (struct_pat.fields) |field| {
                if (!(struct_pat.fields.len == 1 and std.mem.eql(u8, field.name, "0"))) {
                    try validateName(field.name);
                }
                try validatePattern(field.pat);
            }
        },
        .range_pat => |range_pat| {
            // A range with neither bound is a catch-all, which must be spelled
            // `_` so the match keeps an explicit fallback prong.
            if (range_pat.lo == null and range_pat.hi == null) return error.UnnamedMatchSelector;
            if (range_pat.lo) |lo| try validateLiteral(lo);
            if (range_pat.hi) |hi| try validateLiteral(hi);
        },
    }
}

/// Statements and optional value of one translated block.
///
/// An empty block is legal: a Rust `for _ in xs {}` has no statements to
/// translate and emits `{}`. Emptiness only means "nothing was translated"
/// where the block IS the translation of a body the source requires — a
/// function body, a test body, or an arm that owes a value — and those checks
/// live where that position is known.
fn validateBlock(block: Block) ValidationError!void {
    return validateBlockAt(block, 0);
}

fn validateBlockAt(block: Block, depth: usize) ValidationError!void {
    if (depth >= recursion_depth_limit) return error.UnsupportedTranslationNode;
    if (block.label) |label| try validateName(label);
    for (block.stmts) |stmt| {
        switch (stmt) {
            .let_stmt => |let_stmt| {
                try validateName(let_stmt.name);
                if (let_stmt.ty) |ty| try validateTypeAt(ty, depth + 1);
                try validateExprAt(let_stmt.init, depth + 1);
            },
            .assign => |assign| {
                // `_` is a discard: it names no binding, so Zig spells it with
                // `=` and nothing else. `_ = expr;` is a real shape the emitter
                // writes for an unread binding (`unusedBindingAsDiscard`), but
                // there is no `_ += expr;` in the language, so a compound op on
                // a discard target describes a statement that cannot be written.
                if (assign.op != .assign and assign.target == .ident and
                    std.mem.eql(u8, assign.target.ident, "_"))
                {
                    return error.UnsupportedTranslationNode;
                }
                try validateExprAt(assign.target, depth + 1);
                try validateExprAt(assign.val, depth + 1);
            },
            .defer_stmt => |defer_stmt| try validateExprAt(defer_stmt.expr, depth + 1),
            .expr_stmt => |expr| try validateExprAt(expr.*, depth + 1),
        }
    }
    if (block.expr) |expr| try validateExprAt(expr.*, depth + 1);
}

fn validateExpr(expr: Expr) ValidationError!void {
    return validateExprAt(expr, 0);
}

fn validateExprAt(expr: Expr, depth: usize) ValidationError!void {
    if (depth >= recursion_depth_limit) return error.UnsupportedTranslationNode;
    switch (expr) {
        .lit => |literal| try validateLiteral(literal),
        .ident => |name| try validateQualifiedName(name),
        .field_access => |field_access| {
            try validateExprAt(field_access.target.*, depth + 1);
            try validateFieldName(field_access.field_name);
        },
        .call => |call| {
            try validateExprAt(call.callee.*, depth + 1);
            for (call.generic_args) |arg| try validateTypeAt(arg, depth + 1);
            for (call.args) |arg| try validateExprAt(arg, depth + 1);
        },
        .block => |block| try validateBlockAt(block, depth + 1),
        .match_expr => |match| {
            try validateExprAt(match.target.*, depth + 1);
            if (match.arms.len == 0) return error.EmptyTranslatedBody;
            for (match.arms) |arm| {
                if (arm.patterns.len == 0) return error.UnnamedMatchSelector;
                for (arm.patterns) |pattern| try validatePattern(pattern);
                if (arm.capture) |capture| {
                    try validateName(capture.name);
                    if (matchArmContainsBinding(arm)) return error.AmbiguousMatchCapture;
                }
                try validateExprAt(arm.body, depth + 1);
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
                    try validateTypeAt(source, depth + 1);
                    try validateTypeAt(cast.target, depth + 1);
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
                    if (!sameTypeAt(source_element.*, target_slice.elem.*, depth + 1))
                        return error.UnsupportedTranslationNode;
                    try validateTypeAt(source, depth + 1);
                    try validateTypeAt(cast.target, depth + 1);
                },
                .named, .opt => try validateTypeAt(cast.target, depth + 1),
                else => return error.UnsupportedTranslationNode,
            }
            try validateExprAt(cast.operand.*, depth + 1);
        },
        .bin_op => |bin_op| {
            try validateExprAt(bin_op.lhs.*, depth + 1);
            try validateExprAt(bin_op.rhs.*, depth + 1);
        },
        .unary_op => |unary_op| try validateExprAt(unary_op.operand.*, depth + 1),
        .struct_init => |struct_init| {
            // A null type name is a Zig anonymous struct literal, which the
            // emitter writes as `.{ .field = .. }`. That is required, not
            // accidental, when the literal is the payload of a tagged union
            // field declared with named fields: the field's type IS an
            // anonymous struct, so the payload must be one too.
            if (struct_init.type_name) |type_name| try validateTypeAt(type_name, depth + 1);
            for (struct_init.fields) |field| {
                try validateFieldName(field.name);
                try validateExprAt(field.expr, depth + 1);
            }
        },
        .array_init => |array_init| {
            if (array_init.type_name == null) return error.MissingTypedLiteralIdentity;
            if (array_init.type_name) |type_name| try validateTypeAt(type_name, depth + 1);
            for (array_init.elements) |element| try validateExprAt(element, depth + 1);
        },
        .repeat => |repeat| {
            if (repeat.type_name == null) return error.MissingTypedLiteralIdentity;
            if (repeat.type_name) |type_name| try validateTypeAt(type_name, depth + 1);
            try validateExprAt(repeat.elem.*, depth + 1);
        },
        .multi_array => |multi_array| {
            if (multi_array.type_name == null) return error.MissingTypedLiteralIdentity;
            if (multi_array.type_name) |type_name| try validateTypeAt(type_name, depth + 1);
            for (multi_array.elements) |element| try validateExprAt(element, depth + 1);
        },
        .tuple => |elements| for (elements) |element| try validateExprAt(element, depth + 1),
        .builtin => |builtin| {
            try validateQualifiedName(builtin.name);
            for (builtin.args) |arg| try validateExprAt(arg, depth + 1);
        },
        .unit, .panic_ => {},
        .unsupported => return error.UnsupportedTranslationNode,
        .if_expr => |if_expr| {
            try validateExprAt(if_expr.cond.*, depth + 1);
            if (if_expr.then_capture) |capture| try validateName(capture.name);
            try validateExprAt(if_expr.then_body.*, depth + 1);
            if (if_expr.else_body) |else_body| {
                if (if_expr.else_capture) |capture| try validateName(capture.name);
                try validateExprAt(else_body.*, depth + 1);
            } else if (if_expr.else_capture != null) {
                // An else payload reads the branch that is not there, so the
                // AST cannot describe it as anything but a missing branch.
                return error.ElseCaptureWithoutElseBody;
            }
        },
        .while_expr => |while_expr| {
            try validateExprAt(while_expr.cond.*, depth + 1);
            if (while_expr.continue_expr) |continue_expr| try validateExprAt(continue_expr.*, depth + 1);
            if (while_expr.captures) |captures| for (captures) |capture| try validateName(capture);
            try validateBlockAt(while_expr.body, depth + 1);
            if (while_expr.else_body) |else_body| try validateExprAt(else_body.*, depth + 1);
            if (while_expr.label) |label| try validateName(label);
        },
        .for_expr => |for_expr| {
            if (for_expr.inputs.len == 0 or for_expr.captures.len == 0) {
                return error.EmptyTranslatedBody;
            }
            for (for_expr.inputs) |input| try validateExprAt(input, depth + 1);
            for (for_expr.captures) |capture| try validateName(capture.name);
            try validateBlockAt(for_expr.body, depth + 1);
            if (for_expr.else_body) |else_body| try validateExprAt(else_body.*, depth + 1);
            if (for_expr.label) |label| try validateName(label);
        },
        .range => |range| {
            try validateExprAt(range.start.*, depth + 1);
            if (range.end) |end| try validateExprAt(end.*, depth + 1);
        },
        .return_expr => |value| if (value) |expr_ptr| try validateExprAt(expr_ptr.*, depth + 1),
        .break_expr => |break_expr| {
            if (break_expr.value) |expr_ptr| try validateExprAt(expr_ptr.*, depth + 1);
            if (break_expr.label) |label| try validateName(label);
        },
        .continue_expr => |continue_expr| {
            if (continue_expr.label) |label| try validateName(label);
        },
        .unreachable_ => {},
        .type_value => |ty| try validateTypeAt(ty, depth + 1),
    }
}

fn validateTraitDescriptor(descriptor: TraitDescriptorDecl) ValidationError!void {
    return validateTraitDescriptorAt(descriptor, 0);
}

fn validateTraitDescriptorAt(
    descriptor: TraitDescriptorDecl,
    depth: usize,
) ValidationError!void {
    if (depth >= recursion_depth_limit) return error.UnsupportedTranslationNode;
    try validateName(descriptor.name);
    if (descriptor.cases.len == 0) return error.EmptyTranslatedContainer;
    for (descriptor.cases, 0..) |case, case_index| {
        try validateTypeAt(case.receiver, depth + 1);
        if (case.members.len == 0) return error.EmptyTranslatedContainer;
        for (descriptor.cases[0..case_index]) |prior| {
            if (sameTypeAt(prior.receiver, case.receiver, depth + 1)) {
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
                .type_ => |value| try validateTypeAt(value.ty, depth + 1),
                .const_ => |value| try validateExprAt(value.value, depth + 1),
            }
        }
    }
}

/// A declaration's body is not a block EXPRESSION, so no emitter can label
/// it: `emitFnDecl` writes `fn …(…) T {` and `emitFile` writes
/// `test "…" {`, and neither has a slot for a `label: ` prefix. A label that
/// arrives on one is therefore silently dropped while every `break :label`
/// inside the body still carries it — and the emitted file then names a block
/// label that is not there, which the Zig compiler refuses.
///
/// The shape that produces this is real and not hypothetical: `lowerBlock`
/// flattens a labelled block used as a block's tail into the block that holds
/// it and hands the label over with it, so the body of a function whose tail
/// was a guarded-match chain comes back carrying that chain's label. Nothing
/// else in the body is lost by dropping the label — the chain keeps its own
/// labelled block wherever it is written — so refusing it here loses no
/// translation and stops the one that would not compile.
fn validateUnlabelledBody(body: Block) ValidationError!void {
    if (body.label != null) return error.LabelledDeclarationBody;
}

fn validateDecl(decl: Decl) ValidationError!void {
    return validateDeclAt(decl, 0);
}

fn validateDeclAt(decl: Decl, depth: usize) ValidationError!void {
    if (depth >= recursion_depth_limit) return error.UnsupportedTranslationNode;
    switch (decl) {
        .trait_descriptor => |descriptor| try validateTraitDescriptorAt(descriptor, depth + 1),
        .comment => {},
        .const_decl => |const_decl| {
            try validateName(const_decl.name);
            if (const_decl.ty) |ty| try validateTypeAt(ty, depth + 1);
            try validateExprAt(const_decl.init, depth + 1);
        },
        .var_decl => |var_decl| {
            try validateName(var_decl.name);
            if (var_decl.ty) |ty| try validateTypeAt(ty, depth + 1);
            try validateExprAt(var_decl.init, depth + 1);
        },
        .fn_decl => |fn_decl| {
            try validateName(fn_decl.name);
            if (fn_decl.body == null) return error.EmptyTranslatedFunction;
            if (fn_decl.body.?.stmts.len == 0 and fn_decl.body.?.expr == null) {
                return error.EmptyTranslatedBody;
            }
            try validateUnlabelledBody(fn_decl.body.?);
            for (fn_decl.params) |param| {
                try validateName(param.name);
                try validateTypeAt(param.ty, depth + 1);
            }
            for (fn_decl.generic_params) |param| {
                try validateName(param.name);
                if (param.ty) |ty| try validateTypeAt(ty, depth + 1);
            }
            try validateTypeAt(fn_decl.ret_type, depth + 1);
            try validateBlockAt(fn_decl.body.?, depth + 1);
        },
        .struct_decl => |struct_decl| {
            try validateName(struct_decl.name);
            if (struct_decl.fields.len == 0 and struct_decl.decls.len == 0) {
                return error.EmptyTranslatedContainer;
            }
            for (struct_decl.fields) |field| {
                try validateFieldName(field.name);
                try validateTypeAt(field.ty, depth + 1);
                if (field.default_val) |value| try validateExprAt(value.*, depth + 1);
            }
            for (struct_decl.generic_params) |param| {
                try validateName(param.name);
                if (param.ty) |ty| try validateTypeAt(ty, depth + 1);
            }
            for (struct_decl.decls) |inner| try validateDeclAt(inner, depth + 1);
        },
        .enum_decl => |enum_decl| {
            try validateName(enum_decl.name);
            if (enum_decl.variants.len == 0 and enum_decl.decls.len == 0) {
                return error.EmptyTranslatedContainer;
            }
            if (enum_decl.tag_type) |tag_type| try validateTypeAt(tag_type, depth + 1);
            for (enum_decl.variants) |variant| {
                try validateName(variant.name);
                if (variant.value) |value| try validateExprAt(value.*, depth + 1);
            }
            for (enum_decl.decls) |inner| try validateDeclAt(inner, depth + 1);
        },
        .union_decl => |union_decl| {
            try validateName(union_decl.name);
            if (union_decl.fields.len == 0 and union_decl.decls.len == 0) {
                return error.EmptyTranslatedContainer;
            }
            if (union_decl.tag_type) |tag_type| try validateTypeAt(tag_type, depth + 1);
            for (union_decl.fields) |field| {
                try validateName(field.name);
                try validateTypeAt(field.ty, depth + 1);
            }
            for (union_decl.decls) |inner| try validateDeclAt(inner, depth + 1);
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
        // A test with no body translated is a test that was never lowered;
        // an empty loop body is not, which is why the check is here and not in
        // `validateBlock`.
        if (test_decl.body.stmts.len == 0 and test_decl.body.expr == null) {
            return error.EmptyTranslatedBody;
        }
        try validateUnlabelledBody(test_decl.body);
        try validateBlock(test_decl.body);
    }
}

/// Structural validation for a package on its way to disk or to promotion.
///
/// What has to hold is the package's shape: exactly one `src/root.zig`, unique
/// file paths, a fingerprint, resolvable dependency names, and bodies that
/// were actually translated. How much the root declares is not part of that
/// shape. A crate whose every module sits behind an opt-in feature — as
/// `xxhash-rust` does, with no `default` feature at all — translates to a root
/// that declares nothing, and a module that declares nothing is the faithful
/// image of that crate rather than a hole in the translation.
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
        .tests = &.{.{ .name = "test", .body = .{ .expr = &Expr{ .continue_expr = .{} } } }},
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
        .arms = &.{.{ .patterns = &.{.{ .struct_pat = .{} }}, .body = .{ .continue_expr = .{} } }},
    } };
    try std.testing.expectError(error.UnnamedMatchSelector, validateExpr(unnamed_match));

    // An anonymous struct literal is valid, not a missing identity: it is how a
    // named-field enum variant payload reaches Zig.
    const anonymous_payload: Expr = .{ .struct_init = .{
        .fields = &.{.{ .name = "value", .expr = .{ .lit = .{ .int = 1 } } }},
    } };
    try validateExpr(anonymous_payload);

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

test "ast validation: a conditional payload needs the branch it binds" {
    const captured: Expr = .{ .if_expr = .{
        .cond = &Expr{ .ident = "maybe" },
        .then_capture = .{ .name = "ok" },
        .then_body = &Expr{ .ident = "ok" },
        .else_body = &Expr{ .ident = "fallback" },
        .else_capture = .{ .name = "tag", .by_ref = true },
    } };
    try validateExpr(captured);

    // An else payload reads the branch it belongs to, so a conditional
    // without one cannot describe what that payload would bind.
    const orphan_else_capture: Expr = .{ .if_expr = .{
        .cond = &Expr{ .ident = "maybe" },
        .then_body = &Expr{ .ident = "ok" },
        .else_capture = .{ .name = "tag" },
    } };
    try std.testing.expectError(
        error.ElseCaptureWithoutElseBody,
        validateExpr(orphan_else_capture),
    );

    for ([_][]const u8{ "", "0tag", "tag*" }) |name| {
        const malformed: Expr = .{ .if_expr = .{
            .cond = &Expr{ .ident = "maybe" },
            .then_capture = .{ .name = name },
            .then_body = &Expr{ .ident = "ok" },
        } };
        try std.testing.expectError(error.InvalidIdentifier, validateExpr(malformed));
    }
}

test "ast validation: an unnamed conditional payload is a name error, not a read past the name" {
    // A conditional payload whose binding was never named leaves an empty
    // name in the capture. It has to come back as the name error it is: the
    // bytes of the name are read to classify them, and a name with none has
    // no byte to classify.
    const unnamed_then_capture: Expr = .{ .if_expr = .{
        .cond = &Expr{ .ident = "maybe" },
        .then_capture = .{ .name = "" },
        .then_body = &Expr{ .unit = {} },
    } };
    try std.testing.expectError(error.InvalidIdentifier, validateExpr(unnamed_then_capture));

    const unnamed_else_capture: Expr = .{ .if_expr = .{
        .cond = &Expr{ .ident = "maybe" },
        .then_body = &Expr{ .unit = {} },
        .else_body = &Expr{ .unit = {} },
        .else_capture = .{ .name = "" },
    } };
    try std.testing.expectError(error.InvalidIdentifier, validateExpr(unnamed_else_capture));

    // The same conditional with both payloads named is the shape that has to
    // keep validating, so what the two above reject is the name and not the
    // capture.
    const named_captures: Expr = .{ .if_expr = .{
        .cond = &Expr{ .ident = "maybe" },
        .then_capture = .{ .name = "ok" },
        .then_body = &Expr{ .ident = "ok" },
        .else_body = &Expr{ .ident = "fallback" },
        .else_capture = .{ .name = "tag" },
    } };
    try validateExpr(named_captures);
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

// A raw-pointer cast reinterprets the address, so the pointee width is free
// to change. `utils.rs` in xxhash-rust casts a `*const u8` cursor to the
// caller's `*const T`, where `T` is a generic parameter; both sides lower to
// `[*]align(1) …`, so this must validate. A slice pointee is fat and must not.
// This is the emit-time half of the pair guarded by
// `lower.pointerPointeesCompatible`; both must admit the same casts.
test "pointer casts reinterpret across pointee widths but not into a fat pointer" {
    const byte: Type = .{ .prim = .u8 };
    const word: Type = .{ .prim = .u32 };
    const fat: Type = .{ .slice = .{ .elem = &byte, .is_const = true } };
    const operand: Expr = .{ .builtin = .{
        .name = "ptrCast",
        .args = &.{.{ .ident = "cursor" }},
    } };

    // A generic parameter lowers to a bare name, not a primitive.
    const type_param: Type = .{ .named = "T" };
    var expression: Expr = .{ .cast = .{
        .target = .{ .ptr = .{
            .elem = &type_param,
            .size = .many,
            .is_const = true,
            .alignment = 1,
        } },
        .source = .{ .ptr = .{ .elem = &byte, .size = .many, .is_const = true, .alignment = 1 } },
        .operand = &operand,
    } };
    try validateExpr(expression);

    // Widening the pointee to a wider scalar is still a reinterpret.
    expression.cast.target.ptr.elem = &word;
    try validateExpr(expression);

    // Widening it to an unsized type is not: that pointer is fat.
    expression.cast.target.ptr.elem = &fat;
    try std.testing.expectError(error.UnsupportedTranslationNode, validateExpr(expression));
}

// A thin source is not a reinterpret. Zig's `@ptrCast` may widen a single
// pointer to a many pointer only when the pointee is an array, because only
// then is the length a comptime-known fact the runtime can rely on; for any
// other pointee the cast does not compile. `lower`'s `pointerPointeesCompatible`
// compares pointee SIZEDNESS only and its call site passes `.pointee` on both
// sides, so a thin source slips past there. This half is deliberately the
// stricter one: the emitted file is what has to compile.
test "pointer casts refuse a thin source: only an array pointee has a known length" {
    const byte: Type = .{ .prim = .u8 };
    const operand: Expr = .{ .builtin = .{
        .name = "ptrCast",
        .args = &.{.{ .ident = "cursor" }},
    } };
    const expression: Expr = .{ .cast = .{
        .target = .{ .ptr = .{
            .elem = &byte,
            .size = .many,
            .is_const = true,
            .alignment = 1,
        } },
        .source = .{ .ptr = .{ .elem = &byte, .size = .one, .is_const = true, .alignment = 1 } },
        .operand = &operand,
    } };
    try std.testing.expectError(error.UnsupportedTranslationNode, validateExpr(expression));
}

test "ast validation: accepts a declared root that has no translated tests" {
    // `test/crates/mini` is testless yet complete: it declares
    // `pub const util` and `pub const helper`. Zero tests must not be
    // mistaken for zero declarations.
    const declared_root: File = .{
        .path = "src/root.zig",
        .decls = &.{
            .{ .const_decl = .{ .name = "util", .init = Expr{ .lit = .{ .int = 1 } } } },
            .{ .const_decl = .{ .name = "helper", .init = Expr{ .lit = .{ .int = 2 } } } },
        },
    };
    try validateForTranslation(&.{
        .name = "testless_crate",
        .fingerprint = 0xabcd,
        .files = &.{declared_root},
    });

    // One declaration is a whole package as far as the shape goes: this reads
    // structure, and structure has no opinion about how much a root declares.
    try validateForTranslation(&.{
        .name = "single_decl_crate",
        .fingerprint = 0xbcde,
        .files = &.{.{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
            .name = "run",
            .ret_type = .{ .void_type = {} },
            .body = .{ .expr = &Expr{ .continue_expr = .{} } },
        } }} }},
    });
}

test "ast validation: a type value is validated as the type it carries" {
    const byte: Type = .{ .prim = .u8 };

    // `[*]align(3) u8` is not a Zig type, and the value that spells it must
    // be rejected for the same reason a declared pointer would be: the type
    // travels through `validateType`, not past it.
    const misaligned: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "Skewed",
            .init = Expr{ .type_value = .{ .ptr = .{
                .elem = &byte,
                .alignment = 3,
            } } },
        } }},
    };
    try std.testing.expectError(
        error.InvalidPointerAlignment,
        validateFileForTranslation(&misaligned),
    );

    // `const BytePointer = [*c]const u8` has no identifier spelling at all.
    const byte_pointer: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "BytePointer",
            .init = Expr{ .type_value = .{ .ptr = .{
                .elem = &byte,
                .is_const = true,
                .size = .c,
            } } },
        } }},
    };
    try validateFileForTranslation(&byte_pointer);

    // Nesting is ordinary: an optional of a const slice is just a type.
    const rows: Type = .{ .slice = .{ .elem = &byte, .is_const = true } };
    const optional_rows: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "Rows",
            .init = Expr{ .type_value = .{ .opt = &rows } },
        } }},
    };
    try validateFileForTranslation(&optional_rows);
}

test "ast validation: a type expression is validated as the expression it carries" {
    const byte: Type = .{ .prim = .u8 };

    // `RustHashType(*align(3) u8, ...)` is not a Zig type whatever expression
    // spells it. The spelling is an expression, so it is validated as one —
    // and the type arguments it carries are validated along with it.
    const skewed_callee: Expr = .{ .ident = "RustHashType" };
    const misaligned: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .struct_decl = .{
            .name = "Descriptor",
            .fields = &.{.{ .name = "hash", .ty = .{ .expr = &Expr{ .call = .{
                .callee = &skewed_callee,
                .generic_args = &.{.{ .ptr = .{ .elem = &byte, .alignment = 3 } }},
            } } } }},
        } }},
    };
    try std.testing.expectError(
        error.InvalidPointerAlignment,
        validateFileForTranslation(&misaligned),
    );

    // The descriptor this node exists for: a generic call whose payload is a
    // tagged struct literal, written where a type is expected.
    const descriptor_callee: Expr = .{ .ident = "RustHashType" };
    const layout: Expr = .{ .struct_init = .{
        .type_name = .{ .named = "RustHashLayout" },
        .fields = &.{.{ .name = "nominal", .expr = Expr{ .unit = {} } }},
    } };
    const descriptor: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .const_decl = .{
            .name = "Descriptor",
            .ty = .{ .expr = &Expr{ .call = .{
                .callee = &descriptor_callee,
                .generic_args = &.{.{ .prim = .u64 }},
                .args = &.{layout},
            } } },
            .init = Expr{ .unit = {} },
        } }},
    };
    try validateFileForTranslation(&descriptor);
}

test "ast validation: type expression receivers compare by payload, not by box" {
    const members = [_]TraitDescriptorMember{
        .{ .type_ = .{ .name = "Tag", .ty = .{ .prim = .u8 } } },
    };

    // Two separately built boxes naming the same descriptor. `RustHashType(u64)`
    // written twice is one case, whichever tree each spelling came from.
    const callee: Expr = .{ .ident = "RustHashType" };
    const first: Type = .{ .expr = &Expr{ .call = .{
        .callee = &callee,
        .generic_args = &.{.{ .prim = .u64 }},
    } } };
    const first_again: Type = .{ .expr = &Expr{ .call = .{
        .callee = &callee,
        .generic_args = &.{.{ .prim = .u64 }},
    } } };
    // A different type argument is a different descriptor, so it stays a
    // second case rather than a duplicate of the first.
    const second: Type = .{ .expr = &Expr{ .call = .{
        .callee = &callee,
        .generic_args = &.{.{ .prim = .u32 }},
    } } };

    const duplicated: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .trait_descriptor = .{
            .name = "Descriptor",
            .cases = &.{
                .{ .receiver = first, .members = &members },
                .{ .receiver = first_again, .members = &members },
            },
        } }},
    };
    try std.testing.expectError(
        error.DuplicateTraitDescriptorCase,
        validateFileForTranslation(&duplicated),
    );

    const distinct: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .trait_descriptor = .{
            .name = "Descriptor",
            .cases = &.{
                .{ .receiver = first, .members = &members },
                .{ .receiver = second, .members = &members },
            },
        } }},
    };
    try validateFileForTranslation(&distinct);
}

// ---------------------------------------------------------------------------
// The shapes this session introduced
// ---------------------------------------------------------------------------

// A self-valued labelled block: `emitBlockScoped` writes `label: { …` and a
// value tail as `break :label <tail>;`, so the value leaves through the label
// the block itself carries. The label is the whole shape — dropping it changes
// which block the exits land on — so `sameBlock` has to see it, and a block
// that both is labelled and carries a tail is not the same block as one that
// only does one of the two.
test "ast: a self-valued labelled block is one shape, not two" {
    const value: Expr = .{ .lit = .{ .uint = 1 } };
    const labelled: Block = .{ .label = "chain", .expr = &value };
    // The same block, built again from its own parts: a label and a tail are
    // the shape, and two blocks that both carry them are one shape.
    const rebuilt: Block = .{ .label = "chain", .expr = &value };
    const other_label: Block = .{ .label = "other", .expr = &value };
    const unlabelled: Block = .{ .expr = &value };
    const no_tail: Block = .{ .label = "chain" };

    try std.testing.expect(sameBlock(labelled, rebuilt));
    // A different label names a different exit target.
    try std.testing.expect(!sameBlock(labelled, other_label));
    // The emitter writes a label of its own for an unlabelled value block, and
    // a block with no tail is a statement: neither is the labelled value block.
    try std.testing.expect(!sameBlock(labelled, unlabelled));
    try std.testing.expect(!sameBlock(labelled, no_tail));

    // The labelled form validates wherever a block EXPRESSION is legal, which
    // is every position `validateExpr` reaches on its own.
    const as_expression: Expr = .{ .block = labelled };
    try validateExpr(as_expression);
}

// The shape is legal as an expression and fatal as a body, because no emitter
// can write a body's label. `lowerBlock` hands a flattened tail's label to the
// block that swallowed it, so a function body whose tail was a guarded-match
// chain comes back labelled — and every `break :label` inside still names it.
test "ast validation: a labelled body is refused, an unlabelled one is not" {
    const payload: Expr = .{ .ident = "payload" };
    const exit: Expr = .{ .break_expr = .{ .value = &payload, .label = "__r2z_match_block" } };
    const chain: Block = .{
        .label = "__r2z_match_block",
        .stmts = &.{.{ .expr_stmt = &exit }},
    };

    // `lowerBlock`'s flattening path: the chain's statements and its label both
    // land on the body, which is exactly the shape that cannot be emitted.
    const flattened: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "select",
            .ret_type = .{ .named = "Tag" },
            .body = .{
                .label = "__r2z_match_block",
                .stmts = &.{.{ .expr_stmt = &exit }},
            },
        } }},
    };
    try std.testing.expectError(
        error.LabelledDeclarationBody,
        validateFileForTranslation(&flattened),
    );

    // A test body is the other declaration body, and it is written the same
    // way — `test "…" {` with no slot for a label.
    const labelled_test: File = .{
        .path = "src/root.zig",
        .imports = &.{.{ .local_name = "std", .module_or_path = "std" }},
        .tests = &.{.{ .name = "select", .body = chain }},
    };
    try std.testing.expectError(
        error.LabelledDeclarationBody,
        validateFileForTranslation(&labelled_test),
    );

    // The chain kept whole in an expression position is the shape that has to
    // keep validating, so what the two above reject is the body's label and
    // not the chain.
    const whole: File = .{
        .path = "src/root.zig",
        .decls = &.{.{ .fn_decl = .{
            .name = "select",
            .ret_type = .{ .named = "Tag" },
            .body = .{ .expr = &Expr{ .block = chain } },
        } }},
    };
    try validateFileForTranslation(&whole);
}

// The ordered chain a guarded `match` lowers to: a labelled block whose value
// leaves through `break :label` and whose last statement is the `unreachable`
// that closes the chain. Nothing else has all three, so the three together
// are the identity — and the lowerer reads them back off exactly these three.
test "ast: the guard chain is a labelled block closed by an unreachable" {
    const payload: Expr = .{ .ident = "payload" };
    const exit: Expr = .{ .break_expr = .{ .value = &payload, .label = "__r2z_match_block" } };
    const terminal: Expr = .{ .unreachable_ = {} };
    const last_exit: Expr = .{ .break_expr = .{ .label = "__r2z_match_block" } };

    const chain: Block = .{
        .label = "__r2z_match_block",
        .stmts = &.{
            .{ .expr_stmt = &exit },
            .{ .expr_stmt = &terminal },
        },
    };
    const rebuilt: Block = .{
        .label = "__r2z_match_block",
        .stmts = &.{
            .{ .expr_stmt = &exit },
            .{ .expr_stmt = &terminal },
        },
    };
    try std.testing.expect(sameBlock(chain, rebuilt));

    // A chain whose last statement is not the `unreachable` is not a chain, and
    // a chain that carries a tail of its own is not one either: the lowerer
    // refuses to promote either, so they must not compare equal.
    const without_unreachable: Block = .{
        .label = "__r2z_match_block",
        .stmts = &.{.{ .expr_stmt = &exit }},
    };
    const with_tail: Block = .{
        .label = "__r2z_match_block",
        .stmts = &.{.{ .expr_stmt = &terminal }},
        .expr = &payload,
    };
    // A value exit and a valueless exit leave the block differently too.
    const valueless: Block = .{
        .label = "__r2z_match_block",
        .stmts = &.{
            .{ .expr_stmt = &last_exit },
            .{ .expr_stmt = &terminal },
        },
    };
    try std.testing.expect(!sameBlock(chain, without_unreachable));
    try std.testing.expect(!sameBlock(chain, with_tail));
    try std.testing.expect(!sameBlock(chain, valueless));

    try validateExpr(Expr{ .block = chain });
}

// The per-field named destructure: `emitMatchDestructureBody` writes one
// `const <binding> = <payload>.<field>;` per binding, all in the arm's own
// block. The fields are therefore declarations, which makes two of them
// binding one name a redefinition the Zig compiler refuses, and it makes the
// order and the field each name binds part of the shape.
test "ast validation: per-field bindings are declarations, so they cannot collide" {
    const pair: Expr = .{ .ident = "payload" };
    const two_fields: Pattern = .{ .struct_pat = .{
        .name = "Some",
        .fields = &.{
            .{ .name = "value", .pat = .{ .binding = "first" } },
            .{ .name = "other", .pat = .{ .binding = "second" } },
        },
    } };
    try validatePattern(two_fields);

    // Same fields, same order — the same shape.
    const same_pair: Pattern = .{ .struct_pat = .{
        .name = "Some",
        .fields = &.{
            .{ .name = "value", .pat = .{ .binding = "first" } },
            .{ .name = "other", .pat = .{ .binding = "second" } },
        },
    } };
    try std.testing.expect(samePattern(two_fields, same_pair));

    // Swapping which field each name binds is a different destructure: the
    // emitter writes the pairing out, so it cannot be collapsed.
    const swapped: Pattern = .{ .struct_pat = .{
        .name = "Some",
        .fields = &.{
            .{ .name = "value", .pat = .{ .binding = "second" } },
            .{ .name = "other", .pat = .{ .binding = "first" } },
        },
    } };
    try std.testing.expect(!samePattern(two_fields, swapped));

    // Two fields binding one name is the redefinition.
    const colliding: Pattern = .{ .struct_pat = .{
        .name = "Some",
        .fields = &.{
            .{ .name = "value", .pat = .{ .binding = "same" } },
            .{ .name = "other", .pat = .{ .binding = "same" } },
        },
    } };
    try std.testing.expectError(error.DuplicatePatternBinding, validatePattern(colliding));

    // It is the same rule one level down, and the same rule for a tuple, which
    // the emitter spells as one capture list.
    const nested_collision: Pattern = .{ .struct_pat = .{
        .name = "Outer",
        .fields = &.{
            .{ .name = "inner", .pat = .{ .struct_pat = .{
                .name = "Some",
                .fields = &.{
                    .{ .name = "value", .pat = .{ .binding = "deep" } },
                    .{ .name = "other", .pat = .{ .binding = "deep" } },
                },
            } } },
        },
    } };
    try std.testing.expectError(error.DuplicatePatternBinding, validatePattern(nested_collision));

    const tuple_collision: Pattern = .{ .tuple = &.{
        .{ .binding = "twice" },
        .{ .binding = "twice" },
    } };
    try std.testing.expectError(error.DuplicatePatternBinding, validatePattern(tuple_collision));

    // A field the destructure reaches as `payload.<name>` has to be one Zig
    // reads as a field. A tuple position is `payload[0]`, and the only spelling
    // of that here is the single positional field, which never takes this
    // route.
    const positional_pair: Pattern = .{ .struct_pat = .{
        .name = "Pair",
        .fields = &.{
            .{ .name = "0", .pat = .{ .binding = "left" } },
            .{ .name = "1", .pat = .{ .binding = "right" } },
        },
    } };
    try std.testing.expectError(error.InvalidIdentifier, validatePattern(positional_pair));

    const positional_single: Pattern = .{ .struct_pat = .{
        .name = "Some",
        .fields = &.{.{ .name = "0", .pat = .{ .binding = "value" } }},
    } };
    try validatePattern(positional_single);

    // The whole arm these fields belong to validates, and the arm's body reads
    // both names the destructure introduced.
    const arm: Expr = .{ .match_expr = .{
        .target = &pair,
        .arms = &.{.{
            .patterns = &.{two_fields},
            .body = .{ .bin_op = .{
                .op = .add,
                .lhs = &Expr{ .ident = "first" },
                .rhs = &Expr{ .ident = "second" },
            } },
        }},
    } };
    try validateExpr(arm);
}

// The owner-position turbofish: `Vec::<T>::new()` lowers to the type
// instantiated in OWNER position — a call that carries the type argument and
// no value argument, wrapped in the field access that reaches the owner. The
// generic argument is written by `emitType` ahead of every value argument, so
// it is part of the shape and not decoration on the callee.
test "ast validation: the owner turbofish carries a spelled type" {
    const element: Type = .{ .prim = .u8 };
    const owner: Expr = .{ .call = .{
        .callee = &Expr{ .ident = "std.ArrayListUnmanaged" },
        .generic_args = &.{element},
    } };
    const owner_init: Expr = .{ .field_access = .{ .target = &owner, .field_name = "empty" } };
    try validateExpr(owner_init);

    // The turbofish is what makes this shape different from the same field
    // access without one, from a different element type, and from a different
    // field: the emitted bytes differ in each case.
    const without_turbofish: Expr = .{ .field_access = .{
        .target = &Expr{ .ident = "std.ArrayListUnmanaged" },
        .field_name = "empty",
    } };
    const other_element: Type = .{ .prim = .u32 };
    const retyped_owner: Expr = .{ .call = .{
        .callee = &Expr{ .ident = "std.ArrayListUnmanaged" },
        .generic_args = &.{other_element},
    } };
    const other_field: Expr = .{ .field_access = .{
        .target = &owner,
        .field_name = "init",
    } };
    try std.testing.expect(!sameExpr(owner_init, without_turbofish));
    try std.testing.expect(!sameExpr(owner_init, other_field));
    try std.testing.expect(!sameExpr(owner, retyped_owner));
    try std.testing.expect(sameExpr(owner_init, owner_init));

    // A turbofish argument is validated as the TYPE it is, so a type carrying a
    // malformed shape of its own is caught on this path too: an unsupported
    // pointer alignment cannot ride into an owner instantiation unnoticed.
    const byte: Type = .{ .prim = .u8 };
    const misaligned: Type = .{ .ptr = .{ .elem = &byte, .alignment = 3 } };
    const bad_turbofish: Expr = .{ .call = .{
        .callee = &Expr{ .ident = "std.ArrayListUnmanaged" },
        .generic_args = &.{misaligned},
    } };
    try std.testing.expectError(error.InvalidPointerAlignment, validateExpr(bad_turbofish));

    // A dotted path a runtime type is named by, and a type grammar a strategy
    // hands back already spelled, are BOTH carried by a name, and both stay
    // legal: `emitType` writes the name verbatim, so a name here is a type
    // spelling and not an identifier. The one name that is not a type at all is
    // the one the emitter maps to `anyopaque`, and it keeps its own error.
    for ([_][]const u8{
        "Vec",
        "std.ArrayListUnmanaged",
        "r2z.alloc.Vec",
        "[]const u8",
        "std.AutoHashMap",
    }) |type_name| {
        try validateType(.{ .named = type_name });
        try validateType(.{ .generic = .{ .name = type_name, .params = &.{element} } });
    }
    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        validateType(.{ .named = "unsupported type" }),
    );
    try std.testing.expectError(error.InvalidIdentifier, validateType(.{ .named = "" }));
}

// The `_ = <name>;` an unread parameter gets is not an AST node: the emitter
// writes those bytes from the parameter list and a body scan, so the AST's
// half of the contract is the parameter itself. Zig has no spelling for a
// parameter the body never reads — unnamed is `missing parameter name` and a
// `_`-prefixed one is still `unused function parameter` — which is why the
// name is kept verbatim and the discard is the only answer. So the name has
// to be a real identifier, and a `_` name has to keep validating, because
// that is exactly the parameter the discard exists for.
test "ast validation: an unread parameter keeps an identifier, `_` included" {
    // A body that reads no parameter at all: every ordinary parameter on it
    // is one the emitter has to discard in the body.
    const body: Block = .{ .stmts = &.{.{ .expr_stmt = &Expr{ .unit = {} } }} };

    // A plain name is the shape the emitter writes verbatim and then discards.
    const plain: File = .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "consume",
        .params = &.{.{ .name = "value", .ty = .{ .prim = .u8 } }},
        .ret_type = .void_type,
        .body = body,
    } }} };
    try validateFileForTranslation(&plain);

    // `_value` is still a live parameter to Zig — `_value: u8` is
    // `error: unused function parameter`, not a discard — so it is the same
    // shape and it has to keep validating. A bare `_` is the one spelling Zig
    // accepts as a discard, and it is still a name this AST carries rather
    // than rejects.
    const underscore_prefixed: File = .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "consume",
        .params = &.{.{ .name = "_value", .ty = .{ .prim = .u8 } }},
        .ret_type = .void_type,
        .body = body,
    } }} };
    try validateFileForTranslation(&underscore_prefixed);

    const bare_underscore: File = .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "consume",
        .params = &.{.{ .name = "_", .ty = .{ .prim = .u8 } }},
        .ret_type = .void_type,
        .body = body,
    } }} };
    try validateFileForTranslation(&bare_underscore);

    // A `comptime T: type` parameter is the one shape the emitter exempts: its
    // references live in the signature, not the body, so a body-only scan must
    // not discard it. It still has to be a name.
    const type_param: File = .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
        .name = "consume",
        .params = &.{.{
            .name = "T",
            .ty = .{ .prim = .type_type },
            .is_comptime = true,
        }},
        .ret_type = .void_type,
        .body = body,
    } }} };
    try validateFileForTranslation(&type_param);

    // What the emitter writes is `_ = <name>;`, so a name it could not spell is
    // a name error here rather than a discard the compiler refuses.
    for ([_][]const u8{ "", "0value", "value*" }) |name| {
        const malformed: File = .{ .path = "src/root.zig", .decls = &.{.{ .fn_decl = .{
            .name = "consume",
            .params = &.{.{ .name = name, .ty = .{ .prim = .u8 } }},
            .ret_type = .void_type,
            .body = body,
        } }} };
        try std.testing.expectError(error.InvalidIdentifier, validateFileForTranslation(&malformed));
    }

    // The discard is a statement, and a statement is not a binding: the `_ =
    // <name>;` the emitter writes and a `let` of the same name are different
    // shapes, and only the second one introduces a name at all.
    const discard: Stmt = .{ .expr_stmt = &Expr{ .ident = "value" } };
    const binding: Stmt = .{ .let_stmt = .{
        .name = "value",
        .init = .{ .lit = .{ .uint = 0 } },
    } };
    try std.testing.expect(!sameStmt(discard, binding));
    try std.testing.expect(sameStmt(discard, discard));
}

// `_` names no binding, so Zig has `_ = expr;` and nothing else: there is no
// `_ += expr;` in the language. The discard assignment is still a real shape —
// `unusedBindingAsDiscard` writes exactly that for an unread binding — so the
// default op has to keep validating while every other one is refused.
test "ast validation: a discard assignment takes no compound operator" {
    const value: Expr = .{ .lit = .{ .uint = 1 } };

    // The shape the emitter writes for an unread parameter.
    const discard: Block = .{ .stmts = &.{.{ .assign = .{
        .target = .{ .ident = "_" },
        .val = value,
    } }} };
    try validateBlock(discard);

    // A compound op on a discard target describes a statement no emitter can
    // write and no Zig compiler accepts, so it is refused by name.
    for ([_]AssignOp{
        .add_assign,
        .add_assign_wrap,
        .sub_assign,
        .sub_assign_wrap,
        .mul_assign,
        .mul_assign_wrap,
        .div_assign,
        .mod_assign,
        .bit_and_assign,
        .bit_or_assign,
        .bit_xor_assign,
        .shl_assign,
        .shr_assign,
    }) |op| {
        const compound: Block = .{ .stmts = &.{.{ .assign = .{
            .target = .{ .ident = "_" },
            .val = value,
            .op = op,
        } }} };
        try std.testing.expectError(
            error.UnsupportedTranslationNode,
            validateBlock(compound),
        );
    }

    // The same compound op on a real binding is the ordinary statement the
    // lowerer emits for `x += 1;`, so what is refused is the discard and not
    // the operator.
    const bound: Block = .{ .stmts = &.{.{ .assign = .{
        .target = .{ .ident = "total" },
        .val = value,
        .op = .add_assign,
    } }} };
    try validateBlock(bound);

    // A field access is not the discard spelling either, so a compound op into
    // one is still the ordinary statement.
    const receiver: Expr = .{ .ident = "total" };
    const field: Block = .{ .stmts = &.{.{ .assign = .{
        .target = .{ .field_access = .{ .target = &receiver, .field_name = "count" } },
        .val = value,
        .op = .sub_assign,
    } }} };
    try validateBlock(field);

    // A binding merely NAMED like the discard — `_value` is a live parameter to
    // Zig — keeps every operator.
    const prefixed: Block = .{ .stmts = &.{.{ .assign = .{
        .target = .{ .ident = "_value" },
        .val = value,
        .op = .add_assign,
    } }} };
    try validateBlock(prefixed);
}

// `Type.expr` and `Expr.type_value` are inverse pairs, so a row can name
// itself: a type carrying an expression that carries the same type. Validating
// that row has to end in a refusal rather than in the stack, and comparing it
// has to end in "not the same" rather than in the stack.
test "ast validation: a self-referential type/expression pair is refused" {
    // `type_row.expr` and `type_row.type_value.expr` are the same address, so
    // every hop returns to this pair.
    var type_row: Type = undefined;
    var expr_row: Expr = undefined;
    expr_row = .{ .type_value = Type{ .expr = &expr_row } };
    type_row = .{ .expr = &expr_row };

    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        validateType(type_row),
    );
    // The same row reached from the expression side is refused the same way.
    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        validateExpr(expr_row),
    );

    // Both walkers terminate on the pair rather than overflowing.
    try std.testing.expect(!sameType(type_row, type_row));
    try std.testing.expect(!sameExpr(expr_row, expr_row));

    // The bound must not swallow a row that is merely deep. The guard refuses
    // a row AT the limit (`depth >= limit`), so a chain `recursion_depth_limit`
    // nodes deep reaches its `u8` leaf at depth `limit - 1` and still has to
    // validate. Both fixtures below are written against the constant itself,
    // so this pair stays on opposite sides of whatever the bound is; measured
    // against the deepest crate in the tree (`percent-encoding`, 68) the chain
    // is now a factor of 3.7 clear of the bound.
    var chain: [recursion_depth_limit]Type = undefined;
    chain[recursion_depth_limit - 1] = .{ .prim = .u8 };
    var index: usize = recursion_depth_limit - 1;
    while (index > 0) : (index -= 1) {
        chain[index - 1] = .{ .opt = &chain[index] };
    }
    try validateType(chain[0]);

    // One hop further is past the bound, and a past-the-bound row is refused
    // rather than walked.
    const over_deep: Type = .{ .opt = &chain[0] };
    try std.testing.expectError(
        error.UnsupportedTranslationNode,
        validateType(over_deep),
    );
}
