//! P1 name-resolution tests. Builds a small CrateGraph inline (mirroring what
//! cst.zig lowers from source), runs `names.resolveGraph`, and asserts the
//! UseDecl/Entity resolution contract.
//!
//! C-free on purpose: this file runs under `zig build test`, which links no
//! tree-sitter C, so it must not (transitively) import anything that does.
//! It imports only names.zig / graph.zig / spine.zig.

const std = @import("std");
const ir = @import("translate_rust.ir");
const graph = ir.graph;
const spine = ir.spine;
const names = @import("names.zig");

const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

const Fixture = struct {
    g: graph.CrateGraph,
    // entity ids captured after construction (indices into symbol_table)
    root: spine.EntityId,
    point: spine.EntityId,
    area: spine.EntityId,
    util: spine.EntityId, // module entity (EntityKind.module)
    helper: spine.EntityId,
    use_plain: spine.EntityId, // use crate::util::Helper;
    use_alias: spine.EntityId, // use crate::area as compute;
    use_glob: spine.EntityId, // use super::util::*;  (inside util)
    use_missing: spine.EntityId, // use crate::nope::Missing;
};

fn addEntity(g: *graph.CrateGraph, a: std.mem.Allocator, kind: spine.EntityKind, name: []const u8, parent: ?spine.EntityId) !spine.EntityId {
    return try g.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = try a.dupe(u8, name),
        .span = span,
        .visibility = .private,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
}

/// Build the fixture graph: root module (id 0) with `Point`, `area`, an inline
/// `util` module (containing `Helper` and the glob use), plus three uses in the
/// root and one missing-path use. Entity ordering mirrors cst.zig's extract
/// walk (addEntity per item in source order; addModule per module).
fn buildFixture(a: std.mem.Allocator) !Fixture {
    var g = graph.CrateGraph.init(a);
    errdefer g.deinit();
    const gt = &g;

    // Root module entity must be added first (id 0), then its Module table row.
    const root = try addEntity(gt, a, .module, "", null);
    _ = try gt.addModule(.{
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

    const point = try addEntity(gt, a, .struct_, "Point", root);
    const area = try addEntity(gt, a, .fn_, "area", root);
    const util = try addEntity(gt, a, .module, "util", root);
    _ = try gt.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try a.dupe(u8, "util"),
        .parent = root,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    const helper = try addEntity(gt, a, .struct_, "Helper", util);

    const use_plain = try addEntity(gt, a, .use_, "crate::util::Helper", root);
    try gt.addUse(.{
        .id = use_plain,
        .kind = .{ .plain = 0 },
        .local_name = "",
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });

    const use_alias = try addEntity(gt, a, .use_, "crate::area as compute", root);
    try gt.addUse(.{
        .id = use_alias,
        .kind = .{ .plain = 0 },
        .local_name = "",
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });

    const use_glob = try addEntity(gt, a, .use_, "super::util::*", util);
    try gt.addUse(.{
        .id = use_glob,
        .kind = .{ .plain = 0 },
        .local_name = "",
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });

    const use_missing = try addEntity(gt, a, .use_, "crate::nope::Missing", root);
    try gt.addUse(.{
        .id = use_missing,
        .kind = .{ .plain = 0 },
        .local_name = "",
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });

    // Populate module item lists (ids match the entity ids above). The lists
    // must be heap-allocated: CrateGraph.deinit frees each module's items.
    gt.modules.items[0].items = try a.dupe(spine.EntityId, &.{ point, area, util, use_plain, use_alias, use_missing });
    gt.modules.items[1].items = try a.dupe(spine.EntityId, &.{ helper, use_glob });

    _ = try gt.addCrate(.{
        .name = try a.dupe(u8, "fixture"),
        .edition = 2018,
        .kind = .lib,
        .root = root,
        .deps = &.{},
        .is_translated = true,
    });

    return .{
        .g = g,
        .root = root,
        .point = point,
        .area = area,
        .util = util,
        .helper = helper,
        .use_plain = use_plain,
        .use_alias = use_alias,
        .use_glob = use_glob,
        .use_missing = use_missing,
    };
}

test "resolveGraph resolves a plain use to its target item" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(fx.use_plain) orelse return error.MissingUse;
    try std.testing.expectEqual(fx.helper, u.target);
    switch (u.kind) {
        .plain => |t| try std.testing.expectEqual(fx.helper, t),
        else => return error.ExpectedPlainKind,
    }
    const e = fx.g.symbol_table.get(fx.use_plain) orelse return error.MissingEntity;
    try std.testing.expectEqual(fx.helper, e.resolved orelse return error.NotResolved);
}

test "resolveGraph resolves an alias use to its target with local name" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(fx.use_alias) orelse return error.MissingUse;
    try std.testing.expectEqual(fx.area, u.target);
    switch (u.kind) {
        .alias => |t| {
            try std.testing.expectEqual(fx.area, t);
            try std.testing.expectEqualStrings("compute", u.local_name);
        },
        else => return error.ExpectedAliasKind,
    }
    const e = fx.g.symbol_table.get(fx.use_alias) orelse return error.MissingEntity;
    try std.testing.expectEqual(fx.area, e.resolved orelse return error.NotResolved);
}

