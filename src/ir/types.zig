//! translate_rust.model.types — type representation of the lossless semantic IR.
//! Consumer: the Zig backend.
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

/// Replace `Self` leaves, or return null when no rewrite is needed.
/// The result can share storage with both inputs. Keep that storage and the
/// caller-owned arena behind `alloc` alive until the last use of the result.
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

/// §4.2 — The count side of `[T; N]`, and the only place a const generic
/// parameter's USE survives: `generic` is the INDEX the parameter declared at,
/// never the value it carries. The index is checked against the declaring
/// declaration's `Generics.params` — `validate` accepts an index that is in
/// range for that list OR for the type-parameter list, so the two index spaces
/// are not one — and no frontend producer writes `.generic` today:
/// `cst.mapArrayLen` reads a literal count and refuses anything else. See
/// `GenericArgs` for the half that has no representation at all.
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

/// §4.2 — The arguments of a generic application: one `Type` per TYPE argument,
/// in source order.
///
/// A const generic ARGUMENT is a value, and this list has no slot for one.
/// `Foo<3>` cannot be spelled, and neither can any other instantiation of a
/// declaration whose parameters are const or lifetime parameters. That is the
/// one shape `Type` cannot express, and the two halves that do have homes do
/// not close it: `ConstParam` carries the `const N: usize` the declaration
/// introduces, and `ArrayLen.generic` carries the index `[u8; N]` uses — but
/// nothing anywhere carries WHICH value an instantiation supplies. So the
/// declaration survives and every use of it does not.
///
/// The refusal that names this gap is `validate`'s
/// `error.IncompleteGenericMetadata`: an instantiation's arity is checked
/// against `genericCountForEntity`, which counts `generic_params` — the type
/// parameters alone — so a `generic_inst` naming a const-generic declaration
/// measures zero arguments and is refused before the missing value is even
/// visible. Adding a value slot here is a separate design decision and is
/// deliberately not made; this declaration is where that decision would land.
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

/// §3 — `const N: usize`, DECLARED. Only the declaration is representable: no
/// `GenericArgs` slot carries the value an instantiation supplies, so the
/// parameter reaches the IR as a name and nothing more.
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
/// Return the argument slot named by a single-segment generic parameter.
pub fn isTypeParam(t: Type, param_names: []const []const u8) ?usize {
    switch (t) {
        .path => |p| {
            if (p.segments.len == 1) {
                const seg_name = p.segments[0].name;
                for (param_names, 0..) |pn, idx| {
                    if (std.mem.eql(u8, seg_name, pn)) return idx;
                }
            }
        },
        else => {},
    }
    return null;
}

