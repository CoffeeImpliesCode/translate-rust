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

fn literalIntValue(expr: ast.Expr) i128 {
    if (expr != .lit or expr.lit != .int) return std.math.minInt(i128);
    return expr.lit.int;
}

/// The import path a root-file module re-export binds, read from a
/// declaration.
///
/// A Rust `pub mod foo;` re-export is emitted as
/// `pub const foo = @import("./foo.zig");`, and in Zig that is a
/// *declaration*, not a private import — so it lives in `decls`, not in
/// `imports`. Callers that care which name a module is bound to read it here.
fn reExportPathFor(decl: ast.Decl) ?[]const u8 {
    const constant = switch (decl) {
        .const_decl => |value| value,
        else => return null,
    };
    const builtin = switch (constant.init) {
        .builtin => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, builtin.name, "import")) return null;
    if (builtin.args.len != 1) return null;
    return switch (builtin.args[0]) {
        .lit => |literal| switch (literal) {
            .str => |text| text,
            else => null,
        },
        else => null,
    };
}

/// The name a module is bound to in a file, whether the binding is still an
/// import entry or has been promoted to a re-export declaration.
fn rootModuleBindingName(
    file: ast.File,
    module_path: []const u8,
) ?[]const u8 {
    for (file.imports) |entry| {
        if (std.mem.eql(u8, entry.module_or_path, module_path)) return entry.local_name;
    }
    for (file.decls) |decl| {
        const path = reExportPathFor(decl) orelse continue;
        if (std.mem.eql(u8, path, module_path)) return decl.const_decl.name;
    }
    return null;
}

fn litChar(v: u32) ir.exprs.ExprKind {
    return .{ .literal = .{ .character = .{ .text = "", .value = v } } };
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

    // Only the cross-module `pub use util::helper;` should lower to a
    // re-export declaration; the self-ref `pub use dup;` and the wildcard
    // re-exports are skipped.
    //
    // Scoped to re-exports of a *member* (`util.helper`, a field access).
    // The root also now declares `pub const util = @import("./util.zig");`
    // for the public `mod util` — that is the module re-export, a different
    // declaration with a different init, and it must not be counted here.
    var helper_decl: ?ast.Decl = null;
    for (rf.decls) |decl| {
        const constant = switch (decl) {
            .const_decl => |value| value,
            else => continue,
        };
        if (constant.init != .field_access) continue;
        try std.testing.expect(helper_decl == null);
        helper_decl = decl;
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

    // The self-ref and wildcard forms still produce nothing, which is the
    // part of this test that the representation change does not touch.
    for (rf.decls) |decl| {
        if (decl != .const_decl) continue;
        try std.testing.expect(!std.mem.eql(u8, decl.const_decl.name, "dup"));
        try std.testing.expect(!std.mem.eql(u8, decl.const_decl.name, "_"));
    }
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

test "lower: private std::collections module import has explicit no-emission policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "std", "collections" },
        "collections",
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
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "collections"));
    }
}

// The bare `std::collections` module is a no-op, but the type paths under it
// are not. `HashMap` and `HashSet` now have a lowering — the r2z `collections`
// containers, which keep the `BuildHasher` the source named — so their `use`
// is accepted. Every *other* three-segment path under that namespace has no
// runtime type and no `lowerExternalNominal` entry, so it must keep
// rejecting. Widening the namespace rule to accept them all would turn a
// precise `error.UnsupportedExternalUse` into a silently dropped import, and
// the generated package would then name a type the translator never defined.
test "lower: unmapped std::collections types are not a namespace catch-all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { path: []const []const u8, name: []const u8 }{
        .{ .path = &.{ "core", "collections", "VecDeque" }, .name = "VecDeque" },
        .{ .path = &.{ "std", "collections", "BinaryHeap" }, .name = "BinaryHeap" },
        .{ .path = &.{ "alloc", "collections", "VecDeque" }, .name = "VecDeque" },
    };
    for (cases) |case| {
        var graph = ir.graph.CrateGraph.init(alloc);
        var bodies: ir.bodies.Bodies = undefined;
        try buildSingleExternalUseModel(
            alloc,
            &graph,
            &bodies,
            case.path,
            case.name,
            false,
        );
        const rust_ir = ir.RustIr{
            .crate_name = "external_uses",
            .edition = "2021",
            .graph = graph,
            .types = &.{},
            .bodies = bodies,
        };
        try std.testing.expectError(
            error.UnsupportedExternalUse,
            lower.lowerRustIr(alloc, &rust_ir, null),
        );
    }
}

// The flip side of the test above: the two mapped containers now import
// without a declaration, and the `r2z` runtime import the nominal lowering
// adds is what actually names the type in the generated package.
test "lower: mapped std::collections types import through the r2z runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { path: []const []const u8, name: []const u8 }{
        .{ .path = &.{ "std", "collections", "HashMap" }, .name = "HashMap" },
        .{ .path = &.{ "std", "collections", "HashSet" }, .name = "HashSet" },
        .{ .path = &.{ "core", "collections", "HashMap" }, .name = "HashMap" },
    };
    for (cases) |case| {
        var graph = ir.graph.CrateGraph.init(alloc);
        var bodies: ir.bodies.Bodies = undefined;
        try buildSingleExternalUseModel(
            alloc,
            &graph,
            &bodies,
            case.path,
            case.name,
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
            try std.testing.expect(!std.mem.eql(u8, import.local_name, case.name));
        }
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

test "lower: a trait impl method on an enum is hoisted into the enum" {
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
    const color_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = "Color",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const display_impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = "Display for Color",
        .span = span,
        .visibility = .public,
        .parent = color_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fmt_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "fmt",
        .span = span,
        .visibility = .public,
        .parent = display_impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // `fn fmt(&self) {}` — the body is irrelevant here, only the hoist is.
    const unit = try model.e(.{ .unit = {} });
    const self_ref = try model.e(.{ .path = .{ .def = color_id, .generic_args = &.{} } });
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit,
        .labelled = null,
    } });
    _ = self_ref;

    const color_ty: ir.types.Type = .{ .path = .{ .segments = &.{.{ .name = "Color", .id = null }} } };
    try model.bodies.append(alloc, .none);
    try model.bodies.append(alloc, .{ .enum_ = .{
        .kind = .c_like,
        .variants = &.{
            .{ .name = "red", .fields = .{ .none = {} }, .discriminant = null },
        },
    } });
    try model.bodies.append(alloc, .{ .impl_ = .{
        .self_ty = color_ty,
        .trait_path = .{ .segments = &.{.{ .name = "Display", .id = null }} },
    } });
    try model.bodies.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = body,
    } });

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
        .items = try alloc.dupe(ir.spine.EntityId, &.{ color_id, display_impl_id, fmt_id }),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "colors",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
    const rust_ir = ir.RustIr{
        .crate_name = "colors",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };

    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    const enum_decl = for (pkg.files[0].decls) |decl| {
        if (decl == .enum_decl and
            std.mem.eql(u8, decl.enum_decl.name, "Color")) break decl;
    } else return error.TestUnexpectedResult;

    // The impl method must be attached to the enum, not dropped and not
    // emitted twice.
    var saw_fmt = false;
    for (enum_decl.enum_decl.decls) |decl| {
        if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, "fmt")) saw_fmt = true;
    }
    try std.testing.expect(saw_fmt);
}

test "lower: a source trait declaration emits no Zig declaration" {
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
    const trait_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .trait_,
        .name = "ToHex",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    try model.bodies.append(alloc, .none);
    try model.bodies.append(alloc, .{ .trait_ = .{
        .name = "ToHex",
        .methods = &.{.{ .name = "encode_hex", .ret = .{ .path = .{ .segments = &.{.{ .name = "Self", .id = null }} } } }},
    } });

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
        .items = try alloc.dupe(ir.spine.EntityId, &.{trait_id}),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "traits",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
    const rust_ir = ir.RustIr{
        .crate_name = "traits",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };

    // A trait has no Zig counterpart. Its methods are hoisted onto the
    // implementing type by `collectHoistedMethods` and its bounds are erased,
    // so the declaration itself must contribute nothing to the file.
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 0), pkg.files[0].decls.len);
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
    generic_params: []const []const u8,
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
    body_rows[1] = .{ .type_alias = .{
        .target = .{ .external_nominal = .{
            .path = path,
            .args = args,
        } },
        .generic_params = generic_params,
    } };
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
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, args, &.{});
    try std.testing.expectError(expected_error, lower.lowerRustIr(alloc, &rust_ir, null));
}

fn expectBuildHasherDefaultLowered(
    alloc: std.mem.Allocator,
    path: []const []const u8,
) !void {
    const args = [_]ir.types.Type{.{ .prim = .u8 }};
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, &args, &.{});
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
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, args, &.{});
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

/// Lower a `pub type` alias whose target is a `collections` type path and
/// return the emitted generic call, so a test can inspect its callee and its
/// forwarded arguments.
fn lowerExternalNominalCall(
    alloc: std.mem.Allocator,
    path: []const []const u8,
    args: []const ir.types.Type,
) !struct { name: []const u8, call: ast.Call } {
    const rust_ir = try buildExternalNominalAliasIr(alloc, path, args, &.{});
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    try std.testing.expectEqual(@as(usize, 1), pkg.files[0].decls.len);

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
    const name = switch (call.callee.*) {
        .ident => |value| value,
        else => return error.UnexpectedCalleeKind,
    };
    return .{ .name = name, .call = call };
}

test "lower: collections HashMap and HashSet keep the source's BuildHasher" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `HashMap<K, V, FnvBuildHasher>` must emit all three arguments. The
    // third is the whole point: dropping it, or swapping it for Wyhash,
    // turns a crate whose only product is its hasher into a lie.
    const map_args = [_]ir.types.Type{
        .{ .prim = .u64 },
        .{ .prim = .f32 },
        .{ .prim = .usize },
    };
    const map = try lowerExternalNominalCall(
        alloc,
        &.{ "std", "collections", "HashMap" },
        &map_args,
    );
    try std.testing.expectEqualStrings("r2z.collections.HashMap", map.name);
    try std.testing.expectEqual(@as(usize, 3), map.call.generic_args.len);
    try std.testing.expectEqual(
        ast.Prim.u64,
        switch (map.call.generic_args[0]) {
            .prim => |value| value,
            else => return error.UnexpectedGenericArgumentKind,
        },
    );
    try std.testing.expectEqual(
        ast.Prim.f32,
        switch (map.call.generic_args[1]) {
            .prim => |value| value,
            else => return error.UnexpectedGenericArgumentKind,
        },
    );
    try std.testing.expectEqual(
        ast.Prim.usize,
        switch (map.call.generic_args[2]) {
            .prim => |value| value,
            else => return error.UnexpectedGenericArgumentKind,
        },
    );

    // `core::collections` and `alloc::collections` name the same Rust type.
    const from_core = try lowerExternalNominalCall(
        alloc,
        &.{ "core", "collections", "HashMap" },
        &map_args,
    );
    try std.testing.expectEqualStrings("r2z.collections.HashMap", from_core.name);

    const from_alloc = try lowerExternalNominalCall(
        alloc,
        &.{ "alloc", "collections", "HashMap" },
        &map_args,
    );
    try std.testing.expectEqualStrings("r2z.collections.HashMap", from_alloc.name);

    const set_args = [_]ir.types.Type{ .{ .prim = .u64 }, .{ .prim = .usize } };
    const set = try lowerExternalNominalCall(
        alloc,
        &.{ "std", "collections", "HashSet" },
        &set_args,
    );
    try std.testing.expectEqualStrings("r2z.collections.HashSet", set.name);
    try std.testing.expectEqual(@as(usize, 2), set.call.generic_args.len);
}

test "lower: collections containers reject a missing BuildHasher argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `HashMap<K, V>` defaults to Rust's per-process `RandomState`. There is
    // no static Zig equivalent, so inventing a builder here would be a
    // silent lie in the other direction.
    const two_args = [_]ir.types.Type{ .{ .prim = .u64 }, .{ .prim = .f32 } };
    try expectExternalNominalError(
        alloc,
        &.{ "std", "collections", "HashMap" },
        &two_args,
        error.GenericArgumentArityMismatch,
    );

    // `HashSet<T, S>` takes two arguments, not three: the element type and
    // the builder. Handing it `HashMap`'s two-argument list is a *complete*
    // `HashSet<u64, FnvBuildHasher>`, so the missing-builder case is the
    // one-argument form. The three-argument read of `HashSet` was the test
    // being wrong about the shape, and no arity change is warranted: the
    // sibling test above already pins that two arguments lower.
    const one_arg = [_]ir.types.Type{.{ .prim = .u64 }};
    try expectExternalNominalError(
        alloc,
        &.{ "std", "collections", "HashSet" },
        &one_arg,
        error.GenericArgumentArityMismatch,
    );
    try expectExternalNominalError(
        alloc,
        &.{ "std", "collections", "HashSet" },
        &.{},
        error.GenericArgumentArityMismatch,
    );
}

test "lower: a generic type alias becomes a comptime type function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `pub type FnvHashMap<K, V> = HashMap<K, V, FnvBuildHasher>;` from the
    // `fnv` crate. K and V are bound by the alias, so a `const` would leave
    // their names dangling in the generated package.
    const map_args = [_]ir.types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "K", .id = null }} } },
        .{ .path = .{ .segments = &.{.{ .name = "V", .id = null }} } },
        .{ .path = .{ .segments = &.{.{ .name = "FnvBuildHasher", .id = null }} } },
    };
    const rust_ir = try buildExternalNominalAliasIr(
        alloc,
        &.{ "std", "collections", "HashMap" },
        &map_args,
        &.{ "K", "V" },
    );
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    try std.testing.expectEqual(@as(usize, 1), pkg.files[0].decls.len);

    const alias = switch (pkg.files[0].decls[0]) {
        .fn_decl => |decl| decl,
        else => return error.UnexpectedDeclarationKind,
    };
    try std.testing.expectEqualStrings("ExternalAlias", alias.name);
    try std.testing.expect(alias.is_pub);
    try std.testing.expectEqual(@as(usize, 0), alias.params.len);
    try std.testing.expectEqualStrings("type", alias.ret_type.named);
    try std.testing.expectEqual(@as(usize, 2), alias.generic_params.len);
    try std.testing.expectEqualStrings("K", alias.generic_params[0].name);
    try std.testing.expect(alias.generic_params[0].is_comptime);
    try std.testing.expectEqualStrings("type", alias.generic_params[0].ty.?.named);
    try std.testing.expectEqualStrings("V", alias.generic_params[1].name);
    try std.testing.expect(alias.generic_params[1].is_comptime);
    try std.testing.expectEqualStrings("type", alias.generic_params[1].ty.?.named);

    // The body is the container call with the alias parameters forwarded.
    const returned = alias.body.?.expr.?.*;
    const call = switch (returned) {
        .call => |value| value,
        else => return error.UnexpectedInitializerKind,
    };
    try std.testing.expectEqualStrings(
        "r2z.collections.HashMap",
        switch (call.callee.*) {
            .ident => |name| name,
            else => return error.UnexpectedCalleeKind,
        },
    );
    try std.testing.expectEqual(@as(usize, 3), call.generic_args.len);
    try std.testing.expectEqualStrings("K", call.generic_args[0].named);
    try std.testing.expectEqualStrings("V", call.generic_args[1].named);
    try std.testing.expectEqualStrings("FnvBuildHasher", call.generic_args[2].named);
}