test "resolveGraph resolves a super:: glob use to its target module" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(fx.use_glob) orelse return error.MissingUse;
    // `super::util::*` inside the inline `util` module climbs to root and
    // resolves `util` to its module entity.
    try std.testing.expectEqual(fx.util, u.target);
    switch (u.kind) {
        .glob => {},
        else => return error.ExpectedGlobKind,
    }
    const e = fx.g.symbol_table.get(fx.use_glob) orelse return error.MissingEntity;
    try std.testing.expectEqual(fx.util, e.resolved orelse return error.NotResolved);
}

test "resolveGraph resolves a self-only glob to its current module" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    const use_id = try addPendingUseInModule(
        a,
        &fx.g,
        &fx.g.modules.items[1],
        fx.util,
        "self::*",
        "",
    );
    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(use_id) orelse return error.MissingUse;
    try std.testing.expectEqual(fx.util, u.target);
    switch (u.kind) {
        .glob => {},
        else => return error.ExpectedGlobKind,
    }
    try std.testing.expectEqual(
        fx.util,
        (fx.g.symbol_table.get(use_id) orelse return error.MissingEntity).resolved orelse
            return error.NotResolved,
    );
}

test "resolveGraph resolves a super-only glob to its parent module" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    const use_id = try addPendingUseInModule(
        a,
        &fx.g,
        &fx.g.modules.items[1],
        fx.util,
        "super::*",
        "",
    );
    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(use_id) orelse return error.MissingUse;
    try std.testing.expectEqual(fx.root, u.target);
    switch (u.kind) {
        .glob => {},
        else => return error.ExpectedGlobKind,
    }
    try std.testing.expectEqual(
        fx.root,
        (fx.g.symbol_table.get(use_id) orelse return error.MissingEntity).resolved orelse
            return error.NotResolved,
    );
}

test "resolveGraph resolves a crate-only glob to the crate root module" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    const use_id = try addPendingUseInModule(
        a,
        &fx.g,
        &fx.g.modules.items[1],
        fx.util,
        "crate::*",
        "",
    );
    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(use_id) orelse return error.MissingUse;
    try std.testing.expectEqual(fx.root, u.target);
    switch (u.kind) {
        .glob => {},
        else => return error.ExpectedGlobKind,
    }
    try std.testing.expectEqual(
        fx.root,
        (fx.g.symbol_table.get(use_id) orelse return error.MissingEntity).resolved orelse
            return error.NotResolved,
    );
}

test "resolveGraph keeps an unresolved plain path at target zero" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    try names.resolveGraph(a, &fx.g);

    try expectUnresolvedPlain(&fx.g, fx.use_missing);
}

test "resolveGraph degrades an unresolved use without error" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    // Must not return an error for a missing path — it degrades to target 0.
    try names.resolveGraph(a, &fx.g);

    const u = fx.g.useById(fx.use_missing) orelse return error.MissingUse;
    try std.testing.expectEqual(@as(spine.EntityId, 0), u.target);
    const e = fx.g.symbol_table.get(fx.use_missing) orelse return error.MissingEntity;
    try std.testing.expectEqual(null, e.resolved);
}

fn appendModuleItem(
    a: std.mem.Allocator,
    module: *graph.Module,
    item_id: spine.EntityId,
) !void {
    const old_items = module.items;
    const new_items = try a.alloc(spine.EntityId, old_items.len + 1);
    @memcpy(new_items[0..old_items.len], old_items);
    new_items[old_items.len] = item_id;
    a.free(old_items);
    module.items = new_items;
}

