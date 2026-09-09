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
    pub fn add(self: *SymbolTable, entity: Entity) !EntityId {
        const id: EntityId = @intCast(self.entities.items.len);
        var e = entity;
        e.id = id;
        try self.entities.append(self.allocator, e);
        return id;
    }

    pub fn count(self: *const SymbolTable) usize {
        return self.entities.items.len;
    }

    pub fn get(self: *const SymbolTable, id: EntityId) ?Entity {
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

test "visibility round trips through the union" {
    const v: Visibility = .{ .in_path = "crate::foo" };
    switch (v) {
        .in_path => |p| try std.testing.expectEqualStrings("crate::foo", p),
        else => @panic("expected in_path"),
    }
}