/// Substitute generic parameters while borrowing source and argument storage.
/// Release the result with `freeSubstitutedType` using the same inputs; only
/// newly allocated containers belong to the caller, not substituted arguments.
/// Keep the source and argument storage alive through the result's last use
/// and release. `error.OutOfMemory` releases all partial allocations and leaves
/// both inputs unchanged.
pub fn substType(
    alloc: std.mem.Allocator,
    t: Type,
    param_names: []const []const u8,
    args: []const Type,
) std.mem.Allocator.Error!Type {
    if (param_names.len == 0 or args.len == 0) return t;

    if (isTypeParam(t, param_names)) |idx| {
        if (idx < args.len) return args[idx];
    }

    switch (t) {
        .prim => return t,
        .path => |p| {
            if (p.segments.len == 1) {
                if (isTypeParam(t, param_names)) |idx| {
                    if (idx < args.len) return args[idx];
                }
            }
            return t;
        },
        .reference => |r| {
            const sub_pointee = try substType(alloc, r.pointee, param_names, args);
            errdefer freeSubstitutedType(alloc, r.pointee, sub_pointee, param_names, args);
            if (deepEqual(sub_pointee, r.pointee)) {
                freeSubstitutedType(alloc, r.pointee, sub_pointee, param_names, args);
                return t;
            }
            const ref_ptr = try alloc.create(Ref);
            ref_ptr.* = .{ .mut = r.mut, .pointee = sub_pointee };
            return .{ .reference = ref_ptr };
        },
        .raw_ptr => |rp| {
            const sub_pointee = try substType(alloc, rp.pointee, param_names, args);
            errdefer freeSubstitutedType(alloc, rp.pointee, sub_pointee, param_names, args);
            if (deepEqual(sub_pointee, rp.pointee)) {
                freeSubstitutedType(alloc, rp.pointee, sub_pointee, param_names, args);
                return t;
            }
            const raw_ptr = try alloc.create(RawPtr);
            raw_ptr.* = .{ .mut = rp.mut, .pointee = sub_pointee };
            return .{ .raw_ptr = raw_ptr };
        },
        .slice => |s| {
            const sub_elem = try substType(alloc, s.elem, param_names, args);
            errdefer freeSubstitutedType(alloc, s.elem, sub_elem, param_names, args);
            if (deepEqual(sub_elem, s.elem)) {
                freeSubstitutedType(alloc, s.elem, sub_elem, param_names, args);
                return t;
            }
            const slice_ptr = try alloc.create(Slice);
            slice_ptr.* = .{ .const_ = s.const_, .elem = sub_elem };
            return .{ .slice = slice_ptr };
        },
        .array => |arr| {
            const sub_elem = try substType(alloc, arr.elem, param_names, args);
            errdefer freeSubstitutedType(alloc, arr.elem, sub_elem, param_names, args);
            if (deepEqual(sub_elem, arr.elem)) {
                freeSubstitutedType(alloc, arr.elem, sub_elem, param_names, args);
                return t;
            }
            const array_ptr = try alloc.create(Array);
            array_ptr.* = .{ .len = arr.len, .elem = sub_elem };
            return .{ .array = array_ptr };
        },
        .tuple => |tup| {
            const sub_elems = try substTypeSlice(alloc, tup, param_names, args);
            if (deepEqual(.{ .tuple = sub_elems }, t)) {
                freeSubstitutedTypeSlice(alloc, tup, sub_elems, param_names, args);
                return t;
            }
            return .{ .tuple = sub_elems };
        },
        .option => |opt| {
            const sub_inner = try substType(alloc, opt.*, param_names, args);
            errdefer freeSubstitutedType(alloc, opt.*, sub_inner, param_names, args);
            if (deepEqual(sub_inner, opt.*)) {
                freeSubstitutedType(alloc, opt.*, sub_inner, param_names, args);
                return t;
            }
            const opt_ptr = try alloc.create(Type);
            opt_ptr.* = sub_inner;
            return .{ .option = opt_ptr };
        },
        .result => |res| {
            const sub_ok = try substType(alloc, res.ok, param_names, args);
            errdefer freeSubstitutedType(alloc, res.ok, sub_ok, param_names, args);
            const sub_err = try substType(alloc, res.err, param_names, args);
            errdefer freeSubstitutedType(alloc, res.err, sub_err, param_names, args);
            if (deepEqual(sub_ok, res.ok) and deepEqual(sub_err, res.err)) {
                freeSubstitutedType(alloc, res.ok, sub_ok, param_names, args);
                freeSubstitutedType(alloc, res.err, sub_err, param_names, args);
                return t;
            }
            const res_ptr = try alloc.create(Result);
            res_ptr.* = .{ .ok = sub_ok, .err = sub_err, .is_error_unionable = res.is_error_unionable };
            return .{ .result = res_ptr };
        },
        .boxed => |bx| {
            const sub_inner = try substType(alloc, bx.*, param_names, args);
            errdefer freeSubstitutedType(alloc, bx.*, sub_inner, param_names, args);
            if (deepEqual(sub_inner, bx.*)) {
                freeSubstitutedType(alloc, bx.*, sub_inner, param_names, args);
                return t;
            }
            const bx_ptr = try alloc.create(Type);
            bx_ptr.* = sub_inner;
            return .{ .boxed = bx_ptr };
        },
        .@"opaque" => |opaque_type| {
            const sub_bounds = try substBoundSlice(alloc, opaque_type.bounds, param_names, args);
            errdefer {
                freeSubstitutedBounds(alloc, opaque_type.bounds, sub_bounds, param_names, args);
                if (sub_bounds.len > 0) alloc.free(sub_bounds);
            }
            const sub_concrete = if (opaque_type.concrete) |concrete| blk: {
                const concrete_ptr = try alloc.create(Type);
                errdefer alloc.destroy(concrete_ptr);
                concrete_ptr.* = try substType(alloc, concrete.*, param_names, args);
                break :blk @as(?*const Type, concrete_ptr);
            } else null;
            const opaque_copy = Opaque{
                .bounds = sub_bounds,
                .concrete = sub_concrete,
            };
            return .{ .@"opaque" = opaque_copy };
        },
        .dyn_trait => |bounds| return .{ .dyn_trait = try substBoundSlice(alloc, bounds, param_names, args) },
        .external_nominal => |external| {
            const sub_args = try substTypeSlice(alloc, external.args, param_names, args);
            const substituted: Type = .{ .external_nominal = .{
                .path = external.path,
                .args = sub_args,
            } };
            if (deepEqual(substituted, t)) {
                freeSubstitutedTypeSlice(alloc, external.args, sub_args, param_names, args);
                return t;
            }
            return substituted;
        },
        .generic_inst => |gi| {
            const sub_args = try substTypeSlice(alloc, gi.args.params, param_names, args);
            const substituted: Type = .{ .generic_inst = .{
                .decl = gi.decl,
                .args = .{ .params = sub_args },
            } };
            if (deepEqual(substituted, t)) {
                freeSubstitutedTypeSlice(alloc, gi.args.params, sub_args, param_names, args);
                return t;
            }
            return substituted;
        },
        .fn_ptr => |fp| {
            const sub_params = try substTypeSlice(alloc, fp.params, param_names, args);
            errdefer freeSubstitutedTypeSlice(alloc, fp.params, sub_params, param_names, args);
            const sub_ret = try substType(alloc, fp.ret, param_names, args);
            errdefer freeSubstitutedType(alloc, fp.ret, sub_ret, param_names, args);
            if (deepEqual(.{ .tuple = sub_params }, .{ .tuple = fp.params }) and
                deepEqual(sub_ret, fp.ret))
            {
                freeSubstitutedTypeSlice(alloc, fp.params, sub_params, param_names, args);
                freeSubstitutedType(alloc, fp.ret, sub_ret, param_names, args);
                return t;
            }
            const fn_ptr = try alloc.create(FnPtr);
            fn_ptr.* = .{ .params = sub_params, .ret = sub_ret };
            return .{ .fn_ptr = fn_ptr };
        },
        .unsupported => return t,
    }
}

fn substTypeSlice(
    alloc: std.mem.Allocator,
    source: []const Type,
    param_names: []const []const u8,
    args: []const Type,
) std.mem.Allocator.Error![]const Type {
    if (source.len == 0) return &.{};
    const substituted = try alloc.alloc(Type, source.len);
    var initialized: usize = 0;
    errdefer {
        for (source[0..initialized], substituted[0..initialized]) |original, replacement| {
            freeSubstitutedType(alloc, original, replacement, param_names, args);
        }
        alloc.free(substituted);
    }
    for (source, 0..) |original, index| {
        substituted[index] = try substType(alloc, original, param_names, args);
        initialized += 1;
    }
    return substituted;
}