test "lower: a plain type alias stays a const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The generic form must not leak into the ordinary case: `pub type
    // FnvBuildHasher = BuildHasherDefault<FnvHasher>;` has no parameters and
    // stays a `const`.
    const args = [_]ir.types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "FnvHasher", .id = null }} } },
    };
    const rust_ir = try buildExternalNominalAliasIr(
        alloc,
        &.{ "std", "hash", "BuildHasherDefault" },
        &args,
        &.{},
    );
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    const alias = switch (pkg.files[0].decls[0]) {
        .const_decl => |decl| decl,
        else => return error.UnexpectedDeclarationKind,
    };
    const call = switch (alias.init) {
        .call => |value| value,
        else => return error.UnexpectedInitializerKind,
    };
    try std.testing.expectEqualStrings(
        "r2z.BuildHasherDefault",
        switch (call.callee.*) {
            .ident => |name| name,
            else => return error.UnexpectedCalleeKind,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
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
        &.{},
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
        &.{},
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

/// A combinator closure as it reaches the lowerer: the parameter pattern, the
/// capture list, and the entity the body tail resolves to.
const ClosureCombinatorFixture = struct {
    method_name: []const u8,
    receiver_ty: ir.types.Type,
    /// The parameter's own binding name, also the entity the body tail
    /// resolves to when no capture is requested.
    param_name: []const u8,
    /// null → the body tail resolves to the parameter binding.
    capture_name: ?[]const u8 = null,
    capture_by_value: bool = false,
    /// false → the argument is a plain literal, exercising the runtime call.
    closure_argument: bool = true,
    /// Element binding names for a destructured parameter (`|(a, b)| ..`).
    /// Empty → the parameter is a plain binding.
    tuple_names: []const []const u8 = &.{},
    /// Build the destructured parameter as a slice pattern (`|[a, rest]|`)
    /// instead of a tuple, which the lowerer has no Zig spelling for.
    param_is_slice: bool = false,
    /// Further parameter bindings, so the closure takes more than one argument.
    /// The body tail still resolves to the first.
    extra_param_names: []const []const u8 = &.{},
};

/// Lower `receiver.<method>(|param| ..)` into a package. `capture_name` names
/// an extra function parameter captured by the closure; with
/// `capture_by_value` the capture is copied into a snapshot first.
fn lowerClosureCombinatorPackage(
    alloc: std.mem.Allocator,
    fixture: ClosureCombinatorFixture,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const method_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = fixture.method_name,
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
    const param_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = fixture.param_name,
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
        .name = "closure_combinator_fixture",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    graph.symbol_table.entities.items[method_id].parent = function_id;
    graph.symbol_table.entities.items[receiver_id].parent = function_id;
    graph.symbol_table.entities.items[param_id].parent = function_id;
    var capture_id: ?ir.spine.EntityId = null;
    if (fixture.capture_name) |capture_name| {
        capture_id = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .const_,
            .name = capture_name,
            .span = span,
            .visibility = .private,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        graph.symbol_table.entities.items[capture_id.?].parent = function_id;
    }

    // A destructured parameter binds its element names, so the body tail reads
    // the first of them — `|(a, b)| a` — not the parameter as a whole.
    var element_ids: []const ir.spine.EntityId = &.{};
    if (fixture.tuple_names.len > 0) {
        const ids = try alloc.alloc(ir.spine.EntityId, fixture.tuple_names.len);
        for (fixture.tuple_names, 0..) |name, index| {
            ids[index] = try graph.symbol_table.add(.{
                .id = 0,
                .kind = .const_,
                .name = name,
                .span = span,
                .visibility = .private,
                .parent = null,
                .resolved = null,
                .renamed_to = null,
                .attributes = &.{},
            });
            graph.symbol_table.entities.items[ids[index]].parent = function_id;
        }
        element_ids = ids;
    }

    const types_store = try alloc.alloc(ir.types.Type, 1);
    types_store[0] = fixture.receiver_ty;

    const receiver_expr = try model.e(.{
        .path = .{ .def = receiver_id, .generic_args = &.{} },
    });
    model.exprs.items[receiver_expr].ty = 0;

    // The body tail names the captured binding when one is requested, so a
    // by-value capture is visible as a renamed reference in the closure body.
    const tail_expr = try model.e(.{ .path = .{
        .def = capture_id orelse if (element_ids.len > 0) element_ids[0] else param_id,
        .generic_args = &.{},
    } });
    model.exprs.items[tail_expr].ty = 0;

    // A tuple-destructured parameter (`|(a, b)| ..`) is ONE parameter whose
    // pattern is a tuple, matching how the frontend desugars `|(i, pair)|`.
    const param_pattern: ir.exprs.NodeId = if (fixture.tuple_names.len == 0)
        try model.pat(.{
            .binding = .{
                .name = fixture.param_name,
                .mode = .{ .value = {} },
                .mutable = false,
            },
        })
    else blk: {
        const elements = try alloc.alloc(ir.exprs.NodeId, fixture.tuple_names.len);
        for (fixture.tuple_names, 0..) |name, index| {
            elements[index] = try model.pat(.{
                .binding = .{ .name = name, .mode = .{ .value = {} }, .mutable = false },
            });
        }
        break :blk try model.pat(if (fixture.param_is_slice)
            .{ .slice = .{ .elements = elements, .rest = null } }
        else
            .{ .tuple = .{ .elements = elements, .rest = false } });
    };
    var captures: []const ir.exprs.Capture = &.{};
    if (fixture.capture_name) |capture_name| {
        const one = try alloc.alloc(ir.exprs.Capture, 1);
        one[0] = .{
            .name = capture_name,
            .mode = if (fixture.capture_by_value) .by_value else .by_ref,
            .ty = 0,
        };
        captures = one;
    }
    const param_count = 1 + fixture.extra_param_names.len;
    const param_ids = try alloc.alloc(ir.exprs.NodeId, param_count);
    param_ids[0] = param_pattern;
    for (fixture.extra_param_names, 0..) |name, index| {
        param_ids[index + 1] = try model.pat(.{
            .binding = .{ .name = name, .mode = .{ .value = {} }, .mutable = false },
        });
    }
    const closure_expr = try model.e(.{ .closure = .{
        .captures = captures,
        .params = param_ids,
        .return_ty = null,
        .body = .{ .statements = &.{}, .tail = tail_expr, .labelled = null },
        .trait = .@"fn",
    } });
    const argument_ids = try alloc.alloc(ir.exprs.NodeId, 1);
    argument_ids[0] = if (fixture.closure_argument)
        closure_expr
    else
        try model.e(litInt(1));

    const method_expr = try model.e(.{ .method_call = .{
        .receiver = receiver_expr,
        .receiver_mode = .value,
        .method = method_id,
        .args = argument_ids,
    } });
    const method_block = try model.e(.{
        .block = .{ .statements = &.{}, .tail = method_expr, .labelled = null },
    });

    var params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "value", .ty = fixture.receiver_ty, .span = span };
    if (fixture.capture_name != null) {
        const two = try alloc.alloc(ir.items.Param, 2);
        two[0] = params[0];
        two[1] = .{ .name = fixture.capture_name.?, .ty = .{ .prim = .u8 }, .span = span };
        params = two;
    }
    // The body table is indexed by EntityId, so the callable's own body has to
    // land on its own slot however many helper entities precede it.
    while (model.bodies.items.len < function_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .u8 },
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
        .crate_name = "closure_combinator_fixture",
        .edition = 2021,
        .items = &.{function_id},
    });

    const rust_ir = ir.RustIr{
        .crate_name = "closure_combinator_fixture",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The emitted body tail of `lowerClosureCombinatorPackage`.
fn lowerClosureCombinatorExpr(
    alloc: std.mem.Allocator,
    fixture: ClosureCombinatorFixture,
) !ast.Expr {
    const pkg = try lowerClosureCombinatorPackage(alloc, fixture);
    const decl = pkg.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const expr = body.expr orelse return error.ExpectedBodyExpression;
    return expr.*;
}

test "lower: Option::map with an inline closure expands to an optional if, not a switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const option_elem = try alloc.create(ir.types.Type);
    option_elem.* = .{ .prim = .u8 };
    const option_ty: ir.types.Type = .{ .option = option_elem };

    const expr = try lowerClosureCombinatorExpr(alloc, .{
        .method_name = "map",
        .receiver_ty = option_ty,
        .param_name = "byte",
    });

    // Zig cannot `switch` an optional, so the two cases ride on `if (opt !=
    // null)`: a `match_expr` here emitted `switch (value)` over a `?u8` and
    // never compiled.
    if (expr != .if_expr) return error.ExpectedOptionMapIf;
    if (expr.if_expr.cond != .bin_op or expr.if_expr.cond.bin_op.op != .not_equal) {
        return error.ExpectedNullTest;
    }
    if (expr.if_expr.cond.bin_op.rhs.* != .lit or
        expr.if_expr.cond.bin_op.rhs.lit != .null_lit)
    {
        return error.ExpectedNullComparison;
    }
    const else_body = expr.if_expr.else_body orelse return error.ExpectedElseBranch;
    if (else_body.* != .lit or else_body.lit != .null_lit) return error.ExpectedNullElse;
    const then_body = expr.if_expr.then_body.*;
    if (then_body != .block) return error.ExpectedMappedBlock;
    // `const __r2z_in_byte = r2z.option.unwrap(..); const byte = __r2z_in_byte;`
    const stmts = then_body.block.stmts;
    if (stmts.len != 2) return error.ExpectedUnwrapThenBinding;
    if (stmts[0] != .let_stmt or stmts[1] != .let_stmt) {
        return error.ExpectedTwoBindingStatements;
    }
    const unwrap = stmts[0].let_stmt.init;
    if (unwrap != .call or unwrap.call.callee.* != .ident or
        !std.mem.eql(u8, unwrap.call.callee.ident, "r2z.option.unwrap"))
    {
        return error.ExpectedOptionUnwrap;
    }
    if (unwrap.call.args.len != 1) return error.ExpectedSingleUnwrapArgument;
    if (!std.mem.eql(u8, stmts[1].let_stmt.name, "byte")) return error.ExpectedParameterBinding;
    if (stmts[1].let_stmt.init != .ident or
        !std.mem.eql(u8, stmts[1].let_stmt.init.ident, stmts[0].let_stmt.name))
    {
        return error.ExpectedBindingFromUnwrap;
    }
    const tail = then_body.block.expr orelse return error.ExpectedMappedTail;
    if (tail.* != .ident or !std.mem.eql(u8, tail.ident, "byte")) {
        return error.ExpectedParameterBody;
    }
}

test "lower: Option::map with a non-closure argument keeps the runtime call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const option_elem = try alloc.create(ir.types.Type);
    option_elem.* = .{ .prim = .u8 };
    const option_ty: ir.types.Type = .{ .option = option_elem };

    const expr = try lowerClosureCombinatorExpr(alloc, .{
        .method_name = "map",
        .receiver_ty = option_ty,
        .param_name = "byte",
        .closure_argument = false,
    });
    if (expr != .call) return error.ExpectedRuntimeMapCall;
    if (expr.call.callee.* != .ident or
        !std.mem.eql(u8, expr.call.callee.ident, "r2z.option.map"))
    {
        return error.ExpectedRuntimeMapCallee;
    }
    if (expr.call.args.len != 2) return error.ExpectedReceiverAndMapper;
}

test "lower: inline closure combinator snapshots a by-value capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const option_elem = try alloc.create(ir.types.Type);
    option_elem.* = .{ .prim = .u8 };
    const option_ty: ir.types.Type = .{ .option = option_elem };

    const expr = try lowerClosureCombinatorExpr(alloc, .{
        .method_name = "map",
        .receiver_ty = option_ty,
        .param_name = "byte",
        .capture_name = "bias",
        .capture_by_value = true,
    });
    if (expr != .block) return error.ExpectedCapturePrologueBlock;
    const stmts = expr.block.stmts;
    if (stmts.len != 1 or stmts[0] != .let_stmt) return error.ExpectedSingleSnapshot;
    const snapshot = stmts[0].let_stmt;
    if (!std.mem.startsWith(u8, snapshot.name, "__r2z_capture_")) {
        return error.ExpectedCaptureSnapshotName;
    }
    if (snapshot.init != .ident or !std.mem.eql(u8, snapshot.init.ident, "bias")) {
        return error.ExpectedSnapshotOfCapturedBinding;
    }
    const expanded = expr.block.expr orelse return error.ExpectedExpandedCombinator;
    if (expanded.* != .if_expr) return error.ExpectedOptionMapIf;
    const then_body = expanded.if_expr.then_body.*;
    if (then_body != .block) return error.ExpectedMappedBlock;
    const tail = then_body.block.expr orelse return error.ExpectedMappedTail;
    // The body reads the snapshot, not the outer `bias` binding.
    if (tail.* != .ident or !std.mem.eql(u8, tail.ident, snapshot.name)) {
        return error.ExpectedBodyReadsSnapshot;
    }
}

test "lower: Result::map with an inline closure rewraps the untouched arm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ok_elem = try alloc.create(ir.types.Type);
    ok_elem.* = .{ .prim = .u8 };
    const err_elem = try alloc.create(ir.types.Type);
    err_elem.* = .{ .prim = .u8 };
    const result_info = try alloc.create(ir.types.Result);
    result_info.* = .{
        .ok = ok_elem.*,
        .err = err_elem.*,
        .is_error_unionable = false,
    };
    const result_ty: ir.types.Type = .{ .result = result_info };

    const expr = try lowerClosureCombinatorExpr(alloc, .{
        .method_name = "map",
        .receiver_ty = result_ty,
        .param_name = "byte",
    });
    if (expr != .match_expr) return error.ExpectedResultMapSwitch;
    const arms = expr.match_expr.arms;
    if (arms.len != 2) return error.ExpectedTwoSwitchArms;
    if (arms[0].patterns.len != 1 or arms[0].patterns[0] != .enum_literal or
        !std.mem.eql(u8, arms[0].patterns[0].enum_literal, "Ok"))
    {
        return error.ExpectedOkProng;
    }
    const ok_capture = arms[0].capture orelse return error.ExpectedOkPayloadCapture;
    if (!std.mem.eql(u8, ok_capture.name, "__r2z_in_byte")) return error.ExpectedOkPayloadName;
    if (arms[1].patterns.len != 1 or arms[1].patterns[0] != .enum_literal or
        !std.mem.eql(u8, arms[1].patterns[0].enum_literal, "Err"))
    {
        return error.ExpectedErrProng;
    }
    const err_capture = arms[1].capture orelse return error.ExpectedErrPayloadCapture;
    if (!std.mem.eql(u8, err_capture.name, "__r2z_in_byte_err")) {
        return error.ExpectedErrPayloadName;
    }
    if (arms[1].body != .struct_init) return error.ExpectedRewrappedErrArm;
    // A field-bearing literal without a type name is not a valid AST node.
    const rewrapped = arms[1].body.struct_init;
    if (rewrapped.type_name == null) return error.ExpectedTypedResultLiteral;
    if (rewrapped.fields.len != 1) return error.ExpectedSingleResultField;
    if (!std.mem.eql(u8, rewrapped.fields[0].name, "Err")) return error.ExpectedErrFieldName;
    if (rewrapped.fields[0].expr != .ident or
        !std.mem.eql(u8, rewrapped.fields[0].expr.ident, err_capture.name))
    {
        return error.ExpectedErrFieldFromCapture;
    }
}

test "lower: Option::map with a tuple-destructured closure parameter binds the tuple and destructures it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const elem = try alloc.create(ir.types.Type);
    elem.* = .{ .prim = .u8 };
    const two = try alloc.alloc(ir.types.Type, 2);
    @memset(two, elem.*);
    const inner = try alloc.create(ir.types.Type);
    inner.* = .{ .tuple = two };
    const option_ty: ir.types.Type = .{ .option = inner };

    const expr = try lowerClosureCombinatorExpr(alloc, .{
        .method_name = "map",
        .receiver_ty = option_ty,
        .param_name = "pair",
        // `|(a, b)| a` — one parameter whose pattern destructures a tuple.
        .tuple_names = &.{ "a", "b" },
    });
    if (expr != .match_expr) return error.ExpectedOptionMapSwitch;
    const arms = expr.match_expr.arms;
    if (arms.len != 2) return error.ExpectedTwoSwitchArms;
    const capture = arms[1].capture orelse return error.ExpectedPayloadCapture;
    // A tuple pattern names no single value, so the payload is named for the
    // shape and destructured inside the prong.
    if (!std.mem.eql(u8, capture.name, "__r2z_in_tuple")) return error.ExpectedPayloadName;
    if (arms[1].body != .block) return error.ExpectedMappedBlock;
    const mapped = arms[1].body.block;
    // `const __r2z_tuple = <payload>;` then one index binding per element.
    if (mapped.stmts.len != 3) return error.ExpectedTupleDestructure;
    const whole = mapped.stmts[0].let_stmt;
    if (!std.mem.eql(u8, whole.name, "__r2z_tuple")) return error.ExpectedTupleBinding;
    if (whole.init != .ident or !std.mem.eql(u8, whole.init.ident, capture.name)) {
        return error.ExpectedTupleBoundToPayload;
    }
    const first = mapped.stmts[1].let_stmt;
    if (!std.mem.eql(u8, first.name, "a")) return error.ExpectedFirstElementName;
    if (first.init != .builtin or !std.mem.eql(u8, first.init.builtin.name, "index")) {
        return error.ExpectedElementIndex;
    }
    if (first.init.builtin.args.len != 2 or first.init.builtin.args[0] != .ident or
        !std.mem.eql(u8, first.init.builtin.args[0].ident, "__r2z_tuple"))
    {
        return error.ExpectedElementIndexedFromTuple;
    }
    const second = mapped.stmts[2].let_stmt;
    if (!std.mem.eql(u8, second.name, "b")) return error.ExpectedSecondElementName;
    if (second.init != .builtin or second.init.builtin.args.len != 2 or
        second.init.builtin.args[1] != .lit or second.init.builtin.args[1].lit.int != 1)
    {
        return error.ExpectedSecondElementIndex;
    }
    // The body reads the destructured binding, not the payload.
    const tail = mapped.expr orelse return error.ExpectedMappedTail;
    if (tail.* != .ident or !std.mem.eql(u8, tail.ident, "a")) {
        return error.ExpectedParameterBody;
    }
}

test "lower: inline closure combinator still refuses a genuinely multi-parameter closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const option_elem = try alloc.create(ir.types.Type);
    option_elem.* = .{ .prim = .u8 };
    const option_ty: ir.types.Type = .{ .option = option_elem };

    // Two separate parameters is not a tuple destructuring: the payload is one
    // value, so there is nothing to hand a second argument. This must stay
    // refused rather than silently binding the first parameter alone.
    try std.testing.expectError(
        error.UnsupportedExpression,
        lowerClosureCombinatorExpr(alloc, .{
            .method_name = "map",
            .receiver_ty = option_ty,
            .param_name = "byte",
            .extra_param_names = &.{"other"},
        }),
    );
}

test "lower: inline closure combinator still refuses an unsupported parameter shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const option_elem = try alloc.create(ir.types.Type);
    option_elem.* = .{ .prim = .u8 };
    const option_ty: ir.types.Type = .{ .option = option_elem };

    // `|[first, rest]|` is a real Rust pattern the Zig AST cannot spell: it
    // needs a slice view plus a sub-slice binding. Admitting tuple patterns
    // must not admit this one.
    try std.testing.expectError(
        error.UnsupportedIteratorAdapter,
        lowerClosureCombinatorExpr(alloc, .{
            .method_name = "map",
            .receiver_ty = option_ty,
            .param_name = "pair",
            .tuple_names = &.{ "first", "rest" },
            .param_is_slice = true,
        }),
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

    // (i) The re-export is present and public, and (ii) the name `support` is
    // bound exactly once. Both claims are unchanged; only the AST node they
    // inspect moved, because `pub const support = @import("./support.zig");`
    // is a Zig *declaration*, so a public root module is recorded in `decls`
    // rather than left as a private import entry.
    var support_bindings: usize = 0;
    for (root_file.decls) |decl| {
        const path = reExportPathFor(decl) orelse continue;
        if (!std.mem.eql(u8, decl.const_decl.name, "support")) continue;
        support_bindings += 1;
        try std.testing.expectEqualStrings("./support.zig", path);
        try std.testing.expect(decl.const_decl.is_pub);
    }
    try std.testing.expectEqual(@as(usize, 1), support_bindings);

    // Stronger than the original check: the name must not ALSO survive as an
    // import entry. Keeping both would be the double representation this
    // test exists to prevent, and the original assertions could not see it
    // because they only ever looked at one of the two lists.
    for (root_file.imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "support"));
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

    // The owner module is bound under `owner_1`, not `owner`, so the import
    // cannot collide with the `let owner` temporary below. The binding is
    // read through `rootModuleBindingName` because a re-export is a
    // declaration, not an import entry.
    const import_name = rootModuleBindingName(file, "./owner.zig") orelse
        return error.MissingLazyOwnerImport;
    try std.testing.expectEqualStrings("owner_1", import_name);

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
    try std.testing.expectEqualStrings(import_name, remote_module);
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

    try std.testing.expect(std.mem.indexOf(u8, source, "seed.* +% 1") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, source, "seed.* +% 1") != null);
}

// ── Range patterns ───────────────────────────────────────────────────────────

/// One range pattern of a fixture match arm. `lo`/`hi` carry the IR
/// expression kind used as that bound; null leaves the side unbounded.
const RangeArmPattern = struct {
    lo: ?ir.exprs.ExprKind,
    hi: ?ir.exprs.ExprKind,
    inclusive: bool,
};

