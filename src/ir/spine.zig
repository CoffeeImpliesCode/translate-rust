//! translate_rust.ir.spine — the shared spine of the lossless semantic IR.
//! Every entity is keyed by a dense EntityId into a SymbolTable.

const std = @import("std");

/// Source span (1-based line/col).
pub const Span = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

/// Dense, IR-local index into a SymbolTable's entities.
pub const EntityId = u32;
/// Dense index into a crate's type table.
pub const TypeId = u32;

pub const EntityKind = enum {
    crate_,
    module,
    struct_,
    enum_,
    union_,
    fn_,
    method_ref,
    const_,
    static_,
    trait_,
    impl_,
    type_alias,
    use_,
    extern_crate,

    macro_,
    field,
    variant,
};

/// How many ids at the TOP of the id space are reserved for the deferred
/// binders. A real declaration may never take one, and a placeholder may never
/// fall out of the band.
///
/// This module is the ONLY place a placeholder id may be computed. A frontend
/// that mints its own must derive it from `deferredPlaceholder` rather than
/// re-deriving `maxInt - ordinal`: an independently written copy of that
/// subtraction has no floor, so it keeps handing out ids the table is still free
/// to mint, and the collision arrives as two declarations with one id rather
/// than as an out-of-range error.
pub const deferred_placeholder_reserve: usize = 4096;

/// The FIRST placeholder id, and the top of the reserved band.
///
/// A `SymbolTable` hands out dense ids from `0`, so a real entity id is always
/// its own row index and `add` refuses rather than reach this value. A DEFERRED
/// BINDER — an `impl`, or a generic application, whose target extraction has
/// not resolved yet — names a declaration that has no row to be, so it is given
/// a synthetic id counted down from here instead (see `deferredPlaceholder`).
pub const deferred_placeholder_base: EntityId = std.math.maxInt(EntityId);

/// The LOWEST id the reserved band reaches: the LAST placeholder, and the
/// first id no graph entity may ever take.
///
/// The band is `[deferred_placeholder_floor, deferred_placeholder_base]` and
/// the entity range is `[0, deferred_placeholder_floor)`. Naming the frontier
/// as ONE constant is what makes the two ranges provably disjoint instead of
/// two independent formulas that must be kept in step: every placeholder is at
/// or above the floor and every mintable index is below it, so neither can
/// reach a member of the other. Counting placeholders DOWN from the top of the
/// space while the table counts UP from the bottom would otherwise meet in the
/// middle, and the first meeting — `deferred_placeholder_base - 1` — is a
/// perfectly mintable row index.
pub const deferred_placeholder_floor: EntityId = deferred_placeholder_base -
    @as(EntityId, @intCast(deferred_placeholder_reserve - 1));

/// The placeholder id for the `ordinal`-th deferred binder.
///
/// `ordinal` counts binders from zero, so the first placeholder is exactly
/// `deferred_placeholder_base` and the last is exactly
/// `deferred_placeholder_floor`. Null once the band is exhausted, which is the
/// one answer a caller may not paper over: handing out one more id would step
/// BELOW the floor into the entity range, where `base - 1` names a real row and
/// the collision would be silent.
pub fn deferredPlaceholder(ordinal: usize) ?EntityId {
    if (ordinal >= deferred_placeholder_reserve) return null;
    return deferred_placeholder_base - @as(EntityId, @intCast(ordinal));
}

/// Whether `id` is a deferred binder's placeholder rather than an entity.
///
/// A reader that has to tell the two apart — a resolver following a
/// `GenericInst.decl`, say — asks here instead of comparing against a table,
/// so the answer stays true for a graph that has no rows at all. This is the
/// exact complement of `canMintIdAt` over the whole id space, so an id is a
/// placeholder or is a mintable index and never both.
pub fn isDeferredPlaceholder(id: EntityId) bool {
    return id >= deferred_placeholder_floor;
}

/// Whether a table holding `len` rows may mint the id at that index.
///
/// The frontier between the two id spaces is one id wide, and this predicate is
/// the whole of the collision claim: every index below
/// `deferred_placeholder_floor` is a real entity's, and the floor itself is the
/// last placeholder's, so a table that reached it would name one declaration by
/// two ids.
pub fn canMintIdAt(len: usize) bool {
    return len < @as(usize, deferred_placeholder_floor);
}

/// Full Rust visibility lattice, kept losslessly; reduced to Zig pub/private
/// only at emit time.
pub const Visibility = union(enum) {
    public,
    crate_restricted,
    super_restricted,
    in_path: []const u8,
    private,
};

/// Preserved raw attribute; `known` marks ones the backend understands and
/// acts on (repr, no_mangle, non_exhaustive, ...).
pub const Attribute = struct {
    name: []const u8,
    meta: []const u8,
    known: bool,
};