fn substBoundSlice(
    alloc: std.mem.Allocator,
    source: []const Bound,
    param_names: []const []const u8,
    args: []const Type,
) std.mem.Allocator.Error![]const Bound {
    if (source.len == 0) return &.{};
    const substituted = try alloc.alloc(Bound, source.len);
    var initialized: usize = 0;
    errdefer {
        freeSubstitutedBounds(alloc, source[0..initialized], substituted[0..initialized], param_names, args);
        alloc.free(substituted);
    }
    for (source, 0..) |original, index| {
        const bound_args = try substTypeSlice(alloc, original.args, param_names, args);
        errdefer {
            for (original.args, bound_args) |original_arg, substituted_arg| {
                freeSubstitutedType(alloc, original_arg, substituted_arg, param_names, args);
            }
            if (bound_args.len > 0) alloc.free(bound_args);
        }
        const associated_types = try alloc.alloc(AssociatedTypeBinding, original.associated_types.len);
        var associated_initialized: usize = 0;
        errdefer {
            for (
                original.associated_types[0..associated_initialized],
                associated_types[0..associated_initialized],
            ) |original_binding, replacement_binding| {
                freeSubstitutedType(
                    alloc,
                    original_binding.ty,
                    replacement_binding.ty,
                    param_names,
                    args,
                );
            }
            if (associated_types.len > 0) alloc.free(associated_types);
        }
        for (original.associated_types, 0..) |binding, binding_index| {
            associated_types[binding_index] = .{
                .name = binding.name,
                .ty = try substType(alloc, binding.ty, param_names, args),
            };
            associated_initialized += 1;
        }
        substituted[index] = .{
            .path = original.path,
            .args = bound_args,
            .associated_types = if (associated_types.len > 0) associated_types else &.{},
            .optional = original.optional,
        };
        initialized += 1;
    }
    return substituted;
}

fn freeSubstitutedTypeSlice(
    alloc: std.mem.Allocator,
    original: []const Type,
    substituted: []const Type,
    param_names: []const []const u8,
    args: []const Type,
) void {
    for (original, substituted) |original_type, substituted_type| {
        freeSubstitutedType(alloc, original_type, substituted_type, param_names, args);
    }
    if (substituted.len > 0) alloc.free(substituted);
}

fn freeSubstitutedBounds(
    alloc: std.mem.Allocator,
    original: []const Bound,
    substituted: []const Bound,
    param_names: []const []const u8,
    args: []const Type,
) void {
    if (original.len != substituted.len) return;
    for (original, substituted) |original_bound, substituted_bound| {
        if (original_bound.args.len == substituted_bound.args.len) {
            for (original_bound.args, substituted_bound.args) |original_arg, substituted_arg| {
                freeSubstitutedType(alloc, original_arg, substituted_arg, param_names, args);
            }
        }
        if (substituted_bound.args.len > 0) alloc.free(substituted_bound.args);
        if (original_bound.associated_types.len == substituted_bound.associated_types.len) {
            for (original_bound.associated_types, substituted_bound.associated_types) |
                original_binding,
                substituted_binding,
            | {
                freeSubstitutedType(
                    alloc,
                    original_binding.ty,
                    substituted_binding.ty,
                    param_names,
                    args,
                );
            }
        }
        if (substituted_bound.associated_types.len > 0) alloc.free(substituted_bound.associated_types);
    }
}

