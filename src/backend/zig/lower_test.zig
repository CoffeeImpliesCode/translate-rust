//! translate_rust.backend.zig.lower_test — Lowering engine tests.
//!
//! Builds hand-written RustIr fixtures and verifies either complete lowering
//! or the precise strict rejection reached by incomplete legacy topology.

const std = @import("std");
const ir = @import("translate_rust.ir");
const ast = @import("ast.zig");
const lower = @import("lower.zig");
const emit = @import("emit.zig");
const serialize = @import("serialize.zig");

const span: ir.spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

// Build hand-written RustIr fixtures. All allocations go to the caller's
// `alloc` (the test's long-lived arena), which must outlive lowering.
const Model = struct {
    alloc: std.mem.Allocator,
    exprs: std.ArrayListUnmanaged(ir.exprs.Expr) = .empty,
    stmts: std.ArrayListUnmanaged(ir.exprs.Statement) = .empty,
    pats: std.ArrayListUnmanaged(ir.exprs.Pattern) = .empty,
    bodies: std.ArrayListUnmanaged(ir.bodies.BodyKind) = .empty,

    fn init(alloc: std.mem.Allocator) Model {
        return .{ .alloc = alloc };
    }

    fn a(self: *Model) std.mem.Allocator {
        return self.alloc;
    }

    /// Append an expression node, returning its dense NodeId.
    fn e(self: *Model, kind: ir.exprs.ExprKind) !ir.exprs.NodeId {
        const id: ir.exprs.NodeId = @intCast(self.exprs.items.len);
        try self.exprs.append(self.a(), .{
            .id = id,
            .span = span,
            .ty = null,
            .kind = kind,
        });
        return id;
    }

    /// Append a statement node.
    fn stmt(self: *Model, kind: ir.exprs.StatementKind) !ir.exprs.NodeId {
        const id: ir.exprs.NodeId = @intCast(self.stmts.items.len);
        try self.stmts.append(self.a(), .{
            .id = id,
            .span = span,
            .ty = null,
            .kind = kind,
        });
        return id;
    }

    /// Append a pattern node.
    fn pat(self: *Model, kind: ir.exprs.PatternKind) !ir.exprs.NodeId {
        const id: ir.exprs.NodeId = @intCast(self.pats.items.len);
        try self.pats.append(self.a(), .{
            .id = id,
            .span = span,
            .ty = null,
            .kind = kind,
        });
        return id;
    }
};

const RootModuleOptions = struct {
    crate_name: []const u8,
    edition: u16,
    items: []const ir.spine.EntityId,
};

fn addRootModule(
    graph: *ir.graph.CrateGraph,
    options: RootModuleOptions,
) !ir.spine.EntityId {
    const root_entity_id = try graph.symbol_table.add(.{
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
    const owned_items = try graph.allocator.dupe(ir.spine.EntityId, options.items);
    errdefer graph.allocator.free(owned_items);
    for (options.items) |item_id| {
        const item = &graph.symbol_table.entities.items[item_id];
        if (item.parent == null) item.parent = root_entity_id;
    }
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = owned_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = options.crate_name,
        .edition = options.edition,
        .kind = .lib,
        .root = root_entity_id,
        .deps = &.{},
        .is_translated = true,
    });
    return root_entity_id;
}

fn litInt(v: i128) ir.exprs.ExprKind {
    return .{ .literal = .{ .int = .{ .text = "", .value = v, .base = .dec, .ty_suffix = null } } };
}

fn addLowerEntity(
    graph: *ir.graph.CrateGraph,
    kind: ir.spine.EntityKind,
    name: []const u8,
    parent: ?ir.spine.EntityId,
) !ir.spine.EntityId {
    return graph.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = name,
        .span = span,
        .visibility = .public,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
}

fn buildSampleModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
    local_generic_args: []const ir.types.Type,
) !void {
    var model = Model.init(alloc);

    // ── Entities ──────────────────────────────────────────────────────────
    // id0: struct Point            (target struct)
    // id1: fn scale — inherent method, parent = Point (id0) → hoisted
    // id2: fn eval  — top-level fn with a match expression
    // id3: fn test_dbg — #[test] fn
    const point_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = "Point",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const scale_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "scale",
        .span = span,
        .visibility = .public,
        .parent = point_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = scale_id;
    const eval_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "eval",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const test_dbg_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "test_dbg",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const local_x_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = "x",
        .span = span,
        .visibility = .private,
        .parent = test_dbg_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // ── Expression graph ──────────────────────────────────────────────────
    // scale body: block { tail = 7 }
    const e_scale_lit = try model.e(litInt(7));
    const e_scale_block = try model.e(.{ .block = .{ .statements = &.{}, .tail = e_scale_lit, .labelled = null } });

    // dist (StructMethod) body: block { tail = 10 }
    const e_dist_lit = try model.e(litInt(10));
    const e_dist_block = try model.e(.{ .block = .{ .statements = &.{}, .tail = e_dist_lit, .labelled = null } });

    // eval body: block { tail = match(5) { _ => 99 } }
    const e_scrut = try model.e(litInt(5));
    const e_arm_body = try model.e(litInt(99));
    const p_wild = try model.pat(.wildcard);
    const match_patterns = try alloc.alloc(ir.exprs.NodeId, 1);
    match_patterns[0] = p_wild;
    const match_arms = try alloc.alloc(ir.exprs.MatchArm, 1);
    match_arms[0] = .{
        .patterns = match_patterns,
        .guard = null,
        .body = e_arm_body,
    };
    const e_match = try model.e(.{
        .match = .{
            .scrutinee = e_scrut,
            .arms = match_arms,
            .option_scrutinee = false,
        },
    });
    const e_eval_block = try model.e(.{
        .block = .{ .statements = &.{}, .tail = e_match, .labelled = null },
    });

    // var x = 1; x = 2; x += 2; x -= 2; x *= 2; x &= 2; x |= 2; x ^= 2;
    const e_one = try model.e(litInt(1));
    const e_two = try model.e(litInt(2));
    const e_x = try model.e(.{ .path = .{
        .def = local_x_id,
        .generic_args = local_generic_args,
    } });
    const p_bind_x = try model.pat(.{
        .binding = .{
            .name = "x",
            .mode = .{ .value = {} },
            .mutable = true,
        },
    });
    const s_let_x = try model.stmt(.{
        .let = .{ .pattern = p_bind_x, .init = e_one, .ty = null },
    });
    const assign_ops = [_]ir.exprs.AssignOp{
        .plain,
        .add,
        .sub,
        .mul,
        .bit_and,
        .bit_or,
        .bit_xor,
    };
    var assign_stmts: [assign_ops.len]ir.exprs.NodeId = undefined;
    for (assign_ops, 0..) |op, index| {
        const assignment = try model.e(.{ .assign = .{
            .target = e_x,
            .op = op,
            .value = e_two,
            .overflow = .wrapping,
        } });
        assign_stmts[index] = try model.stmt(.{ .expr = assignment });
    }
    const test_statements = try alloc.alloc(ir.exprs.NodeId, 1 + assign_stmts.len);
    test_statements[0] = s_let_x;
    @memcpy(test_statements[1..], &assign_stmts);
    const e_test_block = try model.e(.{
        .block = .{ .statements = test_statements, .tail = null, .labelled = null },
    });

    // ── Bodies ────────────────────────────────────────────────────────────
    const point_fields = try alloc.dupe(ir.items.Field, &[_]ir.items.Field{
        .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
        .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
    });
    const point_methods = try alloc.dupe(ir.bodies.StructMethod, &[_]ir.bodies.StructMethod{
        .{
            .name = "dist",
            .visibility = .public,
            .params = &.{},
            .ret = .{ .prim = .u64 },
            .body = e_dist_block,
            .receiver = .ref_,
        },
    });
    try model.bodies.append(model.a(), .{
        .struct_ = .{
            .fields = point_fields,
            .methods = point_methods,
        },
    });
    try model.bodies.append(model.a(), .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u32 },
            .body = e_scale_block,
        },
    });
    try model.bodies.append(model.a(), .{
        .fn_ = .{
            .params = &.{
                .{ .name = "v", .ty = .{ .prim = .i32 }, .span = span },
            },
            .ret = .{ .prim = .i32 },
            .body = e_eval_block,
        },
    });

    // Pad the sparse bodies table to cover entity id 3 (test_dbg).
    var filler: usize = model.bodies.items.len;
    while (filler <= test_dbg_id) : (filler += 1) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[test_dbg_id] = .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = e_test_block,
        },
    };

    // ── Wire bodies into the RustIr ───────────────────────────────────────
    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    // ── Module graph ──────────────────────────────────────────────────────
    // scale_id (id1) is an inherent method — not a module-level item.
    _ = try addRootModule(graph, .{
        .crate_name = "sample",
        .edition = 2021,
        .items = &.{ point_id, eval_id, test_dbg_id },
    });
}

fn lowerSampleModel(
    alloc: std.mem.Allocator,
    local_generic_args: []const ir.types.Type,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var ir_bodies: ir.bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    try buildSampleModel(alloc, &graph, &ir_bodies, local_generic_args);

    const rust_ir = ir.RustIr{
        .crate_name = "sample",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

test "lowerRustIr: local pattern field paths are non-generic values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerSampleModel(alloc, &.{});
    var saw_local_path = false;
    for (package.files) |file| {
        for (file.tests) |test_decl| {
            if (!std.mem.eql(u8, test_decl.name, "test_dbg")) continue;
            try std.testing.expect(test_decl.body.stmts.len >= 2);
            const assignment = switch (test_decl.body.stmts[1]) {
                .assign => |value| value,
                else => return error.TestUnexpectedResult,
            };
            const target_name = switch (assignment.target) {
                .ident => |name| name,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings("x", target_name);
            saw_local_path = true;
        }
    }
    try std.testing.expect(saw_local_path);
}

test "lowerRustIr: explicit generics on local pattern fields reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const explicit_args = [_]ir.types.Type{.{ .prim = .u32 }};
    try std.testing.expectError(
        error.GenericArgumentArityMismatch,
        lowerSampleModel(alloc, &explicit_args),
    );
}

/// Build the legacy non-primitive return fixture. Its malformed empty path
/// must be rejected before return-type or block-tail lowering.
fn buildTypeModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
) !void {
    var model = Model.init(alloc);

    // Entities:
    //  id0: struct Point (id)
    //  id1: fn make_point — body struct_init tail, ret = path Point
    //  id2: fn first_char — ret = prim char
    const point_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = "Point",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const make_point_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "make_point",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const first_char_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "first_char",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const empty_path_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "empty_path",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const recovered_path_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "recovered_path",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // make_point body: block { tail = Point { x = 1, y = 2 } }
    const e_x = try model.e(litInt(1));
    const e_y = try model.e(litInt(2));
    const point_init_fields = try alloc.dupe(ir.exprs.FieldInit, &[_]ir.exprs.FieldInit{
        .{ .field = "x", .value = e_x, .shorthand = false },
        .{ .field = "y", .value = e_y, .shorthand = false },
    });
    const e_pt_lit = try model.e(.{
        .struct_lit = .{
            .def = point_id,
            .fields = point_init_fields,
            .base = null,
        },
    });
    const e_pt_block = try model.e(.{ .block = .{ .statements = &.{}, .tail = e_pt_lit, .labelled = null } });

    // first_char body: block { tail = literal 'A' }
    const e_char = try model.e(.{ .literal = .{ .character = .{ .text = "'A'", .value = 'A' } } });
    const e_char_block = try model.e(.{ .block = .{ .statements = &.{}, .tail = e_char, .labelled = null } });
    const point_segments = try alloc.alloc(ir.types.PathSegment, 1);
    point_segments[0] = .{ .name = "Point", .id = point_id };
    const point_type: ir.types.Type = .{ .path = .{ .segments = point_segments } };
    const empty_path_type: ir.types.Type = .{ .path = .{ .segments = &.{} } };
    const recovered_segments = try alloc.alloc(ir.types.PathSegment, 1);
    recovered_segments[0] = .{ .name = "", .id = point_id };
    const recovered_path_type: ir.types.Type = .{ .path = .{ .segments = recovered_segments } };

    // Bodies (indexed by entity id):
    //  id0: Point struct owns the fields used by the struct-literal tail.
    try model.bodies.append(model.a(), .{ .struct_ = .{
        .fields = &.{
            .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
            .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
        },
        .methods = &.{},
    } });
    //  id1: make_point → path Point, body = pt block
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = point_type,
        .body = e_pt_block,
    } });
    //  id2: first_char → prim char, body = char block
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .char },
        .body = e_char_block,
    } });
    // The empty path is intentionally malformed. Strict path validation
    // rejects this fixture before later return-type checks.
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = empty_path_type,
        .body = e_char_block,
    } });
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = recovered_path_type,
        .body = e_char_block,
    } });

    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    _ = try addRootModule(graph, .{
        .crate_name = "types",
        .edition = 2021,
        .items = &.{ point_id, make_point_id, first_char_id, empty_path_id, recovered_path_id },
    });
}

test "lower: rejects incomplete non-primitive return fixture topology" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var ir_bodies: ir.bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    try buildTypeModel(alloc, &graph, &ir_bodies);

    const rust_ir = ir.RustIr{
        .crate_name = "types",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    try std.testing.expectError(
        error.InvalidTypePath,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

/// Build a graph exercising `pub use` re-export lowering:
/// - cross-module qualified re-export (`pub use util::helper;` → `util.helper`)
/// - nested-module qualified re-export (`api::helper` imports `./util.zig` publicly)
/// - same-module self-referential `pub use dup;` → skipped (no `pub const dup = dup;`)
/// - `_` wildcard re-export → skipped
fn buildUseModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
) !void {
    var model = Model.init(alloc);

    // Module rows are dense (root=0, util=1, api=2); symbol entities have
    // stable ids and continue with module-owned declarations.
    const root_id = try graph.symbol_table.add(.{
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
    const util_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "util",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const helper_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "helper",
        .span = span,
        .visibility = .public,
        .parent = util_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const dup_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "dup",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const use_helper_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = helper_id,
        .renamed_to = null,
        .attributes = &.{},
    });
    try graph.addUse(.{
        .id = use_helper_id,
        .kind = .{ .plain = helper_id },
        .target = helper_id,
        .local_name = "helper",
        .is_pub_export = true,
        .span = span,
    });

    const use_dup_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = dup_id,
        .renamed_to = null,
        .attributes = &.{},
    });
    try graph.addUse(.{
        .id = use_dup_id,
        .kind = .{ .plain = dup_id },
        .target = dup_id,
        .local_name = "dup",
        .is_pub_export = true,
        .span = span,
    });

    const use_wild_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = helper_id,
        .renamed_to = null,
        .attributes = &.{},
    });
    try graph.addUse(.{
        .id = use_wild_id,
        .kind = .{ .plain = helper_id },
        .target = helper_id,
        .local_name = "_",
        .is_pub_export = true,
        .span = span,
    });

    const use_glob_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = util_id,
        .renamed_to = null,
        .attributes = &.{},
    });
    try graph.addUse(.{
        .id = use_glob_id,
        .kind = .glob,
        .target = util_id,
        .local_name = "Foo",
        .is_pub_export = true,
        .span = span,
    });

    const api_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "api",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const api_use_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = api_id,
        .resolved = helper_id,
        .renamed_to = null,
        .attributes = &.{},
    });
    try graph.addUse(.{
        .id = api_use_id,
        .kind = .{ .plain = helper_id },
        .target = helper_id,
        .local_name = "helper",
        .is_pub_export = true,
        .span = span,
    });

    const e_unit = try model.e(.unit);
    const e_block = try model.e(.{
        .block = .{ .statements = &.{}, .tail = e_unit, .labelled = null },
    });
    try model.bodies.append(model.a(), .{ .none = {} }); // root module
    try model.bodies.append(model.a(), .{ .none = {} }); // util module
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = e_block,
    } });
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = e_block,
    } });
    while (model.bodies.items.len <= api_use_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }

    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ util_id, dup_id, use_helper_id, use_dup_id, use_wild_id, use_glob_id, api_id },
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "util",
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{helper_id},
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "api",
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{api_use_id},
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "usecrate",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
}

test "lower: pub use re-exports — qualified, self-ref, and wildcard" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var ir_bodies: ir.bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    try buildUseModel(alloc, &graph, &ir_bodies);

    const rust_ir = ir.RustIr{
        .crate_name = "usecrate",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);

    // Root module maps to src/root.zig.
    var root_file: ?ast.File = null;
    for (pkg.files) |f| {
        if (std.mem.eql(u8, f.path, "src/root.zig")) {
            root_file = f;
            break;
        }
    }
    const rf = root_file orelse return error.RootFileMissing;

    // Only the cross-module `pub use util::helper;` should lower to a const
    // decl; the self-ref `pub use dup;` and wildcard re-exports are skipped.
    var helper_decl: ?ast.Decl = null;
    for (rf.decls) |decl| {
        if (decl == .const_decl) {
            try std.testing.expect(helper_decl == null);
            helper_decl = decl;
        }
    }
    const d = helper_decl orelse return error.ExpectedHelperReExport;
    try std.testing.expectEqualStrings("helper", d.const_decl.name);
    try std.testing.expect(d.const_decl.is_pub);
    // init must be a qualified field access: util.helper
    try std.testing.expect(d.const_decl.init == .field_access);
    const fa = d.const_decl.init.field_access;
    try std.testing.expect(fa.target.* == .ident);
    try std.testing.expectEqualStrings("util", fa.target.*.ident);
    try std.testing.expectEqualStrings("helper", fa.field_name);
}