pub const Entity = struct {
    id: EntityId,
    kind: EntityKind,
    name: []const u8, // definition-site name (pre-rename)
    /// Whether `CrateGraph.deinit` owns `name` and must free it.
    ///
    /// `name` is a caller-supplied slice, so ownership is a fact about the
    /// call and not about the type. A caller that hands over a string literal,
    /// or any slice it does not itself own, must say so here: freeing such a
    /// slice corrupts memory the graph never had — and because Zig dedupes
    /// identical literals, one such free can damage a `"self"` or `""` that
    /// every other part of the same test binary compares against. The default
    /// is owned, which is what every production construction site does (it
    /// dupes) and what the free path has always assumed; `false` is the
    /// deliberate statement that this particular name belongs to someone else.
    ///
    /// The same contract applies to `renamed_to`, `visibility.in_path` and
    /// `attributes`, which `deinit` still frees unconditionally; this flag
    /// covers `name` only, because `name` is the one a source-derived slice
    /// reaches most often.
    name_owned: bool = true,
    span: Span,
    visibility: Visibility,
    parent: ?EntityId, // containing module/impl/union
    resolved: ?EntityId, // if a use/alias: the target definition
    renamed_to: ?[]const u8, // emitted name if renamed / keyword-escaped @"name"
    attributes: []const Attribute,
};

/// A finite language feature the model is *designed* for but not translated
/// yet. Always explicit — never silent omission.
pub const Unsupported = struct {
    reason: UnsupportedReason,
    message: []const u8,
    span: Span,
};

pub const UnsupportedReason = enum {
    std_prelude,
    async_,
    dyn_trait,
    proc_macro,
    workspace_dep,
    cfg_gated,
    catch_unwind,
    iterators,
    closures,
    rc_arc_refcell,
};

/// Dense EntityId -> Entity store. EntityId == index into `entities`.
pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayListUnmanaged(Entity) = .empty,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.entities.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append an entity, assigning the next dense id (the caller-supplied
    /// `.id` field is overwritten with the authoritative index).
    ///
    /// The id is the row's own index and the caller's `.id` is discarded, so an
    /// EntityId names exactly one row for the life of the table and no id is
    /// ever handed to a second declaration. A caller cannot reach into the
    /// table to reuse one either: `entities` grows only here, only at the end,
    /// and only after the append — so a row's index is fixed the moment the row
    /// exists and no later row can displace it.
    ///
    /// The reserved band `deferred_placeholder_floor` and above belongs to the
    /// deferred binders, so a table refuses to grow into it rather than mint an
    /// id a placeholder already owns — a collision there would be silent,
    /// because both ids would resolve to a declaration.
    pub fn add(self: *SymbolTable, entity: Entity) !EntityId {
        const len = self.entities.items.len;
        if (!canMintIdAt(len)) return error.EntityIdRangeExhausted;
        const id: EntityId = @intCast(len);
        var e = entity;
        e.id = id;
        try self.entities.append(self.allocator, e);
        return id;
    }

    pub fn count(self: *const SymbolTable) usize {
        return self.entities.items.len;
    }

    /// The row `id` names, or null when this table has no such row.
    ///
    /// A placeholder id is answered null for the same reason an index past the
    /// end is: it names no row here, and answering the LAST row for it would be
    /// worse than answering nothing. `canMintIdAt` is what keeps a row from
    /// ever existing at such an index.
    pub fn get(self: *const SymbolTable, id: EntityId) ?Entity {
        if (!canMintIdAt(@as(usize, id))) return null;
        if (id >= self.entities.items.len) return null;
        return self.entities.items[id];
    }
};

test "symbol table assigns dense ids" {
    const span: Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 2 };
    var st = SymbolTable.init(std.testing.allocator);
    defer st.deinit();

    const a = try st.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "a",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const b = try st.add(.{
        .id = 0,
        .kind = .module,
        .name = "b",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    try std.testing.expectEqual(@as(EntityId, 0), a);
    try std.testing.expectEqual(@as(EntityId, 1), b);
    try std.testing.expectEqual(@as(usize, 2), st.count());
    try std.testing.expectEqual(EntityKind.module, st.get(1).?.kind);
    try std.testing.expectEqual(@as(EntityId, 1), st.get(1).?.id);
}

test "an EntityId names one declaration and is never reused for another" {
    const span: Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 2 };
    var st = SymbolTable.init(std.testing.allocator);
    defer st.deinit();

    // Every row asks for a DIFFERENT id than the one it gets, and every row
    // carries a name of its own. The table hands out indices, so the id a
    // declaration reads back is the id it was given and the name it reads back
    // is its own: an id that named two declarations, or one declaration under
    // two ids, would answer one of these two lines with the other's value.
    const kinds = [_]EntityKind{ .fn_, .struct_, .enum_, .trait_, .impl_, .const_ };
    var ids: [kinds.len]EntityId = undefined;
    var index: usize = 0;
    while (index < kinds.len) : (index += 1) {
        ids[index] = try st.add(.{
            .id = @intCast(kinds.len - index),
            .kind = kinds[index],
            .name = @tagName(kinds[index]),
            .span = span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
            .name_owned = false,
        });
    }
    index = 0;
    while (index < kinds.len) : (index += 1) {
        const id = ids[index];
        try std.testing.expectEqual(@as(usize, index), @as(usize, id));
        try std.testing.expectEqual(kinds[index], st.get(id).?.kind);
        try std.testing.expectEqualStrings(@tagName(kinds[index]), st.get(id).?.name);
    }

    // One id, one row: no other row answers for it, and `get` past the end is
    // an absent answer rather than the last row again.
    try std.testing.expect(st.get(kinds.len) == null);
}