/// Release only nodes allocated by `substType`; source and argument types stay borrowed.
/// Pass the allocator and inputs used for that substitution. Call once per
/// successful result after its last use; copies share the same allocated nodes.
pub fn freeSubstitutedType(
    alloc: std.mem.Allocator,
    original: Type,
    substituted: Type,
    param_names: []const []const u8,
    args: []const Type,
) void {
    if (param_names.len == 0 or args.len == 0) return;
    if (isTypeParam(original, param_names) != null) return;

    switch (original) {
        .reference => |ref| {
            const sub_ref = switch (substituted) {
                .reference => |value| value,
                else => return,
            };
            if (sub_ref == ref) return;
            freeSubstitutedType(alloc, ref.pointee, sub_ref.pointee, param_names, args);
            alloc.destroy(sub_ref);
        },
        .raw_ptr => |raw_ptr| {
            const sub_raw_ptr = switch (substituted) {
                .raw_ptr => |value| value,
                else => return,
            };
            if (sub_raw_ptr == raw_ptr) return;
            freeSubstitutedType(alloc, raw_ptr.pointee, sub_raw_ptr.pointee, param_names, args);
            alloc.destroy(sub_raw_ptr);
        },
        .slice => |slice| {
            const sub_slice = switch (substituted) {
                .slice => |value| value,
                else => return,
            };
            if (sub_slice == slice) return;
            freeSubstitutedType(alloc, slice.elem, sub_slice.elem, param_names, args);
            alloc.destroy(sub_slice);
        },
        .array => |array| {
            const sub_array = switch (substituted) {
                .array => |value| value,
                else => return,
            };
            if (sub_array == array) return;
            freeSubstitutedType(alloc, array.elem, sub_array.elem, param_names, args);
            alloc.destroy(sub_array);
        },
        .tuple => |tuple| {
            const sub_tuple = switch (substituted) {
                .tuple => |value| value,
                else => return,
            };
            if (sub_tuple.ptr == tuple.ptr) return;
            freeSubstitutedTypeSlice(alloc, tuple, sub_tuple, param_names, args);
        },
        .option => |option| {
            const sub_option = switch (substituted) {
                .option => |value| value,
                else => return,
            };
            if (sub_option == option) return;
            freeSubstitutedType(alloc, option.*, sub_option.*, param_names, args);
            alloc.destroy(sub_option);
        },
        .result => |result| {
            const sub_result = switch (substituted) {
                .result => |value| value,
                else => return,
            };
            if (sub_result == result) return;
            freeSubstitutedType(alloc, result.ok, sub_result.ok, param_names, args);
            freeSubstitutedType(alloc, result.err, sub_result.err, param_names, args);
            alloc.destroy(sub_result);
        },
        .boxed => |boxed| {
            const sub_boxed = switch (substituted) {
                .boxed => |value| value,
                else => return,
            };
            if (sub_boxed == boxed) return;
            freeSubstitutedType(alloc, boxed.*, sub_boxed.*, param_names, args);
            alloc.destroy(sub_boxed);
        },
        .@"opaque" => |opaque_type| {
            const sub_opaque = switch (substituted) {
                .@"opaque" => |value| value,
                else => return,
            };
            if (sub_opaque.bounds.ptr != opaque_type.bounds.ptr) {
                freeSubstitutedBounds(alloc, opaque_type.bounds, sub_opaque.bounds, param_names, args);
                if (sub_opaque.bounds.len > 0) alloc.free(sub_opaque.bounds);
            }
            if (sub_opaque.concrete) |sub_concrete| {
                if (opaque_type.concrete) |original_concrete| {
                    if (sub_concrete == original_concrete) return;
                    freeSubstitutedType(
                        alloc,
                        original_concrete.*,
                        sub_concrete.*,
                        param_names,
                        args,
                    );
                }
                alloc.destroy(sub_concrete);
            }
        },
        .dyn_trait => |bounds| {
            const sub_bounds = switch (substituted) {
                .dyn_trait => |value| value,
                else => return,
            };
            if (sub_bounds.ptr == bounds.ptr) return;
            freeSubstitutedBounds(alloc, bounds, sub_bounds, param_names, args);
            if (sub_bounds.len > 0) alloc.free(sub_bounds);
        },
        .fn_ptr => |fn_ptr| {
            const sub_fn_ptr = switch (substituted) {
                .fn_ptr => |value| value,
                else => return,
            };
            if (sub_fn_ptr == fn_ptr) return;
            freeSubstitutedTypeSlice(alloc, fn_ptr.params, sub_fn_ptr.params, param_names, args);
            freeSubstitutedType(alloc, fn_ptr.ret, sub_fn_ptr.ret, param_names, args);
            alloc.destroy(sub_fn_ptr);
        },
        .generic_inst => |generic_inst| {
            const sub_generic_inst = switch (substituted) {
                .generic_inst => |value| value,
                else => return,
            };
            if (sub_generic_inst.args.params.ptr == generic_inst.args.params.ptr) return;
            freeSubstitutedTypeSlice(
                alloc,
                generic_inst.args.params,
                sub_generic_inst.args.params,
                param_names,
                args,
            );
        },
        .external_nominal => |external| {
            const sub_external = switch (substituted) {
                .external_nominal => |value| value,
                else => return,
            };
            if (sub_external.args.ptr == external.args.ptr) return;
            freeSubstitutedTypeSlice(alloc, external.args, sub_external.args, param_names, args);
        },
        .prim, .path, .unsupported => {},
    }
}

/// Return whether a source type contains one of the named generic parameters.
pub fn typeContainsParam(t: Type, param_names: []const []const u8) bool {
    switch (t) {
        .prim, .unsupported => return false,
        .path => |p| {
            if (p.segments.len == 1) {
                return isTypeParam(t, param_names) != null;
            }
            return false;
        },
        .external_nominal => |external| {
            for (external.args) |arg| {
                if (typeContainsParam(arg, param_names)) return true;
            }
            return false;
        },
        .reference => |r| return typeContainsParam(r.pointee, param_names),
        .raw_ptr => |rp| return typeContainsParam(rp.pointee, param_names),
        .slice => |s| return typeContainsParam(s.elem, param_names),
        .array => |arr| return typeContainsParam(arr.elem, param_names),
        .tuple => |tup| {
            for (tup) |elem| {
                if (typeContainsParam(elem, param_names)) return true;
            }
            return false;
        },
        .fn_ptr => |fp| {
            for (fp.params) |elem| {
                if (typeContainsParam(elem, param_names)) return true;
            }
            return typeContainsParam(fp.ret, param_names);
        },
        .generic_inst => |gi| {
            for (gi.args.params) |elem| {
                if (typeContainsParam(elem, param_names)) return true;
            }
            return false;
        },
        .option => |opt| return typeContainsParam(opt.*, param_names),
        .result => |res| {
            return typeContainsParam(res.ok, param_names) or typeContainsParam(res.err, param_names);
        },
        .boxed => |bx| return typeContainsParam(bx.*, param_names),
        .@"opaque" => |opaque_type| {
            if (opaque_type.concrete) |concrete| {
                if (typeContainsParam(concrete.*, param_names)) return true;
            }
            return boundsContainParam(opaque_type.bounds, param_names);
        },
        .dyn_trait => |bounds| return boundsContainParam(bounds, param_names),
    }
}

