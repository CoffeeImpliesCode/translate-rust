//! translate_rust.model.ownership — Ownership, Borrow, Drop, Allocator,
//! Unsoundness (P3 model layer).
//! See notes/design/data-model/ownership-mem.md §1–§5.
//!
//! The IR cannot represent Rust borrow-checking; it records enough **usage**
//! so the emitter produces semantically identical Zig and flags points where
//! Zig's runtime checks do **not** reproduce Rust's borrow safety.  Every
//! unsoundness point is an explicit marker — never silent omission.

const std = @import("std");
const spine = @import("spine.zig");

// ── ID aliases ─────────────────────────────────────────────────────────────

/// Drop / ownership location (local, field, box, arena).
pub const EntityRef = spine.EntityId;
/// Node reference (expression / statement / pattern id).
pub const NodeRef = spine.EntityId;
/// Zig type index (resolved from SCIP signature).
pub const ZigTyRef = spine.TypeId;

// ── §2.1 Value kind: move vs Copy ─────────────────────────────────────────

pub const ValueKind = enum {
    move,
    copy,
    /// Has a Drop impl; moves transfer the drop owner.
    move_drop,
};

/// Ownership banner on a value-typed node.
pub const Ownership = struct {
    kind: ValueKind,
    /// Drop location: local / field / box / arena.  null = no owner
    /// (e.g. `Copy` type).
    owner: ?EntityRef,
    moved_across_boundary: bool = false,
    span: spine.Span,
};

// ── §2.2 By-value vs by-reference params and receivers ────────────────────

pub const BorrowKind = enum {
    owned, // T
    shared, // &T  → *const T
    mutable, // &mut T → *T (unique; emitter must not alias)
    slice_const, // &[T] → []const T
    slice_mut, // &mut [T] → []T
};

/// Shape of a parameter in the Zig output; driven by the SCIP signature.
pub const ParamShape = struct {
    borrow: BorrowKind,
    zig_ty: ZigTyRef,
    is_receiver: bool = false,
    lifetime_uses: std.ArrayListUnmanaged(UnsoundMarker) = .empty,
    span: spine.Span,
};

// ── §3 Drop / RAII ────────────────────────────────────────────────────────

pub const DropStrategy = enum {
    /// v1: defer (and errdefer on error paths).
    defer_only,
    /// Deferred: path-sensitive; an alive bit carries the state.
    alive_flag,
};

pub const DropInfo = struct {
    /// impl Drop body, else field-wise drop.
    drop_impl: ?EntityRef,
    field_order: std.ArrayListUnmanaged(FieldDrop) = .empty,
    strategy: DropStrategy,
    uses_allocator: bool = false,
    allocator: ?AllocatorUse,
    span: spine.Span,
};

pub const FieldDrop = struct {
    field: EntityRef,
    drop: DropInfo,
};

// ── §4 Allocator / arena strategy ─────────────────────────────────────────

pub const AllocatorSource = enum {
    /// Injected leading param (default for any allocator fn).
    param,
    /// Owning struct holds an arena allocator.
    field,
    /// Harness-owned single arena (no_std v1 test entry).
    global_arena,
    /// Fn does not allocate; v1-legal.
    none,
};

pub const AllocPrim = enum {
    /// Box<T> → gpa.create / gpa.destroy
    create_destroy,
    /// Slice-of-T → gpa.alloc / gpa.free
    alloc_free,
    /// alignedAlloc (Box<[u8;N]>)
    aligned,
    /// Owned bucket → arena.alloc / arena.deinit
    arena,
};

pub const AllocatorUse = struct {
    source: AllocatorSource,
    /// .param: insertion position.
    param_index: ?u16,
    /// .field: which field owns the arena.
    owner_field: ?EntityRef,
    prim: AllocPrim,
    span: spine.Span,
};

// ── §5 Unsoundness marker ─────────────────────────────────────────────────

pub const UnsoundCategory = enum {
    /// &mut uniqueness unenforced.
    alias_mut,
    /// UAF Zig may not catch (Roc's two UAFs).
    borrow_outlives_owner,
    /// Returned pointer may dangle post-erasure.
    returned_dangling,
    /// Copy preserved only by convention.
    copy_alias,
    /// *T/atomic not gated by Zig checks (deferred).
    interior_mut,
};

pub const Severity = enum {
    /// Always emit `// UNSOUND: <message>`.
    comment,
    /// Add runtime guard: `if (!cond) @panic(...)`.
    assert_unreachable,
    /// Refuse to emit unless human override flag is passed.
    redesign_required,
};

pub const UnsoundMarker = struct {
    category: UnsoundCategory,
    at: NodeRef,
    severity: Severity,
    message: []const u8,
    span: spine.Span,
};

/// Alias: used in ParamShape.lifetime_uses (semantically identical).
pub const UnsoundUsage = UnsoundMarker;

// =============================================================================
// Tests — instantiate every enum and struct to prove compile.  All values use
// compile-time static slices; no allocator needed (mirrors items.zig).
// =============================================================================