fn addPendingUse(
    a: std.mem.Allocator,
    g: *graph.CrateGraph,
    root: spine.EntityId,
    source: []const u8,
    local_name: []const u8,
) !spine.EntityId {
    const use_id = try addEntity(g, a, .use_, source, root);
    try g.addUse(.{
        .id = use_id,
        .kind = .{ .plain = 0 },
        .local_name = try a.dupe(u8, local_name),
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });
    try appendModuleItem(a, &g.modules.items[0], use_id);
    return use_id;
}

fn addPendingUseInModule(
    a: std.mem.Allocator,
    g: *graph.CrateGraph,
    module: *graph.Module,
    parent: spine.EntityId,
    source: []const u8,
    local_name: []const u8,
) !spine.EntityId {
    const use_id = try addEntity(g, a, .use_, source, parent);
    try g.addUse(.{
        .id = use_id,
        .kind = .{ .plain = 0 },
        .local_name = try a.dupe(u8, local_name),
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });
    try appendModuleItem(a, module, use_id);
    return use_id;
}

fn expectUnresolvedPlain(g: *const graph.CrateGraph, use_id: spine.EntityId) !void {
    const use_decl = g.useById(use_id) orelse return error.MissingUse;
    try std.testing.expectEqual(@as(spine.EntityId, 0), use_decl.target);
    switch (use_decl.kind) {
        .plain => |target| try std.testing.expectEqual(@as(spine.EntityId, 0), target),
        else => return error.ExpectedPlainKind,
    }
    const entity = g.symbol_table.get(use_id) orelse return error.MissingEntity;
    try std.testing.expectEqual(null, entity.resolved);
}

test "resolveGraph classifies unresolved rooted core and std non-glob uses as external" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    const core_hasher = try addPendingUse(
        a,
        &fx.g,
        fx.root,
        "core::hash::Hasher",
        "Hasher",
    );
    const std_default = try addPendingUse(
        a,
        &fx.g,
        fx.root,
        "std::default::Default as RustDefault",
        "RustDefault",
    );

    try names.resolveGraph(a, &fx.g);

    const core_use = fx.g.useById(core_hasher) orelse return error.MissingUse;
    try std.testing.expectEqual(@as(spine.EntityId, 0), core_use.target);
    const core_external = switch (core_use.kind) {
        .external => |external| external,
        else => return error.ExpectedExternalKind,
    };
    try std.testing.expectEqual(@as(usize, 3), core_external.path.len);
    try std.testing.expectEqualStrings("core", core_external.path[0]);
    try std.testing.expectEqualStrings("hash", core_external.path[1]);
    try std.testing.expectEqualStrings("Hasher", core_external.path[2]);
    try std.testing.expectEqualStrings("Hasher", core_use.local_name);
    try std.testing.expectEqual(
        null,
        (fx.g.symbol_table.get(core_hasher) orelse return error.MissingEntity).resolved,
    );

    const std_use = fx.g.useById(std_default) orelse return error.MissingUse;
    const std_external = switch (std_use.kind) {
        .external => |external| external,
        else => return error.ExpectedExternalKind,
    };
    try std.testing.expectEqualStrings("std", std_external.path[0]);
    try std.testing.expectEqualStrings("default", std_external.path[1]);
    try std.testing.expectEqualStrings("Default", std_external.path[2]);
    try std.testing.expectEqualStrings("RustDefault", std_use.local_name);
    try std.testing.expectEqual(@as(spine.EntityId, 0), std_use.target);
    try std.testing.expectEqual(
        null,
        (fx.g.symbol_table.get(std_default) orelse return error.MissingEntity).resolved,
    );
}