fn boundsContainParam(bounds: []const Bound, param_names: []const []const u8) bool {
    for (bounds) |bound| {
        for (bound.args) |arg| {
            if (typeContainsParam(arg, param_names)) return true;
        }
        for (bound.associated_types) |binding| {
            if (typeContainsParam(binding.ty, param_names)) return true;
        }
    }
    return false;
}

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
    const inner: Type = .{ .result = blk: {
        const result = try arena.create(Result);
        result.* = .{
            .ok = self_leaf,
            .err = pair,
            .is_error_unionable = true,
        };
        break :blk result;
    } };
    const declared: Type = .{ .tuple = blk: {
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

fn testPrimPath(alloc: std.mem.Allocator, name: []const u8) !Type {
    const seg = try alloc.dupe(PathSegment, &.{.{ .name = name, .id = null }});
    return .{ .path = .{ .segments = seg } };
}

test "substType substitutes generic type parameters structurally" {
    const a = std.testing.allocator;

    const t_inner = try testPrimPath(a, "T");
    defer a.free(t_inner.path.segments);
    const param_names = try a.alloc([]const u8, 1);
    defer a.free(param_names);
    param_names[0] = "T";
    const args = try a.alloc(Type, 1);
    defer a.free(args);
    args[0] = .{ .prim = .u32 };

    // &T -> &u32.
    const ref_heap = try a.create(Ref);
    defer a.destroy(ref_heap);
    const ref_t: Type = .{ .reference = ref_heap };
    init_heap: {
        ref_heap.* = .{ .mut = false, .pointee = t_inner };
        const subst = try substType(a, ref_t, param_names, args);
        try std.testing.expect(subst == .reference);
        try std.testing.expectEqual(Type{ .prim = .u32 }, subst.reference.pointee);
        // Free the substituted Allocation's pointee (a prim — nothing to free)
        // and the substituted reference node itself.
        a.destroy(subst.reference);
        break :init_heap;
    }
}

fn checkBoundSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const parameter: Type = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    const declared: Type = .{ .dyn_trait = &.{.{
        .path = .{ .segments = &.{.{ .name = "Trait", .id = null }} },
        .args = &.{parameter},
        .associated_types = &.{.{ .name = "Item", .ty = .{ .prim = .bool } }},
        .optional = false,
    }} };
    const param_names = &.{"T"};
    const args = &.{Type{ .prim = .u32 }};
    const substituted = try substType(alloc, declared, param_names, args);
    defer freeSubstitutedType(alloc, declared, substituted, param_names, args);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.dyn_trait[0].args[0]);
    try std.testing.expectEqual(Type{ .prim = .bool }, substituted.dyn_trait[0].associated_types[0].ty);
}

test "substType releases partial generic bounds on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBoundSubstitutionAllocationFailures,
        .{},
    );
}

fn checkNestedSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const parameter: Type = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    const inner: Ref = .{ .mut = false, .pointee = parameter };
    const outer: Ref = .{ .mut = false, .pointee = .{ .reference = &inner } };
    const declared: Type = .{ .reference = &outer };
    const param_names = &.{"T"};
    const args = &.{Type{ .prim = .u32 }};
    const substituted = try substType(alloc, declared, param_names, args);
    defer freeSubstitutedType(alloc, declared, substituted, param_names, args);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.reference.pointee.reference.pointee);
}

test "substType releases nested reference substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkNestedSubstitutionAllocationFailures,
        .{},
    );
}

/// The generic-parameter slot every fixture below rewrites, and the borrowed
/// argument it rewrites it to. Both stay out of the fault-injected allocator
/// so an allocation sweep only ever exercises the containers `substType`
/// itself allocates.
const substitution_parameter: Type = .{
    .path = .{ .segments = &.{.{ .name = "T", .id = null }} },
};
const substitution_param_names: []const []const u8 = &.{"T"};
const substitution_args: []const Type = &.{Type{ .prim = .u32 }};

fn checkRawPtrSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const inner: Ref = .{ .mut = true, .pointee = substitution_parameter };
    const outer: RawPtr = .{ .mut = false, .pointee = .{ .reference = &inner } };
    const declared: Type = .{ .raw_ptr = &outer };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .raw_ptr);
    try std.testing.expectEqual(@as(bool, false), substituted.raw_ptr.mut);
    try std.testing.expect(substituted.raw_ptr.pointee == .reference);
    try std.testing.expectEqual(@as(bool, true), substituted.raw_ptr.pointee.reference.mut);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.raw_ptr.pointee.reference.pointee);
    // The borrowed source node is never released alongside the substituted copy.
    try std.testing.expectEqual(substitution_parameter, inner.pointee);
}

test "substType releases nested raw pointer substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRawPtrSubstitutionAllocationFailures,
        .{},
    );
}

fn checkSliceSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const inner: Slice = .{ .const_ = false, .elem = substitution_parameter };
    const outer: Slice = .{ .const_ = true, .elem = .{ .slice = &inner } };
    const declared: Type = .{ .slice = &outer };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .slice);
    try std.testing.expectEqual(@as(bool, true), substituted.slice.const_);
    try std.testing.expect(substituted.slice.elem == .slice);
    try std.testing.expectEqual(@as(bool, false), substituted.slice.elem.slice.const_);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.slice.elem.slice.elem);
    try std.testing.expectEqual(substitution_parameter, inner.elem);
}

test "substType releases nested slice substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSliceSubstitutionAllocationFailures,
        .{},
    );
}

