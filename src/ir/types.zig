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

/// The type a value names once every carrier around it is peeled: `&T`,
/// `&mut T`, `Box<T>` and `*T` all stand for the thing they carry. A receiver
/// and a method's `Self` are the same thing once the carrier is gone, which is
/// what lets a caller read a callee's `Self` as its own receiver.
pub fn peelCarrier(ty: Type) ?Type {
    var current = ty;
    var depth: usize = 0;
    while (depth < traversal_depth_max) : (depth += 1) {
        switch (current) {
            .reference => |reference| current = reference.pointee,
            .raw_ptr => |raw_ptr| current = raw_ptr.pointee,
            .boxed => |boxed| current = boxed.*,
            else => return current,
        }
    }
    return null;
}

/// Whether a type spells the `Self` of its own declaration: one segment named
/// `Self`, which names the enclosing impl rather than any type a table holds.
/// A longer path starting with `Self` is a projection the impl resolves, not a
/// spelling of the type, so it is not a leaf.
pub fn isSelfLeaf(ty: Type) bool {
    return ty == .path and ty.path.segments.len == 1 and
        std.mem.eql(u8, ty.path.segments[0].name, "Self");
}

/// Whether a type names `Self` anywhere inside it, answered without allocating.
///
/// Conservative in one direction only. A type nested past
/// `traversal_depth_max` cannot be walked to its end, and this answers `true`
/// for it rather than a `false` the walk never earned. A caller that acts on
/// the answer hands the type to `replaceSelfLeaves`, which refuses such a type
/// outright, so the guess here can only ever start a refusal — never let one
/// through.
pub fn mentionsSelf(ty: Type) bool {
    return mentionsSelfAt(ty, 0) catch true;
}

/// The scan `replaceSelfLeaves` gates each subtree on.
///
/// Truncation is an error and not a `false` because every arm of that rewrite
/// reads a child's null as "this subtree names no `Self`", and a walk that
/// stopped at the bound has not earned that reading. The bound is the IR's own,
/// the same `traversal_depth_max` that `validateForTranslation` and
/// `serialize` walk a type against, and the refusal is that walk's own error
/// rather than a second kind of "no".
fn mentionsSelfAt(ty: Type, depth: usize) error{InvalidTypeTraversal}!bool {
    if (depth >= traversal_depth_max) return error.InvalidTypeTraversal;
    if (isSelfLeaf(ty)) return true;
    return switch (ty) {
        .reference => |value| try mentionsSelfAt(value.pointee, depth + 1),
        .raw_ptr => |value| try mentionsSelfAt(value.pointee, depth + 1),
        .boxed => |value| try mentionsSelfAt(value.*, depth + 1),
        .slice => |value| try mentionsSelfAt(value.elem, depth + 1),
        .array => |value| try mentionsSelfAt(value.elem, depth + 1),
        .tuple => |values| try listMentionsSelf(values, depth),
        .option => |value| try mentionsSelfAt(value.*, depth + 1),
        // Both halves are walked and the first that names a `Self` ends it; a
        // half that cannot be walked to its end is an error, not a `false`.
        .result => |value| blk: {
            if (try mentionsSelfAt(value.ok, depth + 1)) break :blk true;
            break :blk try mentionsSelfAt(value.err, depth + 1);
        },
        .external_nominal => |value| try listMentionsSelf(value.args, depth),
        .generic_inst => |value| try listMentionsSelf(value.args.params, depth),
        .fn_ptr => |value| blk: {
            if (try listMentionsSelf(value.params, depth)) break :blk true;
            break :blk try mentionsSelfAt(value.ret, depth + 1);
        },
        // A trait bound is a claim about the type, not the type itself: `T:
        // Clone` says nothing about what `T` is called, and `dyn Trait` names
        // no `Self` to rewrite.
        .path, .prim, .@"opaque", .dyn_trait, .unsupported => false,
    };
}

fn listMentionsSelf(
    elements: []const Type,
    depth: usize,
) error{InvalidTypeTraversal}!bool {
    for (elements) |element| {
        if (try mentionsSelfAt(element, depth + 1)) return true;
    }
    return false;
}

/// Every `Self` leaf in `declared` becomes `self_type`, and everything around
/// the leaf is kept as it was.
///
/// `Self` is a statement about the type of the declaration that owns the impl
/// block, and it is only meaningful there. A caller that carries the spelling
/// into its own context has no impl in scope to resolve it against, so the
/// `Self` has to become the type the CALL SITE already knows — the receiver's
/// own type, with whatever generic arguments it carries. The signature around
/// the leaf belongs to neither: `Option<Self>` on a `Foo<u8>` receiver is
/// `Option<Foo<u8>>`, not `Foo<u8>`.
///
/// Null says `declared` names no `Self` anywhere, and the caller keeps exactly
/// the type it already had. A type that needs no rewrite allocates nothing.
///
/// The rewrite is all or nothing, and the error set is what says so.
/// `OutOfMemory` and `InvalidTypeTraversal` are errors rather than nulls
/// because a null lets the caller keep the type it had, while either of them
/// folded into a null would have let a HALF-REWRITTEN type through: the leaves
/// that did get replaced, replaced, and a leaf the walk could not reach still
/// saying `Self`. `InvalidTypeTraversal` is the IR's own refusal —
/// `traversal_depth_max`, walked by `validateForTranslation` and by
/// `serialize` against the same bound with the same error — reached here
/// because a walk that cannot see the end of a type cannot say what the type
/// names. So every arm below reads a child's null as "this subtree names no
/// `Self`" and nothing else, and a sibling that needs no rewrite is carried
/// over for the same reason.
pub const SelfRewriteError = error{ OutOfMemory, InvalidTypeTraversal };