test "ownership — every enum variant compiles" {
    // ValueKind
    const vk_move: ValueKind = .move;
    const vk_copy: ValueKind = .copy;
    const vk_move_drop: ValueKind = .move_drop;
    _ = vk_move;
    _ = vk_copy;
    _ = vk_move_drop;

    // BorrowKind
    const bk_owned: BorrowKind = .owned;
    const bk_shared: BorrowKind = .shared;
    const bk_mut: BorrowKind = .mutable;
    const bk_sc: BorrowKind = .slice_const;
    const bk_sm: BorrowKind = .slice_mut;
    _ = bk_owned;
    _ = bk_shared;
    _ = bk_mut;
    _ = bk_sc;
    _ = bk_sm;

    // DropStrategy
    const ds_defer: DropStrategy = .defer_only;
    const ds_alive: DropStrategy = .alive_flag;
    _ = ds_defer;
    _ = ds_alive;

    // AllocatorSource
    const as_param: AllocatorSource = .param;
    const as_field: AllocatorSource = .field;
    const as_arena: AllocatorSource = .global_arena;
    const as_none: AllocatorSource = .none;
    _ = as_param;
    _ = as_field;
    _ = as_arena;
    _ = as_none;

    // AllocPrim
    const ap_create: AllocPrim = .create_destroy;
    const ap_alloc: AllocPrim = .alloc_free;
    const ap_aligned: AllocPrim = .aligned;
    const ap_arena: AllocPrim = .arena;
    _ = ap_create;
    _ = ap_alloc;
    _ = ap_aligned;
    _ = ap_arena;

    // UnsoundCategory
    const uc_alias: UnsoundCategory = .alias_mut;
    const uc_borrow: UnsoundCategory = .borrow_outlives_owner;
    const uc_dang: UnsoundCategory = .returned_dangling;
    const uc_copy: UnsoundCategory = .copy_alias;
    const uc_im: UnsoundCategory = .interior_mut;
    _ = uc_alias;
    _ = uc_borrow;
    _ = uc_dang;
    _ = uc_copy;
    _ = uc_im;

    // Severity
    const se_comment: Severity = .comment;
    const se_assert: Severity = .assert_unreachable;
    const se_redesign: Severity = .redesign_required;
    _ = se_comment;
    _ = se_assert;
    _ = se_redesign;
}

test "ownership — every struct compiles" {
    const span = spine.Span{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Ownership (every ValueKind + optional owner)
    const own_move: Ownership = .{ .kind = .move, .owner = 1, .moved_across_boundary = false, .span = span };
    const own_copy: Ownership = .{ .kind = .copy, .owner = null, .span = span };
    const own_drop: Ownership = .{ .kind = .move_drop, .owner = 2, .moved_across_boundary = true, .span = span };
    _ = own_move;
    _ = own_copy;
    _ = own_drop;

    // ParamShape (all BorrowKind + optional fields)
    const ps_owned: ParamShape = .{ .borrow = .owned, .zig_ty = 10, .span = span };
    const ps_shared: ParamShape = .{ .borrow = .shared, .zig_ty = 11, .is_receiver = true, .span = span };
    const ps_mut: ParamShape = .{ .borrow = .mutable, .zig_ty = 12, .span = span };
    const ps_sc: ParamShape = .{ .borrow = .slice_const, .zig_ty = 13, .span = span };
    const ps_sm: ParamShape = .{ .borrow = .slice_mut, .zig_ty = 14, .span = span };
    _ = ps_owned;
    _ = ps_shared;
    _ = ps_mut;
    _ = ps_sc;
    _ = ps_sm;

    // AllocatorUse (every AllocatorSource + AllocPrim)
    const au_param: AllocatorUse = .{
        .source = .param,
        .param_index = 0,
        .owner_field = null,
        .prim = .create_destroy,
        .span = span,
    };
    const au_field: AllocatorUse = .{
        .source = .field,
        .param_index = null,
        .owner_field = 42,
        .prim = .arena,
        .span = span,
    };
    const au_arena: AllocatorUse = .{
        .source = .global_arena,
        .param_index = null,
        .owner_field = null,
        .prim = .arena,
        .span = span,
    };
    const au_none: AllocatorUse = .{
        .source = .none,
        .param_index = null,
        .owner_field = null,
        .prim = .alloc_free,
        .span = span,
    };
    _ = au_param;
    _ = au_field;
    _ = au_arena;
    _ = au_none;

    // UnsoundMarker
    const um: UnsoundMarker = .{
        .category = .alias_mut,
        .at = 301,
        .severity = .comment,
        .message = "&mut uniqueness not enforced by Zig",
        .span = span,
    };
    _ = um;

    // UnsoundUsage alias
    const uu: UnsoundUsage = .{
        .category = .borrow_outlives_owner,
        .at = 400,
        .severity = .assert_unreachable,
        .message = "borrow may outlive its referent after lifetime erasure",
        .span = span,
    };
    _ = uu;

    // DropInfo (strategy + optional allocator; field_order starts empty)
    const di_defer: DropInfo = .{
        .drop_impl = null,
        .strategy = .defer_only,
        .uses_allocator = true,
        .allocator = .{
            .source = .global_arena,
            .param_index = null,
            .owner_field = null,
            .prim = .arena,
            .span = span,
        },
        .span = span,
    };
    const di_noalloc: DropInfo = .{
        .drop_impl = 50,
        .strategy = .alive_flag,
        .uses_allocator = false,
        .allocator = null,
        .span = span,
    };
    _ = di_noalloc;

    // FieldDrop — consumes di_defer
    const fd: FieldDrop = .{
        .field = 43,
        .drop = di_defer,
    };
    _ = fd;
}