fn checkArraySubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const declared_len: ArrayLen = .{ .literal = 4 };
    const inner: Ref = .{ .mut = false, .pointee = substitution_parameter };
    const outer: Array = .{ .elem = .{ .reference = &inner }, .len = declared_len };
    const declared: Type = .{ .array = &outer };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .array);
    try std.testing.expectEqual(declared_len, substituted.array.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.array.elem.reference.pointee);
    try std.testing.expectEqual(substitution_parameter, inner.pointee);
}

test "substType releases nested array substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkArraySubstitutionAllocationFailures,
        .{},
    );
}

fn checkTupleSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const first: Ref = .{ .mut = true, .pointee = substitution_parameter };
    const second: RawPtr = .{ .mut = true, .pointee = substitution_parameter };
    const declared: Type = .{ .tuple = &.{
        .{ .reference = &first },
        .{ .raw_ptr = &second },
        .{ .prim = .bool },
    } };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .tuple);
    try std.testing.expectEqual(@as(usize, 3), substituted.tuple.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.tuple[0].reference.pointee);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.tuple[1].raw_ptr.pointee);
    try std.testing.expectEqual(Type{ .prim = .bool }, substituted.tuple[2]);
    // Both borrowed sources survive the rollback of the partially built slice.
    try std.testing.expectEqual(substitution_parameter, first.pointee);
    try std.testing.expectEqual(substitution_parameter, second.pointee);
}

test "substType releases partial tuple substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkTupleSubstitutionAllocationFailures,
        .{},
    );
}

fn checkOptionSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const inner: RawPtr = .{ .mut = true, .pointee = substitution_parameter };
    const payload: Type = .{ .raw_ptr = &inner };
    const declared: Type = .{ .option = &payload };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .option);
    try std.testing.expect(substituted.option.* == .raw_ptr);
    try std.testing.expectEqual(@as(bool, true), substituted.option.*.raw_ptr.mut);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.option.*.raw_ptr.pointee);
    try std.testing.expectEqual(substitution_parameter, inner.pointee);
}

test "substType releases nested option substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOptionSubstitutionAllocationFailures,
        .{},
    );
}

fn checkResultSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const ok_slice: Slice = .{ .const_ = true, .elem = substitution_parameter };
    const err_ref: Ref = .{ .mut = false, .pointee = substitution_parameter };
    const payload: Result = .{
        .ok = .{ .slice = &ok_slice },
        .err = .{ .reference = &err_ref },
        .is_error_unionable = true,
    };
    const declared: Type = .{ .result = &payload };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .result);
    try std.testing.expectEqual(@as(bool, true), substituted.result.is_error_unionable);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.result.ok.slice.elem);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.result.err.reference.pointee);
    // A failure while building the second arm releases the first arm's node.
    try std.testing.expectEqual(substitution_parameter, ok_slice.elem);
    try std.testing.expectEqual(substitution_parameter, err_ref.pointee);
}

test "substType releases partial result substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResultSubstitutionAllocationFailures,
        .{},
    );
}

fn checkBoxedSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const payload: Type = .{ .tuple = &.{ substitution_parameter, .{ .prim = .bool } } };
    const declared: Type = .{ .boxed = &payload };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .boxed);
    try std.testing.expect(substituted.boxed.* == .tuple);
    try std.testing.expectEqual(@as(usize, 2), substituted.boxed.*.tuple.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.boxed.*.tuple[0]);
    try std.testing.expectEqual(Type{ .prim = .bool }, substituted.boxed.*.tuple[1]);
}

test "substType releases nested boxed substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBoxedSubstitutionAllocationFailures,
        .{},
    );
}

fn checkOpaqueSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const arg_ref: Ref = .{ .mut = true, .pointee = substitution_parameter };
    const bound_arg: Type = .{ .tuple = &.{.{ .reference = &arg_ref }} };
    const concrete_slice: Slice = .{ .const_ = false, .elem = substitution_parameter };
    const concrete: Type = .{ .slice = &concrete_slice };
    const declared: Type = .{ .@"opaque" = .{
        .bounds = &.{.{
            .path = .{ .segments = &.{.{ .name = "Trait", .id = null }} },
            .args = &.{bound_arg},
            .associated_types = &.{.{ .name = "Item", .ty = substitution_parameter }},
            .optional = false,
        }},
        .concrete = &concrete,
    } };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .@"opaque");
    try std.testing.expectEqual(@as(usize, 1), substituted.@"opaque".bounds.len);
    try std.testing.expectEqual(@as(usize, 1), substituted.@"opaque".bounds[0].args.len);
    try std.testing.expect(substituted.@"opaque".bounds[0].args[0] == .tuple);
    try std.testing.expectEqual(
        Type{ .prim = .u32 },
        substituted.@"opaque".bounds[0].args[0].tuple[0].reference.pointee,
    );
    try std.testing.expectEqual(
        Type{ .prim = .u32 },
        substituted.@"opaque".bounds[0].associated_types[0].ty,
    );
    try std.testing.expect(substituted.@"opaque".concrete != null);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.@"opaque".concrete.?.slice.elem);
    try std.testing.expectEqual(substitution_parameter, concrete_slice.elem);
    try std.testing.expectEqual(substitution_parameter, arg_ref.pointee);
}

test "substType releases opaque bound and concrete substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOpaqueSubstitutionAllocationFailures,
        .{},
    );
}

fn checkExternalNominalSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const arg: Ref = .{ .mut = true, .pointee = substitution_parameter };
    const declared: Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .reference = &arg }},
    } };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .external_nominal);
    try std.testing.expect(substituted.external_nominal.path.ptr == declared.external_nominal.path.ptr);
    try std.testing.expectEqual(@as(usize, 1), substituted.external_nominal.args.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.external_nominal.args[0].reference.pointee);
    try std.testing.expectEqual(substitution_parameter, arg.pointee);
}

