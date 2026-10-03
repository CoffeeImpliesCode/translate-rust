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
    /// The declaration's TYPE parameters, in source order, owned by the frontend
    /// arena. A const or lifetime parameter contributes NO entry:
    /// `struct Buf<const N: usize, T>` carries `&.{"T"}`.
    ///
    /// Nothing else belongs here. A name in this list binds in every type the
    /// row owns, so one entry that the declaration does not declare turns a
    /// const parameter's own type into an in-scope type parameter and answers
    /// questions about a type that was never written.
    ///
    /// `validate` counts a declaration's parameters from THIS list
    /// (`genericCountForEntity`) rather than from `generics`, which is why an
    /// instantiation of a const-generic declaration is refused rather than
    /// admitted with a missing value. See `types.GenericArgs`.
    generic_params: []const []const u8 = &.{},
    /// The declaration's full generic metadata, the way `FnBody`,
    /// `StructMethod`, `TraitMethodSig`, `TraitBody` and `ImplBody` carry it:
    /// every parameter the source spells — type, const and lifetime alike —
    /// with the bounds each carries, plus its `where` clauses.
    /// `struct S<T: Copy> where T: Debug` records BOTH bounds here, and
    /// `genericBound` reads them back through the owning declaration.
    ///
    /// `null` means the source spells no parameters and no `where` clause at
    /// all, which is a fact `generic_params = &.{}` cannot state: an empty name
    /// list is also what a declaration carrying only const or lifetime
    /// parameters produces.
    generics: ?types.Generics = null,
    /// Bounds the source spells on the declaration, as it spells them
    /// (`"T: Copy"`). Diagnostics only, and a strict subset of what `generics`
    /// already carries: the resolved `types.Bound`s a reader needs live in
    /// `generics.params[].type_.bounds` and `generics.where_clauses[].bounds`.
    ///
    /// The field stays because the wire format requires the key and `validate`
    /// reads it. No producer fills it, so it is empty on every row the pipeline
    /// builds; the producer obligation is the `generics` field above.
    trait_bounds: []const []const u8 = &.{},
    /// The Rust SOURCE FORM of the declaration, never a fact about the fields the
    /// row happens to carry:
    ///
    ///   `struct S;`          → `.unit`    no field list at all
    ///   `struct S {}`        → `.named`   a named field list, empty
    ///   `struct S();`        → `.tuple`   an ordered field list, empty
    ///   `struct S(T);`       → `.tuple`, one field named `"0"`
    ///   `struct S { t: T }`  → `.named`
    ///
    /// The field count cannot decide this, and deciding it that way is the
    /// mistake this field is here to prevent: `struct S();` is an ordered list
    /// holding nothing, and its constructor answers `S()`, not `S {}`. A
    /// `.tuple` row's fields are named by position — `"0"`, `"1"`, … — which is
    /// what lets a reader recover the source form from the row alone.
    layout: items.StructKind = .named,
    fields: []const items.Field = &.{},
    methods: []const StructMethod = &.{},
    has_dynamic_resources: bool = false,
};