test "a deferred binder placeholder can never collide with a real EntityId" {
    // The first placeholder sits at the very top of the id space and each
    // further binder steps down by one, so no two binders ever share an id.
    const first = deferredPlaceholder(0);
    const second = deferredPlaceholder(1);
    const third = deferredPlaceholder(2);
    try std.testing.expectEqual(@as(?EntityId, deferred_placeholder_base), first);
    try std.testing.expect(first.? > second.? and second.? > third.?);

    // EVERY placeholder in the band, not a sample of them. The band is 4096
    // wide, so this is exhaustive rather than illustrative: for each ordinal the
    // id is inside the reserved range, `isDeferredPlaceholder` calls it a
    // placeholder, and — the claim that matters — `canMintIdAt` refuses to mint
    // it. A table that could mint a placeholder's id would name one declaration
    // by two ids, and this is the line that rules it out.
    var ordinal: usize = 0;
    while (ordinal < deferred_placeholder_reserve) : (ordinal += 1) {
        const id = deferredPlaceholder(ordinal) orelse unreachable;
        try std.testing.expect(isDeferredPlaceholder(id));
        try std.testing.expect(!canMintIdAt(@as(usize, id)));
        try std.testing.expectEqual(
            deferred_placeholder_base - @as(EntityId, @intCast(ordinal)),
            id,
        );
    }

    // The last id in the band is the floor itself, so it belongs to the
    // placeholders and the largest mintable index is one below it. Both sides
    // of that one-id frontier are named rather than allocated, because a table
    // cannot hold four billion rows.
    const last_placeholder = deferredPlaceholder(deferred_placeholder_reserve - 1) orelse unreachable;
    try std.testing.expectEqual(deferred_placeholder_floor, last_placeholder);
    const last_mintable: usize = @as(usize, deferred_placeholder_floor) - 1;
    try std.testing.expect(canMintIdAt(last_mintable));
    try std.testing.expect(!canMintIdAt(last_mintable + 1));
    try std.testing.expect(!isDeferredPlaceholder(@as(EntityId, @intCast(last_mintable))));
    try std.testing.expect(isDeferredPlaceholder(last_placeholder));

    // `canMintIdAt` and `isDeferredPlaceholder` are exact complements over the
    // id space: an id is mintable or is a placeholder, never both and never
    // neither. Checked at the floor and at the top, which is where a formula
    // that disagreed with itself would show it.
    try std.testing.expectEqual(
        canMintIdAt(@as(usize, deferred_placeholder_floor)),
        !isDeferredPlaceholder(deferred_placeholder_floor),
    );
    try std.testing.expectEqual(
        canMintIdAt(@as(usize, deferred_placeholder_base)),
        !isDeferredPlaceholder(deferred_placeholder_base),
    );
    try std.testing.expect(!canMintIdAt(@as(usize, deferred_placeholder_base)));
    if (@bitSizeOf(usize) > @bitSizeOf(EntityId)) {
        try std.testing.expect(!canMintIdAt(@as(usize, deferred_placeholder_base) + 1));
    }

    // One ordinal past the band is refused rather than wrapped or clamped. The
    // step down from the last placeholder is what would land on
    // `deferred_placeholder_floor - 1`, a perfectly mintable row index, so this
    // null is the answer that keeps the two id spaces apart.
    try std.testing.expectEqual(@as(?EntityId, null), deferredPlaceholder(deferred_placeholder_reserve));
    try std.testing.expectEqual(@as(?EntityId, null), deferredPlaceholder(deferred_placeholder_reserve + 1));
    try std.testing.expectEqual(@as(?EntityId, null), deferredPlaceholder(std.math.maxInt(usize)));

    // A real table hands out ids from the bottom of the entity range, and every
    // one it hands out names a row and answers `false` for the placeholder
    // question.
    var st = SymbolTable.init(std.testing.allocator);
    defer st.deinit();
    const id = try st.add(.{
        .id = 0,
        .kind = .module,
        .name = "root",
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 2 },
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
        .name_owned = false,
    });
    try std.testing.expect(!isDeferredPlaceholder(id));
    try std.testing.expect(st.get(id) != null);
    try std.testing.expect(canMintIdAt(@as(usize, id) + 1));

    // `get` answers null for every placeholder id even when it is asked of a
    // table that HAS rows, so no reader can resolve a binder's placeholder to
    // some unrelated declaration.
    var probe: usize = 0;
    while (probe < deferred_placeholder_reserve) : (probe += 1) {
        const probe_id = deferredPlaceholder(probe) orelse unreachable;
        try std.testing.expectEqual(@as(?Entity, null), st.get(probe_id));
    }
}

test "visibility round trips through the union" {
    const v: Visibility = .{ .in_path = "crate::foo" };
    switch (v) {
        .in_path => |p| try std.testing.expectEqualStrings("crate::foo", p),
        else => @panic("expected in_path"),
    }
}
