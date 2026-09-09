//! translate_rust.model.types — type representation of the lossless semantic IR.
//! See notes/design/data-model/items-types.md §3 (Generics & monomorphization) and
//! §4 (Type representation). Consumer: a Zig backend.
//!
//! Self-reference is bounded by `*const Type` / `[]const Type` (known-size), so
//! `Type` is well-defined as a recursive tagged union.

const std = @import("std");
const spine = @import("spine.zig");
/// Maximum nested type edges followed while walking node-owned types.
pub const traversal_depth_max: usize = 256;

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

/// A nominal Rust type outside the translated crate.
///
/// `path` retains every Rust segment, in source order. Unlike `Path`, the
/// segments have no nullable `EntityId`; external names are never graph
/// entities. Generic arguments remain first-class IR types.
pub const ExternalNominal = struct {
    path: []const []const u8,
    args: []const Type = &.{},
};
/// Canonical nominal identity for Rust's unsized `str` primitive.
pub const str_type: Type = .{ .external_nominal = .{
    .path = &.{ "core", "primitive", "str" },
} };

/// Return whether `ty` is the zero-argument Rust `str` primitive.
pub fn isStr(ty: Type) bool {
    const nominal = switch (ty) {
        .external_nominal => |value| value,
        else => return false,
    };
    if (nominal.args.len != 0) return false;
    if (nominal.path.len != 3) return false;
    const root = nominal.path[0];
    if (!std.mem.eql(u8, root, "core") and !std.mem.eql(u8, root, "std")) return false;
    if (!std.mem.eql(u8, nominal.path[1], "primitive")) return false;
    return std.mem.eql(u8, nominal.path[2], "str");
}

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
/// already carry its resolved `EntityId` so a backend can read the symbol
/// table directly without re-resolution.
pub const Path = struct {
    segments: []const PathSegment,
};