/// Lower a one-function crate whose body is `match value { <arms> }` and
/// return the lowered switch. Every arm lists the alternatives of its
/// top-level or-pattern, so one entry is a plain range pattern and two
/// entries are the `a | b` form.
fn lowerRangeMatch(
    alloc: std.mem.Allocator,
    arms: []const []const RangeArmPattern,
) !ast.Expr {
    var graph = ir.graph.CrateGraph.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "classify", null);
    const param_id = try addLowerEntity(&graph, .field, "value", fn_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "range_pat_fixture",
        .edition = 2021,
        .items = &.{fn_id},
    });

    var model = Model.init(alloc);
    const scrutinee = try model.e(.{ .path = .{ .def = param_id, .generic_args = &.{} } });
    const ir_arms = try alloc.alloc(ir.exprs.MatchArm, arms.len);
    for (arms, 0..) |alternatives, index| {
        const selectors = try alloc.alloc(ir.exprs.NodeId, alternatives.len);
        for (alternatives, 0..) |alternative, alternative_index| {
            const lo = if (alternative.lo) |kind| try model.e(kind) else null;
            const hi = if (alternative.hi) |kind| try model.e(kind) else null;
            const range_id = try model.pat(.{ .range = .{
                .lo = lo,
                .hi = hi,
                .inclusive = alternative.inclusive,
            } });
            selectors[alternative_index] = if (alternatives.len == 1)
                range_id
            else blk_or: {
                const group = try alloc.alloc(ir.exprs.NodeId, 1);
                group[0] = range_id;
                break :blk_or try model.pat(.{ .@"or" = .{ .alternatives = group } });
            };
        }
        ir_arms[index] = .{
            .patterns = selectors,
            .guard = null,
            .body = try model.e(litInt(0)),
        };
    }
    const match_expr = try model.e(.{ .match = .{
        .scrutinee = scrutinee,
        .arms = ir_arms,
        .option_scrutinee = false,
    } });
    const body = try model.e(.{
        .block = .{ .statements = &.{}, .tail = match_expr, .labelled = null },
    });

    while (model.bodies.items.len <= fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[fn_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "value", .ty = .{ .prim = .u8 }, .span = span }},
        .ret = .{ .prim = .u8 },
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "range_pat_fixture",
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
    for (package.files) |file| {
        for (file.decls) |decl| {
            if (decl != .fn_decl) continue;
            if (!std.mem.eql(u8, decl.fn_decl.name, "classify")) continue;
            const fn_block = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
            const tail = fn_block.expr orelse return error.ExpectedFunctionTail;
            return tail.*;
        }
    }
    return error.ExpectedRangeMatchFunction;
}

fn expectRangeMatch(alloc: std.mem.Allocator, arms: []const []const RangeArmPattern) !ast.Match {
    const expr = try lowerRangeMatch(alloc, arms);
    if (expr != .match_expr) return error.ExpectedRangeMatch;
    return expr.match_expr;
}

test "lower: a range pattern keeps both integer bounds and inclusivity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const match_expr = try expectRangeMatch(alloc, &.{&.{
        .{ .lo = litInt(1), .hi = litInt(5), .inclusive = true },
    }});
    try std.testing.expectEqual(@as(usize, 1), match_expr.arms.len);
    const patterns = match_expr.arms[0].patterns;
    try std.testing.expectEqual(@as(usize, 1), patterns.len);
    if (patterns[0] != .range_pat) return error.ExpectedRangeProng;
    const range = patterns[0].range_pat;
    if (!range.inclusive) return error.ExpectedInclusiveRange;
    const lo = range.lo orelse return error.ExpectedRangeLo;
    if (lo != .int or lo.int != 1) return error.ExpectedRangeLoValue;
    const hi = range.hi orelse return error.ExpectedRangeHi;
    if (hi != .int or hi.int != 5) return error.ExpectedRangeHiValue;
}

test "lower: an exclusive range pattern records inclusive = false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const match_expr = try expectRangeMatch(alloc, &.{&.{
        .{ .lo = litInt(0), .hi = litInt(9), .inclusive = false },
    }});
    const patterns = match_expr.arms[0].patterns;
    if (patterns[0] != .range_pat) return error.ExpectedRangeProng;
    const range = patterns[0].range_pat;
    if (range.inclusive) return error.ExpectedExclusiveRange;
    const lo = range.lo orelse return error.ExpectedRangeLo;
    if (lo != .int or lo.int != 0) return error.ExpectedRangeLoValue;
    const hi = range.hi orelse return error.ExpectedRangeHi;
    if (hi != .int or hi.int != 9) return error.ExpectedRangeHiValue;
}

test "lower: an open-ended range pattern leaves the missing bound null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const match_expr = try expectRangeMatch(alloc, &.{&.{
        .{ .lo = litInt(3), .hi = null, .inclusive = true },
    }});
    const patterns = match_expr.arms[0].patterns;
    if (patterns[0] != .range_pat) return error.ExpectedRangeProng;
    const range = patterns[0].range_pat;
    if (range.hi != null) return error.ExpectedUnboundedHi;
    const lo = range.lo orelse return error.ExpectedRangeLo;
    if (lo != .int or lo.int != 3) return error.ExpectedRangeLoValue;

    // A null lower bound is unbounded the other way round.
    const lower_open = try expectRangeMatch(alloc, &.{&.{
        .{ .lo = null, .hi = litInt(4), .inclusive = true },
    }});
    const open_range = lower_open.arms[0].patterns[0];
    if (open_range != .range_pat) return error.ExpectedRangeProng;
    if (open_range.range_pat.lo != null) return error.ExpectedUnboundedLo;
    if (open_range.range_pat.hi == null) return error.ExpectedBoundedHi;
}

test "lower: a character range pattern keeps both character bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const match_expr = try expectRangeMatch(alloc, &.{&.{
        .{ .lo = litChar('a'), .hi = litChar('z'), .inclusive = true },
    }});
    const patterns = match_expr.arms[0].patterns;
    if (patterns[0] != .range_pat) return error.ExpectedRangeProng;
    const range = patterns[0].range_pat;
    const lo = range.lo orelse return error.ExpectedRangeLo;
    if (lo != .char_lit or lo.char_lit != 'a') return error.ExpectedRangeLoChar;
    const hi = range.hi orelse return error.ExpectedRangeHi;
    if (hi != .char_lit or hi.char_lit != 'z') return error.ExpectedRangeHiChar;
}

test "lower: an or-pattern of ranges becomes one arm with both range prongs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `b'A'..=b'F' | b'a'..=b'f' => ...`
    const match_expr = try expectRangeMatch(alloc, &.{&.{
        .{ .lo = litChar('A'), .hi = litChar('F'), .inclusive = true },
        .{ .lo = litChar('a'), .hi = litChar('f'), .inclusive = true },
    }});
    try std.testing.expectEqual(@as(usize, 1), match_expr.arms.len);
    const patterns = match_expr.arms[0].patterns;
    try std.testing.expectEqual(@as(usize, 2), patterns.len);
    for (patterns, 0..) |pattern, index| {
        if (pattern != .range_pat) return error.ExpectedRangeProng;
        const range = pattern.range_pat;
        const lo = range.lo orelse return error.ExpectedRangeLo;
        if (lo != .char_lit) return error.ExpectedRangeLoChar;
        const expected_lo: u21 = if (index == 0) 'A' else 'a';
        if (lo.char_lit != expected_lo) return error.ExpectedRangeLoChar;
        const expected_hi: u21 = if (index == 0) 'F' else 'f';
        const hi = range.hi orelse return error.ExpectedRangeHi;
        if (hi != .char_lit or hi.char_lit != expected_hi) return error.ExpectedRangeHiChar;
    }
}

test "lower: a non-scalar range bound is a typed rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const string_bound: ir.exprs.ExprKind = .{ .literal = .{ .string = .{ .bytes = "a" } } };
    try std.testing.expectError(error.UnsupportedPattern, lowerRangeMatch(alloc, &.{&.{
        .{ .lo = string_bound, .hi = litChar('z'), .inclusive = true },
    }}));
}

// A `for` input is a statement position, so a range iterable must still reach
// the `for` header as a bare Zig range.
test "lower: a for loop over a range keeps the bare Zig range input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "sum_range", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "range_for_test",
        .edition = 2021,
        .items = &.{function_id},
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const types = [_]ir.types.Type{usize_ty};

    const end = try model.e(litInt(8));
    model.exprs.items[end].ty = 0;
    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(0)),
        .end = end,
        .inclusive = false,
    } });
    model.exprs.items[range_expr].ty = 0;
    const index_pattern = try model.pat(.{ .binding = .{
        .name = "i",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    const loop_statement = try model.stmt(.{ .expr = try model.e(.unit) });
    const loop_expr = try model.e(.{ .for_ = .{
        .pattern = index_pattern,
        .iterable = range_expr,
        .body = .{ .statements = &.{loop_statement}, .tail = null, .labelled = null },
        .iter_kind = .{ .slice = {} },
    } });

    const params = try alloc.alloc(ir.items.Param, 0);
    const rust_ir = ir.RustIr{
        .crate_name = "range_for_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &.{.{ .fn_ = .{
                .params = params,
                .ret = usize_ty,
                .generic_params = &.{},
                .body = loop_expr,
                .is_allocating = false,
            } }},
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (0..8) |") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.Range") == null);
}

// A Zig range is a statement, so a range in value position — here the
// receiver of a method call — has to become the `r2z.Range` struct.
test "lower: a range used as a method-call receiver lowers to an r2z.Range literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "stepped", null);
    const method_id = try addLowerEntity(&graph, .method_ref, "step_by", function_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "range_receiver_test",
        .edition = 2021,
        .items = &.{function_id},
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const types = [_]ir.types.Type{usize_ty};

    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(0)),
        .end = try model.e(litInt(8)),
        .inclusive = false,
    } });
    model.exprs.items[range_expr].ty = 0;
    const step = try model.e(litInt(2));
    model.exprs.items[step].ty = 0;
    const args = try alloc.alloc(ir.exprs.NodeId, 1);
    args[0] = step;
    const call = try model.e(.{ .method_call = .{
        .receiver = range_expr,
        .receiver_mode = .value,
        .method = method_id,
        .args = args,
    } });
    model.exprs.items[call].ty = 0;

    const params = try alloc.alloc(ir.items.Param, 0);
    const rust_ir = ir.RustIr{
        .crate_name = "range_receiver_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &.{.{ .fn_ = .{
                .params = params,
                .ret = usize_ty,
                .generic_params = &.{},
                .body = call,
                .is_allocating = false,
            } }},
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.Range{ .start = 0, .end = 8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "0..8") == null);
}

// The inclusive adjustment must survive into the `r2z.Range` end bound.
test "lower: an inclusive range value adds one to the r2z.Range end bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "inclusive", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "range_inclusive_test",
        .edition = 2021,
        .items = &.{function_id},
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const types = [_]ir.types.Type{usize_ty};

    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(1)),
        .end = try model.e(litInt(5)),
        .inclusive = true,
    } });
    model.exprs.items[range_expr].ty = 0;
    const call = try model.e(.{ .method_call = .{
        .receiver = range_expr,
        .receiver_mode = .value,
        .method = try addLowerEntity(&graph, .method_ref, "len", function_id),
        .args = &.{},
    } });
    model.exprs.items[call].ty = 0;

    const params = try alloc.alloc(ir.items.Param, 0);
    const rust_ir = ir.RustIr{
        .crate_name = "range_inclusive_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &.{.{ .fn_ = .{
                .params = params,
                .ret = usize_ty,
                .generic_params = &.{},
                .body = call,
                .is_allocating = false,
            } }},
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const lowered = body.expr orelse return error.ExpectedBodyExpression;
    const call_expr = lowered.*;
    if (call_expr != .call) return error.ExpectedMethodCall;
    const callee = call_expr.call.callee.*;
    if (callee != .field_access) return error.ExpectedFieldAccess;
    const receiver = callee.field_access.target.*;
    if (receiver != .struct_init) return error.ExpectedRangeStructLiteral;
    const type_name = receiver.struct_init.type_name orelse return error.ExpectedRangeTypeName;
    try std.testing.expectEqualStrings("r2z.Range", type_name.named);
    const fields = receiver.struct_init.fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("start", fields[0].name);
    try std.testing.expectEqualStrings("end", fields[1].name);
    const end_bound = fields[1].expr;
    if (end_bound != .bin_op) return error.ExpectedInclusiveEndAdjustment;
    try std.testing.expectEqual(ast.BinOpKind.add, end_bound.bin_op.op);
    try std.testing.expectEqual(@as(i128, 5), literalIntValue(end_bound.bin_op.lhs.*));
    try std.testing.expectEqual(@as(i128, 1), literalIntValue(end_bound.bin_op.rhs.*));
}

// A blanket `impl<T: AsRef<[u8]>> ToHex for T` names a type parameter as its
// self type, so the impl has no declaration body of its own and every method
// is hoisted onto the enclosing module. The receiver still spells `&T`, and
// nothing else in the emitted file binds `T`, so the hoisted function has to
// carry the impl's own type parameter onto its signature.
test "lower: a module-hoisted blanket impl method binds the impl type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const impl_id = try addLowerEntity(&graph, .impl_, "ToHex", null);
    const fn_id = try addLowerEntity(&graph, .fn_, "encode_hex", impl_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "blanket_impl_test",
        .edition = 2021,
        // The method is a child of the impl, not a module item, so the only
        // declaration reaching the file is the hoisted one.
        .items = &.{impl_id},
    });

    var model = Model.init(alloc);
    const impl_segments = try alloc.alloc(ir.types.PathSegment, 1);
    impl_segments[0] = .{ .name = "T", .id = null };
    const impl_type: ir.types.Type = .{ .path = .{ .segments = impl_segments } };
    const ret_segments = try alloc.alloc(ir.types.PathSegment, 1);
    ret_segments[0] = .{ .name = "U", .id = null };
    const ret_type: ir.types.Type = .{ .path = .{ .segments = ret_segments } };
    const receiver_type: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(receiver_type.reference).* = .{ .mut = false, .pointee = impl_type };
    const types = [_]ir.types.Type{impl_type};

    const unit_body = try model.e(.unit);
    model.exprs.items[unit_body].ty = 0;

    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "self", .ty = receiver_type, .span = span };
    const impl_generic_params = try alloc.alloc(ir.types.GenericParam, 1);
    impl_generic_params[0] = .{ .type_ = .{ .name = "T", .bounds = &.{} } };
    const impl_generics: ir.types.Generics = .{
        .params = impl_generic_params,
        .where_clauses = &.{},
    };

    // The body table is indexed by EntityId, and the crate root the hoisted
    // method lands on is itself an entity, so cover the whole symbol table.
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[impl_id] = .{ .impl_ = .{
        .self_ty = impl_type,
        .generics = impl_generics,
    } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = ret_type,
        .generic_params = &.{"U"},
        .body = unit_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "blanket_impl_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    try std.testing.expectEqualStrings("encode_hex", decl.fn_decl.name);

    // The impl's `T` leads, then the method's own `U`, then the receiver that
    // names `T`.
    const fn_params = decl.fn_decl.params;
    try std.testing.expectEqual(@as(usize, 3), fn_params.len);
    try std.testing.expectEqualStrings("T", fn_params[0].name);
    try std.testing.expect(fn_params[0].is_comptime);
    try std.testing.expectEqualStrings("type", fn_params[0].ty.named);
    try std.testing.expectEqualStrings("U", fn_params[1].name);
    try std.testing.expect(fn_params[1].is_comptime);
    try std.testing.expectEqualStrings("type", fn_params[1].ty.named);
    try std.testing.expectEqualStrings("self", fn_params[2].name);
    try std.testing.expect(fn_params[2].ty.ptr.is_const);
    try std.testing.expectEqualStrings("T", fn_params[2].ty.ptr.elem.named);
}

// A `Result` whose error is not a Zig error set lowers to the tagged
// `r2z.Result` union. `Ok(value)` is then a union value, and an anonymous
// `.{}` initializer only coerces where the expected type is already known, so
// the construction has to name its union type.
test "lower: Ok for a tagged Result emits a named r2z.Result initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try addRootModule(&graph, .{
        .crate_name = "result_ok_test",
        .edition = 2021,
        .items = &.{},
    });
    const core_id = try addLowerEntity(&graph, .module, "core", root_id);
    const result_module_id = try addLowerEntity(&graph, .module, "result", core_id);
    const result_enum_id = try addLowerEntity(&graph, .enum_, "Result", result_module_id);
    const fn_id = try addLowerEntity(&graph, .fn_, "build", root_id);
    graph.modules.items[0].items = try alloc.dupe(ir.spine.EntityId, &.{fn_id});
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "core",
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = true,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "result",
        .parent = core_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = true,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    var model = Model.init(alloc);
    const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
    err_segments[0] = .{ .name = "DecodeError", .id = null };
    const err_type: ir.types.Type = .{ .path = .{ .segments = err_segments } };
    const result_type: ir.types.Type = .{ .result = try alloc.create(ir.types.Result) };
    @constCast(result_type.result).* = .{
        .ok = .{ .prim = .u8 },
        .err = err_type,
        .is_error_unionable = false,
    };
    const types = [_]ir.types.Type{result_type};

    const payload = try model.e(litInt(7));
    model.exprs.items[payload].ty = 0;
    const payload_fields = try alloc.alloc(ir.exprs.NodeId, 1);
    payload_fields[0] = payload;
    const ok_expr = try model.e(.{ .enum_variant = .{
        .def = result_enum_id,
        .variant = "Ok",
        .tuple_fields = payload_fields,
        .named_fields = &.{},
    } });
    model.exprs.items[ok_expr].ty = 0;

    const ok_variants = try alloc.alloc(ir.items.Variant, 2);
    const ok_payload = try alloc.alloc(ir.types.Type, 1);
    ok_payload[0] = .{ .prim = .u8 };
    const err_payload = try alloc.alloc(ir.types.Type, 1);
    err_payload[0] = err_type;
    ok_variants[0] = .{ .name = "Ok", .fields = .{ .tuple = ok_payload }, .discriminant = null };
    ok_variants[1] = .{ .name = "Err", .fields = .{ .tuple = err_payload }, .discriminant = null };

    // The body table is indexed by EntityId, and the extern `core`/`result`
    // module entities are entities too, so cover the whole symbol table.
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[result_enum_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = ok_variants,
    } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = result_type,
        .generic_params = &.{},
        .body = ok_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "result_ok_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const fn_body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const tail = fn_body.expr orelse return error.ExpectedBodyExpression;
    if (tail.* != .struct_init) return error.ExpectedResultInitializer;

    // The initializer names its union, so it stays a `Result` wherever no
    // expected type reaches it.
    const type_name = tail.struct_init.type_name orelse return error.ExpectedResultTypeName;
    if (type_name != .generic) return error.ExpectedResultTypeName;
    try std.testing.expectEqualStrings("r2z.Result", type_name.generic.name);
    try std.testing.expectEqual(@as(usize, 2), type_name.generic.params.len);

    const fields = tail.struct_init.fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("Ok", fields[0].name);
    try std.testing.expectEqual(@as(i128, 7), literalIntValue(fields[0].expr));
}