test "lower: nested pub use keeps relative public module import" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var ir_bodies: ir.bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    try buildUseModel(alloc, &graph, &ir_bodies);

    const rust_ir = ir.RustIr{
        .crate_name = "usecrate",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);

    var api_file: ?ast.File = null;
    for (pkg.files) |file| {
        if (std.mem.eql(u8, file.path, "src/api.zig")) {
            api_file = file;
            break;
        }
    }
    const file = api_file orelse return error.ApiModuleMissing;

    var util_import: ?ast.Import = null;
    for (file.imports) |import| {
        if (!std.mem.eql(u8, import.local_name, "util")) continue;
        try std.testing.expect(util_import == null);
        util_import = import;
    }
    const import = util_import orelse return error.UtilImportMissing;
    try std.testing.expectEqualStrings("./util.zig", import.module_or_path);
    try std.testing.expect(import.is_pub);

    var helper_decl: ?ast.Decl = null;
    for (file.decls) |decl| {
        if (decl != .const_decl) continue;
        helper_decl = decl;
        break;
    }
    const decl = helper_decl orelse return error.HelperReExportMissing;
    try std.testing.expectEqualStrings("helper", decl.const_decl.name);
    try std.testing.expect(decl.const_decl.is_pub);
    try std.testing.expect(decl.const_decl.init == .field_access);
    const field_access = decl.const_decl.init.field_access;
    try std.testing.expect(field_access.target.* == .ident);
    try std.testing.expectEqualStrings("util", field_access.target.*.ident);
    try std.testing.expectEqualStrings("helper", field_access.field_name);
}

test "lower: child module ignores resolved parent glob use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const child_id = try addLowerEntity(&graph, .module, "child", root_id);
    const glob_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .private,
        .parent = child_id,
        .resolved = root_id,
        .renamed_to = null,
        .attributes = &.{},
    });
    const translated_id = try addLowerEntity(&graph, .struct_, "Translated", child_id);

    try graph.addUse(.{
        .id = glob_id,
        .kind = .glob,
        .target = root_id,
        .local_name = "",
        .is_pub_export = false,
        .span = span,
    });
    const root_module_id = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{child_id},
        .attributes = &.{},
    });
    const child_module_id = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "child",
        .parent = root_id,
        .source_path = "src/child.rs",
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{ glob_id, translated_id },
        .attributes = &.{},
    });
    std.debug.assert(root_module_id == root_id);
    std.debug.assert(child_module_id == child_id);
    try graph.addCrate(.{
        .name = "glob_child",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const entity_bodies = [_]ir.bodies.BodyKind{
        .none,
        .none,
        .none,
        .{ .struct_ = .{} },
    };
    const rust_ir = ir.RustIr{
        .crate_name = "glob_child",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &entity_bodies,
        },
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);

    var child_file: ?ast.File = null;
    for (pkg.files) |file| {
        if (std.mem.eql(u8, file.path, "src/child.zig")) {
            child_file = file;
            break;
        }
    }
    const file = child_file orelse return error.ChildModuleMissing;
    try std.testing.expectEqual(@as(usize, 1), file.decls.len);
    try std.testing.expect(file.decls[0] == .struct_decl);
    try std.testing.expectEqualStrings("Translated", file.decls[0].struct_decl.name);
}

fn buildSingleExternalUseModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
    path: []const []const u8,
    local_name: []const u8,
    is_pub_export: bool,
) !void {
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const use_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = try alloc.dupe(u8, local_name),
        .span = span,
        .visibility = if (is_pub_export) .public else .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const external_path = try alloc.alloc([]const u8, path.len);
    for (path, 0..) |segment, index| {
        external_path[index] = try alloc.dupe(u8, segment);
    }
    try graph.addUse(.{
        .id = use_id,
        .kind = .{ .external = .{ .path = external_path } },
        .local_name = try alloc.dupe(u8, local_name),
        .is_pub_export = is_pub_export,
        .target = 0,
        .span = span,
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{use_id}),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = try alloc.dupe(u8, "external_uses"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
    bodies.* = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = try alloc.dupe(ir.bodies.BodyKind, &.{ .none, .none }),
    };
}

test "lower: private core/std marker imports have explicit no-emission policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "core", "default", "Default" },
        "Default",
        false,
    );
    const rust_ir = ir.RustIr{
        .crate_name = "external_uses",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    for (pkg.files[0].imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "Default"));
    }
}

test "lower: private alloc Vec imports have explicit no-emission policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "alloc", "vec", "Vec" },
        "Vec",
        false,
    );
    const rust_ir = ir.RustIr{
        .crate_name = "external_uses",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    for (pkg.files[0].imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "Vec"));
    }
}

test "lower: private extern crate alloc is omitted beside a root declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try graph.symbol_table.add(.{
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
    const extern_crate_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .extern_crate,
        .name = "alloc",
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const offset_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = "FNV_OFFSET",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const offset_value = try model.e(litInt(0xcbf29ce484222325));
    try model.bodies.append(alloc, .none);
    try model.bodies.append(alloc, .none);
    try model.bodies.append(alloc, .{
        .const_ = .{
            .ty = .{ .prim = .u64 },
            .init = offset_value,
        },
    });
    const ir_bodies: ir.bodies.Bodies = .{
        .exprs = try model.exprs.toOwnedSlice(alloc),
        .stmts = try model.stmts.toOwnedSlice(alloc),
        .pats = try model.pats.toOwnedSlice(alloc),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(alloc),
    };
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{ extern_crate_id, offset_id }),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "fnv",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
    const rust_ir = ir.RustIr{
        .crate_name = "fnv",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };

    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    try std.testing.expectEqual(@as(usize, 1), pkg.files[0].decls.len);
    try std.testing.expect(pkg.files[0].decls[0] == .const_decl);
    try std.testing.expectEqualStrings(
        "FNV_OFFSET",
        pkg.files[0].decls[0].const_decl.name,
    );
}

test "lower: private core/std Hasher marker imports are omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "std", "hash", "Hasher" },
        "Hasher",
        false,
    );
    const rust_ir = ir.RustIr{
        .crate_name = "external_hasher",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    for (pkg.files[0].imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "Hasher"));
    }
}

test "lower: public and unknown external uses fail with a typed error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var public_graph = ir.graph.CrateGraph.init(alloc);
    var public_bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &public_graph,
        &public_bodies,
        &.{ "std", "hash", "Hasher" },
        "Hasher",
        true,
    );
    const public_ir = ir.RustIr{
        .crate_name = "public_external",
        .edition = "2021",
        .graph = public_graph,
        .types = &.{},
        .bodies = public_bodies,
    };
    try std.testing.expectError(
        error.UnsupportedExternalUse,
        lower.lowerRustIr(alloc, &public_ir, null),
    );

    var unknown_graph = ir.graph.CrateGraph.init(alloc);
    var unknown_bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &unknown_graph,
        &unknown_bodies,
        &.{ "alloc", "collections", "VecDeque" },
        "VecDeque",
        false,
    );
    const unknown_ir = ir.RustIr{
        .crate_name = "unknown_external",
        .edition = "2021",
        .graph = unknown_graph,
        .types = &.{},
        .bodies = unknown_bodies,
    };
    try std.testing.expectError(
        error.UnsupportedExternalUse,
        lower.lowerRustIr(alloc, &unknown_ir, null),
    );
}

fn buildExternalNominalAliasIr(
    alloc: std.mem.Allocator,
    path: []const []const u8,
    args: []const ir.types.Type,
) !ir.RustIr {
    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const alias_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .type_alias,
        .name = try alloc.dupe(u8, "ExternalAlias"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{alias_id}),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = try alloc.dupe(u8, "external_nominal"),
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, 2);
    body_rows[0] = .none;
    body_rows[1] = .{ .type_alias = .{ .target = .{ .external_nominal = .{
        .path = path,
        .args = args,
    } } } };
    return .{
        .crate_name = "external_nominal",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = body_rows,
        },
    };
}

fn expectExternalNominalError(
    alloc: std.mem.Allocator,
    path: []const []const u8,
    args: []const ir.types.Type,
    expected_error: anyerror,
) !void {
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, args);
    try std.testing.expectError(expected_error, lower.lowerRustIr(alloc, &rust_ir, null));
}

fn expectBuildHasherDefaultLowered(
    alloc: std.mem.Allocator,
    path: []const []const u8,
) !void {
    const args = [_]ir.types.Type{.{ .prim = .u8 }};
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, &args);
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);

    var found_runtime_import = false;
    for (pkg.files[0].imports) |import| {
        if (std.mem.eql(u8, import.local_name, "r2z") and
            std.mem.eql(u8, import.module_or_path, "r2z"))
        {
            found_runtime_import = true;
        }
    }
    try std.testing.expect(found_runtime_import);

    const alias = switch (pkg.files[0].decls[0]) {
        .const_decl => |decl| decl,
        else => return error.UnexpectedDeclarationKind,
    };
    const call = switch (alias.init) {
        .call => |value| value,
        else => return error.UnexpectedInitializerKind,
    };
    const callee_name = switch (call.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedCalleeKind,
    };
    try std.testing.expectEqualStrings("r2z.BuildHasherDefault", callee_name);
    try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
    const arg_prim = switch (call.generic_args[0]) {
        .prim => |value| value,
        else => return error.UnexpectedGenericArgumentKind,
    };
    try std.testing.expectEqual(ast.Prim.u8, arg_prim);
}

fn expectBuildHasherDefaultArityError(
    alloc: std.mem.Allocator,
    path: []const []const u8,
    args: []const ir.types.Type,
) !void {
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, args);
    try std.testing.expectError(
        error.GenericArgumentArityMismatch,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

test "lower: core/std BuildHasherDefault map to the r2z runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectBuildHasherDefaultLowered(
        alloc,
        &.{ "core", "hash", "BuildHasherDefault" },
    );
    try expectBuildHasherDefaultLowered(
        alloc,
        &.{ "std", "hash", "BuildHasherDefault" },
    );
}

test "lower: BuildHasherDefault rejects zero and multiple arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const two_args = [_]ir.types.Type{
        .{ .prim = .u8 },
        .{ .prim = .u16 },
    };

    try expectBuildHasherDefaultArityError(
        alloc,
        &.{ "core", "hash", "BuildHasherDefault" },
        &.{},
    );
    try expectBuildHasherDefaultArityError(
        alloc,
        &.{ "core", "hash", "BuildHasherDefault" },
        &two_args,
    );
    try expectBuildHasherDefaultArityError(
        alloc,
        &.{ "std", "hash", "BuildHasherDefault" },
        &.{},
    );
    try expectBuildHasherDefaultArityError(
        alloc,
        &.{ "std", "hash", "BuildHasherDefault" },
        &two_args,
    );
}

test "lower: alloc Vec maps to the Zig unmanaged vector type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]ir.types.Type{.{ .prim = .u8 }};
    const rust_ir = try buildExternalNominalAliasIr(
        alloc,
        &.{ "alloc", "vec", "Vec" },
        &args,
    );
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    try std.testing.expectEqual(@as(usize, 1), pkg.files[0].decls.len);

    const alias = switch (pkg.files[0].decls[0]) {
        .const_decl => |decl| decl,
        else => return error.UnexpectedDeclarationKind,
    };
    const call = switch (alias.init) {
        .call => |value| value,
        else => return error.UnexpectedInitializerKind,
    };
    const callee_name = switch (call.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedCalleeKind,
    };
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged", callee_name);
    try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
    const element_prim = switch (call.generic_args[0]) {
        .prim => |value| value,
        else => return error.UnexpectedGenericArgumentKind,
    };
    try std.testing.expectEqual(ast.Prim.u8, element_prim);
}

test "lower: alloc Vec rejects malformed arity and path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const element = [_]ir.types.Type{.{ .prim = .u8 }};
    const two_args = [_]ir.types.Type{
        .{ .prim = .u8 },
        .{ .prim = .u16 },
    };

    try expectExternalNominalError(
        alloc,
        &.{ "alloc", "vec", "Vec" },
        &.{},
        error.GenericArgumentArityMismatch,
    );
    try expectExternalNominalError(
        alloc,
        &.{ "alloc", "vec", "Vec" },
        &two_args,
        error.GenericArgumentArityMismatch,
    );
    try expectExternalNominalError(
        alloc,
        &.{ "alloc", "vec" },
        &element,
        error.UnsupportedExternalNominalType,
    );
    try expectExternalNominalError(
        alloc,
        &.{},
        &element,
        error.InvalidTypePath,
    );
}

test "lower: unknown external nominal remains unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = [_]ir.types.Type{.{ .prim = .u8 }};
    const rust_ir = try buildExternalNominalAliasIr(
        alloc,
        &.{ "alloc", "collections", "VecDeque" },
        &args,
    );
    try std.testing.expectError(
        error.UnsupportedExternalNominalType,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

fn checkLowerUseAllocationFailures(
    alloc: std.mem.Allocator,
    rust_ir: *const ir.RustIr,
) !void {
    var output_arena = std.heap.ArenaAllocator.init(alloc);
    defer output_arena.deinit();
    _ = try lower.lowerRustIr(output_arena.allocator(), rust_ir, null);
}

test "lower: import ownership survives later allocation failure" {
    var fixture_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer fixture_arena.deinit();
    const alloc = fixture_arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var ir_bodies: ir.bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    try buildUseModel(alloc, &graph, &ir_bodies);
    const rust_ir = ir.RustIr{
        .crate_name = "usecrate",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLowerUseAllocationFailures,
        .{&rust_ir},
    );
}

fn buildGenericModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
) !void {
    var model = Model.init(alloc);

    // id0: tuple struct Fletcher<T>(T, T)
    const struct_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = "Fletcher",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const t_path = ir.types.Path{ .segments = &.{.{ .name = "T", .id = null }} };

    // Explicit `generic_params` list on a tuple struct.
    try model.bodies.append(model.a(), .{
        .struct_ = .{
            .generic_params = &.{"T"},
            .trait_bounds = &.{},
            .layout = .tuple,
            .fields = &.{
                .{ .name = "0", .ty = .{ .path = t_path }, .visibility = .public, .span = span },
                .{ .name = "1", .ty = .{ .path = t_path }, .visibility = .public, .span = span },
            },
            .methods = &.{},
            .has_dynamic_resources = false,
        },
    });

    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    _ = try addRootModule(graph, .{
        .crate_name = "fletcher",
        .edition = 2018,
        .items = &.{struct_id},
    });
}

test "lower: generic tuple struct with numeric fields emits" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var ir_bodies: ir.bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    try buildGenericModel(alloc, &graph, &ir_bodies);

    const rust_ir = ir.RustIr{
        .crate_name = "fletcher",
        .edition = "2018",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);

    var root_file: ?ast.File = null;
    for (pkg.files) |f| {
        if (std.mem.eql(u8, f.path, "src/root.zig")) {
            root_file = f;
            break;
        }
    }
    const rf = root_file orelse return error.RootFileMissing;
    try std.testing.expectEqual(@as(usize, 1), rf.decls.len);

    const d = rf.decls[0];
    try std.testing.expect(d == .struct_decl);
    const sd = d.struct_decl;
    try std.testing.expectEqualStrings("Fletcher", sd.name);
    try std.testing.expectEqual(@as(usize, 2), sd.fields.len);

    // The single generic param T is carried onto the ast.StructDecl.
    try std.testing.expectEqual(@as(usize, 1), sd.generic_params.len);
    try std.testing.expectEqualStrings("T", sd.generic_params[0].name);
    try std.testing.expect(sd.generic_params[0].is_comptime);
    try std.testing.expectEqualStrings("0", sd.fields[0].name);
    try std.testing.expectEqualStrings("1", sd.fields[1].name);
    try std.testing.expectEqual(@as(usize, 0), sd.decls.len);
    try std.testing.expect(sd.generic_params[0].ty == null);

    const source = try emit.emitFile(alloc, &rf);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn Fletcher(comptime T: type) type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"0\": T") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"1\": T") != null);
}

