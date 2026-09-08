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