// `?` on a `Result` propagates through Rust's `From` conversion. When the
// operand and the enclosing function share one tagged error type that
// conversion is the identity, so the propagation is a switch over the two
// tags — never a Zig `try`, which only applies to error unions.
test "lower: ? on a Result-typed value propagates through the tagged union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const error_id = try addLowerEntity(&graph, .enum_, "DecodeError", null);
    const fn_id = try addLowerEntity(&graph, .fn_, "run", null);
    // A local binding of that function, not a module item of its own.
    const pending_id = try addLowerEntity(&graph, .const_, "pending", fn_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "result_try_test",
        .edition = 2021,
        .items = &.{ error_id, fn_id },
    });

    var model = Model.init(alloc);
    const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
    err_segments[0] = .{ .name = "DecodeError", .id = error_id };
    const err_type: ir.types.Type = .{ .path = .{ .segments = err_segments } };
    // A data-carrying error enum cannot be a Zig error set, so this `Result`
    // is the tagged union rather than an error union.
    const pending_type: ir.types.Type = .{ .result = try alloc.create(ir.types.Result) };
    @constCast(pending_type.result).* = .{
        .ok = .{ .prim = .unit },
        .err = err_type,
        .is_error_unionable = true,
    };
    const return_type: ir.types.Type = .{ .result = try alloc.create(ir.types.Result) };
    @constCast(return_type.result).* = .{
        .ok = .{ .prim = .u8 },
        .err = err_type,
        .is_error_unionable = false,
    };
    const types = [_]ir.types.Type{ pending_type, return_type };

    const operand = try model.e(.{ .path = .{ .def = pending_id, .generic_args = &.{} } });
    model.exprs.items[operand].ty = 0;
    const question = try model.e(.{ .try_ = .{ .inner = operand } });
    model.exprs.items[question].ty = 1;

    const error_variants = try alloc.alloc(ir.items.Variant, 1);
    const detail_fields = try alloc.alloc(ir.items.Field, 1);
    detail_fields[0] = .{ .name = "index", .ty = .{ .prim = .usize }, .visibility = .public, .span = span };
    error_variants[0] = .{
        .name = "InvalidCharacter",
        .fields = .{ .named = detail_fields },
        .discriminant = null,
    };

    // The body table is indexed by EntityId, and the crate root is itself an
    // entity, so cover the whole symbol table.
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[error_id] = .{ .enum_ = .{ .kind = .data, .variants = error_variants } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = return_type,
        .generic_params = &.{},
        .body = question,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "result_try_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);
    var decl: ?ast.FnDecl = null;
    for (package.files[0].decls) |candidate| {
        if (candidate == .fn_decl and std.mem.eql(u8, candidate.fn_decl.name, "run")) {
            decl = candidate.fn_decl;
        }
    }
    const run_decl = decl orelse return error.ExpectedFunctionDeclaration;
    const fn_body = run_decl.body orelse return error.ExpectedFunctionBody;
    const tail = fn_body.expr orelse return error.ExpectedBodyExpression;
    if (tail.* != .match_expr) return error.ExpectedTaggedResultPropagation;
    if (tail.match_expr.target.* != .ident) return error.ExpectedPropagatedOperand;

    const arms = tail.match_expr.arms;
    try std.testing.expectEqual(@as(usize, 2), arms.len);
    const ok_selector = arms[0].patterns[0];
    if (ok_selector != .enum_literal) return error.ExpectedOkTag;
    try std.testing.expectEqualStrings("Ok", ok_selector.enum_literal);
    const err_selector = arms[1].patterns[0];
    if (err_selector != .enum_literal) return error.ExpectedErrTag;
    try std.testing.expectEqualStrings("Err", err_selector.enum_literal);

    // The error prong returns the enclosing function's own `Err` payload.
    const err_capture = arms[1].capture orelse return error.ExpectedErrCapture;
    const err_body = arms[1].body;
    if (err_body != .return_expr) return error.ExpectedErrReturn;
    const err_value = err_body.return_expr orelse return error.ExpectedErrReturn;
    if (err_value.* != .struct_init) return error.ExpectedErrReturn;
    const err_field = err_value.struct_init.fields[0];
    try std.testing.expectEqualStrings("Err", err_field.name);
    if (err_field.expr != .ident) return error.ExpectedErrCapture;
    try std.testing.expectEqualStrings(err_capture.name, err_field.expr.ident);

    // No `try` survives: a Zig `try` cannot apply to a tagged union.
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "try ") == null);
    // One `return`, not a nested return node: the prong body is the return.
    try std.testing.expect(std.mem.indexOf(u8, source, "return return") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "switch (pending)") != null);
}

// A field-less variant of a source enum has no bare Zig spelling once the
// enum lives in another module: `OddLength` names nothing there, so the
// reference has to be qualified exactly like the enum's own type. These two
// tests pin both halves of that rule, and the third keeps the genuine Zig
// error-set spelling out of it.
fn buildUnitVariantFixture(
    alloc: std.mem.Allocator,
    crate_name: []const u8,
    error_module: ?[]const u8,
) !ir.RustIr {
    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try addRootModule(&graph, .{
        .crate_name = crate_name,
        .edition = 2021,
        .items = &.{},
    });
    // The child module row cannot list its items until the enum exists, so
    // keep the row index and fill it in once the entity ids are known.
    var enum_module_row: ?usize = null;
    var enum_parent: ir.spine.EntityId = root_id;
    if (error_module) |module_name| {
        enum_parent = try addLowerEntity(&graph, .module, module_name, root_id);
        enum_module_row = try graph.addModule(.{
            .id = 0,
            .kind = .file,
            .name = module_name,
            .parent = root_id,
            .source_path = "src/error.rs",
            .is_crate = false,
            .is_extern = false,
            .span = span,
            .items = &.{},
            .attributes = &.{},
        });
    }
    const error_enum_id = try addLowerEntity(&graph, .enum_, "FromHexError", enum_parent);
    const fn_id = try addLowerEntity(&graph, .fn_, "run", root_id);
    graph.modules.items[0].items = try alloc.dupe(ir.spine.EntityId, &.{fn_id});
    if (enum_module_row) |row| {
        graph.modules.items[row].items = try alloc.dupe(
            ir.spine.EntityId,
            &.{error_enum_id},
        );
    }

    var model = Model.init(alloc);
    const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
    err_segments[0] = .{ .name = "FromHexError", .id = error_enum_id };
    const err_type: ir.types.Type = .{ .path = .{ .segments = err_segments } };
    const types = [_]ir.types.Type{err_type};

    const variant_expr = try model.e(.{ .enum_variant = .{
        .def = error_enum_id,
        .variant = "OddLength",
        .tuple_fields = &.{},
        .named_fields = &.{},
    } });
    model.exprs.items[variant_expr].ty = 0;
    const ret_expr = try model.e(.{ .return_ = .{ .value = variant_expr } });
    model.exprs.items[ret_expr].ty = 0;

    const error_variants = try alloc.alloc(ir.items.Variant, 2);
    error_variants[0] = .{ .name = "OddLength", .fields = .none, .discriminant = null };
    error_variants[1] = .{
        .name = "InvalidStringLength",
        .fields = .none,
        .discriminant = null,
    };

    // The body table is indexed by EntityId, and the crate root and every
    // child module are entities too, so cover the whole symbol table.
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[error_enum_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = error_variants,
    } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = err_type,
        .generic_params = &.{},
        .body = ret_expr,
        .is_allocating = false,
    } };

    return ir.RustIr{
        .crate_name = crate_name,
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };
}

/// Emitted value of `run`'s `return` in a unit-variant fixture.
fn unitVariantReturnIdent(alloc: std.mem.Allocator, rust_ir: *const ir.RustIr) ![]const u8 {
    const package = try lower.lowerRustIr(alloc, rust_ir, null);
    const file = package.files[0];
    const decl = file.decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const fn_body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const tail = fn_body.expr orelse return error.ExpectedBodyExpression;
    if (tail.* != .return_expr) return error.ExpectedReturnExpression;
    const value = tail.return_expr orelse return error.ExpectedReturnValue;
    if (value.* != .ident) return error.ExpectedVariantIdentifier;
    return value.ident;
}

test "lower: a unit variant of an enum in another module is module-qualified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var rust_ir = try buildUnitVariantFixture(alloc, "unit_variant_module_test", "error");
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 2), package.files.len);

    var root_file: ?ast.File = null;
    for (package.files) |file| {
        if (std.mem.eql(u8, file.path, "src/root.zig")) {
            root_file = file;
            break;
        }
    }
    const file = root_file orelse return error.RootModuleMissing;

    // The variant reference carries the same module alias the enum's own type
    // carries: the alias is the only name `OddLength` can resolve through.
    const decl = file.decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    try std.testing.expectEqualStrings("error_1.FromHexError", decl.fn_decl.ret_type.named);
    const fn_body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const tail = fn_body.expr orelse return error.ExpectedBodyExpression;
    if (tail.* != .return_expr) return error.ExpectedReturnExpression;
    const value = (tail.return_expr orelse return error.ExpectedReturnValue).*;
    if (value != .ident) return error.ExpectedVariantIdentifier;
    try std.testing.expectEqualStrings("error_1.FromHexError.OddLength", value.ident);

    // `error` is a reserved Zig identifier, so the alias carries a suffix and
    // the reference has to spell that alias, not the module name.
    const source = try emit.emitFile(alloc, &file);
    try std.testing.expect(
        std.mem.indexOf(u8, source, "return error_1.FromHexError.OddLength;") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, source, "const error_1 = @import(\"./error.zig\");") != null,
    );
}

test "lower: a unit variant of a root-module enum carries no module prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var rust_ir = try buildUnitVariantFixture(alloc, "unit_variant_root_test", null);
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);

    // The enum is declared beside `run`, so its own name already reaches the
    // reference. Qualifying it further would name a module that does not exist.
    const ident = try unitVariantReturnIdent(alloc, &rust_ir);
    try std.testing.expectEqualStrings("FromHexError.OddLength", ident);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "@import") == null);
}

test "lower: a unit variant returned from a Zig error union stays error.<Variant>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const core_id = try addLowerEntity(&graph, .module, "core", null);
    const result_module_id = try addLowerEntity(&graph, .module, "result", core_id);
    const result_enum_id = try addLowerEntity(&graph, .enum_, "Result", result_module_id);
    const error_id = try addLowerEntity(&graph, .enum_, "DecodeError", null);
    const fn_id = try addLowerEntity(&graph, .fn_, "run", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "unit_variant_error_set_test",
        .edition = 2021,
        .items = &.{ error_id, fn_id },
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "core",
        .parent = null,
        .source_path = null,
        .is_crate = false,
        .is_extern = true,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "result",
        .parent = core_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = true,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    var model = Model.init(alloc);
    const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
    err_segments[0] = .{ .name = "DecodeError", .id = error_id };
    const err_type: ir.types.Type = .{ .path = .{ .segments = err_segments } };
    // Every `DecodeError` variant is field-free, so the `Result` err slot is a
    // Zig error set and the enclosing return is an error union.
    const return_type: ir.types.Type = .{ .result = try alloc.create(ir.types.Result) };
    @constCast(return_type.result).* = .{
        .ok = .{ .prim = .u8 },
        .err = err_type,
        .is_error_unionable = true,
    };
    const types = [_]ir.types.Type{return_type};

    const variant_expr = try model.e(.{ .enum_variant = .{
        .def = error_id,
        .variant = "OddLength",
        .tuple_fields = &.{},
        .named_fields = &.{},
    } });
    model.exprs.items[variant_expr].ty = 0;
    // `Err(<unit variant of the error set>)` — the payload is the value under
    // test, not a payload of its own.
    const payload_fields = try alloc.alloc(ir.exprs.NodeId, 1);
    payload_fields[0] = variant_expr;
    const err_expr = try model.e(.{ .enum_variant = .{
        .def = result_enum_id,
        .variant = "Err",
        .tuple_fields = payload_fields,
        .named_fields = &.{},
    } });
    model.exprs.items[err_expr].ty = 0;

    const result_variants = try alloc.alloc(ir.items.Variant, 2);
    const ok_payload = try alloc.alloc(ir.types.Type, 1);
    ok_payload[0] = .{ .prim = .u8 };
    const err_payload = try alloc.alloc(ir.types.Type, 1);
    err_payload[0] = err_type;
    result_variants[0] = .{ .name = "Ok", .fields = .{ .tuple = ok_payload }, .discriminant = null };
    result_variants[1] = .{ .name = "Err", .fields = .{ .tuple = err_payload }, .discriminant = null };
    const error_variants = try alloc.alloc(ir.items.Variant, 2);
    error_variants[0] = .{ .name = "OddLength", .fields = .none, .discriminant = null };
    error_variants[1] = .{ .name = "InvalidStringLength", .fields = .none, .discriminant = null };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[result_enum_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = result_variants,
    } };
    body_rows[error_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = error_variants,
    } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = return_type,
        .generic_params = &.{},
        .body = err_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "unit_variant_error_set_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    // A Zig error set spells its field-free variants `error.Name`; module
    // qualification must not reach in and rewrite that.
    try std.testing.expect(std.mem.indexOf(u8, source, "error.OddLength") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "DecodeError.OddLength") == null);
}

/// `[u8; N]`, the self type a `trait` impl names when the trait has one impl
/// per supported length.
fn u8ArrayType(alloc: std.mem.Allocator, len: u64) !ir.types.Type {
    const array = try alloc.create(ir.types.Array);
    array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = len } };
    return .{ .array = array };
}

/// Three `impl FromHex for [u8; N]` blocks whose self types carry no
/// declaration body, plus a caller that reaches each method by its own
/// entity.
///
/// Every method therefore hoists to module scope under the same source name
/// `from_hex`, and only the impl's self type tells them apart. The third block
/// repeats the first self type, so it has to collapse onto the first
/// emission rather than add a third function.
fn buildSelfTypeHoistIr(alloc: std.mem.Allocator) !ir.RustIr {
    var graph = ir.graph.CrateGraph.init(alloc);
    const one_impl_id = try addLowerEntity(&graph, .impl_, "FromHex for [u8; 1]", null);
    const one_fn_id = try addLowerEntity(&graph, .fn_, "from_hex", one_impl_id);
    const two_impl_id = try addLowerEntity(&graph, .impl_, "FromHex for [u8; 2]", null);
    const two_fn_id = try addLowerEntity(&graph, .fn_, "from_hex", two_impl_id);
    const repeat_impl_id = try addLowerEntity(&graph, .impl_, "FromHex for [u8; 1]", null);
    const repeat_fn_id = try addLowerEntity(&graph, .fn_, "from_hex", repeat_impl_id);
    const check_fn_id = try addLowerEntity(&graph, .fn_, "check_from_hex", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "self_type_hoist",
        .edition = 2021,
        .items = &.{ one_impl_id, two_impl_id, repeat_impl_id, check_fn_id },
    });

    var model = Model.init(alloc);
    const one_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = try model.e(litInt(1)),
        .labelled = null,
    } });
    const two_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = try model.e(litInt(2)),
        .labelled = null,
    } });
    const repeat_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = try model.e(litInt(3)),
        .labelled = null,
    } });

    // Each call names its own impl's method entity, which is what the
    // frontend resolves a qualified `<[u8; N] as FromHex>::from_hex` to.
    const check_statements = try alloc.alloc(ir.exprs.NodeId, 3);
    for ([_]ir.spine.EntityId{ one_fn_id, two_fn_id, repeat_fn_id }, 0..) |callee, index| {
        const call = try model.e(.{ .call = .{
            .call_kind = .{ .associated = callee },
            .args = &.{},
        } });
        check_statements[index] = try model.stmt(.{ .expr = call });
    }
    const check_body = try model.e(.{ .block = .{
        .statements = check_statements,
        .tail = try model.e(.{ .unit = {} }),
        .labelled = null,
    } });

    const trait_path: ir.types.Path = .{
        .segments = &.{.{ .name = "FromHex", .id = null }},
    };
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[one_impl_id] = .{ .impl_ = .{
        .self_ty = try u8ArrayType(alloc, 1),
        .trait_path = trait_path,
    } };
    body_rows[one_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = try u8ArrayType(alloc, 1),
        .body = one_body,
    } };
    body_rows[two_impl_id] = .{ .impl_ = .{
        .self_ty = try u8ArrayType(alloc, 2),
        .trait_path = trait_path,
    } };
    body_rows[two_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = try u8ArrayType(alloc, 2),
        .body = two_body,
    } };
    body_rows[repeat_impl_id] = .{ .impl_ = .{
        .self_ty = try u8ArrayType(alloc, 1),
        .trait_path = trait_path,
    } };
    body_rows[repeat_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = try u8ArrayType(alloc, 1),
        .body = repeat_body,
    } };
    body_rows[check_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = check_body,
    } };

    return .{
        .crate_name = "self_type_hoist",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &.{},
            .bodies = body_rows,
        },
    };
}

test "lower: trait impls for different self types emit one function each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rust_ir = try buildSelfTypeHoistIr(alloc);
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    // Both self types survive. Neither declaration may be dropped in favour
    // of the first impl's, and they may not share a name.
    try std.testing.expect(std.mem.indexOf(u8, source, "fn from_hex(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn from_hex__u8_2(") != null);
    // The repeated `[u8; 1]` impl collapses onto the first, so the module
    // holds two declarations, not three.
    var from_hex_count: usize = 0;
    for (package.files[0].decls) |decl| {
        if (decl != .fn_decl) continue;
        if (std.mem.startsWith(u8, decl.fn_decl.name, "from_hex")) from_hex_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), from_hex_count);
}

test "lower: each call site names the function for its own self type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rust_ir = try buildSelfTypeHoistIr(alloc);
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    // `<[u8; 1] as FromHex>::from_hex` and the repeat of that impl both reach
    // the un-suffixed function; `<[u8; 2] as FromHex>::from_hex` reaches the
    // one that carries the array length.
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, source, "\n    from_hex();"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "\n    from_hex__u8_2();"),
    );
}

test "lower: two impls for one self type still emit a single function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rust_ir = try buildSelfTypeHoistIr(alloc);
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);

    // The second `[u8; 1]` impl is a redeclaration, not a new self type.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fn from_hex("));
    try std.testing.expect(std.mem.indexOf(u8, source, "fn from_hex__u8_1(") == null);
}

// `core::ops::Range` has no `step_by` field in Zig, and the runtime builds the
// adapter with a free function that takes the source by value. A range
// receiver must reach that constructor, not a field access.
test "lower: a range receiver calling step_by lowers to the runtime adapter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "stepped", null);
    const method_id = try addLowerEntity(&graph, .method_ref, "step_by", function_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "step_by_test",
        .edition = 2021,
        .items = &.{function_id},
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const range_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "ops", "Range" },
        .args = &.{usize_ty},
    } };
    const step_by_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "StepBy" },
        .args = &.{range_ty},
    } };
    const types = [_]ir.types.Type{ usize_ty, range_ty, step_by_ty };

    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(0)),
        .end = try model.e(litInt(8)),
        .inclusive = false,
    } });
    model.exprs.items[range_expr].ty = 1;
    const step = try model.e(litInt(2));
    const args = try alloc.alloc(ir.exprs.NodeId, 1);
    args[0] = step;
    const call = try model.e(.{ .method_call = .{
        .receiver = range_expr,
        .receiver_mode = .value,
        .method = method_id,
        .args = args,
    } });
    model.exprs.items[call].ty = 2;

    const rust_ir = ir.RustIr{
        .crate_name = "step_by_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &.{.{ .fn_ = .{
                .params = try alloc.alloc(ir.items.Param, 0),
                .ret = step_by_ty,
                .generic_params = &.{},
                .body = call,
                .is_allocating = false,
            } }},
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.stepBy(r2z.Range{ .start = 0, .end = 8 }, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".step_by(") == null);
}