test "lower: const array + primitive initializers emit real Zig values" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    // Entity 0: `const A: [u16; 2] = [0x88, 0xCC];`  (explicit element list)
    const a_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = "A",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // Entity 1: `const B: [u8; 256] = [0u8; 256];`   (repeating form)
    const b_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = "B",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Type table: [0] = u16, [1] = u8 (element types referenced by Expr.ty).
    const types_store: [2]ir.types.Type = .{ .{ .prim = .u16 }, .{ .prim = .u8 } };

    // A = [0x88, 0xCC]
    const e_a0 = try model.e(litInt(0x88));
    const e_a1 = try model.e(litInt(0xCC));
    const e_a = try model.e(.{ .array = .{ .elements = &.{ e_a0, e_a1 }, .repeat = null } });
    model.exprs.items[e_a].ty = 0;
    // B = [0u8; 256]
    const e_b0 = try model.e(litInt(0));
    const e_b = try model.e(.{ .array = .{ .elements = &.{e_b0}, .repeat = 256 } });
    model.exprs.items[e_b].ty = 1;

    const arr_u16 = try alloc.create(ir.types.Array);
    arr_u16.* = .{ .elem = .{ .prim = .u16 }, .len = .{ .literal = 2 } };
    const arr_u8 = try alloc.create(ir.types.Array);
    arr_u8.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 256 } };
    try model.bodies.append(alloc, .{ .const_ = .{ .ty = .{ .array = arr_u16 }, .init = e_a } });
    try model.bodies.append(alloc, .{ .const_ = .{ .ty = .{ .array = arr_u8 }, .init = e_b } });

    const ir_bodies: ir.bodies.Bodies = .{
        .exprs = try model.exprs.toOwnedSlice(alloc),
        .stmts = try model.stmts.toOwnedSlice(alloc),
        .pats = try model.pats.toOwnedSlice(alloc),
        .types = &types_store,
        .bodies = try model.bodies.toOwnedSlice(alloc),
    };

    _ = try addRootModule(&graph, .{
        .crate_name = "consts",
        .edition = 2021,
        .items = &.{ a_id, b_id },
    });

    const rust_ir = ir.RustIr{
        .crate_name = "consts",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = ir_bodies,
    };

    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);

    var found_a = false;
    var found_b = false;
    for (pkg.files) |*file| {
        const src = try emit.emitFile(alloc, file);
        if (std.mem.indexOf(u8, src, "const A: [2]u16 = [_]u16{ 136, 204 }") != null) found_a = true;
        if (std.mem.indexOf(u8, src, "const B: [256]u8 = [_]u8{ 0 } ** 256") != null) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);

    // Also assert the ast-level shapes directly: multi_array for the list,
    // repeat for the repeating form.
    var saw_multi = false;
    var saw_repeat = false;
    const file0 = pkg.files[0];
    for (file0.decls) |d| {
        if (d != .const_decl) continue;
        switch (d.const_decl.init) {
            .multi_array => |ma| {
                try std.testing.expectEqual(@as(usize, 2), ma.elements.len);
                saw_multi = true;
            },
            .repeat => |rp| {
                try std.testing.expectEqual(@as(usize, 256), rp.len);
                saw_repeat = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_multi);
    try std.testing.expect(saw_repeat);
}

test "lower: Vec literals reject before package output" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const tail_fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "vec_tail",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const statement_fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "vec_statement",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const first = try model.e(litInt(1));
    const second = try model.e(litInt(2));
    const explicit_vec = try model.e(.{
        .vec_lit = .{
            .elements = &.{ first, second },
            .repeat = null,
        },
    });
    const tail_block = try model.e(.{
        .block = .{
            .statements = &.{},
            .tail = explicit_vec,
            .labelled = null,
        },
    });

    const repeated_vec = try model.e(.{
        .vec_lit = .{
            .elements = &.{first},
            .repeat = 3,
        },
    });

    const explicit_element_ids = [_]ir.exprs.NodeId{ first, second };
    switch (model.exprs.items[explicit_vec].kind) {
        .vec_lit => |vec| {
            try std.testing.expectEqualSlices(
                ir.exprs.NodeId,
                &explicit_element_ids,
                vec.elements,
            );
            try std.testing.expectEqual(@as(?usize, null), vec.repeat);
        },
        else => return error.ExpectedVecLiteral,
    }
    switch (model.exprs.items[repeated_vec].kind) {
        .vec_lit => |vec| {
            const repeated_element_ids = [_]ir.exprs.NodeId{first};
            try std.testing.expectEqualSlices(
                ir.exprs.NodeId,
                &repeated_element_ids,
                vec.elements,
            );
            try std.testing.expectEqual(@as(?usize, 3), vec.repeat);
        },
        else => return error.ExpectedVecLiteral,
    }
    const repeated_vec_statement = try model.stmt(.{ .expr = repeated_vec });
    const statement_block = try model.e(.{
        .block = .{
            .statements = &.{repeated_vec_statement},
            .tail = null,
            .labelled = null,
        },
    });

    try model.bodies.append(alloc, .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u64 },
            .body = tail_block,
        },
    });
    try model.bodies.append(alloc, .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = statement_block,
        },
    });

    const ir_bodies: ir.bodies.Bodies = .{
        .exprs = try model.exprs.toOwnedSlice(alloc),
        .stmts = try model.stmts.toOwnedSlice(alloc),
        .pats = try model.pats.toOwnedSlice(alloc),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(alloc),
    };

    _ = try addRootModule(&graph, .{
        .crate_name = "vec_contract",
        .edition = 2021,
        .items = &.{ tail_fn_id, statement_fn_id },
    });

    const rust_ir = ir.RustIr{
        .crate_name = "vec_contract",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    try std.testing.expectError(
        error.UnsupportedExpression,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

test "lower: rejects prelude method fixture with incomplete topology" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    // Register the method entities so the symbol table resolves their names.
    const as_ref_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "as_ref",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const clone_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "clone",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const len_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "len",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bitxor_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "bitxor",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const to_vec_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "to_vec",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Types: 0 = []const u8 (slice), 1 = u8, 2 = usize.
    const slice_t = try alloc.create(ir.types.Slice);
    slice_t.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const types_store = try alloc.alloc(ir.types.Type, 3);
    types_store[0] = .{ .slice = slice_t };
    types_store[1] = .{ .prim = .u8 };
    types_store[2] = .{ .prim = .usize };

    // Receiver `data` (path → ident) is a slice (ty = 0) → slice-compatible.
    const recv_def = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = "data",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const function_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "prelude_fixture",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    for ([_]ir.spine.EntityId{ as_ref_id, clone_id, len_id, bitxor_id, to_vec_id, recv_def }) |id| {
        graph.symbol_table.entities.items[id].parent = function_id;
    }
    const e_recv = try model.e(.{ .path = .{ .def = recv_def, .generic_args = &.{} } });
    // Set the receiver's declared type so array/slice detection is grounded.
    model.exprs.items[e_recv].ty = 0;

    // data.as_ref()
    const mc_asref = try model.e(.{ .method_call = .{
        .receiver = e_recv,
        .receiver_mode = .shared,
        .method = as_ref_id,
        .args = &.{},
    } });
    const e_blk = try model.e(.{ .block = .{ .statements = &.{}, .tail = mc_asref, .labelled = null } });
    for (0..5) |_| {
        try model.bodies.append(model.a(), .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = e_blk,
        } });
    }
    try model.bodies.append(model.a(), .{ .const_ = .{
        .ty = types_store[0],
        .init = e_recv,
    } });
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{.{ .name = "data", .ty = types_store[0], .span = span }},
        .ret = types_store[0],
        .body = e_blk,
    } });

    const final_bodies = ir.bodies.Bodies{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = types_store,
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    _ = try addRootModule(&graph, .{
        .crate_name = "sample",
        .edition = 2021,
        .items = &.{function_id},
    });

    const rust_ir = ir.RustIr{
        .crate_name = "sample",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = final_bodies,
    };
    // The receiver path points at a const entity without a generic body.
    // Strict validation rejects this legacy fixture before prelude lowering.
    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

/// Lower one method call whose receiver type is known to the RustIr.
/// The fixture keeps the method entity separate from the callable entity so
/// the body table exercises the same sparse EntityId convention as production.
fn lowerStdMethodFixture(
    alloc: std.mem.Allocator,
    method_name: []const u8,
    receiver_ty: ir.types.Type,
    return_ty: ir.types.Type,
    argument: ?i128,
) !ast.Expr {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const method_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = method_name,
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const receiver_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = "value",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const function_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "std_method_fixture",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const types_store = try alloc.alloc(ir.types.Type, 1);
    types_store[0] = receiver_ty;

    const receiver_expr = try model.e(.{
        .path = .{ .def = receiver_id, .generic_args = &.{} },
    });
    model.exprs.items[receiver_expr].ty = 0;

    var args: []const ir.exprs.NodeId = &.{};
    if (argument) |value| {
        const argument_expr = try model.e(litInt(value));
        const argument_ids = try alloc.alloc(ir.exprs.NodeId, 1);
        argument_ids[0] = argument_expr;
        args = argument_ids;
    }

    const method_expr = try model.e(.{
        .method_call = .{
            .receiver = receiver_expr,
            .receiver_mode = .value,
            .method = method_id,
            .args = args,
        },
    });
    const method_block = try model.e(.{
        .block = .{ .statements = &.{}, .tail = method_expr, .labelled = null },
    });
    graph.symbol_table.entities.items[method_id].parent = function_id;
    graph.symbol_table.entities.items[receiver_id].parent = function_id;

    // Entity 0 is the method definition, entity 1 is the receiver binding,
    // and entity 2 is the emitted callable.
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{.{ .name = "value", .ty = receiver_ty, .span = span }},
        .ret = return_ty,
        .body = method_block,
    } });
    try model.bodies.append(model.a(), .{ .const_ = .{
        .ty = receiver_ty,
        .init = receiver_expr,
    } });
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{.{ .name = "value", .ty = receiver_ty, .span = span }},
        .ret = return_ty,
        .body = method_block,
    } });

    const bodies = ir.bodies.Bodies{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = types_store,
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };
    _ = try addRootModule(&graph, .{
        .crate_name = "std_method_fixture",
        .edition = 2021,
        .items = &.{function_id},
    });

    const rust_ir = ir.RustIr{
        .crate_name = "std_method_fixture",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    const decl = pkg.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const expr = body.expr orelse return error.ExpectedBodyExpression;
    return expr.*;
}

test "lower: resolver-recognized std methods reject incomplete fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // The receiver path in each legacy fixture lacks a generic body entry.

    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        lowerStdMethodFixture(
            alloc,
            "count_ones",
            .{ .prim = .u32 },
            .{ .prim = .u32 },
            null,
        ),
    );
    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        lowerStdMethodFixture(
            alloc,
            "saturating_mul",
            .{ .prim = .u32 },
            .{ .prim = .u32 },
            2,
        ),
    );

    const elem = try alloc.create(ir.types.Type);
    elem.* = .{ .prim = .u8 };
    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = elem.* };
    const slice_ty: ir.types.Type = .{ .slice = slice_info };

    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        lowerStdMethodFixture(alloc, "iter", slice_ty, slice_ty, null),
    );
    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        lowerStdMethodFixture(
            alloc,
            "len",
            slice_ty,
            .{ .prim = .usize },
            null,
        ),
    );
}

test "lower: resolver-recognized Option method rejects incomplete fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // The receiver path lacks a generic body entry in this legacy fixture.

    const option_elem = try alloc.create(ir.types.Type);
    option_elem.* = .{ .prim = .u8 };
    const option_ty: ir.types.Type = .{ .option = option_elem };

    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        lowerStdMethodFixture(
            alloc,
            "is_some",
            option_ty,
            .{ .prim = .bool },
            null,
        ),
    );
}

test "lower: generic methods resolve Self and associated type qualifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_entity = try graph.symbol_table.add(.{
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
    const struct_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = "Fletcher",
        .span = span,
        .visibility = .public,
        .parent = root_entity,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const trait_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .trait_,
        .name = "FletcherAccumulator",
        .span = span,
        .visibility = .public,
        .parent = root_entity,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = "FletcherAccumulatorU16",
        .span = span,
        .visibility = .public,
        .parent = root_entity,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const alias_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .type_alias,
        .name = "InputType",
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const generic_segments = try alloc.alloc(ir.types.PathSegment, 1);
    generic_segments[0] = .{ .name = "T", .id = null };
    const generic_ty: ir.types.Type = .{ .path = .{
        .segments = generic_segments,
    } };
    const input_segments = try alloc.alloc(ir.types.PathSegment, 3);
    input_segments[0] = .{ .name = "T", .id = null };
    input_segments[1] = .{ .name = "FletcherAccumulator", .id = trait_id };
    input_segments[2] = .{ .name = "InputType", .id = null };
    const input_ty: ir.types.Type = .{ .path = .{
        .segments = input_segments,
    } };
    const self_segments = try alloc.alloc(ir.types.PathSegment, 1);
    self_segments[0] = .{ .name = "Self", .id = null };
    const self_ty: ir.types.Type = .{ .path = .{
        .segments = self_segments,
    } };
    const input_slice = try alloc.create(ir.types.Slice);
    input_slice.* = .{ .const_ = true, .elem = input_ty };
    const e_unit = try alloc.create(ir.exprs.Expr);
    e_unit.* = strictExpr(0, .unit);
    const e_block = try alloc.create(ir.exprs.Expr);
    e_block.* = strictExpr(1, .{ .block = .{
        .statements = &.{},
        .tail = null,
        .labelled = null,
    } });
    const generic_exprs = try alloc.alloc(ir.exprs.Expr, 2);
    generic_exprs[0] = e_unit.*;
    generic_exprs[1] = e_block.*;

    const method_bodies = [_]ir.bodies.StructMethod{
        .{
            .name = "with_initial_values",
            .params = &.{
                .{ .name = "a", .ty = input_ty, .span = span },
                .{ .name = "b", .ty = input_ty, .span = span },
            },
            .ret = self_ty,
            .body = 1,
        },
        .{
            .name = "update",
            .params = &.{
                .{ .name = "data", .ty = .{ .slice = input_slice }, .span = span },
            },
            .ret = .{ .prim = .unit },
            .body = 1,
            .receiver = .mut_ref,
        },
    };
    const struct_body: ir.bodies.BodyKind = .{ .struct_ = .{
        .generic_params = &.{"T"},
        .fields = &.{
            .{ .name = "a", .ty = generic_ty, .visibility = .private, .span = span },
        },
        .methods = &method_bodies,
    } };
    const trait_assoc_types = [_]ir.items.AssocType{
        .{
            .name = "InputType",
            .generics = null,
            .bounds = &.{},
            .default = null,
        },
    };
    const trait_body: ir.bodies.BodyKind = .{ .trait_ = .{
        .name = "FletcherAccumulator",
        .assoc_types = &trait_assoc_types,
    } };
    const trait_path_segments = [_]ir.types.PathSegment{
        .{ .name = "FletcherAccumulator", .id = trait_id },
    };
    const impl_assoc_items = [_]ir.spine.EntityId{alias_id};
    const impl_body: ir.bodies.BodyKind = .{ .impl_ = .{
        .self_ty = .{ .prim = .u16 },
        .trait_path = .{ .segments = &trait_path_segments },
        .assoc_items = &impl_assoc_items,
    } };
    const alias_body: ir.bodies.BodyKind = .{ .type_alias = .{
        .target = .{ .prim = .u8 },
    } };

    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{struct_id},
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "fletcher",
        .edition = 2021,
        .kind = .lib,
        .root = root_entity,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "fletcher",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = generic_exprs,
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &.{ .none, struct_body, trait_body, impl_body, alias_body },
        },
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    var struct_decl: ?ast.StructDecl = null;
    var descriptor_decl: ?ast.TraitDescriptorDecl = null;
    for (pkg.files[0].decls) |decl| {
        switch (decl) {
            .struct_decl => |value| struct_decl = value,
            .trait_descriptor => |value| descriptor_decl = value,
            else => {},
        }
    }
    const lowered_struct = struct_decl orelse return error.MissingFletcherStruct;
    const descriptor = descriptor_decl orelse return error.MissingFletcherDescriptor;
    try std.testing.expectEqualStrings("__r2z_trait_descriptor_2", descriptor.name);
    try std.testing.expectEqual(@as(usize, 1), descriptor.cases.len);
    try std.testing.expectEqual(ast.Type{ .prim = .u16 }, descriptor.cases[0].receiver);
    try std.testing.expectEqual(@as(usize, 1), descriptor.cases[0].members.len);
    const descriptor_member = switch (descriptor.cases[0].members[0]) {
        .type_ => |value| value,
        else => return error.UnexpectedFletcherDescriptorMember,
    };
    try std.testing.expectEqualStrings("InputType", descriptor_member.name);
    try std.testing.expectEqual(ast.Type{ .prim = .u8 }, descriptor_member.ty);

    var saw_constructor = false;
    var saw_update = false;
    for (lowered_struct.decls) |decl| {
        const method = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, method.name, "with_initial_values")) {
            saw_constructor = true;
            const first_projection = switch (method.params[0].ty) {
                .projected => |value| value,
                else => return error.MissingFletcherProjection,
            };
            try std.testing.expectEqualStrings("__r2z_trait_descriptor_2", first_projection.descriptor);
            try std.testing.expectEqualStrings("T", first_projection.receiver.named);
            try std.testing.expectEqualStrings("InputType", first_projection.member);
            const second_projection = switch (method.params[1].ty) {
                .projected => |value| value,
                else => return error.MissingFletcherProjection,
            };
            try std.testing.expectEqualStrings("T", second_projection.receiver.named);
            try std.testing.expectEqualStrings("InputType", second_projection.member);
            try std.testing.expect(method.ret_type == .generic);
            try std.testing.expectEqualStrings("Fletcher", method.ret_type.generic.name);
        } else if (std.mem.eql(u8, method.name, "update")) {
            saw_update = true;
            try std.testing.expect(method.params[0].ty == .ptr);
            try std.testing.expect(!method.params[0].ty.ptr.is_const);
            try std.testing.expect(method.params[0].ty.ptr.elem.* == .generic);
            try std.testing.expectEqualStrings("Fletcher", method.params[0].ty.ptr.elem.generic.name);
            const slice_element = switch (method.params[1].ty) {
                .slice => |value| value.elem.*,
                else => return error.MissingFletcherSlice,
            };
            try std.testing.expect(slice_element == .projected);
            try std.testing.expectEqualStrings("InputType", slice_element.projected.member);
        }
    }
    try std.testing.expect(saw_constructor);
    try std.testing.expect(saw_update);
}
test "lower: qualifies unqualified inherent static calls with Self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try graph.symbol_table.add(.{
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
    const struct_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = "U32X4",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = "U32X4",
        .span = span,
        .visibility = .private,
        .parent = struct_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const new_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "new",
        .span = span,
        .visibility = .private,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    var model = Model.init(alloc);
    const new_value = try model.e(litInt(0));
    const new_body = try model.e(.{
        .block = .{ .statements = &.{}, .tail = new_value, .labelled = null },
    });
    const new_call = try model.e(.{
        .call = .{
            .call_kind = .{ .free = new_id },
            .args = &.{},
        },
    });
    const use_new_body = try model.e(.{
        .block = .{ .statements = &.{}, .tail = new_call, .labelled = null },
    });
    const methods = try alloc.dupe(ir.bodies.StructMethod, &[_]ir.bodies.StructMethod{
        .{
            .name = "new",
            .ret = .{ .prim = .u32 },
            .body = new_body,
            .receiver = null,
        },
        .{
            .name = "use_new",
            .ret = .{ .prim = .u32 },
            .body = use_new_body,
            .receiver = null,
        },
    });
    try model.bodies.append(model.a(), .{ .none = {} });
    try model.bodies.append(model.a(), .{ .struct_ = .{ .methods = methods } });
    try model.bodies.append(model.a(), .{ .none = {} });
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u32 },
        .body = new_body,
    } });

    const root_module = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{struct_id},
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "adler",
        .edition = 2015,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "adler",
        .edition = "2015",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    const struct_decl = pkg.files[0].decls[0].struct_decl;

    for (struct_decl.decls) |decl| {
        if (!std.mem.eql(u8, decl.fn_decl.name, "use_new")) continue;
        const tail = decl.fn_decl.body.?.expr.?;
        try std.testing.expect(tail.* == .call);
        try std.testing.expect(tail.*.call.callee.* == .field_access);
        try std.testing.expectEqualStrings("Self", tail.*.call.callee.field_access.target.ident);
        try std.testing.expectEqualStrings("new", tail.*.call.callee.field_access.field_name);
        return;
    }
    return error.TestUnexpectedResult;
}