test "substType releases external nominal argument substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkExternalNominalSubstitutionAllocationFailures,
        .{},
    );
}

fn checkGenericInstSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const declared_len: ArrayLen = .{ .literal = 3 };
    const first: Slice = .{ .const_ = true, .elem = substitution_parameter };
    const second: Array = .{ .elem = substitution_parameter, .len = declared_len };
    const declared: Type = .{ .generic_inst = .{
        .decl = 5,
        .args = .{ .params = &.{
            .{ .slice = &first },
            .{ .array = &second },
        } },
    } };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .generic_inst);
    try std.testing.expectEqual(@as(spine.EntityId, 5), substituted.generic_inst.decl);
    try std.testing.expectEqual(@as(usize, 2), substituted.generic_inst.args.params.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.generic_inst.args.params[0].slice.elem);
    try std.testing.expectEqual(declared_len, substituted.generic_inst.args.params[1].array.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.generic_inst.args.params[1].array.elem);
    try std.testing.expectEqual(substitution_parameter, first.elem);
    try std.testing.expectEqual(substitution_parameter, second.elem);
}

test "substType releases generic instantiation argument substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkGenericInstSubstitutionAllocationFailures,
        .{},
    );
}

fn checkFnPtrSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const param_slice: Slice = .{ .const_ = false, .elem = substitution_parameter };
    const ret_payload: Type = .{ .tuple = &.{ .{ .prim = .u8 }, substitution_parameter } };
    const payload: FnPtr = .{
        .params = &.{ .{ .slice = &param_slice }, .{ .prim = .bool } },
        .ret = ret_payload,
    };
    const declared: Type = .{ .fn_ptr = &payload };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    defer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .fn_ptr);
    try std.testing.expectEqual(@as(usize, 2), substituted.fn_ptr.params.len);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.fn_ptr.params[0].slice.elem);
    try std.testing.expectEqual(Type{ .prim = .bool }, substituted.fn_ptr.params[1]);
    try std.testing.expect(substituted.fn_ptr.ret == .tuple);
    try std.testing.expectEqual(@as(usize, 2), substituted.fn_ptr.ret.tuple.len);
    try std.testing.expectEqual(Type{ .prim = .u8 }, substituted.fn_ptr.ret.tuple[0]);
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.fn_ptr.ret.tuple[1]);
    try std.testing.expectEqual(substitution_parameter, param_slice.elem);
}

test "substType releases function pointer parameter substitutions" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkFnPtrSubstitutionAllocationFailures,
        .{},
    );
}

/// A substituted parameter becomes the caller's argument by reference. The
/// substituted container is owned by the caller of `substType`; releasing it
/// must reach the nodes `substType` allocated and stop at the borrowed
/// argument's own heap nodes.
fn checkBorrowedCompositeArgumentSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const borrowed_inner: Ref = .{ .mut = true, .pointee = .{ .prim = .f64 } };
    const borrowed_elems = [_]Type{
        .{ .reference = &borrowed_inner },
        .{ .prim = .bool },
    };
    const borrowed: Type = .{ .tuple = &borrowed_elems };
    const owned_ref: Ref = .{ .mut = false, .pointee = substitution_parameter };
    const declared: Type = .{ .tuple = &.{
        substitution_parameter,
        .{ .reference = &owned_ref },
    } };
    const args = &.{borrowed};
    const substituted = try substType(alloc, declared, substitution_param_names, args);
    errdefer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, args);
    try std.testing.expect(substituted == .tuple);
    try std.testing.expectEqual(@as(usize, 2), substituted.tuple.len);
    try std.testing.expectEqual(borrowed, substituted.tuple[0]);
    // The owned reference node wraps the borrowed argument; the argument itself
    // is substituted in by reference and carries no ownership here.
    try std.testing.expectEqual(borrowed, substituted.tuple[1].reference.pointee);
    freeSubstitutedType(alloc, declared, substituted, substitution_param_names, args);
    // The borrowed argument still owns its reference node after the release.
    try std.testing.expectEqual(@as(bool, true), borrowed_elems[0].reference.mut);
    try std.testing.expectEqual(Type{ .prim = .f64 }, borrowed_elems[0].reference.pointee);
    try std.testing.expectEqual(Type{ .prim = .bool }, borrowed_elems[1]);
}

test "substType keeps borrowed substitution arguments intact on rollback" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBorrowedCompositeArgumentSubstitutionAllocationFailures,
        .{},
    );
}