test "resolveGraph keeps a manifest-dependency-rooted use external" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    // A dependency's types are not graph entities either, so a use rooted at one
    // has to survive resolution as external. `num-traits` is declared with a dash
    // and written with underscores at the use site; both spellings have to match.
    const deps = try a.alloc(graph.CrateDep, 1);
    deps[0] = .{
        .extern_name = try a.dupe(u8, "num-traits"),
        .local_alias = try a.dupe(u8, "num-traits"),
        .id = 1,
    };
    fx.g.crates.items[0].deps = deps;

    const bounded = try addPendingUse(a, &fx.g, fx.root, "num_traits::Bounded", "Bounded");
    const undeclared = try addPendingUse(a, &fx.g, fx.root, "unknown::Bounded", "Bounded");

    try names.resolveGraph(a, &fx.g);

    const bounded_use = fx.g.useById(bounded) orelse return error.MissingUse;
    try std.testing.expectEqual(@as(spine.EntityId, 0), bounded_use.target);
    const bounded_external = switch (bounded_use.kind) {
        .external => |external| external,
        else => return error.ExpectedExternalKind,
    };
    try std.testing.expectEqual(@as(usize, 2), bounded_external.path.len);
    try std.testing.expectEqualStrings("num_traits", bounded_external.path[0]);
    try std.testing.expectEqualStrings("Bounded", bounded_external.path[1]);
    try std.testing.expectEqualStrings("Bounded", bounded_use.local_name);
    try std.testing.expectEqual(
        null,
        (fx.g.symbol_table.get(bounded) orelse return error.MissingEntity).resolved,
    );
    try expectUnresolvedPlain(&fx.g, undeclared);
}

test "resolveGraph gives local scope priority and keeps non-external shapes unresolved" {
    const a = std.testing.allocator;
    var fx = try buildFixture(a);
    defer fx.g.deinit();

    const std_module = try addEntity(&fx.g, a, .module, "std", fx.root);
    const local_hasher = try addEntity(&fx.g, a, .struct_, "Hasher", std_module);
    _ = try fx.g.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try a.dupe(u8, "std"),
        .parent = fx.root,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = try a.dupe(spine.EntityId, &.{local_hasher}),
        .attributes = &.{},
    });
    try appendModuleItem(a, &fx.g.modules.items[0], std_module);

    const shadowed = try addPendingUse(a, &fx.g, fx.root, "std::Hasher", "Hasher");
    const glob = try addPendingUse(a, &fx.g, fx.root, "core::hash::*", "");
    const crate_relative = try addPendingUse(
        a,
        &fx.g,
        fx.root,
        "crate::core::hash::Hasher",
        "Hasher",
    );
    const unknown_root = try addPendingUse(
        a,
        &fx.g,
        fx.root,
        "unknown::collections::VecDeque",
        "VecDeque",
    );
    const alloc_vec_deque = try addPendingUse(
        a,
        &fx.g,
        fx.root,
        "alloc::collections::VecDeque",
        "VecDeque",
    );

    try names.resolveGraph(a, &fx.g);

    const shadowed_use = fx.g.useById(shadowed) orelse return error.MissingUse;
    try std.testing.expectEqual(local_hasher, shadowed_use.target);
    switch (shadowed_use.kind) {
        .plain => |target| try std.testing.expectEqual(local_hasher, target),
        else => return error.ExpectedPlainKind,
    }
    try std.testing.expectEqual(
        local_hasher,
        (fx.g.symbol_table.get(shadowed) orelse return error.MissingEntity).resolved orelse
            return error.NotResolved,
    );
    try expectUnresolvedPlain(&fx.g, glob);
    try expectUnresolvedPlain(&fx.g, crate_relative);
    try expectUnresolvedPlain(&fx.g, unknown_root);
    const alloc_use = fx.g.useById(alloc_vec_deque) orelse return error.MissingUse;
    try std.testing.expectEqual(@as(spine.EntityId, 0), alloc_use.target);
    const alloc_external = switch (alloc_use.kind) {
        .external => |external| external,
        else => return error.ExpectedExternalKind,
    };
    try std.testing.expectEqual(@as(usize, 3), alloc_external.path.len);
    try std.testing.expectEqualStrings("alloc", alloc_external.path[0]);
    try std.testing.expectEqualStrings("collections", alloc_external.path[1]);
    try std.testing.expectEqualStrings("VecDeque", alloc_external.path[2]);
    try std.testing.expectEqualStrings("VecDeque", alloc_use.local_name);
    try std.testing.expectEqual(
        null,
        (fx.g.symbol_table.get(alloc_vec_deque) orelse return error.MissingEntity).resolved,
    );
}

// ── Two modules declaring one type name ─────────────────────────────────────
//
// `mod a { pub struct T; } mod b { pub struct T; }` is ordinary Rust, and a
// resolver that answers both paths with one id names one type twice. These
// fixtures drive `resolveGraph` and read the `UseDecl` / entity contract that
// `cst.zig`'s `bindDeclarationTypes` binds declaration types against, so a
// wrong answer here is a wrong type name downstream rather than a latent one.

