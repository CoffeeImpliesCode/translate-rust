//! translate_rust.model.bodies — the per-entity body tables shared by the
//! wire format (json.zig) and the emitter (emit.zig). Extracted to a leaf
//! module so json.zig and emit.zig (which mutually reference each other's
//! types) do not create an import cycle. Both re-export these names.

const exprs = @import("exprs.zig");
const items = @import("items.zig");
const types = @import("types.zig");

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
};

/// Per-entity body selector. Indexed by spine.EntityId.
pub const BodyKind = union(enum) {
    none,
    const_: ConstBody,
    fn_: FnBody,
};

/// Augmented model carrying expression-level data. The emitter (`emitRich`)
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
    const b = Bodies{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    _ = b;
    const k = BodyKind{ .none = {} };
    _ = k;
}