/// An opaque whose bounds and concrete type hold no generic parameter keeps
/// every nested source node borrowed. Only the freshly allocated copies may be
/// released; the nested source graph stays valid for the caller's next use.
fn checkUnchangedOpaqueSubstitutionAllocationFailures(alloc: std.mem.Allocator) !void {
    const nested_ref: Ref = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const nested_associated: Type = .{ .reference = &nested_ref };
    const nested_arg: Type = .{ .tuple = &.{nested_associated} };
    const declared_len: ArrayLen = .{ .literal = 2 };
    const nested_array: Array = .{ .elem = .{ .prim = .u8 }, .len = declared_len };
    const nested_concrete: Type = .{ .array = &nested_array };
    const declared: Type = .{ .@"opaque" = .{
        .bounds = &.{.{
            .path = .{ .segments = &.{.{ .name = "Marker", .id = null }} },
            .args = &.{nested_arg},
            .associated_types = &.{.{ .name = "Out", .ty = nested_associated }},
            .optional = true,
        }},
        .concrete = &nested_concrete,
    } };
    const substituted = try substType(alloc, declared, substitution_param_names, substitution_args);
    errdefer freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    try std.testing.expect(substituted == .@"opaque");
    try std.testing.expectEqual(@as(usize, 1), substituted.@"opaque".bounds.len);
    try std.testing.expectEqual(@as(bool, true), substituted.@"opaque".bounds[0].optional);
    try std.testing.expect(substituted.@"opaque".bounds[0].args[0].tuple[0] == .reference);
    try std.testing.expectEqual(
        Type{ .prim = .u8 },
        substituted.@"opaque".bounds[0].args[0].tuple[0].reference.pointee,
    );
    try std.testing.expectEqual(
        Type{ .prim = .u8 },
        substituted.@"opaque".bounds[0].associated_types[0].ty.reference.pointee,
    );
    try std.testing.expectEqual(Type{ .prim = .u8 }, substituted.@"opaque".concrete.?.array.elem);
    freeSubstitutedType(alloc, declared, substituted, substitution_param_names, substitution_args);
    // The borrowed source graph is untouched by the release of its copy.
    try std.testing.expectEqual(@as(bool, false), nested_ref.mut);
    try std.testing.expectEqual(Type{ .prim = .u8 }, nested_ref.pointee);
    try std.testing.expectEqual(Type{ .prim = .u8 }, nested_array.elem);
    try std.testing.expectEqual(declared_len, nested_array.len);
}

test "substType keeps unchanged opaque source nodes intact" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkUnchangedOpaqueSubstitutionAllocationFailures,
        .{},
    );
}

/// `struct Buf<const N: usize, T> { head: [T; N] }` — the declaration half of a
/// const generic, and the one use that half admits.
const const_generic_declaration: Generics = .{ .params = &.{
    .{ .const_ = .{ .name = "N", .ty = .{ .prim = .usize } } },
    .{ .type_ = .{ .name = "T", .bounds = &.{} } },
}, .where_clauses = &.{} };

/// Whether a payload IS a value rather than a description of one. Every `Type`
/// arm's payload goes through this, and none of them may: a value arm would be
/// the const generic argument slot `GenericArgs` deliberately does not have.
fn isValuePayload(comptime Payload: type) bool {
    return switch (@typeInfo(Payload)) {
        .int, .float, .bool => true,
        else => false,
    };
}

test "a const generic parameter is reached by index, and no Type carries its value" {
    // The boundary itself: every arm describes a type or points at one, so the
    // value a const generic argument supplies has nowhere in this union to go.
    inline for (@typeInfo(Type).@"union".field_types) |field_type| {
        try std.testing.expect(!isValuePayload(field_type));
    }

    // The declaration survives it: `N` is a const parameter, `T` a type one.
    try std.testing.expectEqual(@as(usize, 2), const_generic_declaration.params.len);
    try std.testing.expectEqualStrings("N", const_generic_declaration.params[0].const_.name);
    try std.testing.expectEqualStrings("T", const_generic_declaration.params[1].type_.name);

    // The use inside the declaration is the index the parameter declared at, and
    // that index is part of the type's identity: `[T; N]` is not `[T; M]`.
    const uses_const: Type = .{ .array = &.{
        .elem = substitution_parameter,
        .len = .{ .generic = 0 },
    } };
    const uses_type: Type = .{ .array = &.{
        .elem = substitution_parameter,
        .len = .{ .generic = 1 },
    } };
    try std.testing.expect(!deepEqual(uses_const, uses_type));

    // Substitution fills the type parameter's slot and leaves the const
    // parameter's index exactly as declared — there is no value to put there.
    const substituted = try substType(
        std.testing.allocator,
        uses_const,
        substitution_param_names,
        substitution_args,
    );
    defer freeSubstitutedType(
        std.testing.allocator,
        uses_const,
        substituted,
        substitution_param_names,
        substitution_args,
    );
    try std.testing.expectEqual(Type{ .prim = .u32 }, substituted.array.elem);
    try std.testing.expectEqual(ArrayLen{ .generic = 0 }, substituted.array.len);

    // A parameter walk answers for the type parameter alone: the length is not
    // a `Type` child, so a const parameter's name is never one it can find.
    try std.testing.expect(typeContainsParam(uses_const, substitution_param_names));
    try std.testing.expect(!typeContainsParam(uses_const, &.{"N"}));
}

test "a generic argument list holds one slot per type parameter" {
    const as_u8: Type = .{ .generic_inst = .{
        .decl = 7,
        .args = .{ .params = &.{.{ .prim = .u8 }} },
    } };
    const as_u32: Type = .{ .generic_inst = .{
        .decl = 7,
        .args = .{ .params = &.{.{ .prim = .u32 }} },
    } };
    // The slot this list does have is identity: two applications that differ
    // in it are two types, and an equal one is the same type.
    try std.testing.expect(!deepEqual(as_u8, as_u32));
    try std.testing.expect(deepEqual(as_u8, .{ .generic_inst = .{
        .decl = 7,
        .args = .{ .params = &.{.{ .prim = .u8 }} },
    } }));

    // There is exactly one slot per TYPE parameter of the declaration, and the
    // `const N: usize` it also declares takes none: that is the count
    // `validate` measures, and the reason it refuses an instantiation of a
    // const-generic declaration instead of admitting one with a hole in it.
    var type_parameters: usize = 0;
    for (const_generic_declaration.params) |parameter| {
        if (parameter == .type_) type_parameters += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), type_parameters);
    try std.testing.expectEqual(type_parameters, as_u8.generic_inst.args.params.len);
}