// A `Zip` is a struct, not something a Zig `for` can walk, so a loop over one
// has to become an explicit `next` walk rather than a `for` header naming it.
test "lower: a for over a zipped adapter lowers to an explicit next loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "encode_to_slice", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "zip_for_test",
        .edition = 2021,
        .items = &.{function_id},
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const range_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "ops", "Range" },
        .args = &.{usize_ty},
    } };
    const step_by_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "StepBy" },
        .args = &.{range_ty},
    } };
    const zip_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "Zip" },
        .args = &.{ step_by_ty, step_by_ty },
    } };
    const types = [_]ir.types.Type{ usize_ty, range_ty, step_by_ty, zip_ty };

    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(0)),
        .end = try model.e(litInt(8)),
        .inclusive = false,
    } });
    model.exprs.items[range_expr].ty = 1;
    const zipped = try model.e(.{ .path = .{ .def = function_id, .generic_args = &.{} } });
    model.exprs.items[zipped].ty = 3;

    const index_pattern = try model.pat(.{ .binding = .{
        .name = "i",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    const pair_pattern = try model.pat(.{ .tuple = .{
        .elements = &.{ index_pattern, index_pattern },
        .rest = false,
    } });
    const loop_statement = try model.stmt(.{ .expr = try model.e(.unit) });
    const loop_expr = try model.e(.{ .for_ = .{
        .pattern = pair_pattern,
        .iterable = zipped,
        .body = .{ .statements = &.{loop_statement}, .tail = null, .labelled = null },
        .iter_kind = .{ .multi = &.{ range_expr, zipped } },
    } });

    const rust_ir = ir.RustIr{
        .crate_name = "zip_for_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &.{.{ .fn_ = .{
                .params = try alloc.alloc(ir.items.Param, 0),
                .ret = usize_ty,
                .generic_params = &.{},
                .body = loop_expr,
                .is_allocating = false,
            } }},
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "Zip(") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var __r2z_iter_1 = encode_to_slice;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".next()") != null);
    // The plain input still drives the loop, so the loop keeps its Zig shape.
    try std.testing.expect(std.mem.indexOf(u8, source, "for (0..8) |") != null);
}

// Regression: an ordinary range loop is unaffected by the iterator path and
// still reaches the `for` header as a bare Zig range.
test "lower: an ordinary range for loop keeps the bare Zig range input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "sum_range", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "plain_range_for_test",
        .edition = 2021,
        .items = &.{function_id},
    });

    var model = Model.init(alloc);
    const usize_ty = ir.types.Type{ .prim = .usize };
    const range_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "ops", "Range" },
        .args = &.{usize_ty},
    } };
    const types = [_]ir.types.Type{ usize_ty, range_ty };

    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(0)),
        .end = try model.e(litInt(8)),
        .inclusive = false,
    } });
    model.exprs.items[range_expr].ty = 1;
    const index_pattern = try model.pat(.{ .binding = .{
        .name = "i",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    const loop_statement = try model.stmt(.{ .expr = try model.e(.unit) });
    const loop_expr = try model.e(.{ .for_ = .{
        .pattern = index_pattern,
        .iterable = range_expr,
        .body = .{ .statements = &.{loop_statement}, .tail = null, .labelled = null },
        .iter_kind = .{ .slice = {} },
    } });

    const rust_ir = ir.RustIr{
        .crate_name = "plain_range_for_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = &.{.{ .fn_ = .{
                .params = try alloc.alloc(ir.items.Param, 0),
                .ret = usize_ty,
                .generic_params = &.{},
                .body = loop_expr,
                .is_allocating = false,
            } }},
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "for (0..8) |") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.Range") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "__r2z_iter") == null);
}

test "lower: to_string renders a Display receiver into an owned runtime string" {
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
    const color_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = "Color",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // The crate's own evidence for the `Display` bound.
    const display_impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = "Display for Color",
        .span = span,
        .visibility = .public,
        .parent = color_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fmt_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "fmt",
        .span = span,
        .visibility = .public,
        .parent = display_impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // `to_string` has no declaration in the crate; the frontend reaches it
    // through a synthesized method reference, so the backend must classify it
    // from the receiver type alone.
    const to_string_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = "to_string",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const render_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "render",
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const color_ty: ir.types.Type = .{ .path = .{ .segments = &.{.{ .name = "Color", .id = color_id }} } };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
    } };

    const exprs_store = [_]ir.exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
        },
        // `Color.red` — the receiver, typed as its owning enum.
        .{
            .id = 2,
            .span = span,
            .ty = 0,
            .kind = .{ .enum_variant = .{
                .def = color_id,
                .variant = "red",
                .tuple_fields = &.{},
                .named_fields = &.{},
            } },
        },
        // `Color.red.to_string()`
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .value,
                .method = to_string_id,
                .args = &.{},
            } },
        },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .block = .{ .statements = &.{}, .tail = 3, .labelled = null } } },
    };
    const types_store = [_]ir.types.Type{color_ty};

    try model.bodies.append(alloc, .none);
    try model.bodies.append(alloc, .{ .enum_ = .{
        .kind = .c_like,
        .variants = &.{
            .{ .name = "red", .fields = .{ .none = {} }, .discriminant = null },
        },
    } });
    try model.bodies.append(alloc, .{ .impl_ = .{
        .self_ty = color_ty,
        .trait_path = .{ .segments = &.{.{ .name = "Display", .id = null }} },
    } });
    try model.bodies.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 1,
    } });
    try model.bodies.append(alloc, .none);
    try model.bodies.append(alloc, .{ .fn_ = .{
        .params = &.{.{ .name = "self", .ty = color_ty, .span = span }},
        .ret = string_ty,
        .body = 4,
    } });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{ color_id, display_impl_id, fmt_id, render_id }),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "colors",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "colors",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = &exprs_store,
            .stmts = &.{},
            .pats = &.{},
            .types = &types_store,
            .bodies = try model.bodies.toOwnedSlice(alloc),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    var render_decl: ?ast.FnDecl = null;
    for (package.files[0].decls) |decl| {
        if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, "render")) {
            render_decl = decl.fn_decl;
        }
    }
    const render = render_decl orelse return error.TestUnexpectedResult;

    // The allocator leads the runtime call and the enclosing callable declares
    // it, exactly as for every other allocating runtime call.
    const allocator_param = for (render.params) |param| {
        if (std.mem.eql(u8, param.name, "allocator")) break param;
    } else return error.MissingToStringAllocatorParam;
    const allocator_type = switch (allocator_param.ty) {
        .named => |name| name,
        else => return error.UnexpectedToStringAllocatorType,
    };
    try std.testing.expectEqualStrings("std.mem.Allocator", allocator_type);

    const render_body = render.body orelse return error.MissingToStringBody;
    const tail = render_body.expr orelse return error.MissingToStringTail;
    const tail_try = switch (tail.*) {
        .unary_op => |unary| unary,
        else => return error.MissingToStringTry,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.try_op, tail_try.op);
    const to_string_call = switch (tail_try.operand.*) {
        .call => |call| call,
        else => return error.MissingToStringCall,
    };
    const callee_name = switch (to_string_call.callee.*) {
        .ident => |name| name,
        else => return error.UnexpectedToStringCallee,
    };
    try std.testing.expectEqualStrings("r2z.format.toString", callee_name);
    try std.testing.expectEqual(@as(usize, 2), to_string_call.args.len);
    const leading_arg = switch (to_string_call.args[0]) {
        .ident => |name| name,
        else => return error.UnexpectedToStringLeadingArgument,
    };
    try std.testing.expectEqualStrings("allocator", leading_arg);

    const source = try emit.emitFile(alloc, &package.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "try r2z.format.toString(allocator,") != null);
    // The owned `String` result must reach the caller, and the runtime import
    // must be pulled in with it.
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.alloc.String") != null);
}

// A Rust raw-pointer cast reinterprets one address under a different
// pointee, so the pointee width is free to change. `utils.rs` in
// xxhash-rust spells exactly this: a `*const u8` cursor cast to the
// caller's `*const T`, where `T` is a generic parameter whose layout is not
// known until monomorphization. Requiring both pointees to be primitives of
// equal width rejected that cast outright, which made the whole crate
// untranslatable. The source type is fully recovered here; only the target
// pointee is a type parameter, and `lowerType` names it.
test "lower: raw pointer cast to a generic pointee reinterprets the address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "chunk_ref", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "generic_pointer_cast",
        .edition = 2021,
        .items = &.{function_id},
    });

    // The `*const T` pointee: a path with no resolved id names the generic
    // parameter itself, exactly as the frontend records a type parameter.
    const type_param_segments = [_]ir.types.PathSegment{.{ .name = "T", .id = null }};
    const generic_pointee: ir.types.Type = .{ .path = .{
        .segments = &type_param_segments,
    } };

    const source_ptr: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(source_ptr.raw_ptr).* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const target_ptr: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(target_ptr.raw_ptr).* = .{ .mut = false, .pointee = generic_pointee };
    const types = [_]ir.types.Type{ source_ptr, target_ptr, .{ .prim = .u8 } };

    // The cast operand is a real function parameter, so `lowerPathExpr`
    // resolves it to the declared identifier `cursor`.
    const cursor_def = try addLowerEntity(&graph, .field, "cursor", function_id);
    const cursor = ir.exprs.Expr{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = cursor_def, .generic_args = &.{} } },
    };
    const cast = ir.exprs.Expr{
        .id = 1,
        .span = span,
        .ty = 1,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 0,
            .source_type = source_ptr,
            .target = 1,
        } },
    };
    const body = ir.exprs.Expr{
        .id = 2,
        .span = span,
        .ty = 1,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } },
    };
    const params = [_]ir.items.Param{.{ .name = "cursor", .ty = source_ptr, .span = span }};
    const function_body = ir.bodies.BodyKind{ .fn_ = .{
        .params = &params,
        .ret = target_ptr,
        .generic_params = &.{"T"},
        .body = 2,
        .is_allocating = false,
    } };
    const body_table = [_]ir.bodies.BodyKind{function_body};
    const expressions = [_]ir.exprs.Expr{ cursor, cast, body };
    const rust_ir = ir.RustIr{
        .crate_name = "generic_pointer_cast",
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
    // The address is reinterpreted, not converted: a `@ptrCast` to the
    // generic pointee, with the source pointer type preserved on the cast.
    try std.testing.expect(std.mem.indexOf(u8, source, "@ptrCast(cursor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[*]align(1) const T") != null);
}

// The widening must not become a blanket accept. A pointer to an unsized
// type is a fat pointer, and Zig refuses `@ptrCast` from a thin pointer
// into one (`cannot infer length of slice from many pointer`), so this
// combination still has to be refused precisely rather than emitted.
test "lower: raw pointer cast to an unsized pointee stays unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try addLowerEntity(&graph, .fn_, "wide_ref", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "unsized_pointer_cast",
        .edition = 2021,
        .items = &.{function_id},
    });

    const slice_ty: ir.types.Type = .{ .slice = try alloc.create(ir.types.Slice) };
    @constCast(slice_ty.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const source_ptr: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(source_ptr.raw_ptr).* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const target_ptr: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(target_ptr.raw_ptr).* = .{ .mut = false, .pointee = slice_ty };
    const types = [_]ir.types.Type{ source_ptr, target_ptr, slice_ty };

    const cursor_def = try addLowerEntity(&graph, .field, "cursor", function_id);
    const cursor = ir.exprs.Expr{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = cursor_def, .generic_args = &.{} } },
    };
    const cast = ir.exprs.Expr{
        .id = 1,
        .span = span,
        .ty = 1,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 0,
            .source_type = source_ptr,
            .target = 1,
        } },
    };
    const body = ir.exprs.Expr{
        .id = 2,
        .span = span,
        .ty = 1,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } },
    };
    const params = [_]ir.items.Param{.{ .name = "cursor", .ty = source_ptr, .span = span }};
    const function_body = ir.bodies.BodyKind{ .fn_ = .{
        .params = &params,
        .ret = target_ptr,
        .body = 2,
        .is_allocating = false,
    } };
    const body_table = [_]ir.bodies.BodyKind{function_body};
    const expressions = [_]ir.exprs.Expr{ cursor, cast, body };
    const rust_ir = ir.RustIr{
        .crate_name = "unsized_pointer_cast",
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

    try std.testing.expectError(
        error.UnsupportedExpression,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

// `utils.rs` in xxhash-rust calls `*get_aligned_chunk_ref(input, offset)`
// from `get_aligned_chunk<T>`. The callee declares `-> &T`, so no argument
// mentions `T` and argument unification cannot bind it; the caller's own
// return position is the only context left, and it names `T` too. The
// dereference consumes one borrow layer between them, so the callee's type
// is compared at `T` rather than `&T` and the caller's parameter forwards
// verbatim, exactly as this door's own doc comment describes.
test "lower: a callee whose type appears only behind a borrow takes the caller's parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const chunk_ref_id = try addLowerEntity(&graph, .fn_, "chunk_ref", null);
    const chunk_id = try addLowerEntity(&graph, .fn_, "chunk", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "forwarded_generic",
        .edition = 2021,
        .items = &.{ chunk_ref_id, chunk_id },
    });

    const type_param: ir.types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "T", .id = null },
    } } };
    const borrowed_t: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(borrowed_t.reference).* = .{ .mut = false, .pointee = type_param };
    const types = [_]ir.types.Type{ type_param, borrowed_t, .{ .prim = .u8 } };

    const input_def = try addLowerEntity(&graph, .field, "input", chunk_id);
    const input = try model.e(.{ .path = .{ .def = input_def, .generic_args = &.{} } });
    model.exprs.items[input].ty = 2;
    const call = try model.e(.{ .call = .{
        .call_kind = .{ .free = chunk_ref_id },
        .args = &.{input},
    } });
    model.exprs.items[call].ty = 1;
    const deref = try model.e(.{ .unary = .{ .op = .deref, .operand = call } });
    model.exprs.items[deref].ty = 0;
    const caller_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = deref,
        .labelled = null,
    } });
    model.exprs.items[caller_block].ty = 0;
    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 1;
    const callee_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[callee_block].ty = 1;

    while (model.bodies.items.len <= chunk_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[chunk_ref_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "input", .ty = .{ .prim = .u8 }, .span = span }},
        .ret = borrowed_t,
        .generic_params = &.{"T"},
        .body = callee_block,
        .is_allocating = false,
    } };
    model.bodies.items[chunk_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "input", .ty = .{ .prim = .u8 }, .span = span }},
        .ret = type_param,
        .generic_params = &.{"T"},
        .body = caller_block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "forwarded_generic",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    // The comptime parameter is forwarded by name, not dropped and not
    // invented: `chunk_ref(T, input)`.
    try std.testing.expect(std.mem.indexOf(u8, source, "chunk_ref(T,") != null);
}

// The new shape handling must not divert a call the earlier doors already
// bind. Here the callee mentions `T` in a *parameter*, so argument
// unification binds it to a concrete `u32` argument. The return position
// names the caller's own `U`, so if the return door were consulted first or
// took precedence, `T` would wrongly become `U` instead of `u32`.
test "lower: argument unification still binds a parameter the return position also names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const sink_id = try addLowerEntity(&graph, .fn_, "sink", null);
    const caller_id = try addLowerEntity(&graph, .fn_, "caller", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "argument_wins",
        .edition = 2021,
        .items = &.{ sink_id, caller_id },
    });

    const caller_param: ir.types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "U", .id = null },
    } } };
    const callee_param: ir.types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "T", .id = null },
    } } };
    const borrowed_callee_param: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(borrowed_callee_param.reference).* = .{ .mut = false, .pointee = callee_param };
    const types = [_]ir.types.Type{
        caller_param,
        callee_param,
        borrowed_callee_param,
        .{ .prim = .u32 },
    };

    const seed = try model.e(litInt(7));
    model.exprs.items[seed].ty = 3;
    const call = try model.e(.{ .call = .{
        .call_kind = .{ .free = sink_id },
        .args = &.{seed},
    } });
    model.exprs.items[call].ty = 2;
    const caller_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });
    model.exprs.items[caller_block].ty = 0;
    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 2;
    const callee_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[callee_block].ty = 2;

    while (model.bodies.items.len <= caller_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[sink_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "seed", .ty = callee_param, .span = span }},
        .ret = borrowed_callee_param,
        .generic_params = &.{"T"},
        .body = callee_block,
        .is_allocating = false,
    } };
    model.bodies.items[caller_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "seed", .ty = .{ .prim = .u32 }, .span = span }},
        .ret = caller_param,
        .generic_params = &.{"U"},
        .body = caller_block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "argument_wins",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    const source = try emit.emitFile(alloc, &package.files[0]);
    // Bound from the argument, so `u32` — not the caller's `U`.
    try std.testing.expect(std.mem.indexOf(u8, source, "sink(u32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sink(U,") == null);
}

// With no argument mention and no usable return context there is nothing to
// bind, and that must stay a precise error rather than a panic or a
// silently dropped parameter.
test "lower: a generic call with no binding context anywhere still fails precisely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const orphan_id = try addLowerEntity(&graph, .fn_, "orphan", null);
    const caller_id = try addLowerEntity(&graph, .fn_, "unrelated_caller", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "unbound_generic",
        .edition = 2021,
        .items = &.{ orphan_id, caller_id },
    });

    const first_param: ir.types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "A", .id = null },
    } } };
    const second_param: ir.types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "B", .id = null },
    } } };
    // A tuple return: unifying it against a primitive matches nothing, so
    // neither parameter is reachable from any context.
    const pair: ir.types.Type = .{ .tuple = &.{ first_param, second_param } };
    const types = [_]ir.types.Type{ first_param, second_param, pair, .{ .prim = .u8 } };

    const seed = try model.e(litInt(7));
    model.exprs.items[seed].ty = 3;
    const call = try model.e(.{ .call = .{
        .call_kind = .{ .free = orphan_id },
        .args = &.{seed},
    } });
    model.exprs.items[call].ty = 2;
    // A statement, not the tail. The caller returns `u8`; a tuple return
    // unifies against nothing, and no parameter appears in an argument, so
    // no door can bind `A` or `B`.
    const statement = try model.stmt(.{ .expr = call });
    const statements = [_]ir.exprs.NodeId{statement};
    const caller_block = try model.e(.{ .block = .{
        .statements = &statements,
        .tail = seed,
        .labelled = null,
    } });
    model.exprs.items[caller_block].ty = 3;
    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 2;
    const callee_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[callee_block].ty = 2;

    while (model.bodies.items.len <= caller_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[orphan_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "seed", .ty = .{ .prim = .u8 }, .span = span }},
        .ret = pair,
        .generic_params = &.{ "A", "B" },
        .body = callee_block,
        .is_allocating = false,
    } };
    model.bodies.items[caller_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "seed", .ty = .{ .prim = .u8 }, .span = span }},
        .ret = .{ .prim = .u8 },
        .body = caller_block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "unbound_generic",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    try std.testing.expectError(
        error.GenericInferenceFailed,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

// Rust `pub mod xxh32;` at the crate root re-exports that module's namespace
// as part of the crate's public API. A top-level
// `pub const xxh32 = @import("./xxh32.zig");` is a Zig declaration, so the
// root genuinely declares its API instead of only referencing it — which is
// what the empty-root guard looks for, and what keeps the submodule
// reachable from outside the package.
test "lower: a public root module is re-exported as a public declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const public_mod_id = try addLowerEntity(&graph, .module, "xxh32", null);
    const public_fn_id = try addLowerEntity(&graph, .fn_, "xxh32", public_mod_id);
    // Visibility is what separates this case from the negative one below;
    // `addLowerEntity` defaults to public, so both are set explicitly.
    const private_mod_id = try addLowerEntity(&graph, .module, "utils", null);
    const private_fn_id = try addLowerEntity(&graph, .fn_, "helper", private_mod_id);
    graph.symbol_table.entities.items[public_mod_id].visibility = .public;
    graph.symbol_table.entities.items[private_mod_id].visibility = .private;

    const types_store = [_]ir.types.Type{.{ .prim = .unit }};
    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 0;
    const unit_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[unit_block].ty = 0;

    while (model.bodies.items.len <= private_fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[public_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = unit_block,
        .is_allocating = false,
    } };
    model.bodies.items[private_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = unit_block,
        .is_allocating = false,
    } };

    const root_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{
        public_mod_id,
        private_mod_id,
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
        .items = root_items,
        .attributes = &.{},
    });
    const public_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{public_fn_id});
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "xxh32",
        .parent = null,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = public_items,
        .attributes = &.{},
    });
    const private_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{private_fn_id});
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "utils",
        .parent = null,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = private_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "reexport",
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "reexport",
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
    const source = try emit.emitFile(alloc, &package.files[0]);
    // The public module is a `pub const` declaration in the root.
    try std.testing.expect(
        std.mem.indexOf(u8, source, "pub const xxh32 = @import(\"./xxh32.zig\");") != null,
    );
    // The private module keeps a plain private import and is not re-exported.
    try std.testing.expect(
        std.mem.indexOf(u8, source, "const utils = @import(\"./utils.zig\");") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const utils") == null);
}