pub fn replaceSelfLeaves(
    alloc: std.mem.Allocator,
    self_type: Type,
    declared: Type,
) SelfRewriteError!?Type {
    return replaceSelfLeavesAt(alloc, self_type, declared, 0);
}

fn replaceSelfLeavesAt(
    alloc: std.mem.Allocator,
    self_type: Type,
    declared: Type,
    depth: usize,
) SelfRewriteError!?Type {
    if (isSelfLeaf(declared)) return self_type;
    // Every arm below reads its children's null as "this subtree names no
    // Self", so that reading has to hold before any of them runs. It does: a
    // child that answers null genuinely names no `Self`, because a walk that
    // could not see far enough is an error rather than a null.
    if (!(try mentionsSelfAt(declared, depth))) return null;
    return switch (declared) {
        .reference => |value| blk: {
            const pointee = try replaceSelfLeavesAt(alloc, self_type, value.pointee, depth + 1) orelse return null;
            const reference = try alloc.create(Ref);
            reference.* = .{ .mut = value.mut, .pointee = pointee };
            break :blk Type{ .reference = reference };
        },
        .raw_ptr => |value| blk: {
            const pointee = try replaceSelfLeavesAt(alloc, self_type, value.pointee, depth + 1) orelse return null;
            const pointer = try alloc.create(RawPtr);
            pointer.* = .{ .mut = value.mut, .pointee = pointee };
            break :blk Type{ .raw_ptr = pointer };
        },
        .boxed => |value| blk: {
            const inner = try replaceSelfLeavesAt(alloc, self_type, value.*, depth + 1) orelse return null;
            const boxed = try alloc.create(Type);
            boxed.* = inner;
            break :blk Type{ .boxed = boxed };
        },
        .slice => |value| blk: {
            const elem = try replaceSelfLeavesAt(alloc, self_type, value.elem, depth + 1) orelse return null;
            const slice = try alloc.create(Slice);
            slice.* = .{ .const_ = value.const_, .elem = elem };
            break :blk Type{ .slice = slice };
        },
        .array => |value| blk: {
            const elem = try replaceSelfLeavesAt(alloc, self_type, value.elem, depth + 1) orelse return null;
            const array = try alloc.create(Array);
            array.* = .{ .elem = elem, .len = value.len };
            break :blk Type{ .array = array };
        },
        .tuple => |values| blk: {
            const rebuilt = try replaceSelfLeavesInList(alloc, self_type, values, depth) orelse return null;
            break :blk Type{ .tuple = rebuilt };
        },
        .option => |value| blk: {
            const inner = try replaceSelfLeavesAt(alloc, self_type, value.*, depth + 1) orelse return null;
            const option = try alloc.create(Type);
            option.* = inner;
            break :blk Type{ .option = option };
        },
        // Both halves rewrite independently, so neither decides for the other:
        // `Result<Self, io::Error>` has a `Self` in its `ok` and a plain path in
        // its `err`. The half that needs no rewrite is carried over — which is
        // now a certainty rather than a guess, because the gate above proved
        // this subtree mentions a `Self` and every failure, allocation or
        // depth, is an error rather than a null.
        .result => |value| blk: {
            const ok = try replaceSelfLeavesAt(alloc, self_type, value.ok, depth + 1);
            const err = try replaceSelfLeavesAt(alloc, self_type, value.err, depth + 1);
            if (ok == null and err == null) return null;
            const result = try alloc.create(Result);
            result.* = .{
                .ok = ok orelse value.ok,
                .err = err orelse value.err,
                .is_error_unionable = value.is_error_unionable,
            };
            break :blk Type{ .result = result };
        },
        .external_nominal => |value| blk: {
            const args = try replaceSelfLeavesInList(alloc, self_type, value.args, depth) orelse return null;
            break :blk Type{ .external_nominal = .{ .path = value.path, .args = args } };
        },
        .generic_inst => |value| blk: {
            const params = try replaceSelfLeavesInList(alloc, self_type, value.args.params, depth) orelse return null;
            break :blk Type{ .generic_inst = .{ .decl = value.decl, .args = .{ .params = params } } };
        },
        .fn_ptr => |value| blk: {
            const params = try replaceSelfLeavesInList(alloc, self_type, value.params, depth);
            const ret = try replaceSelfLeavesAt(alloc, self_type, value.ret, depth + 1);
            if (params == null and ret == null) return null;
            const function = try alloc.create(FnPtr);
            function.* = .{ .params = params orelse value.params, .ret = ret orelse value.ret };
            break :blk Type{ .fn_ptr = function };
        },
        .path, .prim, .@"opaque", .dyn_trait, .unsupported => return null,
    };
}

