//! translate_rust.model.bodies — the per-entity body tables shared by the
//! wire format (backend) and the backend (emit.zig). Extracted to a leaf
//! module so json.zig and emit.zig (which mutually reference each other's
//! types) do not create an import cycle. Both re-export these names.

const exprs = @import("exprs.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const spine = @import("spine.zig");

/// Metadata attached to a `const` body (type + init expression).
pub const ConstBody = struct {
    ty: types.Type,
    init: exprs.NodeId,
};

/// Body of a function (params + return type + block expression).
pub const FnBody = struct {
    params: []const items.Param,
    ret: types.Type,
    /// Expr-table index of the fn body block.
    body: exprs.NodeId,
    is_allocating: bool = false,
};

/// Inherent struct method definition with receiver and body.
pub const StructMethod = struct {
    name: []const u8,
    visibility: spine.Visibility = .public,
    params: []const items.Param = &.{},
    ret: types.Type,
    body: exprs.NodeId,
    receiver: ?items.Receiver = null,
    is_allocating: bool = false,
};

/// Body of a struct definition (generic parameters, layout, fields, inherent methods).
pub const StructBody = struct {
    generic_params: []const []const u8 = &.{},
    trait_bounds: []const []const u8 = &.{},
    layout: items.struct_kind = .named,
    fields: []const items.Field = &.{},
    methods: []const StructMethod = &.{},
    has_dynamic_resources: bool = false,
};

/// Body of an enum definition (kind, variants, optional integer repr, non_exhaustive).
pub const EnumBody = struct {
    kind: items.enum_kind = .c_like,
    variants: []const items.Variant = &.{},
    repr_int: ?items.int_repr = null,
    non_exhaustive: bool = false,
};
/// Trait method signature for VTable and TraitObject generation.
pub const TraitMethodSig = struct {
    name: []const u8,
    params: []const items.Param = &.{},
    ret: types.Type,
    receiver: items.Receiver = .ref_,
};

/// Trait declaration body (supertraits, method signatures).
pub const TraitBody = struct {
    name: []const u8,
    supertraits: []const []const u8 = &.{},
    methods: []const TraitMethodSig = &.{},
};

/// Body of a type alias definition.
pub const TypeAliasBody = struct {
    target: types.Type,
};

/// Per-entity body selector. Indexed by spine.EntityId.
pub const BodyKind = union(enum) {
    none,
    const_: ConstBody,
    fn_: FnBody,
    struct_: StructBody,
    enum_: EnumBody,
    trait_: TraitBody,
    type_alias: TypeAliasBody,
};
/// Augmented model carrying expression-level data. The backend (`emitRich`)
/// and the wire decoder (`json.parseFull`) share this exact type.
pub const Bodies = struct {
    exprs: []const exprs.Expr,
    stmts: []const exprs.Statement,
    pats: []const exprs.Pattern,
    types: []const types.Type,
    /// Sparse: `bodies[entity_id]` → `.none` when the entity has no body.
    bodies: []const BodyKind,
};

test "bodies shapes instantiate" {
    const b: Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    _ = b;
    const k: BodyKind = .{ .none = {} };
    _ = k;
}
