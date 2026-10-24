//! translate_rust.model.types — type representation of the lossless semantic IR.
//! Consumer: the Zig emitter.
//!
//! Self-reference is bounded by `*const Type` / `[]const Type` (known-size), so
//! `Type` is well-defined as a recursive tagged union.

const spine = @import("spine.zig");

/// §4 — The type tagged union every field/param/return references.
pub const Type = union(enum) {
    path: Path,
    /// A nominal type supplied by Rust `alloc`/`core`/`std`, not declared in this
    /// crate. Its path is provenance-only: it has no graph entity id.
    external_nominal: ExternalNominal,
    prim: Prim,
    reference: *const Ref,
    raw_ptr: *const RawPtr,
    slice: *const Slice,
    array: *const Array,
    tuple: []const Type,
    fn_ptr: *const FnPtr,
    generic_inst: GenericInst,
    option: *const Type,
    result: *const Result,
    boxed: *const Type,
    /// An opaque Rust type whose declared bounds remain available even when
    /// inference has not yet recovered its concrete representation.
    @"opaque": Opaque,
    /// A dynamic trait object such as `dyn Error + 'static`.
    dyn_trait: []const Bound,
    unsupported: spine.Unsupported,
};

/// §4.1 — Primitives. `()` → `void`, `!` → `noreturn`; `char` → `u21` at emit.
pub const Prim = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,
    isize,
    usize,
    f32,
    f64,
    bool,
    char,
    unit,
    never,
};

/// §4.1 — A resolved nominal type as a list of segments. Each segment may
/// already carry its resolved `EntityId` so the emitter can read the symbol
/// table directly without re-resolution.
pub const Path = struct {
    segments: []const PathSegment,
};

pub const PathSegment = struct {
    name: []const u8,
    id: ?spine.EntityId,
};

/// A nominal Rust type outside the translated crate.
///
/// `path` retains every Rust segment, in source order. Unlike `Path`, the
/// segments have no nullable `EntityId`; external names are never graph
/// entities. Generic arguments remain first-class IR types.
pub const ExternalNominal = struct {
    path: []const []const u8,
    args: []const Type = &.{},
};

/// §4.1 — `&T` → `*const T`, `&mut T` → `*T`. Lifetimes are erased at emit but
/// retained as diagnostics on the path side (§3 LifetimeParam).
pub const Ref = struct {
    mut: bool,
    pointee: Type,
};

/// §4.1 — Raw pointer; arithmetic / C-style casts use `[*]T` / `[*c]T` at emit.
pub const RawPtr = struct {
    mut: bool,
    pointee: Type,
};

/// §4.1 — `&[T]` → `[]const T`; `&mut [T]` → `[]T`.
pub const Slice = struct {
    const_: bool,
    elem: Type,
};

/// §4.2 — `[T; N]` → `[N]T` at emit. `len` is either a literal or a generic
/// parameter index (`const N: usize`).
pub const Array = struct {
    elem: Type,
    len: ArrayLen,
};

pub const ArrayLen = union(enum) {
    literal: u32,
    generic: u32,
};

/// §4.2 — Function pointer; C-ABI fns get `callconv(.c)` at emit.
pub const FnPtr = struct {
    params: []const Type,
    ret: Type,
};

/// §4.2 — `Foo<i32>` → declaration EntityId + args. The emitter joins this
/// with the §3.1 instantiation record for the decl.
pub const GenericInst = struct {
    decl: spine.EntityId,
    args: GenericArgs,
};

pub const GenericArgs = struct {
    params: []const Type,
};

/// §3.1 — Monomorphized instantiation record linking a generic entity to concrete args.
pub const Instantiation = struct {
    generic_id: spine.EntityId,
    args: GenericArgs,
    zig_suffix: []const u8,
};

/// §4.3 — `Result<T, E>` with `is_error_unionable` flagging whether `E` is a
/// finite error set (→ `E!T`) or open (`Box<dyn Error>` → `anyerror` /
/// `unsupported`).
pub const Result = struct {
    ok: Type,
    err: Type,
    is_error_unionable: bool,
};

/// §3 — Rust generics → Zig `comptime`. Where-clauses/bounds are erased at
/// emit (duck typing) but retained for diagnostics.
pub const Generics = struct {
    params: []const GenericParam,
    where_clauses: []const WhereClause,
};

pub const GenericParam = union(enum) {
    type_: TypeParam,
    const_: ConstParam,
    lifetime: LifetimeParam,
};

pub const TypeParam = struct {
    name: []const u8,
    bounds: []const Bound,
};

pub const ConstParam = struct {
    name: []const u8,
    ty: Type,
};

pub const LifetimeParam = struct {
    name: []const u8,
};

pub const AssociatedTypeBinding = struct {
    name: []const u8,
    ty: Type,
};

pub const Bound = struct {
    path: Path,
    args: []const Type = &.{},
    associated_types: []const AssociatedTypeBinding = &.{},
    optional: bool = false,
};

/// An opaque Rust type. `concrete` is optional during extraction and inference;
/// translation backends decide whether an unresolved value is representable.
pub const Opaque = struct {
    bounds: []const Bound,

    concrete: ?*const Type = null,
};

pub const WhereClause = struct {
    self_ty: Path,
    bounds: []const Bound,
};

test "types — external nominal, opaque, and dyn_trait arms carry their payloads" {
    const external_nominal: Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const bound: Bound = .{
        .path = .{ .segments = &.{
            .{ .name = "Iterator", .id = 1 },
            .{ .name = "Item", .id = null },
        } },
        .args = &.{.{ .prim = .u32 }},
        .associated_types = &.{.{ .name = "Item", .ty = .{ .prim = .u32 } }},
        .optional = true,
    };
    const opaque_type: Type = .{ .@"opaque" = .{
        .bounds = &.{bound},
        .concrete = &.{ .prim = .u32 },
    } };
    const dyn_trait: Type = .{ .dyn_trait = &.{bound} };
    _ = external_nominal;
    _ = opaque_type;
    _ = dyn_trait;
}