// A `pub mod` is promoted to a `pub const name = @import("./name.zig")` decl
// before the test-reachability pass runs, so a scan that reads only the import
// list loses the one reference that made Zig analyze the submodule. Without
// it a translated test module that nothing else uses compiles away and its
// tests stop running — silently, because `zig build test` still succeeds over
// zero assertions. This pins the reference for a PROMOTED import, next to the
// re-export test above that pins the promotion itself.
test "lower: a promoted public module import still gets a test reachability reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const support_mod_id = try addLowerEntity(&graph, .module, "support", null);
    const support_test_id = try addLowerEntity(&graph, .fn_, "support_check", support_mod_id);
    // The `#[test]` marker is what makes this a test block, and therefore what
    // makes the submodule worth a reference to.
    graph.symbol_table.entities.items[support_test_id].attributes = &.{
        .{ .name = "test", .meta = "", .known = true },
    };

    const types_store = [_]ir.types.Type{.{ .prim = .unit }};
    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 0;
    const unit_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[unit_block].ty = 0;

    while (model.bodies.items.len <= support_test_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[support_test_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = unit_block,
        .is_allocating = false,
    } };

    const root_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{
        support_mod_id,
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
        .items = root_items,
        .attributes = &.{},
    });
    const support_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{support_test_id});
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "support",
        .parent = null,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = support_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "reach",
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "reach",
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
    const source = try emit.emitFile(alloc, &package.files[0]);
    // The promotion moved the import into a decl, and the reachability
    // reference has to follow it there.
    try std.testing.expect(
        std.mem.indexOf(u8, source, "pub const support = @import(\"./support.zig\");") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, source, "translated tests reachable through ./support.zig") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, source, "_ = support;") != null,
    );
}

// The re-export must not widen the generated API. A Rust `mod utils;` is
// private, so promoting it to `pub const` would publish a namespace the
// source never exposed, and a consumer relying on the current surface would
// silently see more of the package than the crate declared.
test "lower: a private root module is never re-exported as public" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    // Explicitly private, even though the crate root is public.
    const private_mod_id = try addLowerEntity(&graph, .module, "utils", null);
    const private_fn_id = try addLowerEntity(&graph, .fn_, "helper", private_mod_id);
    graph.symbol_table.entities.items[private_mod_id].visibility = .private;

    const types_store = [_]ir.types.Type{.{ .prim = .unit }};
    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 0;
    const unit_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[unit_block].ty = 0;

    while (model.bodies.items.len <= private_fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[private_fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = unit_block,
        .is_allocating = false,
    } };

    const root_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{private_mod_id});
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
    const private_items = try alloc.dupe(ir.spine.EntityId, &[_]ir.spine.EntityId{private_fn_id});
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .file,
        .name = "utils",
        .parent = null,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = private_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "private_module",
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "private_module",
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
    const source = try emit.emitFile(alloc, &package.files[0]);
    // Still a plain private import, and definitely not a `pub const`.
    try std.testing.expect(
        std.mem.indexOf(u8, source, "const utils = @import(\"./utils.zig\");") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const utils") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const") == null);
}

// Rule case 1 of 3 — a *sized* pointee asserts alignment.
// `&*p` where `p: *const u32` came from a raw pointer. The raw pointer made
// no alignment promise, so the place has alignment 1, and Rust's `&u32`
// promises `align_of::<u32>()`. `@alignCast` is how Zig asserts that.
test "lower: a reference to a sized raw-pointer deref asserts alignment" {
    const emitted = try emitAlignmentFixture(.prim_u32);
    defer std.testing.allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "@alignCast(") != null);
    // The place is still indexed, not dereferenced: a many-item pointer
    // needs `[0]`.
    try std.testing.expect(std.mem.indexOf(u8, emitted, "[0]") != null);
}

// Rule case 2 of 3 — an *unsized* pointee does not.
// `&*p` where `p: *const [u8]`. A slice is a fat pointer in Rust and a
// Zig slice, not a pointer with an alignment, so there is nothing to
// assert and an `@alignCast` here would be meaningless.
test "lower: a reference to an unsized raw-pointer deref does not assert alignment" {
    const emitted = try emitAlignmentFixture(.slice_u8);
    defer std.testing.allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "@alignCast") == null);
}

// Rule case 3 of 3 — a place not reached through a raw pointer does not.
// This is the shape a `#[repr(packed)]` struct's field has: the field is
// reached by a field access, its real alignment is whatever the packing
// gave it, and claiming `align_of::<T>()` would be a lie. The rule's
// premise ("reached by dereferencing a raw pointer") does not hold, so no
// assertion is emitted.
test "lower: a reference to a struct field does not assert alignment" {
    const emitted = try emitFieldReferenceFixture();
    defer std.testing.allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "@alignCast") == null);
}

// Negative for the unaligned sibling. A chunk read that is deliberately not
// aligned must contain no alignment assertion anywhere — an `@alignCast` on
// the *deref* rather than the address-of would introduce a runtime check
// Rust never promised, and panic on exactly the data this shape exists to
// read. This is why the assertion is attached to the address-of.
test "lower: an unaligned chunk read emits no alignment assertion" {
    const emitted = try emitUnalignedReadFixture();
    defer std.testing.allocator.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "@alignCast") == null);
}

const AlignmentPointee = enum { prim_u32, slice_u8 };

// Lower `fn read(p: *const T) -> &T { &*p }` and return the emitted root
// source, so the rule cases can assert on the same shape.
fn emitAlignmentFixture(comptime pointee: AlignmentPointee) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "read", null);
    const param_def = try addLowerEntity(&graph, .field, "p", fn_id);

    const pointee_ty: ir.types.Type = switch (pointee) {
        .prim_u32 => .{ .prim = .u32 },
        .slice_u8 => blk: {
            const slice: ir.types.Type = .{ .slice = try alloc.create(ir.types.Slice) };
            @constCast(slice.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
            break :blk slice;
        },
    };
    const pointer_ty: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(pointer_ty.raw_ptr).* = .{ .mut = false, .pointee = pointee_ty };
    const reference_ty: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(reference_ty.reference).* = .{ .mut = false, .pointee = pointee_ty };
    const types = [_]ir.types.Type{ pointer_ty, reference_ty, pointee_ty };

    const cursor = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[cursor].ty = 0;
    const deref = try model.e(.{ .unary = .{ .op = .deref, .operand = cursor } });
    model.exprs.items[deref].ty = 1;
    const reference = try model.e(.{ .unary = .{ .op = .{ .ref = .shared }, .operand = deref } });
    model.exprs.items[reference].ty = 1;
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = reference,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 1;

    while (model.bodies.items.len <= fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[fn_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "p", .ty = pointer_ty, .span = span }},
        .ret = reference_ty,
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "alignment_rule",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

/// Lower `fn field(o: Wrapper) -> &u32 { &o.value }` and return the emitted
/// source: a reference to a struct field, not to a raw-pointer dereference.
fn emitFieldReferenceFixture() ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const struct_id = try addLowerEntity(&graph, .struct_, "Wrapper", null);
    const field_def = try addLowerEntity(&graph, .field, "value", struct_id);
    const fn_id = try addLowerEntity(&graph, .fn_, "field", null);
    const param_def = try addLowerEntity(&graph, .field, "o", fn_id);

    const reference_ty: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(reference_ty.reference).* = .{ .mut = false, .pointee = .{ .prim = .u32 } };
    const types = [_]ir.types.Type{ reference_ty, .{ .prim = .u32 } };

    const wrapper = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[wrapper].ty = 1;
    const accessed = try model.e(.{ .field = .{
        .base = wrapper,
        .field = try alloc.dupe(u8, "value"),
        .resolved = field_def,
    } });
    const reference = try model.e(.{ .unary = .{ .op = .{ .ref = .shared }, .operand = accessed } });
    model.exprs.items[reference].ty = 0;
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = reference,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 0;
    const unit = try model.e(.{ .unit = {} });
    model.exprs.items[unit].ty = 0;
    const struct_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit,
        .labelled = null,
    } });
    model.exprs.items[struct_body].ty = 1;

    while (model.bodies.items.len <= fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[struct_id] = .{ .struct_ = .{
        .fields = &.{
            .{ .name = "value", .ty = .{ .prim = .u32 }, .visibility = .public, .span = span },
        },
    } };
    model.bodies.items[fn_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "o", .ty = .{ .prim = .u32 }, .span = span }},
        .ret = reference_ty,
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "alignment_field",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

/// Lower the `get_unaligned_chunk` shape — a raw-pointer cast whose value is
/// read straight back out, with no address taken — and return the source.
fn emitUnalignedReadFixture() ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "get_unaligned_chunk", null);
    const param_def = try addLowerEntity(&graph, .field, "cursor", fn_id);

    const type_param_segments = [_]ir.types.PathSegment{.{ .name = "T", .id = null }};
    const generic_pointee: ir.types.Type = .{ .path = .{ .segments = &type_param_segments } };
    const source_ptr: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(source_ptr.raw_ptr).* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const target_ptr: ir.types.Type = .{ .raw_ptr = try alloc.create(ir.types.RawPtr) };
    @constCast(target_ptr.raw_ptr).* = .{ .mut = false, .pointee = generic_pointee };
    const types = [_]ir.types.Type{ source_ptr, target_ptr, generic_pointee };

    const cursor = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[cursor].ty = 0;
    const cast = try model.e(.{ .cast = .{
        .kind = .as_,
        .operand = cursor,
        .source_type = source_ptr,
        .target = 1,
    } });
    model.exprs.items[cast].ty = 1;
    // The value is read back out, never address-taken.
    const read = try model.e(.{ .unary = .{ .op = .deref, .operand = cast } });
    model.exprs.items[read].ty = 2;
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = read,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 2;

    while (model.bodies.items.len <= fn_id) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[fn_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "cursor", .ty = source_ptr, .span = span }},
        .ret = generic_pointee,
        .generic_params = &.{"T"},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "unaligned_read",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

/// The receiver shape an `unwrap_err` fixture is built around.
const UnwrapErrReceiver = enum {
    /// `Result<u8, DecodeError>` whose error variant carries a payload. The
    /// shape cannot be a Zig error set, so the value is the tagged
    /// `r2z.Result` union, which holds the error value.
    payload_error,
    /// `Result<u8, DecodeError>` whose variants are all field-free, so the
    /// value is a Zig error union and holds no error value at all.
    error_set_error,
    /// Not a `Result` at all.
    plain_primitive,
};

/// Lower `value.unwrap_err(..)` on a receiver of `shape` and return the
/// emitted source. `argument_count` past zero is deliberate: every
/// `r2z.Result` method enforces its arity, so an extra argument is what
/// distinguishes "the call was classified as the Result method" from "the
/// method was not recognized and fell through to a bare field call".
fn unwrapErrFixtureSource(
    alloc: std.mem.Allocator,
    shape: UnwrapErrReceiver,
    borrow_receiver: bool,
    argument_count: usize,
) ![]const u8 {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "checked", null);
    const method_id = try addLowerEntity(&graph, .method_ref, "unwrap_err", fn_id);
    const value_id = try addLowerEntity(&graph, .const_, "value", fn_id);
    const error_id = try addLowerEntity(&graph, .enum_, "DecodeError", null);
    // A receiver that is not a `Result` has no error entity, so the module
    // declares nothing that could name one.
    const module_items: []const ir.spine.EntityId = if (shape == .plain_primitive)
        &.{fn_id}
    else
        &.{ fn_id, error_id };
    _ = try addRootModule(&graph, .{
        .crate_name = "unwrap_err_test",
        .edition = 2021,
        .items = module_items,
    });

    const ok_type: ir.types.Type = .{ .prim = .u8 };
    const receiver_ty: ir.types.Type = switch (shape) {
        .plain_primitive => ok_type,
        .payload_error, .error_set_error => blk: {
            const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
            err_segments[0] = .{ .name = "DecodeError", .id = error_id };
            const result = try alloc.create(ir.types.Result);
            result.* = .{
                .ok = ok_type,
                .err = .{ .path = .{ .segments = err_segments } },
                .is_error_unionable = true,
            };
            break :blk .{ .result = result };
        },
    };
    const declared_receiver_ty: ir.types.Type = if (borrow_receiver) blk: {
        const pointee = try alloc.create(ir.types.Ref);
        pointee.* = .{ .mut = false, .pointee = receiver_ty };
        break :blk .{ .reference = pointee };
    } else receiver_ty;
    const types = [_]ir.types.Type{ ok_type, receiver_ty, declared_receiver_ty };

    const receiver_expr = try model.e(.{ .path = .{ .def = value_id, .generic_args = &.{} } });
    model.exprs.items[receiver_expr].ty = 2;
    const argument_nodes = try alloc.alloc(ir.exprs.NodeId, argument_count);
    for (argument_nodes, 0..) |*slot, index| {
        slot.* = try model.e(litInt(@intCast(index + 1)));
        model.exprs.items[slot.*].ty = 0;
    }
    const call = try model.e(.{ .method_call = .{
        .receiver = receiver_expr,
        .receiver_mode = .value,
        .method = method_id,
        .args = argument_nodes,
    } });
    const block = try model.e(.{ .block = .{ .statements = &.{}, .tail = call, .labelled = null } });

    const error_variants = try alloc.alloc(ir.items.Variant, 2);
    const payload = try alloc.alloc(ir.types.Type, 1);
    payload[0] = .{ .prim = .u8 };
    if (shape == .payload_error) {
        error_variants[0] = .{ .name = "OddLength", .fields = .{ .tuple = payload }, .discriminant = null };
    } else {
        error_variants[0] = .{ .name = "OddLength", .fields = .none, .discriminant = null };
    }
    error_variants[1] = .{ .name = "InvalidStringLength", .fields = .none, .discriminant = null };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "value", .ty = declared_receiver_ty, .span = span }},
        .ret = ok_type,
        .generic_params = &.{},
        .body = block,
        .is_allocating = false,
    } };
    body_rows[value_id] = .{ .const_ = .{ .ty = receiver_ty, .init = receiver_expr } };
    if (shape != .plain_primitive) {
        body_rows[error_id] = .{ .enum_ = .{ .kind = .data, .variants = error_variants } };
    }

    const rust_ir = ir.RustIr{
        .crate_name = "unwrap_err_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types,
            .bodies = body_rows,
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

// `is_error_unionable` records that the frontend was ASKED to treat the error
// as a Zig error set. `FromHexError::InvalidHexCharacter { c, index }` cannot
// be one — a Zig error set is a list of payload-free names — so `lowerType`
// emits the tagged `r2z.Result` union, and that union holds the error value
// `unwrap_err` hands back. Gating on the flag alone refused every Result
// method on such a receiver.
test "lower: unwrap_err on a payload-carrying error reaches the runtime Result method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The `r2z.Result` arm enforces a zero-argument `unwrap_err`, so the
    // rejection is what proves the call was classified at all. Unrecognized,
    // this fixture emits `value.unwrap_err(1)` and lowers without complaint.
    try std.testing.expectError(
        error.UnsupportedStandardMethod,
        unwrapErrFixtureSource(alloc, .payload_error, false, 1),
    );
}

test "lower: unwrap_err on a borrowed tagged Result dereferences the receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try unwrapErrFixtureSource(alloc, .payload_error, true, 0);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, ".*.unwrap_err()") != null);
}

// The negative that keeps the widening honest: a `Result` that really does
// lower to a Zig error union has no error value, so `unwrap_err` stays
// unrecognized there and must not reach the runtime Result method.
test "lower: unwrap_err on a real error-set Result stays unrecognized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try unwrapErrFixtureSource(alloc, .error_set_error, false, 1);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "value.unwrap_err(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".*") == null);
}

// `unwrap_err` is not a method every type has. A receiver that is not a
// `Result` must keep refusing rather than borrow the tagged-union lowering.
test "lower: unwrap_err on a receiver that is not a Result stays unrecognized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try unwrapErrFixtureSource(alloc, .plain_primitive, false, 1);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "value.unwrap_err(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".*") == null);
}