fn replaceSelfLeavesInList(
    alloc: std.mem.Allocator,
    self_type: Type,
    elements: []const Type,
    depth: usize,
) SelfRewriteError!?[]const Type {
    var mentions_self = false;
    for (elements) |element| {
        if (try mentionsSelfAt(element, depth + 1)) {
            mentions_self = true;
            break;
        }
    }
    if (!mentions_self) return null;
    const rebuilt = try alloc.alloc(Type, elements.len);
    for (elements, 0..) |element, index| {
        rebuilt[index] = try replaceSelfLeavesAt(alloc, self_type, element, depth + 1) orelse element;
    }
    return rebuilt;
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

test "types: replacing a Self leaf is all or nothing under allocation failure" {
    // `(Self, Result<Self, Pair<u8>>)` is the shape that makes a partial rewrite
    // observable, and it needs more than one allocation point and more than one
    // leaf for the sweep below to have anything to catch. The outer list is
    // allocated, then the inner `Result` is: a failure at the second of those
    // arrives with the first element already rewritten. A rebuild that read a
    // failure as "nothing to do here" would then hand back a tuple whose first
    // element said `Receiver` and whose second still said `Self` — a type no
    // caller can use, and the one the error set exists to rule out.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const receiver: Type = .{ .path = .{ .segments = &.{
        .{ .name = "Receiver", .id = @as(?spine.EntityId, 3) },
    } } };
    const self_leaf: Type = .{ .path = .{ .segments = &.{
        .{ .name = "Self", .id = @as(?spine.EntityId, 3) },
    } } };
    const pair_args = try arena.alloc(Type, 1);
    pair_args[0] = .{ .prim = .u8 };
    const pair: Type = .{ .generic_inst = .{
        .decl = 7,
        .args = .{ .params = pair_args },
    } };
    const inner = Type{ .result = blk: {
        const result = try arena.create(Result);
        result.* = .{
            .ok = self_leaf,
            .err = pair,
            .is_error_unionable = true,
        };
        break :blk result;
    } };
    const declared = Type{ .tuple = blk: {
        const elements = try arena.alloc(Type, 2);
        elements[0] = self_leaf;
        elements[1] = inner;
        break :blk elements;
    } };

    // A type that names no `Self` comes back as the caller's own, and the
    // allocator is never touched at all.
    var untouched = std.testing.FailingAllocator.init(arena, .{});
    try std.testing.expect((try replaceSelfLeaves(untouched.allocator(), receiver, pair)) == null);
    try std.testing.expectEqual(@as(usize, 0), untouched.allocations);

    // Paid for in full: no `Self` survives, the inner `Result` keeps the `Pair`
    // it never named, and the outer tuple keeps its arity.
    var funded = std.testing.FailingAllocator.init(arena, .{});
    const whole = (try replaceSelfLeaves(funded.allocator(), receiver, declared)).?;
    try std.testing.expect(!mentionsSelf(whole));
    try std.testing.expectEqual(@as(usize, 2), whole.tuple.len);
    try std.testing.expectEqual(receiver, whole.tuple[0]);
    try std.testing.expectEqual(receiver, whole.tuple[1].result.ok);
    try std.testing.expectEqual(pair, whole.tuple[1].result.err);

    // Every failure point in between: an error, or a whole type. Never a type
    // that still says `Self`, which is exactly what a mixed rebuild would leave.
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(arena, .{ .fail_index = fail_index });
        const outcome = replaceSelfLeaves(failing.allocator(), receiver, declared) catch |err| switch (err) {
            error.OutOfMemory => continue,
            // `declared` sits a handful of edges from its root, so a refusal
            // for depth would be the bound turning away a type nowhere near
            // it, and this sweep is about allocation.
            error.InvalidTypeTraversal => return error.TestUnexpectedResult,
        };
        if (outcome) |survivor| {
            try std.testing.expect(!mentionsSelf(survivor));
            try std.testing.expectEqual(receiver, survivor.tuple[0]);
        }
    }
}

test "types: truncated Self substitution refuses the entire mixed type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const self_leaf: Type = .{ .path = .{ .segments = &.{
        .{ .name = "Self", .id = null },
    } } };
    var nested = self_leaf;
    for (0..traversal_depth_max + 1) |_| {
        const child = try alloc.create(Type);
        child.* = nested;
        nested = .{ .option = child };
    }
    const elements = [_]Type{ self_leaf, nested };
    try std.testing.expectError(
        error.InvalidTypeTraversal,
        replaceSelfLeaves(alloc, .{ .prim = .u8 }, .{ .tuple = &elements }),
    );
}