fn lowerParentChildFixture(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const support_id = try addLowerEntity(&graph, .module, "support", root_id);
    const child_id = try addLowerEntity(&graph, .module, "tests", support_id);
    const root_struct_id = try addLowerEntity(&graph, .struct_, "RootStruct", root_id);
    const root_fn_id = try addLowerEntity(&graph, .fn_, "root_fn", root_id);
    const support_struct_id = try addLowerEntity(&graph, .struct_, "ParentStruct", support_id);
    const support_fn_id = try addLowerEntity(&graph, .fn_, "parent_fn", support_id);
    const impl_id = try addLowerEntity(&graph, .impl_, "Build for ParentStruct", support_struct_id);
    const trait_fn_id = try addLowerEntity(&graph, .fn_, "make", impl_id);
    const child_fn_id = try addLowerEntity(&graph, .fn_, "child_entry", child_id);

    var model = Model.init(alloc);
    const types_store: [1]ir.types.Type = .{.{ .prim = .unit }};
    const one = try model.e(litInt(1));
    const empty_block = try model.e(.{
        .block = .{ .statements = &.{}, .tail = null, .labelled = null },
    });
    const parent_lit = try model.e(.{ .struct_lit = .{
        .def = support_struct_id,
        .fields = &.{.{ .field = "value", .value = one, .shorthand = false }},
        .base = null,
    } });
    const parent_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = support_fn_id },
        .args = &.{},
    } });
    const root_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = root_fn_id },
        .args = &.{},
    } });
    const trait_call = try model.e(.{ .call = .{
        .call_kind = .{ .associated = trait_fn_id },
        .args = &.{},
    } });
    model.exprs.items[trait_call].ty = 0;
    const child_stmts = try alloc.dupe(ir.exprs.NodeId, &[_]ir.exprs.NodeId{
        try model.stmt(.{ .expr = parent_lit }),
        try model.stmt(.{ .expr = parent_call }),
        try model.stmt(.{ .expr = root_call }),
        try model.stmt(.{ .expr = trait_call }),
    });
    const child_block = try model.e(.{
        .block = .{ .statements = child_stmts, .tail = null, .labelled = null },
    });

    while (model.bodies.items.len <= child_fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[root_struct_id] = .{ .struct_ = .{} };
    model.bodies.items[root_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = empty_block,
    } };
    const support_methods = try alloc.dupe(ir.bodies.StructMethod, &[_]ir.bodies.StructMethod{
        .{
            .name = "make",
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = empty_block,
            .receiver = null,
        },
    });
    model.bodies.items[support_struct_id] = .{ .struct_ = .{
        .fields = &.{.{ .name = "value", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span }},
        .methods = support_methods,
    } };
    model.bodies.items[support_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = empty_block,
    } };
    model.bodies.items[child_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = child_block,
    } };

    const root_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{
        root_struct_id,
        root_fn_id,
        support_id,
    });
    const support_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{
        support_struct_id,
        support_fn_id,
        child_id,
    });
    const child_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{child_fn_id});
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = root_items,
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "support",
        .parent = root_id,
        .source_path = "src/support.rs",
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = support_items,
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "tests",
        .parent = support_id,
        .source_path = "src/support/tests.rs",
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = child_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "parent_child",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "parent_child",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

test "lower: package files without std references omit std import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pkg = try lowerParentChildFixture(arena.allocator());
    for (pkg.files) |file| {
        var std_imports: usize = 0;
        for (file.imports) |import| {
            if (std.mem.eql(u8, import.local_name, "std") and
                std.mem.eql(u8, import.module_or_path, "std"))
            {
                std_imports += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 0), std_imports);
    }
}

test "lower: generated allocator constructs retain one std import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const file = try lowerTestAllocatorFixture(arena.allocator(), true, true);
    var std_imports: usize = 0;
    for (file.imports) |import| {
        if (std.mem.eql(u8, import.local_name, "std") and
            std.mem.eql(u8, import.module_or_path, "std"))
        {
            std_imports += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), std_imports);
    try std.testing.expect(file.imports.len > 0);
    try std.testing.expectEqualStrings("std", file.imports[0].local_name);
    try std.testing.expectEqualStrings("std", file.imports[0].module_or_path);
}

fn lowerSourceFidelityFixture(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);

    const root_id = try graph.symbol_table.add(.{
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
    const support_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "support",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const private_fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "hidden",
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const test_fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "checks_answer",
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{
            .{ .name = "test", .meta = "", .known = true },
        },
    });
    const support_use_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = support_id,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_module_id = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ support_id, private_fn_id, test_fn_id, support_use_id },
        .attributes = &.{},
    });
    const support_module_id = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "support",
        .parent = root_id,
        .source_path = "src/support.rs",
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    std.debug.assert(root_module_id == root_id);
    std.debug.assert(support_module_id == support_id);

    try graph.addUse(.{
        .id = support_use_id,
        .kind = .{ .plain = support_id },
        .local_name = "support",
        .is_pub_export = true,
        .target = support_id,
        .span = span,
    });
    try graph.addCrate(.{
        .name = "source_fidelity",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const empty_block = try model.e(.{
        .block = .{ .statements = &.{}, .tail = null, .labelled = null },
    });
    var entity_id: usize = 0;
    while (entity_id <= support_use_id) : (entity_id += 1) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[private_fn_id] = .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = empty_block,
        },
    };
    model.bodies.items[test_fn_id] = .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = empty_block,
        },
    };

    const rust_ir = ir.RustIr{
        .crate_name = "source_fidelity",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

fn sourceFidelityRootFile(pkg: ast.Package) !ast.File {
    for (pkg.files) |file| {
        if (std.mem.eql(u8, file.path, "src/root.zig")) return file;
    }
    return error.RootFileMissing;
}

fn lowerTestAllocatorFixture(
    alloc: std.mem.Allocator,
    is_allocating: bool,
    calls_allocating_helper: bool,
) !ast.File {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const helper_id = try addLowerEntity(
        &graph,
        .fn_,
        "allocating_helper",
        null,
    );
    const test_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = if (is_allocating)
            "allocating_case"
        else if (calls_allocating_helper)
            "dynamic_allocating_case"
        else
            "plain_case",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{
            .{ .name = "test", .meta = "", .known = true },
        },
    });
    const test_discard_id = try addLowerEntity(
        &graph,
        .field,
        "_",
        test_id,
    );
    const root_id = try addRootModule(&graph, .{
        .crate_name = "test_allocator",
        .edition = 2021,
        .items = &.{ helper_id, test_id },
    });
    const helper_return = try model.e(.{ .return_ = .{ .value = null } });
    const helper_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = helper_return,
        .labelled = null,
    } });

    const test_discard = try model.e(.{ .path = .{
        .def = test_discard_id,
        .generic_args = &.{},
    } });
    const seven = try model.e(litInt(7));
    const plain_assignment = try model.e(.{ .assign = .{
        .target = test_discard,
        .op = .plain,
        .value = seven,
        .overflow = .wrapping,
    } });
    const plain_statement = try model.stmt(.{ .expr = plain_assignment });

    const helper_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = helper_id },
        .args = &.{},
    } });
    const allocating_statement = try model.stmt(.{ .expr = helper_call });
    const test_statement = if (is_allocating)
        allocating_statement
    else if (calls_allocating_helper)
        allocating_statement
    else
        plain_statement;
    const test_statements = [_]ir.exprs.NodeId{test_statement};

    const nine = try model.e(litInt(9));
    const tail_assignment = try model.e(.{ .assign = .{
        .target = test_discard,
        .op = .plain,
        .value = nine,
        .overflow = .wrapping,
    } });
    const tail_statement = try model.stmt(.{ .expr = tail_assignment });
    const tail_statements = [_]ir.exprs.NodeId{tail_statement};
    const tail_block = try model.e(.{ .block = .{
        .statements = &tail_statements,
        .tail = null,
        .labelled = null,
    } });
    const test_body = try model.e(.{ .block = .{
        .statements = &test_statements,
        .tail = tail_block,
        .labelled = null,
    } });

    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[helper_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = helper_body,
        .is_allocating = true,
    } };
    model.bodies.items[test_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = test_body,
        .is_allocating = is_allocating,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "test_allocator",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &.{},
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    return sourceFidelityRootFile(package);
}

fn testDeclByName(file: ast.File, name: []const u8) !ast.TestDecl {
    for (file.tests) |test_decl| {
        if (std.mem.eql(u8, test_decl.name, name)) return test_decl;
    }
    return error.TestDeclarationMissing;
}

test "lower: test attribute creates an AST test declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pkg = try lowerSourceFidelityFixture(arena.allocator());
    const root_file = try sourceFidelityRootFile(pkg);

    try std.testing.expectEqual(@as(usize, 1), root_file.tests.len);
    try std.testing.expectEqualStrings("checks_answer", root_file.tests[0].name);
    for (root_file.decls) |decl| {
        if (decl != .fn_decl) continue;
        try std.testing.expect(!std.mem.eql(u8, decl.fn_decl.name, "checks_answer"));
    }
}

test "lower and emit: allocating tests receive a local allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try lowerTestAllocatorFixture(alloc, true, true);
    const test_decl = try testDeclByName(file, "allocating_case");
    try std.testing.expectEqual(@as(usize, 2), test_decl.body.stmts.len);

    const allocator_stmt = switch (test_decl.body.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingTestAllocatorBinding,
    };
    try std.testing.expectEqualStrings("allocator", allocator_stmt.name);
    const allocator_type = switch (allocator_stmt.ty orelse return error.MissingTestAllocatorType) {
        .named => |name| name,
        else => return error.UnexpectedTestAllocatorType,
    };
    try std.testing.expectEqualStrings("std.mem.Allocator", allocator_type);
    const allocator_init = switch (allocator_stmt.init) {
        .field_access => |value| value,
        else => return error.MissingTestAllocatorInitializer,
    };
    try std.testing.expectEqualStrings("allocator", allocator_init.field_name);
    const testing_access = switch (allocator_init.target.*) {
        .field_access => |value| value,
        else => return error.UnexpectedTestAllocatorInitializer,
    };
    try std.testing.expectEqualStrings("testing", testing_access.field_name);
    const testing_name = switch (testing_access.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedTestAllocatorNamespace,
    };
    try std.testing.expectEqualStrings("std", testing_name);

    const call_stmt = switch (test_decl.body.stmts[1]) {
        .expr_stmt => |value| value.*,
        else => return error.MissingAllocatingTestCall,
    };
    const call_try = switch (call_stmt) {
        .unary_op => |value| value,
        else => return error.MissingAllocatingTestTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, call_try.op);
    const call = switch (call_try.operand.*) {
        .call => |value| value,
        else => return error.MissingAllocatingTestCall,
    };
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    const call_allocator = switch (call.args[0]) {
        .ident => |name| name,
        else => return error.UnexpectedAllocatingTestArgument,
    };
    try std.testing.expectEqualStrings("allocator", call_allocator);
    const tail = test_decl.body.expr orelse return error.MissingAllocatingTestTail;
    const tail_block = switch (tail.*) {
        .block => |value| value,
        else => return error.UnexpectedAllocatingTestTail,
    };
    try std.testing.expectEqual(@as(usize, 1), tail_block.stmts.len);

    const emitted = try emit.emitFile(alloc, &file);
    const allocator_text = "const allocator: std.mem.Allocator = std.testing.allocator;";
    try std.testing.expect(std.mem.indexOf(u8, emitted, allocator_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "try allocating_helper(allocator);") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "_ = 9;") != null);
}

test "lower and emit: dynamically allocating tests receive a local allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try lowerTestAllocatorFixture(alloc, false, true);
    const test_decl = try testDeclByName(file, "dynamic_allocating_case");
    try std.testing.expectEqual(@as(usize, 2), test_decl.body.stmts.len);

    const allocator_stmt = switch (test_decl.body.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingTestAllocatorBinding,
    };
    try std.testing.expectEqualStrings("allocator", allocator_stmt.name);

    const call_stmt = switch (test_decl.body.stmts[1]) {
        .expr_stmt => |value| value.*,
        else => return error.MissingAllocatingTestCall,
    };
    const call_try = switch (call_stmt) {
        .unary_op => |value| value,
        else => return error.MissingAllocatingTestTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, call_try.op);
    const call = switch (call_try.operand.*) {
        .call => |value| value,
        else => return error.MissingAllocatingTestCall,
    };
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    const call_allocator = switch (call.args[0]) {
        .ident => |name| name,
        else => return error.UnexpectedAllocatingTestArgument,
    };
    try std.testing.expectEqualStrings("allocator", call_allocator);

    const emitted = try emit.emitFile(alloc, &file);
    const allocator_text = "const allocator: std.mem.Allocator = std.testing.allocator;";
    const call_text = "try allocating_helper(allocator);";
    try std.testing.expect(std.mem.indexOf(u8, emitted, allocator_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, call_text) != null);
}

test "lower and emit: nonallocating tests keep their body unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try lowerTestAllocatorFixture(alloc, false, false);
    const test_decl = try testDeclByName(file, "plain_case");
    try std.testing.expectEqual(@as(usize, 1), test_decl.body.stmts.len);
    try std.testing.expect(test_decl.body.stmts[0] == .assign);
    try std.testing.expect(test_decl.body.expr != null);

    const emitted = try emit.emitFile(alloc, &file);
    const expected_test =
        "test \"plain_case\" {\n" ++
        "    _ = 7;\n" ++
        "    {\n" ++
        "        _ = 9;\n" ++
        "    }\n" ++
        "}\n";
    try std.testing.expect(std.mem.indexOf(u8, emitted, expected_test) != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "std.testing.allocator") == null);
}