/// The symbol table and the module table are separate dense spaces: a module
/// has an entity id in one and a row id in the other, and resolution addresses
/// each by its own. Both are kept.
const ModulePair = struct {
    entity: spine.EntityId,
    row: spine.EntityId,
};

/// Register `name` as an inline child of `parent` and return the pair.
///
/// The child entity is appended to the PARENT's item list: a `mod` is a
/// member of the module that declares it, and that membership is the only
/// thing that makes `crate::a::T`, `a::*` and a bare `a::T` out of a sibling
/// resolve at all. It is NOT appended to the child's own row, whose items are
/// only what is written inside it. `cst.zig` makes exactly these two moves —
/// `addModule` for the child's row, then `item_ids.append(child_id)` onto the
/// row being mapped — so a fixture that inverts them resolves nothing for
/// reasons that have nothing to do with the walk under test.
fn addInlineModule(
    a: std.mem.Allocator,
    g: *graph.CrateGraph,
    parent: ModulePair,
    name: []const u8,
) !ModulePair {
    const entity = try addEntity(g, a, .module, name, parent.entity);
    const row = try g.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try a.dupe(u8, name),
        .parent = parent.entity,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    try appendModuleItem(a, &g.modules.items[parent.row], entity);
    return .{ .entity = entity, .row = row };
}