/// Lower `generate_iter(5).collect::<Vec<_>>()` against an `impl Iterator`
/// whose only bound is `Iterator<Item = (usize, usize)>`, and return the
/// emitted source.
///
/// `element_is_placeholder` selects what the turbofish carries: the element
/// inference filled in from the bound, or the `_` that survives when the
/// bound declares no `Item`. `element_is_usize` builds the second negative, a
/// `collect` on a receiver that names no iterator carrier at all.
fn collectFixtureSource(
    alloc: std.mem.Allocator,
    element_is_placeholder: bool,
    element_is_usize: bool,
) ![]const u8 {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const generator_id = try addLowerEntity(&graph, .fn_, "generate_iter", null);
    const method_id = try addLowerEntity(&graph, .method_ref, "collect", null);
    const checked_id = try addLowerEntity(&graph, .fn_, "checked", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "collect_test",
        .edition = 2021,
        .items = &.{ generator_id, method_id, checked_id },
    });
    graph.symbol_table.entities.items[method_id].parent = checked_id;

    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const range_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "ops", "Range" },
        .args = &.{usize_ty},
    } };
    const step_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "StepBy" },
        .args = &.{range_ty},
    } };
    const zip_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "iter", "Zip" },
        .args = &.{ step_ty, step_ty },
    } };
    const tuple_elements = try alloc.alloc(ir.types.Type, 2);
    tuple_elements[0] = usize_ty;
    tuple_elements[1] = usize_ty;
    const item_binding = try alloc.alloc(ir.types.AssociatedTypeBinding, 1);
    item_binding[0] = .{ .name = "Item", .ty = .{ .tuple = tuple_elements } };
    const bounds = try alloc.alloc(ir.types.Bound, 1);
    bounds[0] = .{
        .path = .{ .segments = &.{.{ .name = "Iterator", .id = null }} },
        .associated_types = item_binding,
    };
    const zip_pointer = try alloc.create(ir.types.Type);
    zip_pointer.* = zip_ty;
    const opaque_ty: ir.types.Type = .{ .@"opaque" = .{
        .bounds = bounds,
        .concrete = zip_pointer,
    } };
    const element: ir.types.Type = if (element_is_placeholder) blk: {
        const placeholder = try alloc.alloc([]const u8, 1);
        placeholder[0] = "_";
        break :blk .{ .external_nominal = .{ .path = placeholder, .args = &.{} } };
    } else if (element_is_usize) usize_ty else .{ .tuple = tuple_elements };
    const element_args = try alloc.alloc(ir.types.Type, 1);
    element_args[0] = element;
    const collected_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = element_args,
    } };
    const types = [_]ir.types.Type{ usize_ty, range_ty, step_ty, zip_ty, opaque_ty, collected_ty };

    const range_expr = try model.e(.{ .range = .{
        .start = try model.e(litInt(0)),
        .end = try model.e(litInt(5)),
        .inclusive = false,
    } });
    model.exprs.items[range_expr].ty = 1;
    const length_expr = try model.e(litInt(5));
    model.exprs.items[length_expr].ty = 0;
    const call_args = try alloc.alloc(ir.exprs.NodeId, 1);
    call_args[0] = length_expr;
    const receiver = try model.e(.{ .call = .{
        .call_kind = .{ .free = generator_id },
        .args = call_args,
    } });
    // The second negative retypes the very same receiver expression, so the
    // emitted text is identical and only the classification differs.
    model.exprs.items[receiver].ty = if (element_is_usize) 0 else 4;
    const turbofish = try alloc.alloc(ir.types.Type, 1);
    turbofish[0] = collected_ty;
    const collect_call = try model.e(.{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .value,
        .method = method_id,
        .args = &.{},
        .generic_args = turbofish,
    } });
    const block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = collect_call,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[generator_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "len", .ty = usize_ty, .span = span }},
        .ret = opaque_ty,
        .generic_params = &.{},
        .body = range_expr,
        .is_allocating = false,
    } };
    // The collected vector is an argument to the assertion in the source, not
    // the function's return, so nothing here forces the element type into a
    // signature. A refused turbofish therefore fails on the call alone.
    body_rows[checked_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .bool },
        .generic_params = &.{},
        .body = block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "collect_test",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = try model.pats.toOwnedSlice(model.a()),
            .types = &types,
            .bodies = body_rows,
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

// `collect::<Vec<_>>()` on an `impl Iterator` is a runtime call into the
// owned-vector collector: the turbofish names the container, inference filled
// its element from the bound's own `Item`, and the receiver is an opaque whose
// concrete names the carrier. Before this arm the call fell through to a bare
// `generate_iter(5).collect()` against a type no Zig declaration names.
test "lower: collect on an opaque iterator lowers to the owned-vector collector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try collectFixtureSource(alloc, false, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "try r2z.alloc.vec_collect(struct { usize, usize }, allocator, generate_iter(5))",
    ) != null);
    // The owned vector is built with the call site's allocator, so the
    // enclosing callable gains one and its return becomes fallible.
    try std.testing.expect(std.mem.indexOf(u8, source, "allocator: std.mem.Allocator") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".collect()") == null);
}

// The negative that keeps this honest: Rust writes the element down once, as
// the `Item` of the iterator's bound. A bound that declares no `Item` leaves
// the turbofish's `_` standing, and a placeholder is not a type — admitting it
// would collect into a vector whose element nothing in the program names.
test "lower: collect with an unresolved element turbofish is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(
        error.UnsupportedStandardMethod,
        collectFixtureSource(alloc, true, false),
    );
}

// The receiver is what makes this a runtime iterator method at all. A
// receiver that names no carrier must keep every ordinary method name for
// itself instead of borrowing the collector.
test "lower: collect on a receiver that is not an iterator is not the collector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try collectFixtureSource(alloc, false, true);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "generate_iter(5).collect()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "vec_collect") == null);
}

// A blanket `impl<T: AsRef<[u8]>> ToHex for T` has no concrete self type, so
// the frontend gives the impl the enclosing module as its target. Its methods
// hoist onto that module and are emitted as free functions taking
// `comptime T: type` — the same shape a method on a named type produces. This
// is hex/src/lib.rs:137, the structural blocker before the method_ref
// dispatch itself.
test "lower: a blanket impl targeting the enclosing module is valid topology" {
    const emitted = try emitBlanketImplFixture(.blanket);
    defer std.testing.allocator.free(emitted);
    // Hoisted as a free function whose self is a comptime type parameter.
    try std.testing.expect(std.mem.indexOf(u8, emitted, "comptime T: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "fn encode_hex") != null);
}

// The topology guard is load-bearing for every fixture, so the new branch
// must not become a blanket accept. An impl whose target is neither a type
// declaration nor a crate module is still nonsense, and must refuse.
test "lower: an impl targeting neither a type nor a crate module is still refused" {
    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        emitBlanketImplFixture(.impl_parent_is_const),
    );
}

// A module that is not a crate scope is not a blanket impl's enclosing scope
// either; a stray module parent means the impl was never attached to
// anything real.
test "lower: a blanket impl on a non-crate module is still refused" {
    try std.testing.expectError(
        error.GenericDefinitionMismatch,
        emitBlanketImplFixture(.non_crate_module),
    );
}

const BlanketShape = enum {
    /// `impl<T: AsRef<[u8]>> ToHex for T` — impl parent is the crate root.
    blanket,
    /// The method's parent impl points at a `const`, not a type.
    impl_parent_is_const,
    /// The impl's parent is a nested module rather than the crate root.
    non_crate_module,
};

/// Build `impl ... for T { fn encode_hex(&self) }` with the given topology and
/// lower it, returning the emitted root source. The negative shapes are
/// expected to fail, so they propagate the error instead.
fn emitBlanketImplFixture(comptime shape: BlanketShape) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const trait_id = try addLowerEntity(&graph, .trait_, "ToHex", null);
    const method_id = try addLowerEntity(&graph, .fn_, "encode_hex", null);
    const type_param_segments = [_]ir.types.PathSegment{.{ .name = "T", .id = null }};
    const type_param: ir.types.Type = .{ .path = .{ .segments = &type_param_segments } };

    const impl_id = try addLowerEntity(&graph, .impl_, "ToHex", null);
    graph.symbol_table.entities.items[method_id].parent = impl_id;

    // The crate root is the target a blanket impl hoists onto, and only
    // `addRootModule` creates the root module ENTITY as well as its row. With
    // the row alone `moduleEntityId` resolves to nothing, the lookup key falls
    // back to the dense row id, and the hoisted declaration is dropped.
    const root_entity_id = try addRootModule(&graph, .{
        .crate_name = "blanket_impl",
        .edition = 2021,
        // `addRootModule` parents a null-parent item to the root entity,
        // which is the `.blanket` shape. The two negative shapes move the
        // impl onto a parent of their own afterwards.
        .items = &.{impl_id},
    });

    // The impl's parent is exactly what the topology guard inspects, so each
    // shape has to name a genuinely different parent. One switch arm shared
    // by two shapes would leave both tests asserting opposite outcomes for
    // the same IR.
    switch (shape) {
        .blanket => {},
        .impl_parent_is_const => {
            // Neither a type declaration nor a crate module: the guard's
            // `else` arm refuses it.
            const const_id = try addLowerEntity(&graph, .const_, "NOT_A_TYPE", root_entity_id);
            graph.symbol_table.entities.items[impl_id].parent = const_id;
            // The impl stays a crate-root item; only its parent edge is wrong.
            graph.modules.items[0].items = try alloc.dupe(
                ir.spine.EntityId,
                &.{ const_id, impl_id },
            );
        },
        .non_crate_module => {
            // A real nested module: the `.module` entity parented to the root
            // plus the matching module row. `is_crate` is the only flag the
            // guard reads, so the row has to exist and has to say false.
            const child_id = try addLowerEntity(&graph, .module, "hex", root_entity_id);
            _ = try graph.addModule(.{
                .id = 0,
                .kind = .@"inline",
                .name = "hex",
                .parent = root_entity_id,
                .source_path = null,
                .is_crate = false,
                .is_extern = false,
                .span = span,
                .items = try alloc.dupe(ir.spine.EntityId, &.{impl_id}),
                .attributes = &.{},
            });
            graph.symbol_table.entities.items[impl_id].parent = child_id;
            graph.modules.items[0].items = try alloc.dupe(ir.spine.EntityId, &.{});
        },
    }

    const types = [_]ir.types.Type{ type_param, .{ .prim = .u8 } };

    const unit_expr = try model.e(.{ .unit = {} });
    model.exprs.items[unit_expr].ty = 1;
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 1;

    // The body table is indexed by EntityId and the crate root the hoisted
    // method lands on is itself an entity, so it spans the whole table.
    while (model.bodies.items.len < graph.symbol_table.count()) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }
    model.bodies.items[method_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "self", .ty = type_param, .span = span }},
        .ret = .{ .prim = .u8 },
        .body = body,
        .is_allocating = false,
    } };
    // `T: AsRef<[u8]>` is the DECLARED bound. The element type of the concrete
    // self type comes from here, never from the magnitudes of the values at a
    // call site — an unsuffixed literal has no type until context fixes one.
    const bound_slice: ir.types.Type = .{ .slice = try alloc.create(ir.types.Slice) };
    @constCast(bound_slice.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const generics = ir.types.Generics{
        .params = &.{.{ .type_ = .{
            .name = "T",
            .bounds = &.{.{ .path = .{ .segments = &.{
                .{ .name = "core", .id = null },
                .{ .name = "convert", .id = null },
                .{ .name = "AsRef", .id = null },
            } }, .args = &.{bound_slice} }},
        } }},
        .where_clauses = &.{},
    };
    model.bodies.items[impl_id] = .{ .impl_ = .{
        .self_ty = type_param,
        .trait_path = .{ .segments = &.{
            .{ .name = "ToHex", .id = trait_id },
        } },
        .generics = generics,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "blanket_impl",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(model.a()),
            .stmts = try model.stmts.toOwnedSlice(model.a()),
            .pats = &.{},
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(model.a()),
        },
    };

    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

// ── Round-2 backend regressions ─────────────────────────────────────────────

/// A crate root module row plus its crate entry, for fixtures that build
/// their own symbol table rather than going through `addRootModule` (which
/// needs the item ids up front, and these fixtures only learn them after the
/// parameter entities exist).
fn addBareCrate(
    graph: *ir.graph.CrateGraph,
    alloc: std.mem.Allocator,
    crate_name: []const u8,
    root_id: ir.spine.EntityId,
    items: []const ir.spine.EntityId,
) !void {
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, items),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = crate_name,
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
}

/// Lower `rust_ir` and emit the crate root file, so a test can assert on the
/// Zig source a fixture produces rather than on the AST that produced it.
fn emitRootSource(alloc: std.mem.Allocator, rust_ir: *const ir.RustIr) ![]const u8 {
    const package = try lower.lowerRustIr(alloc, rust_ir, null);
    return emit.emitFile(alloc, &package.files[0]);
}

// ── FIX F: `alloc::string::ToString` is a runtime trait, not a declaration ──

test "lower: a private alloc::string::ToString import lowers with no declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "alloc", "string", "ToString" },
        "ToString",
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
    // The trait is reached through a blanket impl on `Display`, never named as
    // a Zig container, so it declares nothing and imports nothing.
    try std.testing.expectEqual(@as(usize, 0), pkg.files[0].decls.len);
    for (pkg.files[0].imports) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.local_name, "ToString"));
    }
}

test "lower: an unknown alloc::string import is still refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "alloc", "string", "ToStrng" },
        "ToStrng",
        false,
    );
    const rust_ir = ir.RustIr{
        .crate_name = "external_uses",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    // Admitting `ToString` must not turn the arm into a blanket allow: an
    // unrecognised `alloc::string` type still has no lowerable target.
    try std.testing.expectError(
        error.UnsupportedExternalUse,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

// ── FIX G: a shift amount is a `u5` in Zig ──────────────────────────────────

test "lower: every shift spelling narrows its amount to the Zig shift type" {
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
    const a_def = try addLowerEntity(&graph, .const_, "a", root_id);
    const y_def = try addLowerEntity(&graph, .const_, "y", root_id);
    const x_def = try addLowerEntity(&graph, .const_, "x", root_id);
    const shl_id = try addLowerEntity(&graph, .fn_, "shl", root_id);
    const shr_id = try addLowerEntity(&graph, .fn_, "shr", root_id);
    const assign_id = try addLowerEntity(&graph, .fn_, "shift_assign", root_id);
    try addBareCrate(&graph, alloc, "shift_amount", root_id, &.{ shl_id, shr_id, assign_id });

    var model = Model.init(alloc);
    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const types = [_]ir.types.Type{u32_ty};

    // `fn shl(a: u32, y: u32) -> u32 { a << y }`
    const shl_lhs = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[shl_lhs].ty = 0;
    const shl_rhs = try model.e(.{ .path = .{ .def = y_def, .generic_args = &.{} } });
    model.exprs.items[shl_rhs].ty = 0;
    const shl_tail = try model.e(.{ .binary = .{
        .op = .shl,
        .overflow = .checked,
        .lhs = shl_lhs,
        .rhs = shl_rhs,
    } });
    model.exprs.items[shl_tail].ty = 0;
    const shl_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = shl_tail,
        .labelled = null,
    } });

    // `fn shr(a: u32, y: u32) -> u32 { a >> y }`
    const shr_lhs = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[shr_lhs].ty = 0;
    const shr_rhs = try model.e(.{ .path = .{ .def = y_def, .generic_args = &.{} } });
    model.exprs.items[shr_rhs].ty = 0;
    const shr_tail = try model.e(.{ .binary = .{
        .op = .shr,
        .overflow = .checked,
        .lhs = shr_lhs,
        .rhs = shr_rhs,
    } });
    model.exprs.items[shr_tail].ty = 0;
    const shr_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = shr_tail,
        .labelled = null,
    } });

    // `fn shift_assign(a: u32, y: u32) -> u32 { let mut x = a; x <<= y; x }`
    const bind_x = try model.pat(.{ .binding = .{
        .name = "x",
        .mode = .value,
        .mutable = true,
    } });
    const init_x = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[init_x].ty = 0;
    const let_stmt = try model.stmt(.{ .let = .{
        .pattern = bind_x,
        .init = init_x,
        .ty = null,
    } });
    const assign_target = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
    model.exprs.items[assign_target].ty = 0;
    const assign_value = try model.e(.{ .path = .{ .def = y_def, .generic_args = &.{} } });
    model.exprs.items[assign_value].ty = 0;
    const shift_assign = try model.e(.{ .assign = .{
        .target = assign_target,
        .op = .shl,
        .value = assign_value,
        .overflow = .checked,
    } });
    model.exprs.items[shift_assign].ty = 0;
    const assign_stmt = try model.stmt(.{ .expr = shift_assign });
    const statements = try alloc.alloc(ir.exprs.NodeId, 2);
    statements[0] = let_stmt;
    statements[1] = assign_stmt;
    const assign_tail = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
    model.exprs.items[assign_tail].ty = 0;
    const assign_body = try model.e(.{ .block = .{
        .statements = statements,
        .tail = assign_tail,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 2);
    params[0] = .{ .name = "a", .ty = u32_ty, .span = span };
    params[1] = .{ .name = "y", .ty = u32_ty, .span = span };
    body_rows[shl_id] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = shl_body,
        .is_allocating = false,
    } };
    body_rows[shr_id] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = shr_body,
        .is_allocating = false,
    } };
    body_rows[assign_id] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = assign_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "shift_amount",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // Zig takes the shift amount in `u5`. A bare `y: u32` is a compile error
    // (`expected type 'u5', found 'u32'`), so all four spellings narrow it.
    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "a << @intCast(y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "a >> @intCast(y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "x <<= @intCast(y)") != null);
}

// ── FIX H: a tuple-carrying variant is a value of its union ─────────────────

test "lower: a tuple-carrying variant used as a value names its union" {
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
    const enum_id = try addLowerEntity(&graph, .enum_, "Kind", root_id);
    const fn_id = try addLowerEntity(&graph, .fn_, "run", root_id);
    try addBareCrate(&graph, alloc, "tuple_variant", root_id, &.{ enum_id, fn_id });

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const segments = try alloc.alloc(ir.types.PathSegment, 1);
    segments[0] = .{ .name = "Kind", .id = enum_id };
    const kind_ty: ir.types.Type = .{ .path = .{ .segments = segments } };
    const types = [_]ir.types.Type{ kind_ty, u32_ty };

    var model = Model.init(alloc);
    // `Kind::A(7)` — the variant carries a payload, so it is a union value
    // rather than a bare name.
    const payload = try model.e(litInt(7));
    model.exprs.items[payload].ty = 2;
    const tuple_fields = try alloc.alloc(ir.exprs.NodeId, 1);
    tuple_fields[0] = payload;
    const variant_expr = try model.e(.{ .enum_variant = .{
        .def = enum_id,
        .variant = "A",
        .tuple_fields = tuple_fields,
        .named_fields = &.{},
    } });
    model.exprs.items[variant_expr].ty = 1;
    const ret_expr = try model.e(.{ .return_ = .{ .value = variant_expr } });
    model.exprs.items[ret_expr].ty = 1;

    const variant_rows = try alloc.alloc(ir.items.Variant, 1);
    const variant_payload = try alloc.alloc(ir.types.Type, 1);
    variant_payload[0] = u32_ty;
    variant_rows[0] = .{
        .name = "A",
        .fields = .{ .tuple = variant_payload },
        .discriminant = null,
    };
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[enum_id] = .{ .enum_ = .{ .kind = .data, .variants = variant_rows } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = kind_ty,
        .generic_params = &.{},
        .body = ret_expr,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "tuple_variant",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // The union names the variant as its single field, so the value has to
    // carry the payload into `Kind{ .A = ... }`. A bare `A` names nothing.
    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "return Kind{ .A = 7 };") != null);
}

// ── FIX I: indexing a lowered `Vec` reaches its storage ─────────────────────

