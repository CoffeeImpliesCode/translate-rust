//! translate_rust.model.bodies — the per-entity body tables shared by the
//! wire format (backend) and the backend (emit.zig). Extracted to a leaf
//! module so json.zig and emit.zig (which mutually reference each other's
//! types) do not create an import cycle. Both re-export these names.

const std = @import("std");
const graph = @import("graph.zig");
const exprs = @import("exprs.zig");
const items = @import("items.zig");
const types = @import("types.zig");
const spine = @import("spine.zig");

/// Metadata attached to a `const` body (type + init expression).
pub const ConstBody = struct {
    ty: types.Type,
    init: exprs.NodeId,
};

/// A trait-associated constant declaration.
pub const TraitAssocConst = struct {
    name: []const u8,
    ty: types.Type,
    default: ?exprs.NodeId = null,
};

/// Body of a function (params + return type + block expression).
pub const FnBody = struct {
    params: []const items.Param,
    ret: types.Type,
    /// Ordered Rust type parameter names, owned by the frontend arena.
    generic_params: []const []const u8 = &.{},
    /// Full generic bounds, when source metadata provides them.
    generics: ?types.Generics = null,
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
    /// Ordered Rust type parameter names, owned by the frontend arena.
    generic_params: []const []const u8 = &.{},
    /// Full generic bounds, when source metadata provides them.
    generics: ?types.Generics = null,
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
    generic_params: []const []const u8 = &.{},
    variants: []const items.Variant = &.{},
    repr_int: ?items.int_repr = null,
    non_exhaustive: bool = false,
};
/// Trait method signature for VTable and TraitObject generation.
pub const TraitMethodSig = struct {
    name: []const u8,
    params: []const items.Param = &.{},
    ret: types.Type,
    /// Ordered Rust type parameter names, owned by the frontend arena.
    generic_params: []const []const u8 = &.{},
    /// Full generic bounds, when source metadata provides them.
    generics: ?types.Generics = null,
    receiver: items.Receiver = .ref_,
};

/// Trait declaration body (supertraits, methods, associated declarations).
pub const TraitBody = struct {
    name: []const u8,
    /// Ordered Rust type parameter names, owned by the frontend arena.
    generic_params: []const []const u8 = &.{},
    /// Full generic bounds, when source metadata provides them.
    generics: ?types.Generics = null,
    supertraits: []const []const u8 = &.{},
    methods: []const TraitMethodSig = &.{},
    assoc_types: []const items.AssocType = &.{},
    assoc_consts: []const TraitAssocConst = &.{},
};

/// Evidence for a Rust `impl` declaration and its associated child entities.
pub const ImplBody = struct {
    self_ty: types.Type,
    trait_path: ?types.Path = null,
    trait_args: []const types.Type = &.{},
    trait_associated_types: []const types.AssociatedTypeBinding = &.{},
    generics: ?types.Generics = null,
    assoc_items: []const spine.EntityId = &.{},
};