test "lower: private source function remains non-public" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pkg = try lowerSourceFidelityFixture(arena.allocator());
    const root_file = try sourceFidelityRootFile(pkg);

    for (root_file.decls) |decl| {
        if (decl != .fn_decl) continue;
        if (!std.mem.eql(u8, decl.fn_decl.name, "hidden")) continue;
        try std.testing.expect(!decl.fn_decl.is_pub);
        return;
    }
    return error.PrivateFunctionMissing;
}

test "lower: intra-crate module re-export does not self-alias its import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pkg = try lowerSourceFidelityFixture(arena.allocator());
    const root_file = try sourceFidelityRootFile(pkg);

    var support_imports: usize = 0;
    for (root_file.imports) |import| {
        if (!std.mem.eql(u8, import.local_name, "support")) continue;
        support_imports += 1;
        try std.testing.expect(import.is_pub);
    }
    try std.testing.expectEqual(@as(usize, 1), support_imports);

    for (root_file.decls) |decl| {
        if (decl != .const_decl) continue;
        try std.testing.expect(!std.mem.eql(u8, decl.const_decl.name, "support"));
    }
}

fn strictExpr(id: ir.exprs.NodeId, kind: ir.exprs.ExprKind) ir.exprs.Expr {
    return .{ .id = id, .span = span, .ty = null, .kind = kind };
}

fn expectSingleFunctionLoweringError(
    alloc: std.mem.Allocator,
    body_kind: ir.bodies.BodyKind,
    exprs: []const ir.exprs.Expr,
    stmts: []const ir.exprs.Statement,
    pats: []const ir.exprs.Pattern,
    types: []const ir.types.Type,
    expected_error: anyerror,
) !void {
    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "strict_fixture",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try addRootModule(&graph, .{
        .crate_name = "strict_fixture",
        .edition = 2021,
        .items = &.{function_id},
    });
    const entity_bodies = [_]ir.bodies.BodyKind{body_kind};
    const rust_ir = ir.RustIr{
        .crate_name = "strict_fixture",
        .edition = "2021",
        .graph = graph,
        .types = types,
        .bodies = .{
            .exprs = exprs,
            .stmts = stmts,
            .pats = pats,
            .types = types,
            .bodies = &entity_bodies,
        },
    };
    try std.testing.expectError(expected_error, lower.lowerRustIr(alloc, &rust_ir, null));
}

test "lower: missing declaration bodies and expression nodes are typed errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectSingleFunctionLoweringError(
        alloc,
        .{ .none = {} },
        &.{},
        &.{},
        &.{},
        &.{},
        error.DeclarationBodyMismatch,
    );
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 99,
        } },
        &.{},
        &.{},
        &.{},
        &.{},
        error.MissingExpressionNode,
    );
}

test "lower: missing type ids are typed errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const exprs = [_]ir.exprs.Expr{
        strictExpr(0, litInt(1)),
        strictExpr(1, .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } }),
    };
    const stmts = [_]ir.exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 0, .init = 0, .ty = 99 } },
    }};
    const pats = [_]ir.exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "value",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    }};
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 1,
        } },
        &exprs,
        &stmts,
        &pats,
        &.{},
        error.MissingTypeId,
    );
}

test "lower: unknown calls, types, and constructors are strict typed errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const missing_call = [_]ir.exprs.Expr{
        strictExpr(0, .{ .call = .{
            .call_kind = .{ .free = 99 },
            .args = &.{},
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
        &missing_call,
        &.{},
        &.{},
        &.{},
        error.MissingDefinition,
    );

    const missing_type_segments = [_]ir.types.PathSegment{
        .{ .name = "Missing", .id = 99 },
    };
    const unit_expr = [_]ir.exprs.Expr{strictExpr(0, .unit)};
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .path = .{ .segments = &missing_type_segments } },
            .body = 0,
        } },
        &unit_expr,
        &.{},
        &.{},
        &.{},
        error.MissingTypeDefinition,
    );

    // The function target is not a type definition; strict preflight wins.
    const bad_constructor = [_]ir.exprs.Expr{
        strictExpr(0, .{ .call = .{
            .call_kind = .{ .constructor = 0 },
            .args = &.{},
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
        &bad_constructor,
        &.{},
        &.{},
        &.{},
        error.InvalidTypeDefinition,
    );
}

test "lower: generic inference and arity reject incomplete fixture definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const uninferred_call = [_]ir.exprs.Expr{
        strictExpr(0, .{ .call = .{
            .call_kind = .{ .free = 0 },
            .args = &.{},
        } }),
    };
    // Strict fixture validation precedes the intended inference failure.
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .generic_params = &.{"T"},
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
        &uninferred_call,
        &.{},
        &.{},
        &.{},
        error.InvalidTypeDefinition,
    );

    const explicit_args = [_]ir.types.Type{
        .{ .prim = .i32 },
        .{ .prim = .u32 },
    };
    const wrong_arity = [_]ir.exprs.Expr{
        strictExpr(0, .{ .path = .{
            .def = 0,
            .generic_args = &explicit_args,
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .generic_params = &.{"T"},
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
        &wrong_arity,
        &.{},
        &.{},
        &.{},
        error.InvalidTypeDefinition,
    );
}

test "lower: missing module parents and use targets are typed errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bad_module_graph = ir.graph.CrateGraph.init(alloc);
    _ = try bad_module_graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "child",
        .parent = 99,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    const bad_module_ir = ir.RustIr{
        .crate_name = "bad_module",
        .edition = "2021",
        .graph = bad_module_graph,
        .types = &.{},
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &.{},
        },
    };
    try std.testing.expectError(
        error.ModuleParentMissing,
        lower.lowerRustIr(alloc, &bad_module_ir, null),
    );

    var bad_use_graph = ir.graph.CrateGraph.init(alloc);
    const use_id = try bad_use_graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = 99,
        .renamed_to = null,
        .attributes = &.{},
    });
    try bad_use_graph.addUse(.{
        .id = use_id,
        .kind = .{ .plain = 99 },
        // Non-glob uses still require a local binding.
        .target = 99,
        .local_name = "",
        .is_pub_export = true,
        .span = span,
    });
    const root_id = try bad_use_graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{use_id},
        .attributes = &.{},
    });
    try bad_use_graph.addCrate(.{
        .name = "bad_use",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
    const bad_use_bodies = [_]ir.bodies.BodyKind{.{ .none = {} }};
    const bad_use_ir = ir.RustIr{
        .crate_name = "bad_use",
        .edition = "2021",
        .graph = bad_use_graph,
        .types = &.{},
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &bad_use_bodies,
        },
    };
    try std.testing.expectError(
        error.MissingUseTarget,
        lower.lowerRustIr(alloc, &bad_use_ir, null),
    );
}

test "lower: malformed assertion markers are typed errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const exprs = [_]ir.exprs.Expr{
        strictExpr(0, .{ .unsupported = .{
            .reason = "assertion:not-a-node",
            .suggested_version = .v1,
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
        &exprs,
        &.{},
        &.{},
        &.{},
        error.MalformedAssertionMarker,
    );
}

test "lower: test assertion markers remain active test assertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const test_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "assertion_case",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{.{ .name = "test", .meta = "", .known = true }},
    });
    const root_id = try addRootModule(&graph, .{
        .crate_name = "active_assertion",
        .edition = 2021,
        .items = &.{test_id},
    });

    _ = try model.e(.{ .literal = .{ .boolean = true } });
    const marker = try model.e(.{ .unsupported = .{
        .reason = "assertion:0",
        .suggested_version = .v1,
    } });
    const assertion_statement = try model.stmt(.{ .expr = marker });
    const test_body = try model.e(.{ .block = .{
        .statements = &.{assertion_statement},
        .tail = null,
        .labelled = null,
    } });
    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[test_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = test_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "active_assertion",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &.{},
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);
    const file = package.files[0];
    const test_decl = try testDeclByName(file, "assertion_case");
    try std.testing.expectEqual(@as(usize, 1), test_decl.body.stmts.len);

    const assertion_expr = switch (test_decl.body.stmts[0]) {
        .expr_stmt => |expr| expr.*,
        else => return error.MissingTestAssertion,
    };
    const assertion_try = switch (assertion_expr) {
        .unary_op => |value| value,
        else => return error.MissingTestAssertionTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, assertion_try.op);
    const assertion_call = switch (assertion_try.operand.*) {
        .call => |value| value,
        else => return error.MissingTestAssertionCall,
    };
    const expect_access = switch (assertion_call.callee.*) {
        .field_access => |value| value,
        else => return error.UnexpectedTestAssertionCallee,
    };
    try std.testing.expectEqualStrings("expect", expect_access.field_name);
    const testing_access = switch (expect_access.target.*) {
        .field_access => |value| value,
        else => return error.UnexpectedTestAssertionNamespace,
    };
    try std.testing.expectEqualStrings("testing", testing_access.field_name);
    const std_name = switch (testing_access.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedTestAssertionRoot,
    };
    try std.testing.expectEqualStrings("std", std_name);
    try std.testing.expectEqual(@as(usize, 1), assertion_call.args.len);
    const assertion_condition = switch (assertion_call.args[0]) {
        .lit => |value| value,
        else => return error.UnexpectedTestAssertionCondition,
    };
    const assertion_value = switch (assertion_condition) {
        .bool_lit => |value| value,
        else => return error.UnexpectedTestAssertionLiteral,
    };
    try std.testing.expect(assertion_value);

    const emitted = try emit.emitFile(alloc, &file);
    try std.testing.expect(std.mem.indexOf(
        u8,
        emitted,
        "try std.testing.expect(true);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "std.debug.assert") == null);
}

test "lower: invalid match patterns and loop captures are typed errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const empty_arm = [_]ir.exprs.MatchArm{.{
        .patterns = &.{},
        .guard = null,
        .body = 1,
    }};
    const empty_match = [_]ir.exprs.Expr{
        strictExpr(0, litInt(1)),
        strictExpr(1, litInt(2)),
        strictExpr(2, .{ .match = .{
            .scrutinee = 0,
            .arms = &empty_arm,
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .i32 },
            .body = 2,
        } },
        &empty_match,
        &.{},
        &.{},
        &.{},
        error.MissingMatchPattern,
    );

    const bad_patterns = [_]ir.exprs.NodeId{99};
    const bad_arm = [_]ir.exprs.MatchArm{.{
        .patterns = &bad_patterns,
        .guard = null,
        .body = 1,
    }};
    const bad_match = [_]ir.exprs.Expr{
        strictExpr(0, litInt(1)),
        strictExpr(1, litInt(2)),
        strictExpr(2, .{ .match = .{
            .scrutinee = 0,
            .arms = &bad_arm,
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .i32 },
            .body = 2,
        } },
        &bad_match,
        &.{},
        &.{},
        &.{},
        error.MissingPatternNode,
    );

    const bad_while = [_]ir.exprs.Expr{
        strictExpr(0, .{ .literal = .{ .boolean = true } }),
        strictExpr(1, .{ .while_ = .{
            .cond = 0,
            .body = .{ .statements = &.{}, .tail = null, .labelled = null },
            .capture = 99,
        } }),
    };
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 1,
        } },
        &bad_while,
        &.{},
        &.{},
        &.{},
        error.InvalidLoopCapture,
    );
}

test "lower: address-of temporary Vec calls use scoped owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const producer_id = try addLowerEntity(&graph, .fn_, "collect_bytes", null);
    const consumer_id = try addLowerEntity(&graph, .fn_, "consume_bytes", null);
    const caller_id = try addLowerEntity(&graph, .fn_, "use_collected", null);
    const producer_bytes_id = try addLowerEntity(
        &graph,
        .field,
        "bytes",
        producer_id,
    );
    const producer_count_id = try addLowerEntity(
        &graph,
        .field,
        "count",
        producer_id,
    );
    const consumer_bytes_id = try addLowerEntity(
        &graph,
        .field,
        "bytes",
        consumer_id,
    );
    const caller_input_id = try addLowerEntity(
        &graph,
        .field,
        "input",
        caller_id,
    );
    const caller_count_id = try addLowerEntity(
        &graph,
        .field,
        "count",
        caller_id,
    );
    const root_id = try addRootModule(&graph, .{
        .crate_name = "owned_temporary",
        .edition = 2021,
        .items = &.{ producer_id, consumer_id, caller_id },
    });

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: ir.types.Type = .{ .slice = slice_info };
    const vector_args = [_]ir.types.Type{.{ .prim = .u8 }};
    const vector_type: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &vector_args,
    } };
    const types_store = [_]ir.types.Type{
        byte_slice_type,
        .{ .prim = .usize },
        vector_type,
    };

    const range_start = try model.e(litInt(0));
    model.exprs.items[range_start].ty = 1;
    const range_end = try model.e(.{ .path = .{
        .def = producer_count_id,
        .generic_args = &.{},
    } });
    model.exprs.items[range_end].ty = 1;
    const source = try model.e(.{ .range = .{
        .start = range_start,
        .end = range_end,
        .inclusive = false,
    } });
    const index_pattern = try model.pat(.{ .binding = .{
        .name = "index",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    model.pats.items[index_pattern].ty = 1;
    const borrowed_bytes = try model.e(.{ .path = .{
        .def = producer_bytes_id,
        .generic_args = &.{},
    } });
    model.exprs.items[borrowed_bytes].ty = 0;
    const adapters = [_]ir.exprs.IteratorAdapter{.{ .flat_map = .{
        .captures = &.{.{
            .name = "bytes",
            .mode = .by_ref,
            .ty = 0,
        }},
        .params = &.{index_pattern},
        .return_ty = 0,
        .body = .{
            .statements = &.{},
            .tail = borrowed_bytes,
            .labelled = null,
        },
        .trait = .@"fn",
    } }};
    const collection = try model.e(.{ .iterator_chain = .{
        .source = source,
        .adapters = &adapters,
        .terminal = .collect_vec,
    } });
    model.exprs.items[collection].ty = 2;
    const producer_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = collection,
        .labelled = null,
    } });
    model.exprs.items[producer_body].ty = 2;

    const consumer_bytes = try model.e(.{ .path = .{
        .def = consumer_bytes_id,
        .generic_args = &.{},
    } });
    model.exprs.items[consumer_bytes].ty = 0;
    const consumer_byte = try model.pat(.wildcard);
    const consumer_iteration_unit = try model.e(.unit);
    const consumer_iteration_statement = try model.stmt(.{ .expr = consumer_iteration_unit });
    const consumer_use = try model.e(.{ .for_ = .{
        .pattern = consumer_byte,
        .iterable = consumer_bytes,
        .body = .{
            .statements = &.{consumer_iteration_statement},
            .tail = null,
            .labelled = null,
        },
        .iter_kind = .{ .slice = {} },
    } });
    const consumer_use_statement = try model.stmt(.{ .expr = consumer_use });
    const consumer_unit = try model.e(.unit);
    const consumer_body = try model.e(.{ .block = .{
        .statements = &.{consumer_use_statement},
        .tail = consumer_unit,
        .labelled = null,
    } });
    const caller_input = try model.e(.{ .path = .{
        .def = caller_input_id,
        .generic_args = &.{},
    } });
    model.exprs.items[caller_input].ty = 0;
    const caller_count = try model.e(.{ .path = .{
        .def = caller_count_id,
        .generic_args = &.{},
    } });
    model.exprs.items[caller_count].ty = 1;
    const producer_arguments = [_]ir.exprs.NodeId{
        caller_input,
        caller_count,
    };
    const producer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = producer_id },
        .args = &producer_arguments,
    } });
    model.exprs.items[producer_call].ty = 2;
    const borrowed_temporary = try model.e(.{ .unary = .{
        .op = .{ .ref = .shared },
        .operand = producer_call,
    } });
    model.exprs.items[borrowed_temporary].ty = null;
    const consumer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = consumer_id },
        .args = &.{borrowed_temporary},
    } });
    const consumer_statement = try model.stmt(.{ .expr = consumer_call });
    const caller_return = try model.e(.{ .return_ = .{ .value = null } });
    const caller_body = try model.e(.{ .block = .{
        .statements = &.{consumer_statement},
        .tail = caller_return,
        .labelled = null,
    } });

    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[producer_id] = .{ .fn_ = .{
        .params = &.{
            .{
                .name = "bytes",
                .ty = byte_slice_type,
                .span = span,
            },
            .{
                .name = "count",
                .ty = .{ .prim = .usize },
                .span = span,
            },
        },
        .ret = vector_type,
        .body = producer_body,
        .is_allocating = true,
    } };
    model.bodies.items[consumer_id] = .{ .fn_ = .{
        .params = &.{.{
            .name = "bytes",
            .ty = byte_slice_type,
            .span = span,
        }},
        .ret = .{ .prim = .unit },
        .body = consumer_body,
        .is_allocating = false,
    } };
    model.bodies.items[caller_id] = .{ .fn_ = .{
        .params = &.{
            .{
                .name = "input",
                .ty = byte_slice_type,
                .span = span,
            },
            .{
                .name = "count",
                .ty = .{ .prim = .usize },
                .span = span,
            },
        },
        .ret = .{ .prim = .unit },
        .body = caller_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "owned_temporary",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);
    var caller_function: ?ast.FnDecl = null;
    for (package.files[0].decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, function.name, "use_collected")) {
            caller_function = function;
            break;
        }
    }
    const caller = caller_function orelse return error.MissingTemporaryCaller;
    const body = caller.body orelse return error.MissingTemporaryCallerBody;
    try std.testing.expectEqual(@as(usize, 1), body.stmts.len);
    const scoped = switch (body.stmts[0]) {
        .expr_stmt => |expr| switch (expr.*) {
            .block => |value| value,
            else => return error.MissingTemporaryValueBlock,
        },
        else => return error.MissingTemporaryValueBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), scoped.stmts.len);

    const owner = switch (scoped.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingTemporaryOwner,
    };
    try std.testing.expect(owner.is_mut);
    try std.testing.expectEqualStrings("owner", owner.name);
    const owner_type = switch (owner.ty orelse return error.MissingTemporaryOwnerType) {
        .generic => |value| value,
        else => return error.UnexpectedTemporaryOwnerType,
    };
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged", owner_type.name);
    try std.testing.expectEqual(@as(usize, 1), owner_type.params.len);
    const owner_element = switch (owner_type.params[0]) {
        .prim => |value| value,
        else => return error.UnexpectedTemporaryOwnerElement,
    };
    try std.testing.expectEqual(ast.Prim.u8, owner_element);
    const owner_init_try = switch (owner.init) {
        .unary_op => |value| value,
        else => return error.MissingTemporaryOwnerTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, owner_init_try.op);
    const owner_init_call = switch (owner_init_try.operand.*) {
        .call => |value| value,
        else => return error.MissingTemporaryOwnerCall,
    };
    const owner_init_callee = switch (owner_init_call.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedTemporaryOwnerCallee,
    };
    try std.testing.expectEqualStrings("collect_bytes", owner_init_callee);
    try std.testing.expectEqual(@as(usize, 3), owner_init_call.args.len);
    const owner_init_allocator = switch (owner_init_call.args[0]) {
        .ident => |name| name,
        else => return error.UnexpectedTemporaryOwnerAllocator,
    };
    try std.testing.expectEqualStrings("allocator", owner_init_allocator);

    const cleanup = switch (scoped.stmts[1]) {
        .defer_stmt => |value| value,
        else => return error.MissingTemporaryCleanup,
    };
    try std.testing.expect(!cleanup.is_errdefer);
    const cleanup_call = switch (cleanup.expr) {
        .call => |value| value,
        else => return error.UnexpectedTemporaryCleanup,
    };
    const cleanup_access = switch (cleanup_call.callee.*) {
        .field_access => |value| value,
        else => return error.UnexpectedTemporaryCleanupCallee,
    };
    try std.testing.expectEqualStrings("deinit", cleanup_access.field_name);
    const cleanup_owner = switch (cleanup_access.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedTemporaryCleanupTarget,
    };
    try std.testing.expectEqualStrings(owner.name, cleanup_owner);
    try std.testing.expectEqual(@as(usize, 1), cleanup_call.args.len);
    const cleanup_allocator = switch (cleanup_call.args[0]) {
        .ident => |name| name,
        else => return error.UnexpectedTemporaryCleanupAllocator,
    };
    try std.testing.expectEqualStrings("allocator", cleanup_allocator);

    const scoped_tail = scoped.expr orelse return error.MissingTemporaryConsumer;
    const lowered_consumer_call = switch (scoped_tail.*) {
        .call => |value| value,
        else => return error.UnexpectedTemporaryConsumer,
    };
    const consumer_callee = switch (lowered_consumer_call.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedTemporaryConsumerCallee,
    };
    try std.testing.expectEqualStrings("consume_bytes", consumer_callee);
    try std.testing.expectEqual(@as(usize, 1), lowered_consumer_call.args.len);
    const owner_items = switch (lowered_consumer_call.args[0]) {
        .field_access => |value| value,
        else => return error.MissingTemporaryItems,
    };
    try std.testing.expectEqualStrings("items", owner_items.field_name);
    const owner_items_owner = switch (owner_items.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedTemporaryItemsOwner,
    };
    try std.testing.expectEqualStrings(owner.name, owner_items_owner);

    const emitted = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(
        u8,
        emitted,
        "var owner: std.ArrayListUnmanaged(u8) = try collect_bytes(allocator, input, count);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        emitted,
        "defer owner.deinit(allocator);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "consume_bytes(owner.items);") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "&try collect_bytes") == null);
}