test "lower: indexing a Vec goes through the container storage" {
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
    const owned_def = try addLowerEntity(&graph, .const_, "v", root_id);
    const borrowed_def = try addLowerEntity(&graph, .const_, "w", root_id);
    const owned_fn = try addLowerEntity(&graph, .fn_, "first_owned", root_id);
    const borrowed_fn = try addLowerEntity(&graph, .fn_, "third_borrowed", root_id);
    try addBareCrate(&graph, alloc, "vec_index", root_id, &.{ owned_fn, borrowed_fn });

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{u32_ty},
    } };
    const reference = try alloc.create(ir.types.Ref);
    reference.* = .{ .mut = false, .pointee = vec_ty };
    const ref_ty: ir.types.Type = .{ .reference = reference };
    // 0 = `Vec<u32>`, 1 = `&Vec<u32>`, 2 = `u32`.
    const types = [_]ir.types.Type{ vec_ty, ref_ty, u32_ty };

    var model = Model.init(alloc);
    // `fn first_owned(v: Vec<u32>) -> u32 { v[0] }`
    const owned_base = try model.e(.{ .path = .{ .def = owned_def, .generic_args = &.{} } });
    model.exprs.items[owned_base].ty = 0;
    const owned_index = try model.e(litInt(0));
    model.exprs.items[owned_index].ty = 2;
    const owned_read = try model.e(.{ .index = .{ .base = owned_base, .index = owned_index } });
    model.exprs.items[owned_read].ty = 2;
    const owned_ret = try model.e(.{ .return_ = .{ .value = owned_read } });
    model.exprs.items[owned_ret].ty = 2;

    // `fn third_borrowed(w: &Vec<u32>) -> u32 { w[2] }`
    const borrowed_base = try model.e(.{ .path = .{ .def = borrowed_def, .generic_args = &.{} } });
    model.exprs.items[borrowed_base].ty = 1;
    const borrowed_index = try model.e(litInt(2));
    model.exprs.items[borrowed_index].ty = 2;
    const borrowed_read = try model.e(.{ .index = .{
        .base = borrowed_base,
        .index = borrowed_index,
    } });
    model.exprs.items[borrowed_read].ty = 2;
    const borrowed_ret = try model.e(.{ .return_ = .{ .value = borrowed_read } });
    model.exprs.items[borrowed_ret].ty = 2;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const owned_params = try alloc.alloc(ir.items.Param, 1);
    owned_params[0] = .{ .name = "v", .ty = vec_ty, .span = span };
    body_rows[owned_fn] = .{ .fn_ = .{
        .params = owned_params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = owned_ret,
        .is_allocating = false,
    } };
    const borrowed_params = try alloc.alloc(ir.items.Param, 1);
    borrowed_params[0] = .{ .name = "w", .ty = ref_ty, .span = span };
    body_rows[borrowed_fn] = .{ .fn_ = .{
        .params = borrowed_params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = borrowed_ret,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "vec_index",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // `Vec<T>` lowers to `std.ArrayListUnmanaged`, which Zig does not index;
    // its `items` slice does. Both the owned and the borrowed receiver read
    // through the same storage.
    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "return v.items[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return w.items[2];") != null);
}

// ── Round 2: accepted-and-wrong constructs ─────────────────────────────────

test "lower: a labelled continue refuses instead of targeting the innermost loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `fn body() { loop { continue 'outer; } }`. The IR carries the label and
    // `ForExpr` has no field for one, so there is nothing to emit `:outer`
    // from; dropping it silently restarts the inner loop and returns a
    // different answer.
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 1,
        } },
        &.{
            strictExpr(0, .{ .continue_ = .{ .label = "outer" } }),
            strictExpr(1, .{ .block = .{
                .statements = &.{},
                .tail = 0,
                .labelled = null,
            } }),
        },
        &.{},
        &.{},
        &.{},
        error.UnsupportedLabelledControlFlow,
    );
}

test "lower: a tuple pattern in a match arm refuses instead of emitting a tuple prong" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `match t { (0, y) => y, .. }`. `.{0, y}` is a `const` destructuring
    // pattern, not a switch prong, and it declares none of its names.
    const arms = [_]ir.exprs.MatchArm{.{
        .patterns = &.{0},
        .guard = null,
        .body = 2,
    }};
    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u32 },
            .body = 0,
        } },
        &.{
            strictExpr(0, .{ .match = .{ .scrutinee = 1, .arms = &arms } }),
            strictExpr(1, litInt(5)),
            strictExpr(2, .unit),
        },
        &.{},
        &.{
            .{ .id = 0, .span = span, .ty = null, .kind = .{ .tuple = .{
                .elements = &.{ 1, 2 },
                .rest = false,
            } } },
            .{ .id = 1, .span = span, .ty = null, .kind = .wildcard },
            .{ .id = 2, .span = span, .ty = null, .kind = .{ .binding = .{
                .name = "y",
                .mode = .value,
                .mutable = false,
            } } },
        },
        &.{},
        error.UnsupportedPattern,
    );
}

test "lower: a let-else refuses rather than dropping its else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectSingleFunctionLoweringError(
        alloc,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 1,
        } },
        &.{
            strictExpr(0, litInt(1)),
            strictExpr(1, .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } }),
        },
        &.{.{ .id = 0, .span = span, .ty = null, .kind = .{ .let_else = .{
            .pattern = 0,
            .init = 0,
            .else_block = .{ .statements = &.{}, .tail = null, .labelled = null },
        } } }},
        &.{.{ .id = 0, .span = span, .ty = null, .kind = .{ .binding = .{
            .name = "v",
            .mode = .value,
            .mutable = false,
        } } }},
        &.{},
        error.UnsupportedStatement,
    );
}

test "lower: a compound assignment emits the checked operator even when the IR says wrapping" {
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
    const a_def = try addLowerEntity(&graph, .const_, "a", root_id);
    const x_def = try addLowerEntity(&graph, .const_, "x", root_id);
    const assign_id = try addLowerEntity(&graph, .fn_, "bump", root_id);
    const wrap_id = try addLowerEntity(&graph, .fn_, "wrap_add", root_id);
    try addBareCrate(&graph, alloc, "compound_assign", root_id, &.{ assign_id, wrap_id });

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const types = [_]ir.types.Type{u32_ty};
    var model = Model.init(alloc);

    // `fn bump(a: u32) -> u32 { let mut x = a; x += a; x }`. `ts_ext.zig`
    // writes `.wrapping` on every `AssignExpr`, so the IR here is what the
    // sidecar really produces for a plain `+=`.
    const bind_x = try model.pat(.{ .binding = .{
        .name = "x",
        .mode = .value,
        .mutable = true,
    } });
    const init_x = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[init_x].ty = 0;
    const let_stmt = try model.stmt(.{ .let = .{
        .pattern = bind_x,
        .init = init_x,
        .ty = null,
    } });
    const assign_target = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
    model.exprs.items[assign_target].ty = 0;
    const assign_value = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[assign_value].ty = 0;
    const compound = try model.e(.{ .assign = .{
        .target = assign_target,
        .op = .add,
        .value = assign_value,
        .overflow = .wrapping,
    } });
    model.exprs.items[compound].ty = null;
    const compound_stmt = try model.stmt(.{ .expr = compound });
    const bump_tail = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
    model.exprs.items[bump_tail].ty = 0;
    const bump_statements = try alloc.alloc(ir.exprs.NodeId, 2);
    bump_statements[0] = let_stmt;
    bump_statements[1] = compound_stmt;
    const bump_body = try model.e(.{ .block = .{
        .statements = bump_statements,
        .tail = bump_tail,
        .labelled = null,
    } });

    // `fn wrap_add(a: u32) -> u32 { a + a }` — a `wrapping_add` lowers here,
    // and it must keep its wrapping operator.
    const wrap_lhs = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[wrap_lhs].ty = 0;
    const wrap_rhs = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[wrap_rhs].ty = 0;
    const wrap_binary = try model.e(.{ .binary = .{
        .op = .add,
        .overflow = .wrapping,
        .lhs = wrap_lhs,
        .rhs = wrap_rhs,
    } });
    model.exprs.items[wrap_binary].ty = 0;
    const wrap_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = wrap_binary,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "a", .ty = u32_ty, .span = span };
    body_rows[assign_id] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = bump_body,
        .is_allocating = false,
    } };
    body_rows[wrap_id] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = wrap_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "compound_assign",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // A Rust debug build panics on `t += 4294967295; t += 2;`; `+%=` returned
    // 1 in both gate modes instead.
    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "x += a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "x +%= a;") == null);
    // `wrapping_add` is a binary expression, not an assignment, and keeps `%`.
    try std.testing.expect(std.mem.indexOf(u8, source, "return a +% a;") != null);
}

test "lower: a sum over .iter() dereferences the by-pointer item" {
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
    const input_def = try addLowerEntity(&graph, .const_, "input", root_id);
    const iter_def = try addLowerEntity(&graph, .method_ref, "iter", root_id);
    const sum_fn = try addLowerEntity(&graph, .fn_, "byte_sum", root_id);
    try addBareCrate(&graph, alloc, "iter_sum", root_id, &.{sum_fn});

    const elem_ty: ir.types.Type = .{ .prim = .u8 };
    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = elem_ty };
    const slice_ty: ir.types.Type = .{ .slice = slice_info };
    const sum_ty: ir.types.Type = .{ .prim = .u32 };
    // 0 = u8, 1 = &[u8], 2 = u32
    const types = [_]ir.types.Type{ elem_ty, slice_ty, sum_ty };

    var model = Model.init(alloc);
    const receiver = try model.e(.{ .path = .{ .def = input_def, .generic_args = &.{} } });
    model.exprs.items[receiver].ty = 1;
    const iter_call = try model.e(.{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .shared,
        .method = iter_def,
        .args = &.{},
    } });
    model.exprs.items[iter_call].ty = 1;
    const chain = try model.e(.{ .iterator_chain = .{
        .source = iter_call,
        .adapters = &.{},
        .terminal = .sum,
    } });
    model.exprs.items[chain].ty = 2;
    const ret = try model.e(.{ .return_ = .{ .value = chain } });
    model.exprs.items[ret].ty = 2;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "input", .ty = slice_ty, .span = span };
    body_rows[sum_fn] = .{ .fn_ = .{
        .params = params,
        .ret = sum_ty,
        .generic_params = &.{},
        .body = ret,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "iter_sum",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // `input.iter()` walks `for (input[0..]) |*__r2z_item|`, so the item is a
    // `*const u8` and `__r2z_sum: u32 += __r2z_item` was a type error — and a
    // pointer-shaped sink would have silently summed addresses.
    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "__r2z_sum += __r2z_item.*;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "__r2z_sum += __r2z_item;") == null);
}

test "lower: if let binds the subject and reads the payload back through r2z" {
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
    const x_def = try addLowerEntity(&graph, .const_, "x", root_id);
    const v_def = try addLowerEntity(&graph, .const_, "v", root_id);
    const some_def = try addLowerEntity(&graph, .enum_, "Option", root_id);
    const pick_fn = try addLowerEntity(&graph, .fn_, "pick", root_id);
    try addBareCrate(&graph, alloc, "if_let", root_id, &.{pick_fn});

    const elem_ty: ir.types.Type = .{ .prim = .u8 };
    const option_info = try alloc.create(ir.types.Type);
    option_info.* = elem_ty;
    const option_ty: ir.types.Type = .{ .option = option_info };
    const types = [_]ir.types.Type{ elem_ty, option_ty };

    var model = Model.init(alloc);
    const bind_v = try model.pat(.{ .binding = .{
        .name = "v",
        .mode = .value,
        .mutable = false,
    } });
    const some_fields = [_]ir.exprs.FieldPat{.{
        .field = "0",
        .pat = bind_v,
        .shorthand = false,
    }};
    const some_pat = try model.pat(.{ .struct_pat = .{
        .def = some_def,
        .fields = &some_fields,
        .rest = false,
    } });
    const scrutinee = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
    model.exprs.items[scrutinee].ty = 1;
    const then_tail = try model.e(.{ .path = .{ .def = v_def, .generic_args = &.{} } });
    model.exprs.items[then_tail].ty = 0;
    const then_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = then_tail,
        .labelled = null,
    } });
    const else_tail = try model.e(litInt(0));
    model.exprs.items[else_tail].ty = 0;
    const else_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = else_tail,
        .labelled = null,
    } });
    const pick = try model.e(.{ .if_let = .{
        .pattern = some_pat,
        .scrutinee = scrutinee,
        .then_ = .{ .statements = &.{}, .tail = then_body, .labelled = null },
        .@"else" = .{ .block = .{ .statements = &.{}, .tail = else_block, .labelled = null } },
    } });
    model.exprs.items[pick].ty = 0;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "x", .ty = option_ty, .span = span };
    body_rows[pick_fn] = .{ .fn_ = .{
        .params = params,
        .ret = elem_ty,
        .generic_params = &.{},
        .body = pick,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "if_let",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // The subject was the scrutinee itself, so `if (x)` asked Zig for a `bool`
    // over a `?u8` and `v` was never declared.
    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "__r2z_if_let != null") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.option.unwrap(__r2z_if_let)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const v = ") != null);
}

test "lower: a binding a local closure captures stays a var" {
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
    const a_def = try addLowerEntity(&graph, .const_, "a", root_id);
    const t_def = try addLowerEntity(&graph, .const_, "t", root_id);
    const outer_fn = try addLowerEntity(&graph, .fn_, "outer", root_id);
    try addBareCrate(&graph, alloc, "closure_capture", root_id, &.{outer_fn});

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const types = [_]ir.types.Type{u32_ty};
    var model = Model.init(alloc);

    // `let mut t = a; let f = |x| { t += x; t }; ..`. The closure body is
    // emitted at its call site, so the block's own statement list cannot show
    // the assignment and the downgrade turned `t` into a `const`.
    const closure_captures = [_]ir.exprs.Capture{.{
        .name = "t",
        .mode = .by_value,
        .ty = 0,
    }};
    const closure = try model.e(.{ .closure = .{
        .captures = &closure_captures,
        .params = &.{},
        .return_ty = null,
        .body = .{ .statements = &.{}, .tail = null, .labelled = null },
        .trait = .@"fn",
    } });
    const bind_t = try model.pat(.{ .binding = .{
        .name = "t",
        .mode = .value,
        .mutable = true,
    } });
    const init_t = try model.e(.{ .path = .{ .def = a_def, .generic_args = &.{} } });
    model.exprs.items[init_t].ty = 0;
    const let_t = try model.stmt(.{ .let = .{ .pattern = bind_t, .init = init_t, .ty = null } });
    const bind_f = try model.pat(.{ .binding = .{
        .name = "f",
        .mode = .value,
        .mutable = false,
    } });
    const let_f = try model.stmt(.{ .let = .{ .pattern = bind_f, .init = closure, .ty = null } });
    const tail = try model.e(.{ .path = .{ .def = t_def, .generic_args = &.{} } });
    model.exprs.items[tail].ty = 0;
    const outer_statements = try alloc.alloc(ir.exprs.NodeId, 2);
    outer_statements[0] = let_t;
    outer_statements[1] = let_f;
    const body = try model.e(.{ .block = .{
        .statements = outer_statements,
        .tail = tail,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "a", .ty = u32_ty, .span = span };
    body_rows[outer_fn] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "closure_capture",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "var t: u32 = a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const t: u32 = a;") == null);
}

test "lower: rev and count on a range refuse instead of calling a method Zig lacks" {
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
    const count_def = try addLowerEntity(&graph, .method_ref, "count", root_id);
    const count_fn = try addLowerEntity(&graph, .fn_, "counted", root_id);
    try addBareCrate(&graph, alloc, "range_count", root_id, &.{count_fn});

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const types = [_]ir.types.Type{u32_ty};
    var model = Model.init(alloc);
    const start = try model.e(litInt(0));
    model.exprs.items[start].ty = 0;
    const end = try model.e(litInt(10));
    model.exprs.items[end].ty = 0;
    const range = try model.e(.{ .range = .{
        .start = start,
        .end = end,
        .inclusive = false,
    } });
    model.exprs.items[range].ty = 0;
    const counted = try model.e(.{ .method_call = .{
        .receiver = range,
        .receiver_mode = .value,
        .method = count_def,
        .args = &.{},
    } });
    model.exprs.items[counted].ty = 0;
    const ret = try model.e(.{ .return_ = .{ .value = counted } });
    model.exprs.items[ret].ty = 0;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[count_fn] = .{ .fn_ = .{
        .params = &.{},
        .ret = u32_ty,
        .generic_params = &.{},
        .body = ret,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "range_count",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // `return (0..10).count();` has no Zig member behind it.
    try std.testing.expectError(
        error.UnsupportedStandardMethod,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}

test "lower: indexing a Vec returned by an unpropagated call refuses" {
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
    const seed_def = try addLowerEntity(&graph, .const_, "seed", root_id);
    const make_def = try addLowerEntity(&graph, .fn_, "make", root_id);
    const head_fn = try addLowerEntity(&graph, .fn_, "head", root_id);
    try addBareCrate(&graph, alloc, "vec_producer", root_id, &.{ make_def, head_fn });

    const elem_ty: ir.types.Type = .{ .prim = .u32 };
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{elem_ty},
    } };
    // 0 = u32, 1 = Vec<u32>
    const types = [_]ir.types.Type{ elem_ty, vec_ty };
    var model = Model.init(alloc);

    // `fn make(seed: Vec<u32>) -> Vec<u32> { seed }`
    const seed_path = try model.e(.{ .path = .{ .def = seed_def, .generic_args = &.{} } });
    model.exprs.items[seed_path].ty = 1;
    const make_ret = try model.e(.{ .return_ = .{ .value = seed_path } });
    model.exprs.items[make_ret].ty = 1;

    // `fn head() -> u32 { make(Vec::new())[0] }`
    const producer = try model.e(.{ .call = .{
        .call_kind = .{ .free = make_def },
        .args = &.{},
    } });
    model.exprs.items[producer].ty = 1;
    const index = try model.e(litInt(0));
    model.exprs.items[index].ty = 0;
    const read = try model.e(.{ .index = .{ .base = producer, .index = index } });
    model.exprs.items[read].ty = 0;
    const head_ret = try model.e(.{ .return_ = .{ .value = read } });
    model.exprs.items[head_ret].ty = 0;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const make_params = try alloc.alloc(ir.items.Param, 1);
    make_params[0] = .{ .name = "seed", .ty = vec_ty, .span = span };
    body_rows[make_def] = .{ .fn_ = .{
        .params = make_params,
        .ret = vec_ty,
        .generic_params = &.{},
        .body = make_ret,
        .is_allocating = true,
    } };
    body_rows[head_fn] = .{ .fn_ = .{
        .params = &.{},
        .ret = elem_ty,
        .generic_params = &.{},
        .body = head_ret,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "vec_producer",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = body_rows,
        },
    };

    // `make()[0]` projected `.items` onto a call whose Zig type is still the
    // error union, so the member did not exist.
    try std.testing.expectError(
        error.UnsupportedExpression,
        lower.lowerRustIr(alloc, &rust_ir, null),
    );
}