pub const PathSegment = struct {
    name: []const u8,
    id: ?spine.EntityId,
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

/// §4.2 — `[T; N]` → `[N]T` at emit. `len` is a literal, a generic
/// parameter index (`const N: usize`), or an expression-table node id.
pub const Array = struct {
    elem: Type,
    len: ArrayLen,
};

pub const ArrayLen = union(enum) {
    literal: u64,
    generic: u32,
    expression: u32,
};

/// §4.2 — Function pointer; C-ABI fns get `callconv(.c)` at emit.
pub const FnPtr = struct {
    params: []const Type,
    ret: Type,
};

/// §4.2 — `Foo<i32>` → declaration EntityId + args. The backend joins this
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
/// Compare two types by value, including all nested metadata.
///
/// The recursion bound keeps malformed cyclic type graphs from hanging callers.
/// A bounded comparison returning false is conservative: callers must still
/// validate both rows independently.
pub fn deepEqual(left: Type, right: Type) bool {
    return deepEqualDepth(left, right, 0);
}

fn deepEqualDepth(left: Type, right: Type, depth: usize) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    if (depth >= traversal_depth_max) return false;
    return switch (left) {
        .path => |left_path| pathDeepEqual(left_path, right.path),
        .external_nominal => |left_external| {
            const right_external = right.external_nominal;
            if (left_external.path.len != right_external.path.len) return false;
            for (left_external.path, right_external.path) |left_name, right_name| {
                if (!std.mem.eql(u8, left_name, right_name)) return false;
            }
            return typeSliceDeepEqual(left_external.args, right_external.args, depth + 1);
        },
        .prim => |left_primitive| left_primitive == right.prim,
        .reference => |left_reference| {
            const right_reference = right.reference;
            if (left_reference == right_reference) return true;
            return left_reference.mut == right_reference.mut and
                deepEqualDepth(left_reference.pointee, right_reference.pointee, depth + 1);
        },
        .raw_ptr => |left_pointer| {
            const right_pointer = right.raw_ptr;
            if (left_pointer == right_pointer) return true;
            return left_pointer.mut == right_pointer.mut and
                deepEqualDepth(left_pointer.pointee, right_pointer.pointee, depth + 1);
        },
        .slice => |left_slice| {
            const right_slice = right.slice;
            if (left_slice == right_slice) return true;
            return left_slice.const_ == right_slice.const_ and
                deepEqualDepth(left_slice.elem, right_slice.elem, depth + 1);
        },
        .array => |left_array| {
            const right_array = right.array;
            if (left_array == right_array) return true;
            return arrayLenDeepEqual(left_array.len, right_array.len) and
                deepEqualDepth(left_array.elem, right_array.elem, depth + 1);
        },
        .tuple => |left_tuple| typeSliceDeepEqual(left_tuple, right.tuple, depth + 1),
        .fn_ptr => |left_fn| {
            const right_fn = right.fn_ptr;
            if (left_fn == right_fn) return true;
            return typeSliceDeepEqual(left_fn.params, right_fn.params, depth + 1) and
                deepEqualDepth(left_fn.ret, right_fn.ret, depth + 1);
        },
        .generic_inst => |left_generic| {
            const right_generic = right.generic_inst;
            return left_generic.decl == right_generic.decl and
                typeSliceDeepEqual(
                    left_generic.args.params,
                    right_generic.args.params,
                    depth + 1,
                );
        },
        .option => |left_option| {
            const right_option = right.option;
            if (left_option == right_option) return true;
            return deepEqualDepth(left_option.*, right_option.*, depth + 1);
        },
        .result => |left_result| {
            const right_result = right.result;
            if (left_result == right_result) return true;
            return left_result.is_error_unionable == right_result.is_error_unionable and
                deepEqualDepth(left_result.ok, right_result.ok, depth + 1) and
                deepEqualDepth(left_result.err, right_result.err, depth + 1);
        },
        .boxed => |left_boxed| {
            const right_boxed = right.boxed;
            if (left_boxed == right_boxed) return true;
            return deepEqualDepth(left_boxed.*, right_boxed.*, depth + 1);
        },
        .@"opaque" => |left_opaque| {
            const right_opaque = right.@"opaque";
            if (!boundSliceDeepEqual(left_opaque.bounds, right_opaque.bounds, depth + 1)) {
                return false;
            }
            if (left_opaque.concrete == right_opaque.concrete) return true;
            const left_concrete = left_opaque.concrete orelse return false;
            const right_concrete = right_opaque.concrete orelse return false;
            return deepEqualDepth(left_concrete.*, right_concrete.*, depth + 1);
        },
        .dyn_trait => |left_bounds| boundSliceDeepEqual(left_bounds, right.dyn_trait, depth + 1),
        .unsupported => |left_unsupported| {
            const right_unsupported = right.unsupported;
            return left_unsupported.reason == right_unsupported.reason and
                std.mem.eql(u8, left_unsupported.message, right_unsupported.message) and
                std.meta.eql(left_unsupported.span, right_unsupported.span);
        },
    };
}

fn pathDeepEqual(left: Path, right: Path) bool {
    if (left.segments.len != right.segments.len) return false;
    for (left.segments, right.segments) |left_segment, right_segment| {
        if (!std.mem.eql(u8, left_segment.name, right_segment.name) or
            left_segment.id != right_segment.id)
        {
            return false;
        }
    }
    return true;
}

fn typeSliceDeepEqual(left: []const Type, right: []const Type, depth: usize) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_type, right_type| {
        if (!deepEqualDepth(left_type, right_type, depth)) return false;
    }
    return true;
}

fn arrayLenDeepEqual(left: ArrayLen, right: ArrayLen) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .literal => |value| value == right.literal,
        .generic => |value| value == right.generic,
        .expression => |value| value == right.expression,
    };
}

fn boundSliceDeepEqual(left: []const Bound, right: []const Bound, depth: usize) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_bound, right_bound| {
        if (!pathDeepEqual(left_bound.path, right_bound.path) or
            left_bound.optional != right_bound.optional or
            !typeSliceDeepEqual(left_bound.args, right_bound.args, depth))
        {
            return false;
        }
        if (left_bound.associated_types.len != right_bound.associated_types.len) return false;
        for (left_bound.associated_types, right_bound.associated_types) |
            left_binding,
            right_binding,
        | {
            if (!std.mem.eql(u8, left_binding.name, right_binding.name) or
                !deepEqualDepth(left_binding.ty, right_binding.ty, depth))
            {
                return false;
            }
        }
    }
    return true;
}

pub const WhereClause = struct {
    self_ty: Path,
    bounds: []const Bound,
};