test "lower: assertion conditions hoist borrowed Vec consumer arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const producer_id = try addLowerEntity(&graph, .fn_, "produce_bytes", null);
    const consumer_id = try addLowerEntity(&graph, .fn_, "check_bytes", null);
    const caller_id = try addLowerEntity(&graph, .fn_, "assert_collected", null);
    const root_id = try addRootModule(&graph, .{
        .crate_name = "owned_assertion",
        .edition = 2021,
        .items = &.{ producer_id, consumer_id, caller_id },
    });

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: ir.types.Type = .{ .slice = slice_info };
    const vector_args = [_]ir.types.Type{.{ .prim = .u8 }};
    const vector_type: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &vector_args,
    } };
    const types_store = [_]ir.types.Type{
        vector_type,
        .{ .prim = .bool },
    };

    const producer_unit = try model.e(.unit);
    const producer_statement = try model.stmt(.{ .expr = producer_unit });
    const producer_body = try model.e(.{ .block = .{
        .statements = &.{producer_statement},
        .tail = null,
        .labelled = null,
    } });
    const consumer_true = try model.e(.{ .literal = .{ .boolean = true } });
    model.exprs.items[consumer_true].ty = 1;
    const consumer_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = consumer_true,
        .labelled = null,
    } });

    const producer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = producer_id },
        .args = &.{},
    } });
    model.exprs.items[producer_call].ty = 0;
    const borrowed_temporary = try model.e(.{ .unary = .{
        .op = .{ .ref = .shared },
        .operand = producer_call,
    } });
    const consumer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = consumer_id },
        .args = &.{borrowed_temporary},
    } });
    model.exprs.items[consumer_call].ty = 1;
    const assertion_expected = try model.e(.{ .literal = .{ .boolean = true } });
    model.exprs.items[assertion_expected].ty = 1;
    const assertion_condition = try model.e(.{ .binary = .{
        .op = .eq,
        .overflow = .checked,
        .lhs = consumer_call,
        .rhs = assertion_expected,
    } });
    model.exprs.items[assertion_condition].ty = 1;
    const assertion_reason = try std.fmt.allocPrint(
        alloc,
        "assertion:{d}",
        .{assertion_condition},
    );
    const assertion_marker = try model.e(.{ .unsupported = .{
        .reason = assertion_reason,
        .suggested_version = .v1,
    } });
    const assertion_statement = try model.stmt(.{ .expr = assertion_marker });
    const caller_return = try model.e(.{ .return_ = .{ .value = null } });
    const caller_body = try model.e(.{ .block = .{
        .statements = &.{assertion_statement},
        .tail = caller_return,
        .labelled = null,
    } });

    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[producer_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = vector_type,
        .body = producer_body,
        .is_allocating = true,
    } };
    model.bodies.items[consumer_id] = .{ .fn_ = .{
        .params = &.{.{
            .name = "bytes",
            .ty = byte_slice_type,
            .span = span,
        }},
        .ret = .{ .prim = .bool },
        .body = consumer_body,
        .is_allocating = false,
    } };
    model.bodies.items[caller_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = caller_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "owned_assertion",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);

    var caller_function: ?ast.FnDecl = null;
    for (package.files[0].decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, function.name, "assert_collected")) {
            caller_function = function;
            break;
        }
    }
    const caller = caller_function orelse return error.MissingAssertionCaller;
    const body = caller.body orelse return error.MissingAssertionCallerBody;
    try std.testing.expectEqual(@as(usize, 1), body.stmts.len);
    const scoped = switch (body.stmts[0]) {
        .expr_stmt => |expr| switch (expr.*) {
            .block => |value| value,
            else => return error.MissingAssertionValueBlock,
        },
        else => return error.MissingAssertionValueBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), scoped.stmts.len);

    const owner = switch (scoped.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingAssertionOwner,
    };
    try std.testing.expect(owner.is_mut);
    const cleanup = switch (scoped.stmts[1]) {
        .defer_stmt => |value| value,
        else => return error.MissingAssertionCleanup,
    };
    try std.testing.expect(!cleanup.is_errdefer);
    const assertion = scoped.expr orelse return error.MissingAssertionStatement;
    const assertion_call = switch (assertion.*) {
        .call => |value| value,
        else => return error.UnexpectedAssertionExpression,
    };
    const lowered_assertion_condition = switch (assertion_call.args[0]) {
        .bin_op => |value| value,
        else => return error.MissingAssertionConditionEquality,
    };
    try std.testing.expectEqual(ast.BinOpKind.equal, lowered_assertion_condition.op);
    const assertion_arg = switch (lowered_assertion_condition.lhs.*) {
        .call => |value| value,
        else => return error.MissingAssertionConditionCall,
    };
    const condition_callee = switch (assertion_arg.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedAssertionConditionCallee,
    };
    try std.testing.expectEqualStrings("check_bytes", condition_callee);
    const condition_items = switch (assertion_arg.args[0]) {
        .field_access => |value| value,
        else => return error.MissingAssertionTemporaryItems,
    };
    try std.testing.expectEqualStrings("items", condition_items.field_name);
    const items_owner = switch (condition_items.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedAssertionItemsOwner,
    };
    try std.testing.expectEqualStrings(owner.name, items_owner);
    const expected_condition = switch (lowered_assertion_condition.rhs.*) {
        .lit => |value| value,
        else => return error.MissingAssertionExpectedValue,
    };
    const expected_value = switch (expected_condition) {
        .bool_lit => |value| value,
        else => return error.UnexpectedAssertionExpectedValue,
    };
    try std.testing.expect(expected_value);

    const emitted = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "&try produce_bytes") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        emitted,
        "check_bytes(owner.items)",
    ) != null);
}

test "lower: direct caller propagates allocating collector ABI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const collector_id = try addLowerEntity(
        &graph,
        .fn_,
        "collect_bytes",
        null,
    );
    const caller_id = try addLowerEntity(
        &graph,
        .fn_,
        "forward_bytes",
        null,
    );
    const collector_bytes_id = try addLowerEntity(
        &graph,
        .field,
        "bytes",
        collector_id,
    );
    const collector_count_id = try addLowerEntity(
        &graph,
        .field,
        "count",
        collector_id,
    );
    const caller_input_id = try addLowerEntity(
        &graph,
        .field,
        "input",
        caller_id,
    );
    const caller_count_id = try addLowerEntity(
        &graph,
        .field,
        "count",
        caller_id,
    );
    const root_id = try addRootModule(&graph, .{
        .crate_name = "effectful_calls",
        .edition = 2021,
        .items = &.{ collector_id, caller_id },
    });

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: ir.types.Type = .{ .slice = slice_info };
    const vector_args = [_]ir.types.Type{.{ .prim = .u8 }};
    const vector_type: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &vector_args,
    } };
    const types_store = [_]ir.types.Type{
        byte_slice_type,
        .{ .prim = .usize },
        vector_type,
    };

    const range_start = try model.e(litInt(0));
    model.exprs.items[range_start].ty = 1;
    const range_end = try model.e(.{ .path = .{
        .def = collector_count_id,
        .generic_args = &.{},
    } });
    model.exprs.items[range_end].ty = 1;
    const source = try model.e(.{ .range = .{
        .start = range_start,
        .end = range_end,
        .inclusive = false,
    } });

    const index_pattern = try model.pat(.{ .binding = .{
        .name = "index",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    model.pats.items[index_pattern].ty = 1;
    const borrowed_bytes = try model.e(.{ .path = .{
        .def = collector_bytes_id,
        .generic_args = &.{},
    } });
    model.exprs.items[borrowed_bytes].ty = 0;
    const adapters = [_]ir.exprs.IteratorAdapter{.{ .flat_map = .{
        .captures = &.{.{
            .name = "bytes",
            .mode = .by_ref,
            .ty = 0,
        }},
        .params = &.{index_pattern},
        .return_ty = 0,
        .body = .{
            .statements = &.{},
            .tail = borrowed_bytes,
            .labelled = null,
        },
        .trait = .@"fn",
    } }};
    const collection = try model.e(.{ .iterator_chain = .{
        .source = source,
        .adapters = &adapters,
        .terminal = .collect_vec,
    } });
    model.exprs.items[collection].ty = 2;
    const collector_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = collection,
        .labelled = null,
    } });
    model.exprs.items[collector_body].ty = 2;

    const caller_input = try model.e(.{ .path = .{
        .def = caller_input_id,
        .generic_args = &.{},
    } });
    model.exprs.items[caller_input].ty = 0;
    const caller_count = try model.e(.{ .path = .{
        .def = caller_count_id,
        .generic_args = &.{},
    } });
    model.exprs.items[caller_count].ty = 1;
    const caller_arguments = [_]ir.exprs.NodeId{
        caller_input,
        caller_count,
    };
    const collector_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = collector_id },
        .args = &caller_arguments,
    } });
    model.exprs.items[collector_call].ty = 2;
    const caller_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = collector_call,
        .labelled = null,
    } });
    model.exprs.items[caller_body].ty = 2;

    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[collector_id] = .{ .fn_ = .{
        .params = &.{
            .{
                .name = "bytes",
                .ty = byte_slice_type,
                .span = span,
            },
            .{
                .name = "count",
                .ty = .{ .prim = .usize },
                .span = span,
            },
        },
        .ret = vector_type,
        .body = collector_body,
        .is_allocating = true,
    } };
    model.bodies.items[caller_id] = .{
        .fn_ = .{
            .params = &.{
                .{
                    .name = "input",
                    .ty = byte_slice_type,
                    .span = span,
                },
                .{
                    .name = "count",
                    .ty = .{ .prim = .usize },
                    .span = span,
                },
            },
            .ret = vector_type,
            .body = caller_body,
            // The caller is not marked directly; its collector dependency must propagate the effect.
            .is_allocating = false,
        },
    };

    const rust_ir = ir.RustIr{
        .crate_name = "effectful_calls",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);
    try std.testing.expectEqual(@as(usize, 2), package.files[0].decls.len);
    var std_imports: usize = 0;
    for (package.files[0].imports) |import| {
        if (std.mem.eql(u8, import.local_name, "std") and
            std.mem.eql(u8, import.module_or_path, "std"))
        {
            std_imports += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), std_imports);

    var collector_function: ?ast.FnDecl = null;
    var caller_function: ?ast.FnDecl = null;
    for (package.files[0].decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, function.name, "collect_bytes")) {
            collector_function = function;
        } else if (std.mem.eql(u8, function.name, "forward_bytes")) {
            caller_function = function;
        }
    }

    const collector = collector_function orelse return error.MissingCollectorFunction;
    try std.testing.expectEqual(@as(usize, 3), collector.params.len);
    try std.testing.expectEqualStrings("allocator", collector.params[0].name);
    try std.testing.expectEqualStrings("bytes", collector.params[1].name);
    try std.testing.expectEqualStrings("count", collector.params[2].name);
    _ = switch (collector.ret_type) {
        .err_union => |value| value,
        else => return error.UnexpectedCollectorReturnType,
    };

    const caller = caller_function orelse return error.MissingCallerFunction;
    try std.testing.expectEqual(@as(usize, 3), caller.params.len);
    try std.testing.expectEqualStrings("allocator", caller.params[0].name);
    const caller_allocator_type = switch (caller.params[0].ty) {
        .named => |name| name,
        else => return error.UnexpectedCallerAllocatorType,
    };
    try std.testing.expectEqualStrings(
        "std.mem.Allocator",
        caller_allocator_type,
    );
    try std.testing.expectEqualStrings("input", caller.params[1].name);
    try std.testing.expectEqualStrings("count", caller.params[2].name);

    const caller_return = switch (caller.ret_type) {
        .err_union => |value| value,
        else => return error.UnexpectedCallerReturnType,
    };
    try std.testing.expect(caller_return.err_set == null);
    const caller_payload = switch (caller_return.payload.*) {
        .generic => |value| value,
        else => return error.UnexpectedCallerReturnPayload,
    };
    try std.testing.expectEqualStrings(
        "std.ArrayListUnmanaged",
        caller_payload.name,
    );
    try std.testing.expectEqual(@as(usize, 1), caller_payload.params.len);
    const caller_element = switch (caller_payload.params[0]) {
        .prim => |value| value,
        else => return error.UnexpectedCallerReturnElement,
    };
    try std.testing.expectEqual(ast.Prim.u8, caller_element);

    const body = caller.body orelse return error.MissingCallerBody;
    try std.testing.expectEqual(@as(usize, 0), body.stmts.len);
    const tail = body.expr orelse return error.MissingCallerTail;
    const propagated_try = switch (tail.*) {
        .unary_op => |value| value,
        else => return error.MissingEffectfulCallTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, propagated_try.op);
    const call = switch (propagated_try.operand.*) {
        .call => |value| value,
        else => return error.UnexpectedEffectfulCallOperand,
    };
    const callee = switch (call.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedEffectfulCallee,
    };
    try std.testing.expectEqualStrings("collect_bytes", callee);
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    const expected_arguments = [_][]const u8{
        "allocator",
        "input",
        "count",
    };
    for (call.args, expected_arguments) |argument, expected_name| {
        const argument_name = switch (argument) {
            .ident => |name| name,
            else => return error.UnexpectedEffectfulCallArgument,
        };
        try std.testing.expectEqualStrings(expected_name, argument_name);
    }
}