/// Body of an enum definition (kind, variants, optional integer repr, non_exhaustive).
pub const EnumBody = struct {
    kind: items.EnumKind = .c_like,
    generic_params: []const []const u8 = &.{},
    variants: []const items.Variant = &.{},
    repr_int: ?items.IntRepr = null,
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

/// Whether `path` is exactly the trait at `wanted`, resolved the way Rust
/// resolves a name in `owner`'s scope.
///
/// This is the canonical bound-identity test for the whole pipeline, and it is
/// exported rather than wrapped so no second, weaker convention can grow
/// beside it. A caller that proves a trait by comparing a path's LAST segment
/// to a bare name accepts a crate's own homonym: a `trait From<T>` declared in
/// the crate answers to `From` exactly as well as `core::convert::From` does,
/// and the two are different traits with different impls. Every reader that
/// needs trait identity should ask here instead.
///
/// The full path may be written out (`core::convert::From`), or given as a
/// short name the scope imports (`use core::convert::From;`, then `From`), or
/// carry the importing `use` declaration on its first segment — all three
/// reach the same answer, because that is what the source means by all three.
/// `core` and `std` are the same crate for this purpose: `use
/// std::convert::From` proves `core::convert::From`, since std re-exports it.
pub fn boundPathMatches(g: *const graph.CrateGraph, owner: spine.EntityId, path: types.Path, wanted: []const []const u8) bool {
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
///
/// `receiver` may carry its bound itself — an `opaque` or a `dyn Trait`, both
/// reached through any number of reference or box layers — or name a type
/// parameter, whose bound is then read from the enclosing `fn`, `impl` or
/// `trait` that declares it. The identity of the trait is always
/// `boundPathMatches`, so a crate's own `Read` is never `std::io::Read`.
pub fn genericBound(
    g: *const graph.CrateGraph,
    b: *const Bodies,
    owner: spine.EntityId,
    receiver: types.Type,
    trait_path: []const []const u8,
) ?types.Bound {
    var value = receiver;
    // The label is load-bearing. `else => break` inside the switch would break
    // the SWITCH, not this loop, so the loop would spin its whole 128 turns on
    // a receiver that is neither a reference nor a box and then fall into the
    // `else` below and report no bound for every ordinary type parameter.
    // `break :peel` leaves the loop, which is what makes the `for ... else`
    // mean what it says: reached only by a reference chain that never ends.
    peel: for (0..128) |_| {
        switch (value) {
            .reference => |reference| value = reference.pointee,
            .boxed => |boxed| value = boxed.*,
            else => break :peel,
        }
    } else return null;
    if (value == .@"opaque") {
        return genericBoundForBounds(g, b, owner, value.@"opaque".bounds, trait_path);
    }
    // A `dyn Trait` receiver is the bound itself rather than a type parameter
    // some enclosing signature constrains, so it answers from the bounds the
    // object type spells and nothing else has to be looked up. This is the
    // same question the `opaque` arm above asks about the same declaration,
    // read off the representation that keeps it: `fn f(r: &mut dyn Read)`
    // admits `r.read_exact(..)` for exactly the reason `fn f<T: ?Sized +
    // Read>(r: &mut T)` admits it, and `boundPathMatches` resolves the name
    // through the same `use std::io::Read` in both.
    if (value == .dyn_trait) {
        return genericBoundForBounds(g, b, owner, value.dyn_trait, trait_path);
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
            // A `struct S<T: Copy>` bounds `T` for every method and field the
            // declaration owns, exactly as an enclosing `fn` or `impl` does.
            // Leaving `.struct_` out here is what made a struct's bounds
            // unreachable no matter what the producer recorded on the row.
            .struct_ => |structure| structure.generics,
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

test "a struct row's layout is the source form, not its field count" {
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 2 };
    const named_field = [_]items.Field{
        .{ .name = "t", .ty = .{ .prim = .u32 }, .visibility = .public, .span = span },
    };
    const positional_field = [_]items.Field{
        .{ .name = "0", .ty = .{ .prim = .u32 }, .visibility = .public, .span = span },
    };

    // The three source forms, each with the fields it spells. Two of the five
    // spell no field at all and are still three different declarations.
    const forms = [_]struct { source: []const u8, row: StructBody }{
        .{ .source = "struct S;", .row = .{ .layout = .unit } },
        .{ .source = "struct S {}", .row = .{ .layout = .named } },
        .{ .source = "struct S();", .row = .{ .layout = .tuple } },
        .{ .source = "struct S(T);", .row = .{ .layout = .tuple, .fields = &positional_field } },
        .{ .source = "struct S { t: T }", .row = .{ .layout = .named, .fields = &named_field } },
    };
    for (forms) |form| {
        // A row whose fields carry the source's identifiers is named; a row
        // whose fields carry positions is a tuple; an empty ordered list is
        // still the tuple its source wrote.
        switch (form.row.layout) {
            .tuple => {
                for (form.row.fields, 0..) |field, index| {
                    var expected: [8]u8 = undefined;
                    try std.testing.expectEqualStrings(
                        try std.fmt.bufPrint(&expected, "{d}", .{index}),
                        field.name,
                    );
                }
            },
            .named => for (form.row.fields) |field| {
                try std.testing.expect(!isPositionalFieldName(field.name));
            },
            .unit => try std.testing.expectEqual(@as(usize, 0), form.row.fields.len),
        }
    }

    // The pair that a field count cannot tell apart, stated directly: an empty
    // named list and an empty ordered list are different declarations.
    const empty_named = forms[1].row;
    const empty_tuple = forms[2].row;
    try std.testing.expectEqual(@as(usize, 0), empty_named.fields.len);
    try std.testing.expectEqual(@as(usize, 0), empty_tuple.fields.len);
    try std.testing.expect(empty_named.layout != empty_tuple.layout);
}

/// Whether a field name is the position a tuple field is named by. A Rust
/// identifier cannot start with a digit, so this is exactly "the row is a tuple
/// field list".
fn isPositionalFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len == 1 and name[0] == '0') return true;
    if (name[0] < '1' or name[0] > '9') return false;
    for (name[1..]) |digit| {
        if (digit < '0' or digit > '9') return false;
    }
    return true;
}

test "a struct row names the type parameters of its declaration and nothing else" {
    // `struct Buf<'a, const N: usize, T: Copy, U>` as the declaration records
    // it: two lifetimes/const parameters the row cannot hold, two type
    // parameters it must.
    const declaration: types.Generics = .{ .params = &.{
        .{ .lifetime = .{ .name = "'a" } },
        .{ .const_ = .{ .name = "N", .ty = .{ .prim = .usize } } },
        .{ .type_ = .{ .name = "T", .bounds = &.{} } },
        .{ .type_ = .{ .name = "U", .bounds = &.{} } },
    }, .where_clauses = &.{} };
    const row: StructBody = .{ .generic_params = &.{ "T", "U" } };

    // The rule the producer owes: the row names every `.type_` parameter of the
    // declaration, in source order, and nothing else — not the const parameter,
    // not the lifetime.
    var named: usize = 0;
    for (declaration.params) |parameter| {
        if (parameter != .type_) continue;
        try std.testing.expect(named < row.generic_params.len);
        try std.testing.expectEqualStrings(parameter.type_.name, row.generic_params[named]);
        named += 1;
    }
    try std.testing.expectEqual(named, row.generic_params.len);
    try std.testing.expectEqual(@as(usize, 2), named);
    try std.testing.expectEqual(@as(usize, 4), declaration.params.len);
}

test "a struct row carries its declaration's generics and genericBound reads them back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    const struct_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = "S",
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const method_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "value",
        .span = span,
        .visibility = .public,
        .parent = struct_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // `struct S<T: Copy> where T: Debug` — one bound on the parameter itself
    // and one in the where clause, both of which the row has to keep.
    const parameter_name = [_]types.PathSegment{.{ .name = "T", .id = null }};
    const copy_bound: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "Copy", .id = null }} },
    };
    const debug_bound: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "Debug", .id = null }} },
    };
    const row: Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{
            .{ .none = {} },
            .{ .struct_ = .{
                .generic_params = &.{"T"},
                .generics = .{
                    .params = &.{.{ .type_ = .{ .name = "T", .bounds = &.{copy_bound} } }},
                    .where_clauses = &.{.{ .self_ty = .{ .segments = &parameter_name }, .bounds = &.{debug_bound} }},
                },
            } },
            .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u32 }, .body = 0 } },
        },
    };

    // The name list still names the type parameters alone...
    try std.testing.expectEqual(@as(usize, 1), row.bodies[1].struct_.generic_params.len);
    try std.testing.expectEqualStrings("T", row.bodies[1].struct_.generic_params[0]);

    // ...and both bounds reach a method that receives `T`, because the row is
    // in the declaring scope's chain. A trait the declaration never spelled is
    // still refused.
    const receiver: types.Type = .{ .path = .{ .segments = &parameter_name } };
    try std.testing.expect(genericBound(&g, &row, method_id, receiver, &.{"Copy"}) != null);
    try std.testing.expect(genericBound(&g, &row, method_id, receiver, &.{"Debug"}) != null);
    try std.testing.expect(genericBound(&g, &row, method_id, receiver, &.{"Clone"}) == null);
}