fn addCrateRoot(a: std.mem.Allocator, g: *graph.CrateGraph) !ModulePair {
    const entity = try addEntity(g, a, .module, "", null);
    const row = try g.addModule(.{
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
    return .{ .entity = entity, .row = row };
}

/// One crate root, two inline modules, a `T` declared in each, and a `Marker`
/// declared at the root.
const TwinModules = struct {
    g: graph.CrateGraph,
    root: ModulePair,
    a_mod: ModulePair,
    b_mod: ModulePair,
    t_a: spine.EntityId,
    t_b: spine.EntityId,
    /// A declaration at the crate root, so a bare path out of a module has a
    /// root binding to fall back to and the self-hit has nothing to shadow.
    marker: spine.EntityId,

    /// Register a `use` in `module` whose parent entity is the same module.
    fn addUse(
        a: std.mem.Allocator,
        self: *TwinModules,
        module: ModulePair,
        source: []const u8,
        local_name: []const u8,
    ) !spine.EntityId {
        const use_id = try addEntity(&self.g, a, .use_, source, module.entity);
        try self.g.addUse(.{
            .id = use_id,
            .kind = .{ .plain = 0 },
            .local_name = try a.dupe(u8, local_name),
            .is_pub_export = false,
            .target = 0,
            .span = span,
        });
        try appendModuleItem(a, &self.g.modules.items[module.row], use_id);
        return use_id;
    }
};

fn buildTwinModules(a: std.mem.Allocator) !TwinModules {
    var g = graph.CrateGraph.init(a);
    errdefer g.deinit();
    const root = try addCrateRoot(a, &g);
    const a_mod = try addInlineModule(a, &g, root, "a");
    const b_mod = try addInlineModule(a, &g, root, "b");
    const t_a = try addEntity(&g, a, .struct_, "T", a_mod.entity);
    const t_b = try addEntity(&g, a, .struct_, "T", b_mod.entity);
    const marker = try addEntity(&g, a, .struct_, "Marker", root.entity);
    try appendModuleItem(a, &g.modules.items[a_mod.row], t_a);
    try appendModuleItem(a, &g.modules.items[b_mod.row], t_b);
    try appendModuleItem(a, &g.modules.items[root.row], marker);
    _ = try g.addCrate(.{
        .name = try a.dupe(u8, "twin"),
        .edition = 2018,
        .kind = .lib,
        .root = root.entity,
        .deps = &.{},
        .is_translated = true,
    });
    return .{
        .g = g,
        .root = root,
        .a_mod = a_mod,
        .b_mod = b_mod,
        .t_a = t_a,
        .t_b = t_b,
        .marker = marker,
    };
}

fn expectResolved(g: *const graph.CrateGraph, use_id: spine.EntityId, target: spine.EntityId) !void {
    const use_decl = g.useById(use_id) orelse return error.MissingUse;
    try std.testing.expectEqual(target, use_decl.target);
    const entity = g.symbol_table.get(use_id) orelse return error.MissingEntity;
    try std.testing.expectEqual(
        target,
        entity.resolved orelse return error.NotResolved,
    );
}

fn expectPlainTarget(g: *const graph.CrateGraph, use_id: spine.EntityId, target: spine.EntityId) !void {
    try expectResolved(g, use_id, target);
    const use_decl = g.useById(use_id) orelse return error.MissingUse;
    switch (use_decl.kind) {
        .plain => |plain_target| try std.testing.expectEqual(target, plain_target),
        else => return error.ExpectedPlainKind,
    }
}

fn expectAliasTarget(
    g: *const graph.CrateGraph,
    use_id: spine.EntityId,
    target: spine.EntityId,
    alias: []const u8,
) !void {
    try expectResolved(g, use_id, target);
    const use_decl = g.useById(use_id) orelse return error.MissingUse;
    switch (use_decl.kind) {
        .alias => |alias_target| try std.testing.expectEqual(target, alias_target),
        else => return error.ExpectedAliasKind,
    }
    try std.testing.expectEqualStrings(alias, use_decl.local_name);
}

fn expectGlobTarget(g: *const graph.CrateGraph, use_id: spine.EntityId, target: spine.EntityId) !void {
    try expectResolved(g, use_id, target);
    const use_decl = g.useById(use_id) orelse return error.MissingUse;
    switch (use_decl.kind) {
        .glob => {},
        else => return error.ExpectedGlobKind,
    }
}

test "two modules declaring the same type name resolve to distinct declarations" {
    const a = std.testing.allocator;
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    // The fixture only means anything if the two declarations really are two.
    try std.testing.expect(fx.t_a != fx.t_b);

    const left = try TwinModules.addUse(a, &fx, fx.root, "crate::a::T as Left", "Left");
    const right = try TwinModules.addUse(a, &fx, fx.root, "crate::b::T as Right", "Right");
    const plain_a = try TwinModules.addUse(a, &fx, fx.root, "crate::a::T", "T");
    const plain_b = try TwinModules.addUse(a, &fx, fx.root, "crate::b::T", "T");

    try names.resolveGraph(a, &fx.g);

    try expectAliasTarget(&fx.g, left, fx.t_a, "Left");
    try expectAliasTarget(&fx.g, right, fx.t_b, "Right");
    // Two plain paths bound under one name still name two declarations: the
    // target is a property of the path, not of the binding it leaves behind.
    try expectPlainTarget(&fx.g, plain_a, fx.t_a);
    try expectPlainTarget(&fx.g, plain_b, fx.t_b);
    try std.testing.expectEqualStrings("T", (fx.g.useById(plain_b) orelse return error.MissingUse).local_name);
}

test "globs and bare paths keep the two same-named modules apart" {
    const a = std.testing.allocator;
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    const glob_a = try TwinModules.addUse(a, &fx, fx.root, "a::*", "");
    const glob_b = try TwinModules.addUse(a, &fx, fx.root, "b::*", "");
    // A bare path out of one module into its sibling: the first segment is
    // absent locally and resolves from the crate root, and the segments after
    // it resolve from the module that segment named. The two imports bind
    // ALIASED names on purpose: a plain `use a::T;` inside `b` (and symmetrically
    // `use b::T;` inside `a`) would rebind `T` in a module that already
    // declares one — an E0255 duplicate the resolver is not being asked to
    // admit — and would make `a::T` name that neighbour use rather than the
    // declaration of `a`, which is the opposite of the pinned rule that a
    // `use` binding shadows the declaration ("a use alias that shadows a
    // local" pins exactly that). Rust itself rejects the plain pair.
    const into_a = try TwinModules.addUse(a, &fx, fx.b_mod, "a::T as IntoA", "IntoA");
    const into_b = try TwinModules.addUse(a, &fx, fx.a_mod, "b::T as IntoB", "IntoB");

    try names.resolveGraph(a, &fx.g);

    try expectGlobTarget(&fx.g, glob_a, fx.a_mod.entity);
    try expectGlobTarget(&fx.g, glob_b, fx.b_mod.entity);
    try expectAliasTarget(&fx.g, into_a, fx.t_a, "IntoA");
    try expectAliasTarget(&fx.g, into_b, fx.t_b, "IntoB");
}

test "an inline module is a member of the module that declares it" {
    const a = std.testing.allocator;
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    // `mod a { .. }` written in the crate root puts `a` in the ROOT's scope.
    // That membership — and only it — is what `crate::a::T`, `a::*` and a
    // bare `a::T` out of a sibling read through, so it is pinned on its own:
    // a fixture that leaves the child out of its parent leaves every path
    // through the child unresolved, which reads as a walk bug and is not one.
    const glob = try TwinModules.addUse(a, &fx, fx.root, "a::*", "");
    try names.resolveGraph(a, &fx.g);

    try expectGlobTarget(&fx.g, glob, fx.a_mod.entity);
}

/// Resolve one round-trip `use` written INSIDE the module whose declaration it
/// names, with that module holding no other binding of the same name.
fn resolveRoundTrip(a: std.mem.Allocator, into_a: bool, source: []const u8) !void {
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    const module = if (into_a) fx.a_mod else fx.b_mod;
    const declared = if (into_a) fx.t_a else fx.t_b;
    const use_id = try TwinModules.addUse(a, &fx, module, source, "T");
    try names.resolveGraph(a, &fx.g);

    // The one contract this shape has: the use names the declaration its path
    // names, never itself — even though the name it binds is one its own module
    // already declared, so the walk lands on the very entry being resolved.
    const use_decl = fx.g.useById(use_id) orelse return error.MissingUse;
    try std.testing.expect(use_decl.target != use_id);
    try expectPlainTarget(&fx.g, use_id, declared);
    try std.testing.expectEqualStrings("T", use_decl.local_name);
}

test "a use leading back into its own module names the declaration it shadows" {
    const a = std.testing.allocator;

    // Each spelling is resolved in a fixture of its own. A module may hold one
    // binding of a name; a second `use` written under the same one would make
    // the walk land on that neighbour instead of on the entry being resolved,
    // which is a different question than the one this shape asks.
    try resolveRoundTrip(a, true, "a::T");
    try resolveRoundTrip(a, true, "self::T");
    try resolveRoundTrip(a, true, "crate::a::T");
    // The sibling module is the same shape on the other side.
    try resolveRoundTrip(a, false, "b::T");
    try resolveRoundTrip(a, false, "self::T");
    try resolveRoundTrip(a, false, "crate::b::T");
}

test "a use alias that shadows a local names the other module's declaration" {
    const a = std.testing.allocator;
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    // The alias is spelled `T`, so it shadows `a`'s own `T` for every reader
    // of `a`, while the path it was written for names the OTHER module's `T`.
    const alias = try TwinModules.addUse(a, &fx, fx.a_mod, "crate::b::T as T", "T");
    // A reader of `a` that names `T` without the alias resolves through the
    // use binding, which is the re-export this shape is.
    const through_a = try TwinModules.addUse(a, &fx, fx.root, "a::T", "T");

    try names.resolveGraph(a, &fx.g);

    try expectAliasTarget(&fx.g, alias, fx.t_b, "T");
    try expectPlainTarget(&fx.g, through_a, alias);
}

test "a round-trip use names its module's declaration, not the re-export above it" {
    const a = std.testing.allocator;
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    // `b` holds two uses that both bind `T`: a re-export naming `a`'s
    // declaration, and a round trip back into `b`. The second is written
    // through a name the first already bound, so the walk finds the second
    // use itself and has to read past it to the declaration underneath.
    const reexport = try TwinModules.addUse(a, &fx, fx.b_mod, "a::T", "T");
    const round_trip = try TwinModules.addUse(a, &fx, fx.b_mod, "crate::b::T", "T");

    try names.resolveGraph(a, &fx.g);

    try expectPlainTarget(&fx.g, reexport, fx.t_a);
    try expectPlainTarget(&fx.g, round_trip, fx.t_b);
    try std.testing.expect(fx.g.useById(round_trip).?.target != round_trip);
}

test "a self-hit with nothing shadowed still falls back to the crate root" {
    const a = std.testing.allocator;
    var fx = try buildTwinModules(a);
    defer fx.g.deinit();

    // `a` declares no `Marker`, so the use is the only thing under that name
    // in its own module. Reading past it finds nothing, and the ordinary bare
    // fallback is what reaches the crate root's declaration.
    const bare = try TwinModules.addUse(a, &fx, fx.a_mod, "Marker", "Marker");

    try names.resolveGraph(a, &fx.g);

    try expectPlainTarget(&fx.g, bare, fx.marker);
    try std.testing.expectEqualStrings(
        "Marker",
        (fx.g.useById(bare) orelse return error.MissingUse).local_name,
    );
}