fn lowerNestedAllocatorFixture(alloc: std.mem.Allocator) !ast.File {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const test_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "test_nested_wrapper",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{
            .{ .name = "test", .meta = "", .known = true },
        },
    });
    const wrapper_id = try addLowerEntity(&graph, .fn_, "wrapper", null);
    const helper_id = try addLowerEntity(&graph, .fn_, "allocating_helper", null);
    const unrelated_id = try addLowerEntity(&graph, .fn_, "unrelated", null);
    const root_id = try addRootModule(&graph, .{
        .crate_name = "nested_allocator",
        .edition = 2021,
        .items = &.{ test_id, wrapper_id, helper_id, unrelated_id },
    });

    const types_store = [_]ir.types.Type{.{ .prim = .unit }};

    const helper_return = try model.e(.{ .return_ = .{ .value = null } });
    const helper_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = helper_return,
        .labelled = null,
    } });
    const unrelated_return = try model.e(.{ .return_ = .{ .value = null } });
    model.exprs.items[helper_return].ty = 0;
    model.exprs.items[unrelated_return].ty = 0;
    const helper_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = helper_id },
        .args = &.{},
    } });
    model.exprs.items[helper_call].ty = 0;
    const wrapper_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = helper_call,
        .labelled = null,
    } });
    const wrapper_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = wrapper_id },
        .args = &.{},
    } });
    model.exprs.items[wrapper_call].ty = 0;
    const wrapper_statement = try model.stmt(.{ .expr = wrapper_call });
    const test_statements = [_]ir.exprs.NodeId{wrapper_statement};
    const test_body = try model.e(.{ .block = .{
        .statements = &test_statements,
        .tail = null,
        .labelled = null,
    } });
    const unrelated_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unrelated_return,
        .labelled = null,
    } });

    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[test_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = test_body,
        .is_allocating = false,
    } };
    model.bodies.items[wrapper_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = wrapper_body,
        .is_allocating = false,
    } };
    model.bodies.items[helper_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = helper_body,
        .is_allocating = true,
    } };
    model.bodies.items[unrelated_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = unrelated_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "nested_allocator",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    return sourceFidelityRootFile(package);
}

test "lower: nested wrapper effects stabilize test allocator ABI before declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try lowerNestedAllocatorFixture(alloc);
    const test_decl = try testDeclByName(file, "test_nested_wrapper");
    try std.testing.expectEqual(@as(usize, 2), test_decl.body.stmts.len);

    const allocator_stmt = switch (test_decl.body.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingTestAllocatorBinding,
    };
    try std.testing.expectEqualStrings("allocator", allocator_stmt.name);
    const call_stmt = switch (test_decl.body.stmts[1]) {
        .expr_stmt => |value| value.*,
        else => return error.MissingNestedWrapperCall,
    };
    const call_try = switch (call_stmt) {
        .unary_op => |value| value,
        else => return error.MissingNestedWrapperTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, call_try.op);
    const wrapper_call = switch (call_try.operand.*) {
        .call => |value| value,
        else => return error.MissingNestedWrapperCall,
    };
    try std.testing.expectEqual(@as(usize, 1), wrapper_call.args.len);
    const wrapper_allocator = switch (wrapper_call.args[0]) {
        .ident => |name| name,
        else => return error.UnexpectedNestedWrapperAllocator,
    };
    try std.testing.expectEqualStrings("allocator", wrapper_allocator);

    var wrapper_decl: ?ast.FnDecl = null;
    var helper_decl: ?ast.FnDecl = null;
    var unrelated_decl: ?ast.FnDecl = null;
    for (file.decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, function.name, "wrapper")) {
            wrapper_decl = function;
        } else if (std.mem.eql(u8, function.name, "allocating_helper")) {
            helper_decl = function;
        } else if (std.mem.eql(u8, function.name, "unrelated")) {
            unrelated_decl = function;
        }
    }

    const wrapper = wrapper_decl orelse return error.MissingNestedWrapper;
    try std.testing.expectEqual(@as(usize, 1), wrapper.params.len);
    try std.testing.expectEqualStrings("allocator", wrapper.params[0].name);
    _ = switch (wrapper.ret_type) {
        .err_union => |value| value,
        else => return error.NestedWrapperMissingErrorUnion,
    };
    const helper = helper_decl orelse return error.MissingAllocatingHelper;
    try std.testing.expectEqual(@as(usize, 1), helper.params.len);
    _ = switch (helper.ret_type) {
        .err_union => |value| value,
        else => return error.HelperMissingErrorUnion,
    };
    const unrelated = unrelated_decl orelse return error.MissingUnrelatedFunction;
    try std.testing.expectEqual(@as(usize, 0), unrelated.params.len);
    switch (unrelated.ret_type) {
        .void_type => {},
        .prim => |primitive| try std.testing.expectEqual(ast.Prim.void_type, primitive),
        else => return error.UnrelatedFunctionChanged,
    }
    const emitted = try emit.emitFile(alloc, &file);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "try wrapper(allocator);") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "try allocating_helper(allocator);") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "fn unrelated() void") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "fn unrelated(allocator") == null);
}
test "lower: nested owned temporary blocks isolate preludes and names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const inner_producer_id = try addLowerEntity(&graph, .fn_, "produce_inner", null);
    const outer_producer_id = try addLowerEntity(&graph, .fn_, "produce_outer", null);
    const inner_consumer_id = try addLowerEntity(&graph, .fn_, "consume_inner", null);
    const outer_consumer_id = try addLowerEntity(&graph, .fn_, "consume_outer", null);
    const caller_id = try addLowerEntity(&graph, .fn_, "nested_owner_caller", null);
    const root_id = try addRootModule(&graph, .{
        .crate_name = "nested_owned_temporary",
        .edition = 2021,
        .items = &.{
            inner_producer_id,
            outer_producer_id,
            inner_consumer_id,
            outer_consumer_id,
            caller_id,
        },
    });

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: ir.types.Type = .{ .slice = slice_info };
    const vector_args = [_]ir.types.Type{.{ .prim = .u8 }};
    const vector_type: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &vector_args,
    } };
    const types_store = [_]ir.types.Type{
        byte_slice_type,
        vector_type,
        .{ .prim = .unit },
    };

    const inner_return = try model.e(.{ .return_ = .{ .value = null } });
    const inner_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = inner_return,
        .labelled = null,
    } });
    const outer_return = try model.e(.{ .return_ = .{ .value = null } });
    const outer_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = outer_return,
        .labelled = null,
    } });
    const inner_consumer_return = try model.e(.{ .return_ = .{ .value = null } });
    const inner_consumer_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = inner_consumer_return,
        .labelled = null,
    } });
    const outer_consumer_return = try model.e(.{ .return_ = .{ .value = null } });
    const outer_consumer_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = outer_consumer_return,
        .labelled = null,
    } });

    const inner_producer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = inner_producer_id },
        .args = &.{},
    } });
    model.exprs.items[inner_producer_call].ty = 1;
    const inner_borrow = try model.e(.{ .unary = .{
        .op = .{ .ref = .shared },
        .operand = inner_producer_call,
    } });
    const inner_consumer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = inner_consumer_id },
        .args = &.{inner_borrow},
    } });
    model.exprs.items[inner_consumer_call].ty = 2;
    const inner_statement = try model.stmt(.{ .expr = inner_consumer_call });
    const nested_prefix_expr = try model.e(.unit);
    const nested_prefix_statement = try model.stmt(.{ .expr = nested_prefix_expr });
    const nested_block = try model.e(.{ .block = .{
        .statements = &.{ nested_prefix_statement, inner_statement },
        .tail = null,
        .labelled = null,
    } });
    model.exprs.items[nested_block].ty = 2;

    const outer_producer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = outer_producer_id },
        .args = &.{},
    } });
    model.exprs.items[outer_producer_call].ty = 1;
    const outer_borrow = try model.e(.{ .unary = .{
        .op = .{ .ref = .shared },
        .operand = outer_producer_call,
    } });
    const outer_consumer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = outer_consumer_id },
        .args = &.{ outer_borrow, nested_block },
    } });
    model.exprs.items[outer_consumer_call].ty = 2;
    const outer_statement = try model.stmt(.{ .expr = outer_consumer_call });
    const caller_return = try model.e(.{ .return_ = .{ .value = null } });
    const caller_body = try model.e(.{ .block = .{
        .statements = &.{outer_statement},
        .tail = caller_return,
        .labelled = null,
    } });

    while (model.bodies.items.len <= root_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[inner_producer_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = vector_type,
        .body = inner_body,
        .is_allocating = true,
    } };
    model.bodies.items[outer_producer_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = vector_type,
        .body = outer_body,
        .is_allocating = true,
    } };
    model.bodies.items[inner_consumer_id] = .{ .fn_ = .{
        .params = &.{.{
            .name = "bytes",
            .ty = byte_slice_type,
            .span = span,
        }},
        .ret = .{ .prim = .unit },
        .body = inner_consumer_body,
        .is_allocating = false,
    } };
    model.bodies.items[outer_consumer_id] = .{ .fn_ = .{
        .params = &.{
            .{
                .name = "bytes",
                .ty = byte_slice_type,
                .span = span,
            },
            .{
                .name = "nested",
                .ty = .{ .prim = .unit },
                .span = span,
            },
        },
        .ret = .{ .prim = .unit },
        .body = outer_consumer_body,
        .is_allocating = false,
    } };
    model.bodies.items[caller_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = caller_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "nested_owned_temporary",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const file = package.files[0];
    var caller_function: ?ast.FnDecl = null;
    for (file.decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, function.name, "nested_owner_caller")) {
            caller_function = function;
            break;
        }
    }
    const caller = caller_function orelse return error.MissingNestedOwnerCaller;
    const body = caller.body orelse return error.MissingNestedOwnerBody;
    try std.testing.expectEqual(@as(usize, 1), body.stmts.len);
    const scoped = switch (body.stmts[0]) {
        .expr_stmt => |expr| switch (expr.*) {
            .block => |value| value,
            else => return error.MissingNestedOwnerValueBlock,
        },
        else => return error.MissingNestedOwnerValueBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), scoped.stmts.len);
    const outer_owner = switch (scoped.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingOuterOwner,
    };
    try std.testing.expectEqualStrings("owner", outer_owner.name);
    const outer_tail = scoped.expr orelse return error.MissingOuterCall;
    const outer_call = switch (outer_tail.*) {
        .call => |value| value,
        else => return error.UnexpectedOuterCall,
    };
    const outer_items = switch (outer_call.args[0]) {
        .field_access => |value| value,
        else => return error.MissingOuterItems,
    };
    try std.testing.expectEqualStrings("items", outer_items.field_name);
    const outer_items_owner = switch (outer_items.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedOuterItemsOwner,
    };
    try std.testing.expectEqualStrings(outer_owner.name, outer_items_owner);

    const nested = switch (outer_call.args[1]) {
        .block => |value| value,
        else => return error.MissingNestedOwnerBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), nested.stmts.len);
    const inner_owner = switch (nested.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingInnerOwner,
    };
    try std.testing.expectEqualStrings("owner_1", inner_owner.name);
    try std.testing.expect(!std.mem.eql(u8, outer_owner.name, inner_owner.name));
    const inner_tail = nested.expr orelse return error.MissingInnerCall;
    const inner_call = switch (inner_tail.*) {
        .call => |value| value,
        else => return error.UnexpectedInnerCall,
    };
    const inner_items = switch (inner_call.args[0]) {
        .field_access => |value| value,
        else => return error.MissingInnerItems,
    };
    try std.testing.expectEqualStrings("items", inner_items.field_name);
    const inner_items_owner = switch (inner_items.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedInnerItemsOwner,
    };
    try std.testing.expectEqualStrings(inner_owner.name, inner_items_owner);
}

test "lower: lazy owner import avoids temporary owner collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try graph.symbol_table.add(.{
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
    const owner_module_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = "owner",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const remote_id = try addLowerEntity(&graph, .fn_, "remote_unit", owner_module_id);
    const local_producer_id = try addLowerEntity(&graph, .fn_, "produce_local", root_id);
    const consumer_id = try addLowerEntity(&graph, .fn_, "consume_outer", root_id);
    const caller_id = try addLowerEntity(&graph, .fn_, "lazy_owner_caller", root_id);

    const root_items = try alloc.dupe(
        ir.spine.EntityId,
        &.{ local_producer_id, consumer_id, caller_id },
    );
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = root_items,
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "owner",
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{remote_id},
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "lazy_owner_import",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice_type: ir.types.Type = .{ .slice = slice_info };
    const vector_args = [_]ir.types.Type{.{ .prim = .u8 }};
    const vector_type: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &vector_args,
    } };
    const types_store = [_]ir.types.Type{
        byte_slice_type,
        vector_type,
        .{ .prim = .unit },
    };

    const remote_unit = try model.e(.unit);
    const remote_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = remote_unit,
        .labelled = null,
    } });
    const local_return = try model.e(.{ .return_ = .{ .value = null } });
    const local_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = local_return,
        .labelled = null,
    } });
    const consumer_return = try model.e(.{ .return_ = .{ .value = null } });
    const consumer_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = consumer_return,
        .labelled = null,
    } });

    const local_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = local_producer_id },
        .args = &.{},
    } });
    model.exprs.items[local_call].ty = 1;
    const local_borrow = try model.e(.{ .unary = .{
        .op = .{ .ref = .shared },
        .operand = local_call,
    } });
    const remote_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = remote_id },
        .args = &.{},
    } });
    model.exprs.items[remote_call].ty = 2;
    const consumer_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = consumer_id },
        .args = &.{ local_borrow, remote_call },
    } });
    model.exprs.items[consumer_call].ty = 2;
    const caller_statement = try model.stmt(.{ .expr = consumer_call });
    const caller_body = try model.e(.{ .block = .{
        .statements = &.{caller_statement},
        .tail = null,
        .labelled = null,
    } });

    while (model.bodies.items.len <= caller_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[remote_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = remote_body,
        .is_allocating = false,
    } };
    model.bodies.items[local_producer_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = vector_type,
        .body = local_body,
        .is_allocating = true,
    } };
    model.bodies.items[consumer_id] = .{ .fn_ = .{
        .params = &.{
            .{
                .name = "bytes",
                .ty = byte_slice_type,
                .span = span,
            },
            .{
                .name = "remote",
                .ty = .{ .prim = .unit },
                .span = span,
            },
        },
        .ret = .{ .prim = .unit },
        .body = consumer_body,
        .is_allocating = false,
    } };
    model.bodies.items[caller_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = caller_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "lazy_owner_import",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    var root_file: ?ast.File = null;
    for (package.files) |file| {
        if (std.mem.eql(u8, file.path, "src/root.zig")) {
            root_file = file;
            break;
        }
    }
    const file = root_file orelse return error.MissingLazyOwnerRoot;

    var owner_import: ?ast.Import = null;
    for (file.imports) |import| {
        if (std.mem.eql(u8, import.module_or_path, "./owner.zig")) {
            owner_import = import;
            break;
        }
    }
    const import = owner_import orelse return error.MissingLazyOwnerImport;
    try std.testing.expectEqualStrings("owner_1", import.local_name);

    var caller_function: ?ast.FnDecl = null;
    for (file.decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, function.name, "lazy_owner_caller")) {
            caller_function = function;
            break;
        }
    }
    const caller = caller_function orelse return error.MissingLazyOwnerCaller;
    const body = caller.body orelse return error.MissingLazyOwnerBody;
    try std.testing.expectEqual(@as(usize, 1), body.stmts.len);
    const scoped = switch (body.stmts[0]) {
        .expr_stmt => |expr| switch (expr.*) {
            .block => |value| value,
            else => return error.MissingLazyValueBlock,
        },
        else => return error.MissingLazyValueBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), scoped.stmts.len);
    const owner = switch (scoped.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.MissingLazyTemporaryOwner,
    };
    try std.testing.expectEqualStrings("owner", owner.name);

    const scoped_tail = scoped.expr orelse return error.MissingLazyConsumerCall;
    const consumer = switch (scoped_tail.*) {
        .call => |value| value,
        else => return error.UnexpectedLazyConsumerCall,
    };
    try std.testing.expectEqual(@as(usize, 2), consumer.args.len);
    const local_items = switch (consumer.args[0]) {
        .field_access => |value| value,
        else => return error.MissingLazyLocalItems,
    };
    const local_owner = switch (local_items.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedLazyLocalOwner,
    };
    try std.testing.expectEqualStrings(owner.name, local_owner);
    const lowered_remote_call = switch (consumer.args[1]) {
        .call => |value| value,
        else => return error.MissingLazyRemoteCall,
    };
    const remote = switch (lowered_remote_call.callee.*) {
        .field_access => |value| value,
        else => return error.UnexpectedLazyRemoteCallee,
    };
    const remote_module = switch (remote.target.*) {
        .ident => |name| name,
        else => return error.UnexpectedLazyRemoteModule,
    };
    try std.testing.expectEqualStrings(import.local_name, remote_module);
    try std.testing.expectEqualStrings("remote_unit", remote.field_name);
}