test "a fn row's bounds are read back from the declaring body itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    // The callee that DECLARES the bound. A receiver only answers from the
    // body that introduces its name, so the declaration is the first scope the
    // walk has to reach — a walk that skips it answers from an ancestor, or
    // from nothing.
    const wrapper_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "hash_of",
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // `fn hash_of<T: core::hash::Hash, H: core::hash::Hasher>(..)` — one
    // parameter bounded by Hash, one by Hasher, so the two slots are told apart
    // by the bound alone and neither answers for the other's trait.
    const canonical_hash: types.Bound = .{ .path = .{ .segments = &.{
        .{ .name = "core", .id = null },
        .{ .name = "hash", .id = null },
        .{ .name = "Hash", .id = null },
    } } };
    const canonical_hasher: types.Bound = .{ .path = .{ .segments = &.{
        .{ .name = "core", .id = null },
        .{ .name = "hash", .id = null },
        .{ .name = "Hasher", .id = null },
    } } };
    const wanted_hash = [_][]const u8{ "core", "hash", "Hash" };
    const wanted_hasher = [_][]const u8{ "core", "hash", "Hasher" };
    const t_name = [_]types.PathSegment{.{ .name = "T", .id = null }};
    const h_name = [_]types.PathSegment{.{ .name = "H", .id = null }};

    const row: Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{
            .{ .none = {} },
            .{ .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = .u64 },
                .generic_params = &.{ "T", "H" },
                .generics = .{ .params = &.{
                    .{ .type_ = .{ .name = "T", .bounds = &.{canonical_hash} } },
                    .{ .type_ = .{ .name = "H", .bounds = &.{canonical_hasher} } },
                }, .where_clauses = &.{} },
                .body = 0,
            } },
        },
    };

    const receiver_t: types.Type = .{ .path = .{ .segments = &t_name } };
    const receiver_h: types.Type = .{ .path = .{ .segments = &h_name } };
    // The bound the declaring body spells is the bound that answers, from the
    // declaration itself.
    try std.testing.expect(genericBound(&g, &row, wrapper_id, receiver_t, &wanted_hash) != null);
    try std.testing.expect(genericBound(&g, &row, wrapper_id, receiver_h, &wanted_hasher) != null);
    // Each slot answers only for its OWN bound: the matcher never degrades to
    // the last segment, so `Hasher` is not `Hash` and neither is either of them
    // `core::fmt::Debug`.
    try std.testing.expect(genericBound(&g, &row, wrapper_id, receiver_t, &wanted_hasher) == null);
    try std.testing.expect(genericBound(&g, &row, wrapper_id, receiver_h, &wanted_hash) == null);
    try std.testing.expect(genericBound(&g, &row, wrapper_id, receiver_t, &.{"Debug"}) == null);
}