/// Body of a type alias definition.
pub const TypeAliasBody = struct {
    target: types.Type,
    /// Ordered Rust type parameter names declared by the alias, owned by the
    /// frontend arena. The target may name them, so binding and validation
    /// need the names alongside the type.
    generic_params: []const []const u8 = &.{},
};
/// Per-entity body selector. Indexed by spine.EntityId.
pub const BodyKind = union(enum) {
    none,
    const_: ConstBody,
    fn_: FnBody,
    struct_: StructBody,
    enum_: EnumBody,
    trait_: TraitBody,
    impl_: ImplBody,
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

fn externalPathPartEqual(index: usize, actual: []const u8, wanted: []const u8) bool {
    if (index == 0 and std.mem.eql(u8, wanted, "core") and std.mem.eql(u8, actual, "std")) return true;
    return std.mem.eql(u8, actual, wanted);
}

fn importedBoundMatches(prefix: []const []const u8, suffix: []const types.PathSegment, wanted: []const []const u8) bool {
    if (prefix.len + suffix.len != wanted.len) return false;
    for (prefix, 0..) |part, index| {
        if (!externalPathPartEqual(index, part, wanted[index])) return false;
    }
    for (suffix, prefix.len..) |part, index| {
        if (!externalPathPartEqual(index, part.name, wanted[index])) return false;
    }
    return true;
}

fn boundPathMatches(g: *const graph.CrateGraph, owner: spine.EntityId, path: types.Path, wanted: []const []const u8) bool {
    if (path.segments.len == 0) return false;
    const first = path.segments[0];
    if (first.id) |def| {
        if (g.useById(def)) |use_decl| {
            if (use_decl.kind == .external) {
                return importedBoundMatches(use_decl.kind.external.path, path.segments[1..], wanted);
            }
            return false;
        }
    }
    var current: ?spine.EntityId = owner;
    var remaining = g.symbol_table.entities.items.len;
    while (current) |id| {
        if (remaining == 0) return false;
        remaining -= 1;
        const entity = g.symbol_table.get(id) orelse return false;
        if (g.moduleForEntity(id)) |module| {
            for (module.items) |item| {
                const use_decl = g.useById(item) orelse continue;
                if (!std.mem.eql(u8, use_decl.local_name, first.name)) continue;
                return switch (use_decl.kind) {
                    .external => |external| importedBoundMatches(external.path, path.segments[1..], wanted),
                    else => false,
                };
            }
        }
        current = entity.parent;
    }
    if (first.id) |def| {
        if (g.moduleForEntity(def)) |module| {
            if (!module.is_extern) return false;
        }
    }
    return importedBoundMatches(&.{}, path.segments, wanted);
}

fn traitEntityForBound(
    g: *const graph.CrateGraph,
    bound: types.Bound,
) ?spine.EntityId {
    if (bound.path.segments.len == 0) return null;
    const terminal = bound.path.segments[bound.path.segments.len - 1];
    const id = terminal.id orelse return null;
    const entity = g.symbol_table.get(id) orelse return null;
    if (entity.kind != .trait_) return null;
    return id;
}

fn inheritedSelfBound(
    g: *const graph.CrateGraph,
    b: *const Bodies,
    owner: spine.EntityId,
    trait_body: TraitBody,
    wanted: []const []const u8,
    visited: []spine.EntityId,
) ?types.Bound {
    const generics = trait_body.generics orelse return null;
    for (generics.where_clauses) |clause| {
        if (clause.self_ty.segments.len != 1) continue;
        if (!std.mem.eql(u8, clause.self_ty.segments[0].name, "Self")) continue;
        if (inheritedBound(g, b, owner, clause.bounds, wanted, visited)) |result| {
            return result;
        }
    }
    return null;
}

fn inheritedBound(
    g: *const graph.CrateGraph,
    b: *const Bodies,
    owner: spine.EntityId,
    bounds: []const types.Bound,
    wanted: []const []const u8,
    visited: []spine.EntityId,
) ?types.Bound {
    for (bounds) |bound| {
        if (bound.optional) continue;
        if (boundPathMatches(g, owner, bound.path, wanted)) return bound;
    }
    for (bounds) |bound| {
        if (bound.optional) continue;
        const trait_id = traitEntityForBound(g, bound) orelse continue;
        var already_seen = false;
        for (visited) |seen| {
            if (seen == trait_id) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) continue;
        if (@as(usize, trait_id) >= b.bodies.len) continue;
        const trait_body = switch (b.bodies[trait_id]) {
            .trait_ => |value| value,
            else => continue,
        };
        var next_visited: [128]spine.EntityId = undefined;
        if (visited.len >= next_visited.len) continue;
        @memcpy(next_visited[0..visited.len], visited);
        next_visited[visited.len] = trait_id;
        if (inheritedSelfBound(
            g,
            b,
            trait_id,
            trait_body,
            wanted,
            next_visited[0 .. visited.len + 1],
        )) |result| return result;
    }
    return null;
}

fn genericBoundForBounds(
    g: *const graph.CrateGraph,
    b: *const Bodies,
    owner: spine.EntityId,
    bounds: []const types.Bound,
    wanted: []const []const u8,
) ?types.Bound {
    var visited: [128]spine.EntityId = undefined;
    return inheritedBound(g, b, owner, bounds, wanted, visited[0..0]);
}

/// Resolve a receiver's declared trait bound within its callable and impl scopes.
pub fn genericBound(
    g: *const graph.CrateGraph,
    b: *const Bodies,
    owner: spine.EntityId,
    receiver: types.Type,
    trait_path: []const []const u8,
) ?types.Bound {
    var value = receiver;
    for (0..128) |_| {
        switch (value) {
            .reference => |reference| value = reference.pointee,
            .boxed => |boxed| value = boxed.*,
            else => break,
        }
    } else return null;
    if (value == .@"opaque") {
        return genericBoundForBounds(g, b, owner, value.@"opaque".bounds, trait_path);
    }
    if (value != .path or value.path.segments.len != 1) return null;
    const name = value.path.segments[0].name;
    var current: ?spine.EntityId = owner;
    var remaining = g.symbol_table.entities.items.len;
    while (current) |id| {
        if (remaining == 0 or @as(usize, id) >= b.bodies.len) return null;
        remaining -= 1;
        const generics = switch (b.bodies[id]) {
            .fn_ => |function| function.generics,
            .impl_ => |implementation| implementation.generics,
            .trait_ => |trait_body| trait_body.generics,
            else => null,
        };
        if (generics) |parameters| {
            for (parameters.params) |parameter| {
                if (parameter != .type_ or !std.mem.eql(u8, parameter.type_.name, name)) continue;
                if (genericBoundForBounds(g, b, id, parameter.type_.bounds, trait_path)) |bound| {
                    return bound;
                }
            }
            for (parameters.where_clauses) |clause| {
                if (clause.self_ty.segments.len != 1 or
                    !std.mem.eql(u8, clause.self_ty.segments[0].name, name))
                {
                    continue;
                }
                if (genericBoundForBounds(g, b, id, clause.bounds, trait_path)) |bound| {
                    return bound;
                }
            }
        }
        const entity = g.symbol_table.get(id) orelse return null;
        current = entity.parent;
    }
    return null;
}

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