test "serialize: pointer cast source survives roundtrip and emits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source_element: ast.Type = .{ .prim = .u8 };
    const target_element: ast.Type = .{ .prim = .i8 };
    const source_type: ast.Type = .{ .ptr = .{
        .elem = &source_element,
        .is_const = true,
        .size = .many,
    } };
    const target_type: ast.Type = .{ .ptr = .{
        .elem = &target_element,
        .is_const = true,
        .size = .many,
    } };
    const input: ast.Expr = .{ .ident = "input" };
    const pointer_cast: ast.Expr = .{ .builtin = .{
        .name = "ptrCast",
        .args = &.{input},
    } };
    const package: ast.Package = .{
        .name = "pointer_cast_roundtrip",
        .fingerprint = 1,
        .files = &.{.{
            .path = "src/root.zig",
            .decls = &.{.{ .const_decl = .{
                .name = "casted",
                .ty = target_type,
                .init = .{ .cast = .{
                    .target = target_type,
                    .operand = &pointer_cast,
                    .source = source_type,
                } },
            } }},
        }},
    };

    const encoded = try serialize.encode(allocator, &package);
    const decoded = try serialize.decode(allocator, encoded);
    const decoded_cast = switch (decoded.files[0].decls[0].const_decl.init) {
        .cast => |cast| cast,
        else => return error.MissingDecodedCast,
    };
    try std.testing.expect(decoded_cast.source != null);

    const source = try emit.emitFile(allocator, &decoded.files[0]);
    try std.testing.expect(
        std.mem.indexOf(u8, source, "@as([*]const i8, @ptrCast(input))") != null,
    );
}

test "lower: scalar as narrowing uses Rust truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "narrow", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "scalar_casts",
        .edition = 2021,
        .items = &.{function_id},
    });

    const literal = ir.exprs.Expr{
        .id = 0,
        .span = span,
        .ty = 1,
        .kind = litInt(257),
    };
    const cast = ir.exprs.Expr{
        .id = 1,
        .span = span,
        .ty = 0,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 0,
            .source_type = .{ .prim = .u16 },
            .target = 0,
        } },
    };
    const body = ir.exprs.Expr{
        .id = 2,
        .span = span,
        .ty = 0,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } },
    };
    const function_body = ir.bodies.BodyKind{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u8 },
        .body = 2,
        .is_allocating = false,
    } };
    const body_table = [_]ir.bodies.BodyKind{function_body};
    const types = [_]ir.types.Type{
        .{ .prim = .u8 },
        .{ .prim = .u16 },
    };
    const expressions = [_]ir.exprs.Expr{ literal, cast, body };
    const rust_ir = ir.RustIr{
        .crate_name = "scalar_casts",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = &expressions,
            .stmts = &.{},
            .pats = &.{},
            .types = &types,
            .bodies = &body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "@truncate(257)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "narrow") != null);
}

test "lower: associated allocating calls place allocator after receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const struct_id = try addLowerEntity(&graph, .struct_, "Builder", root_id);
    const impl_id = try addLowerEntity(&graph, .impl_, "Builder", struct_id);
    const method_id = try addLowerEntity(&graph, .fn_, "build", impl_id);
    const caller_id = try addLowerEntity(&graph, .fn_, "call_build", root_id);
    const receiver_id = try addLowerEntity(&graph, .field, "self", caller_id);

    const self_segments = [_]ir.types.PathSegment{
        .{ .name = "Builder", .id = struct_id },
    };
    const self_type: ir.types.Type = .{ .path = .{ .segments = &self_segments } };
    const types = [_]ir.types.Type{ self_type, .{ .prim = .u8 } };

    var model = Model.init(alloc);
    const method_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = null,
        .labelled = null,
    } });
    const receiver = try model.e(.{ .path = .{
        .def = receiver_id,
        .generic_args = &.{},
    } });
    model.exprs.items[receiver].ty = 0;
    const argument = try model.e(litInt(1));
    model.exprs.items[argument].ty = 1;
    const call_args = [_]ir.exprs.NodeId{ receiver, argument };
    const associated_call = try model.e(.{ .call = .{
        .call_kind = .{ .associated = method_id },
        .args = &call_args,
    } });
    model.exprs.items[associated_call].ty = 1;
    const caller_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = associated_call,
        .labelled = null,
    } });

    const methods = [_]ir.bodies.StructMethod{.{
        .name = "build",
        .params = &.{},
        .ret = .{ .prim = .u8 },
        .body = method_body,
        .receiver = .ref_,
        .is_allocating = true,
    }};
    const body_table = [_]ir.bodies.BodyKind{
        .none,
        .{ .struct_ = .{ .methods = &methods } },
        .none,
        .none,
        .{ .fn_ = .{
            .params = &.{.{ .name = "self", .ty = self_type, .span = span }},
            .ret = .{ .prim = .u8 },
            .body = caller_body,
        } },
        .none,
    };
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ struct_id, caller_id },
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "associated_allocator",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "associated_allocator",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &body_table,
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    var caller: ?ast.FnDecl = null;
    for (package.files[0].decls) |decl| {
        if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, "call_build")) {
            caller = decl.fn_decl;
            break;
        }
    }
    const caller_decl = caller orelse return error.MissingAssociatedCaller;
    const caller_block = caller_decl.body orelse return error.MissingAssociatedCallerBody;
    const tail = caller_block.expr orelse return error.MissingAssociatedCall;
    const call = switch (tail.*) {
        .unary_op => |value| switch (value.operand.*) {
            .call => |result| result,
            else => return error.MissingAssociatedCall,
        },
        .call => |result| result,
        else => return error.MissingAssociatedCall,
    };
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    const receiver_arg = switch (call.args[0]) {
        .ident => |name| name,
        else => return error.MissingAssociatedReceiver,
    };
    try std.testing.expectEqualStrings("self", receiver_arg);
    const allocator_arg = switch (call.args[1]) {
        .ident => |name| name,
        else => return error.MissingAssociatedAllocator,
    };
    try std.testing.expectEqualStrings("allocator", allocator_arg);
}

test "lower: open-ended range indexing lowers to Zig slice and rejects loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "root"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "tail_slice"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const data_param_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "data"),
        .span = span,
        .visibility = .public,
        .parent = fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try alloc.alloc(ir.spine.EntityId, 1);
    root_items[0] = fn_id;
    const root_module = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "root",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = root_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "range_test",
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const slice_u8_ty = ir.types.Type{ .slice = try alloc.create(ir.types.Slice) };
    @constCast(slice_u8_ty.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const types = [_]ir.types.Type{slice_u8_ty};

    const p_data = try model.e(.{ .path = .{ .def = data_param_id, .generic_args = &.{} } });
    const start_lit = try model.e(litInt(4));
    const open_range = try model.e(.{ .range = .{
        .start = start_lit,
        .end = null,
        .inclusive = false,
    } });
    const index_expr = try model.e(.{ .index = .{
        .base = p_data,
        .index = open_range,
    } });

    const max_bodies = @max(fn_id + 1, graph.symbol_table.count());
    const body_table = try alloc.alloc(ir.bodies.BodyKind, max_bodies);
    for (body_table) |*b| b.* = .none;
    const fn_params = try alloc.alloc(ir.items.Param, 1);
    fn_params[0] = .{ .name = "data", .ty = slice_u8_ty, .span = span };
    body_table[fn_id] = .{ .fn_ = .{
        .params = fn_params,
        .ret = slice_u8_ty,
        .generic_params = &.{},
        .body = index_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "range_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "data[4..]") != null);
}

test "lower: panic expression lowers to @panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "root"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "diverge"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try alloc.alloc(ir.spine.EntityId, 1);
    root_items[0] = fn_id;
    const root_module = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "root",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = root_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "panic_test",
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const void_ty = ir.types.Type{ .prim = .unit };
    const types = [_]ir.types.Type{void_ty};

    const panic_expr = try model.e(.{ .panic_ = .{
        .message = "unreachable",
    } });

    const max_bodies = @max(fn_id + 1, graph.symbol_table.count());
    const body_table = try alloc.alloc(ir.bodies.BodyKind, max_bodies);
    for (body_table) |*b| b.* = .none;
    body_table[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = void_ty,
        .generic_params = &.{},
        .body = panic_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "panic_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "@panic(\"unreachable\")") != null);
}
test "lower: assigned function parameter generates mutable local variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const test_span: ir.spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "root"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "mut_param_fn"),
        .span = test_span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const param_seed_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "seed"),
        .span = test_span,
        .visibility = .public,
        .parent = fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try alloc.alloc(ir.spine.EntityId, 1);
    root_items[0] = fn_id;
    const root_module = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "root",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = test_span,
        .items = root_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "mut_param_test",
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const u64_ty = ir.types.Type{ .prim = .u64 };
    const types = [_]ir.types.Type{u64_ty};

    const p_target = try model.e(.{ .path = .{ .def = param_seed_id, .generic_args = &.{} } });
    const lit_val = try model.e(litInt(42));
    const assign_expr = try model.e(.{ .assign = .{
        .target = p_target,
        .value = lit_val,
        .op = .plain,
        .overflow = .wrapping,
    } });
    const s_assign = try model.stmt(.{ .expr = assign_expr });

    const p_seed_tail = try model.e(.{ .path = .{ .def = param_seed_id, .generic_args = &.{} } });

    const stmts = try alloc.alloc(ir.exprs.NodeId, 1);
    stmts[0] = s_assign;
    const block = try model.e(.{ .block = .{
        .statements = stmts,
        .tail = p_seed_tail,
        .labelled = null,
    } });

    const max_bodies = @max(fn_id + 1, graph.symbol_table.count());
    const body_table = try alloc.alloc(ir.bodies.BodyKind, max_bodies);
    for (body_table) |*b| b.* = .none;
    const fn_params = try alloc.alloc(ir.items.Param, 1);
    fn_params[0] = .{ .name = "seed", .ty = u64_ty, .span = test_span };
    body_table[fn_id] = .{ .fn_ = .{
        .params = fn_params,
        .ret = u64_ty,
        .generic_params = &.{},
        .body = block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "mut_param_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    try std.testing.expect(std.mem.indexOf(u8, source, "_seed: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var seed: u64 = _seed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "seed = 42;") != null);
}

test "lower: numeric pointer receiver autoderefs for wrapping arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const test_span: ir.spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "root"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "ptr_math"),
        .span = test_span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const param_seed_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "seed"),
        .span = test_span,
        .visibility = .public,
        .parent = fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try alloc.alloc(ir.spine.EntityId, 1);
    root_items[0] = fn_id;
    const root_module = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "root",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = test_span,
        .items = root_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "ptr_math_test",
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const u64_ty = ir.types.Type{ .prim = .u64 };
    const ptr_u64_ty = ir.types.Type{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(ptr_u64_ty.reference).* = .{ .mut = true, .pointee = u64_ty };
    const types = [_]ir.types.Type{ u64_ty, ptr_u64_ty };

    const p_seed = try model.e(.{ .path = .{ .def = param_seed_id, .generic_args = &.{} } });
    model.exprs.items[p_seed].ty = 1;

    const lit_one = try model.e(litInt(1));
    model.exprs.items[lit_one].ty = 0;

    const method_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = "wrapping_add",
        .span = test_span,
        .visibility = .private,
        .parent = fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const m_args = try alloc.alloc(ir.exprs.NodeId, 1);
    m_args[0] = lit_one;
    const method_call = try model.e(.{ .method_call = .{
        .receiver = p_seed,
        .method = method_id,
        .receiver_mode = .shared,
        .args = m_args,
    } });
    model.exprs.items[method_call].ty = 0;

    const max_bodies = @max(fn_id + 1, graph.symbol_table.count());
    const body_table = try alloc.alloc(ir.bodies.BodyKind, max_bodies);
    for (body_table) |*b| b.* = .none;
    const fn_params = try alloc.alloc(ir.items.Param, 1);
    fn_params[0] = .{ .name = "seed", .ty = ptr_u64_ty, .span = test_span };
    body_table[fn_id] = .{ .fn_ = .{
        .params = fn_params,
        .ret = u64_ty,
        .generic_params = &.{},
        .body = method_call,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "ptr_math_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    try std.testing.expect(std.mem.indexOf(u8, source, "(seed.* +% 1)") != null);
}

test "lower: integer unary logical_not lowers to bitwise not ~" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const test_span: ir.spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "root"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "bit_not_fn"),
        .span = test_span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try alloc.alloc(ir.spine.EntityId, 1);
    root_items[0] = fn_id;
    const root_module = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "root",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = test_span,
        .items = root_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "bit_not_test",
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const types = [_]ir.types.Type{usize_ty};

    const lit_val = try model.e(litInt(31));
    model.exprs.items[lit_val].ty = 0;

    const not_expr = try model.e(.{ .unary = .{
        .op = .logical_not,
        .operand = lit_val,
    } });
    model.exprs.items[not_expr].ty = 0;

    const max_bodies = @max(fn_id + 1, graph.symbol_table.count());
    const body_table = try alloc.alloc(ir.bodies.BodyKind, max_bodies);
    for (body_table) |*b| b.* = .none;
    body_table[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = usize_ty,
        .generic_params = &.{},
        .body = not_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "bit_not_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    try std.testing.expect(std.mem.indexOf(u8, source, "~@as(usize, 31)") != null);
}
test "lower: binary operation autoderefs pointer operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const test_span: ir.spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };
    const root_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "root"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "bin_ptr_math"),
        .span = test_span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const param_seed_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "seed"),
        .span = test_span,
        .visibility = .public,
        .parent = fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const root_items = try alloc.alloc(ir.spine.EntityId, 1);
    root_items[0] = fn_id;
    const root_module = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "root",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = test_span,
        .items = root_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "bin_ptr_test",
        .edition = 2021,
        .kind = .lib,
        .root = root_module,
        .deps = &.{},
        .is_translated = true,
    });

    var model = Model.init(alloc);
    const u64_ty = ir.types.Type{ .prim = .u64 };
    const ptr_u64_ty = ir.types.Type{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(ptr_u64_ty.reference).* = .{ .mut = true, .pointee = u64_ty };
    const types = [_]ir.types.Type{ u64_ty, ptr_u64_ty };

    const p_seed = try model.e(.{ .path = .{ .def = param_seed_id, .generic_args = &.{} } });
    model.exprs.items[p_seed].ty = 1;

    const lit_one = try model.e(litInt(1));
    model.exprs.items[lit_one].ty = 0;

    const bin_expr = try model.e(.{ .binary = .{
        .op = .add,
        .lhs = p_seed,
        .rhs = lit_one,
        .overflow = .wrapping,
    } });
    model.exprs.items[bin_expr].ty = 0;

    const max_bodies = @max(fn_id + 1, graph.symbol_table.count());
    const body_table = try alloc.alloc(ir.bodies.BodyKind, max_bodies);
    for (body_table) |*b| b.* = .none;
    const fn_params = try alloc.alloc(ir.items.Param, 1);
    fn_params[0] = .{ .name = "seed", .ty = ptr_u64_ty, .span = test_span };
    body_table[fn_id] = .{ .fn_ = .{
        .params = fn_params,
        .ret = u64_ty,
        .generic_params = &.{},
        .body = bin_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "bin_ptr_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_table,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    try std.testing.expect(std.mem.indexOf(u8, source, "(seed.* +% 1)") != null);
}
