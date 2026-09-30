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
        // `#[test]`, not the `test_` in the name, is what makes this a Zig
        // test block; the fixture below asserts on the block it produces.
        .attributes = &.{
            .{ .name = "test", .meta = "", .known = true },
        },
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

// A `vec!` literal allocates: it appends into a fresh `ArrayListUnmanaged` and
// hands the buffer back through `deinit(allocator)`. Scanning only the
// ELEMENTS, the way an array literal is scanned, let `vec![1, 100, 2]` report
// no allocation effect, so the enclosing function was emitted with no
// allocator parameter and no error union while its body spelled
// `append(allocator, ..)` — a package that cannot compile. The literal itself
// is the effect, whether it is the tail expression or a discarded statement.
//
// This used to assert the refusal instead, and that refusal is exactly what
// the round implementing `vec!` removed.
test "lower: a vec literal makes the enclosing function allocate" {
    const backing = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const tail_fn_id = try addLowerEntity(&graph, .fn_, "vec_tail", null);
    const statement_fn_id = try addLowerEntity(&graph, .fn_, "vec_statement", null);

    const elem_ty: ir.types.Type = .{ .prim = .u32 };
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{elem_ty},
    } };
    const types = [_]ir.types.Type{ elem_ty, vec_ty };

    const first = try model.e(litInt(1));
    const second = try model.e(litInt(100));
    const third = try model.e(litInt(2));
    model.exprs.items[first].ty = 0;
    model.exprs.items[second].ty = 0;
    model.exprs.items[third].ty = 0;

    const explicit_vec = try model.e(.{
        .vec_lit = .{
            .elements = &.{ first, second, third },
            .repeat = null,
        },
    });
    model.exprs.items[explicit_vec].ty = 1;
    const tail_block = try model.e(.{
        .block = .{
            .statements = &.{},
            .tail = explicit_vec,
            .labelled = null,
        },
    });
    model.exprs.items[tail_block].ty = 1;

    const repeated_vec = try model.e(.{
        .vec_lit = .{
            .elements = &.{first},
            .repeat = 3,
        },
    });
    model.exprs.items[repeated_vec].ty = 1;
    const repeated_vec_statement = try model.stmt(.{ .expr = repeated_vec });
    const statement_block = try model.e(.{
        .block = .{
            .statements = &.{repeated_vec_statement},
            .tail = null,
            .labelled = null,
        },
    });
    model.exprs.items[statement_block].ty = 0;

    // No `is_allocating` on either body: the literal is the only evidence the
    // lowering has, and it is what the old element-only scan missed.
    try model.bodies.append(alloc, .{
        .fn_ = .{
            .params = &.{},
            .ret = vec_ty,
            .generic_params = &.{},
            .body = tail_block,
        },
    });
    try model.bodies.append(alloc, .{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .generic_params = &.{},
            .body = statement_block,
        },
    });

    _ = try addRootModule(&graph, .{
        .crate_name = "vec_contract",
        .edition = 2021,
        .items = &.{ tail_fn_id, statement_fn_id },
    });

    const rust_ir = ir.RustIr{
        .crate_name = "vec_contract",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = try model.bodies.toOwnedSlice(alloc),
        },
    };

    const src = try emitRootSource(alloc, &rust_ir);
    // The allocator leads the value parameters and the fallible append
    // propagates, so `allocator` is bound wherever the literal is spelled.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "pub fn vec_tail(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(u32)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "pub fn vec_statement(allocator: std.mem.Allocator)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "errdefer __r2z_vec.deinit(allocator)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "try __r2z_vec.append(allocator, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "try __r2z_vec.append(allocator, 100)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "try __r2z_vec.append(allocator, 2)") != null);
    // The repeating form fills through one loop over `0..n` rather than `n`
    // unrolled appends. Its input slice is allocated storage: `&.{ .{ .range
    // = .. } }` is a pointer to a runtime temporary, and validation reads it
    // back after this frame has returned.
    try std.testing.expect(std.mem.indexOf(u8, src, "for (0..3) |_| {") != null);
}

test "lower: a vec literal appends each element's own value, not the last one" {
    // `vec![1, 100, 2]` is the shape that catches element aliasing: the
    // element count and the container type are both right whatever the
    // element EXPRESSION is, so a reused `ast.Expr` prints the last value at
    // every position and the package still compiles and runs. Worse, it makes
    // a false assertion report success — `vec![4, 4, 4, 4]` against a
    // `vec![1, 2, 3, 4]` source passes. Three DISTINCT values, asserted in
    // order against the emitted text, is the only shape that fails.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const make_def = try addLowerEntity(&graph, .fn_, "make", root_id);
    try addBareCrate(&graph, alloc, "vec_fidelity", root_id, &.{make_def});

    const elem_ty: ir.types.Type = .{ .prim = .u32 };
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{elem_ty},
    } };
    var model = Model.init(alloc);

    const first = try model.e(litInt(1));
    const second = try model.e(litInt(100));
    const third = try model.e(litInt(2));
    const vec_node = try model.e(.{ .vec_lit = .{
        .elements = &.{ first, second, third },
        .repeat = null,
    } });
    model.exprs.items[vec_node].ty = 1;
    const make_ret = try model.e(.{ .return_ = .{ .value = vec_node } });
    model.exprs.items[make_ret].ty = 1;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[make_def] = .{ .fn_ = .{
        .params = &.{},
        .ret = vec_ty,
        .generic_params = &.{},
        .body = make_ret,
        .is_allocating = true,
    } };

    const types = [_]ir.types.Type{ elem_ty, vec_ty };
    const rust_ir = ir.RustIr{
        .crate_name = "vec_fidelity",
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

    const src = try emitRootSource(alloc, &rust_ir);
    const append_first = std.mem.indexOf(u8, src, "append(allocator, 1)") orelse
        return error.MissingFirstElement;
    const append_second = std.mem.indexOf(u8, src, "append(allocator, 100)") orelse
        return error.MissingSecondElement;
    const append_third = std.mem.indexOf(u8, src, "append(allocator, 2)") orelse
        return error.MissingThirdElement;
    try std.testing.expect(append_first < append_second);
    try std.testing.expect(append_second < append_third);
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

    const receiver_expr = try model.e(.{ .path = .{ .def = receiver_id, .generic_args = &.{} } });
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
            .mode = if (fixture.capture_by_value)
                .by_value
            else
                .by_ref,
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
    const condition = expr.if_expr.cond.*;
    if (condition != .bin_op or condition.bin_op.op != .not_equal) {
        return error.ExpectedNullTest;
    }
    if (condition.bin_op.rhs.* != .lit or condition.bin_op.rhs.lit != .null_lit) {
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

// Zig cannot `switch` an optional, so `Option::map` rides on
// `if (opt != null)` and the payload is read back with `r2z.option.unwrap`.
// The old `null => null, else => |p|` expansion emitted `switch (value)` over
// a `?T` and never compiled, so this test's `match_expr` expectation — two
// arms, the payload captured as `__r2z_in_tuple`, the destructure in the
// second prong — described a shape the round replaced. What the test is for
// is the tuple destructuring, and that is unchanged: it just lives in the
// `then` block now.
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
    if (expr != .if_expr) return error.ExpectedOptionMapIf;
    const condition = expr.if_expr.cond.*;
    if (condition != .bin_op or condition.bin_op.op != .not_equal) {
        return error.ExpectedNullTest;
    }
    if (condition.bin_op.rhs.* != .lit or condition.bin_op.rhs.lit != .null_lit) {
        return error.ExpectedNullComparison;
    }
    const else_body = expr.if_expr.else_body orelse return error.ExpectedElseBranch;
    if (else_body.* != .lit or else_body.lit != .null_lit) return error.ExpectedNullElse;
    const then_body = expr.if_expr.then_body.*;
    if (then_body != .block) return error.ExpectedMappedBlock;
    const mapped = then_body.block;
    // `const __r2z_in_tuple = r2z.option.unwrap(..);` reads the payload out of
    // the optional, then the destructuring the prong used to carry.
    if (mapped.stmts.len != 4) return error.ExpectedTupleDestructure;
    const unwrap = mapped.stmts[0];
    if (unwrap != .let_stmt) return error.ExpectedOptionUnwrap;
    // A tuple pattern names no single value, so the payload is named for the
    // shape and destructured beside it.
    if (!std.mem.eql(u8, unwrap.let_stmt.name, "__r2z_in_tuple")) {
        return error.ExpectedPayloadName;
    }
    if (unwrap.let_stmt.init != .call or unwrap.let_stmt.init.call.callee.* != .ident or
        !std.mem.eql(u8, unwrap.let_stmt.init.call.callee.ident, "r2z.option.unwrap"))
    {
        return error.ExpectedOptionUnwrap;
    }
    if (unwrap.let_stmt.init.call.args.len != 1) return error.ExpectedSingleUnwrapArgument;
    const whole = mapped.stmts[1].let_stmt;
    if (!std.mem.eql(u8, whole.name, "__r2z_tuple")) return error.ExpectedTupleBinding;
    if (whole.init != .ident or !std.mem.eql(u8, whole.init.ident, unwrap.let_stmt.name)) {
        return error.ExpectedTupleBoundToPayload;
    }
    const first = mapped.stmts[2].let_stmt;
    if (!std.mem.eql(u8, first.name, "a")) return error.ExpectedFirstElementName;
    if (first.init != .builtin or !std.mem.eql(u8, first.init.builtin.name, "index")) {
        return error.ExpectedElementIndex;
    }
    if (first.init.builtin.args.len != 2 or first.init.builtin.args[0] != .ident or
        !std.mem.eql(u8, first.init.builtin.args[0].ident, "__r2z_tuple"))
    {
        return error.ExpectedElementIndexedFromTuple;
    }
    const second = mapped.stmts[3].let_stmt;
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

/// Lower one function and emit its crate root file, so a fixture can assert on
/// the Zig text a control-flow shape produces rather than on the AST.
fn emitSingleFunctionSource(
    alloc: std.mem.Allocator,
    body_kind: ir.bodies.BodyKind,
    exprs: []const ir.exprs.Expr,
    types: []const ir.types.Type,
) ![]const u8 {
    var graph = ir.graph.CrateGraph.init(alloc);
    const function_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "control_exit_fixture",
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try addRootModule(&graph, .{
        .crate_name = "control_exit_fixture",
        .edition = 2021,
        .items = &.{function_id},
    });
    const entity_bodies = [_]ir.bodies.BodyKind{body_kind};
    const rust_ir = ir.RustIr{
        .crate_name = "control_exit_fixture",
        .edition = "2021",
        .graph = graph,
        .types = types,
        .bodies = .{
            .exprs = exprs,
            .stmts = &.{},
            .pats = &.{},
            .types = types,
            .bodies = &entity_bodies,
        },
    };
    return emitRootSource(alloc, &rust_ir);
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
    // Two type arguments where the declaration names one. The call is
    // refused for exactly that, so this is the error the arity check owes;
    // naming whatever other refusal it reaches first would pin an accident
    // of ordering instead of the contract.
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
        error.GenericArgumentArityMismatch,
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

    // The `use_` is parented to a real root module entity, not to itself. The
    // cross-module reference pre-pass walks every entity's parent chain to
    // decide which private items have to be `pub` in Zig, and an entity that
    // is its own parent is a hierarchy cycle. That cycle was incidental — the
    // use happened to be entity 0, which is what `.parent = 0` named — and it
    // is not the unresolvable use target this half of the test is about.
    var bad_use_graph = ir.graph.CrateGraph.init(alloc);
    const use_id = try bad_use_graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = "",
        .span = span,
        .visibility = .public,
        .parent = null,
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
    _ = try addRootModule(&bad_use_graph, .{
        .crate_name = "bad_use",
        .edition = 2021,
        .items = &.{use_id},
    });
    const bad_use_bodies = [_]ir.bodies.BodyKind{ .{ .none = {} }, .{ .none = {} } };
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

// The allocator LEADS the value-argument list. `lowerFnEntity` puts it ahead
// of every value parameter — a hoisted method's `self` included — and a
// method inside its own struct declares `self` implicitly, so `self` is never
// one of these arguments either. Placing it after the first argument produced
// `from_hex(T, hex, allocator)`, which binds `hex` to the allocator parameter
// and Zig rejects the type. This test used to pin the old index-1 position;
// the round that fixed that type error moved the allocator to index 0.
test "lower: associated allocating calls place allocator before the receiver" {
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
    const allocator_arg = switch (call.args[0]) {
        .ident => |name| name,
        else => return error.MissingAssociatedAllocator,
    };
    try std.testing.expectEqualStrings("allocator", allocator_arg);
    const receiver_arg = switch (call.args[1]) {
        .ident => |name| name,
        else => return error.MissingAssociatedReceiver,
    };
    try std.testing.expectEqualStrings("self", receiver_arg);
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

/// The name of the function every expectation fixture passes its message to.
///
/// Rust evaluates the `expect` argument at the call on EVERY path, success
/// included. Building the message through a call is what makes that visible
/// here: a lowering that computed the message inside a failure branch, or
/// substituted a constant for it, would not carry this operand through.
const message_builder = "note_message";

/// The receiver shape a `Result` expectation fixture is built around.
const ExpectReceiver = enum {
    /// `Result<u8, DecodeError>` whose error variant carries a payload, so
    /// the value is the tagged `r2z.Result` union: it holds the error value,
    /// and the runtime owns the arms that hand a payload back.
    payload_error,
    /// `Result<u8, DecodeError>` whose variants are all field-free, so the
    /// value is a Zig error union: it still has an `Ok` payload to hand out,
    /// but the failure lives in the union as a tag rather than a value.
    error_set_error,
};

/// Lower `value.<method>(note_message(1))` on a receiver of `shape` and hand
/// back the call the enclosing function body is built from.
fn resultExpectationFixture(
    alloc: std.mem.Allocator,
    method_name: []const u8,
    shape: ExpectReceiver,
    borrow_receiver: bool,
) !ast.Expr {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "checked", null);
    const method_id = try addLowerEntity(&graph, .method_ref, method_name, fn_id);
    const value_id = try addLowerEntity(&graph, .const_, "value", fn_id);
    const error_id = try addLowerEntity(&graph, .enum_, "DecodeError", null);
    const note_id = try addLowerEntity(&graph, .fn_, message_builder, null);
    _ = try addRootModule(&graph, .{
        .crate_name = "result_expectation_test",
        .edition = 2021,
        .items = &.{ fn_id, error_id, note_id },
    });

    const ok_type: ir.types.Type = .{ .prim = .u8 };
    const receiver_ty: ir.types.Type = blk: {
        const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
        err_segments[0] = .{ .name = "DecodeError", .id = error_id };
        const result = try alloc.create(ir.types.Result);
        result.* = .{
            .ok = ok_type,
            .err = .{ .path = .{ .segments = err_segments } },
            .is_error_unionable = true,
        };
        break :blk .{ .result = result };
    };
    const declared_receiver_ty: ir.types.Type = if (borrow_receiver) blk: {
        const pointee = try alloc.create(ir.types.Ref);
        pointee.* = .{ .mut = false, .pointee = receiver_ty };
        break :blk .{ .reference = pointee };
    } else receiver_ty;
    // The Rust `&str` the message is passed as: a borrow the call site owns,
    // and the only shape an expectation can be handed.
    const message_ty: ir.types.Type = .{ .slice = blk: {
        const slice_info = try alloc.create(ir.types.Slice);
        slice_info.* = .{ .const_ = true, .elem = ok_type };
        break :blk slice_info;
    } };
    const types = [_]ir.types.Type{ ok_type, receiver_ty, declared_receiver_ty, message_ty };

    const receiver_expr = try model.e(.{ .path = .{ .def = value_id, .generic_args = &.{} } });
    model.exprs.items[receiver_expr].ty = 2;
    const message_code = try model.e(litInt(1));
    model.exprs.items[message_code].ty = 0;
    const message_expr = try model.e(.{ .call = .{
        .call_kind = .{ .free = note_id },
        .args = &.{message_code},
    } });
    model.exprs.items[message_expr].ty = 3;
    const call = try model.e(.{ .method_call = .{
        .receiver = receiver_expr,
        .receiver_mode = .value,
        .method = method_id,
        .args = &.{message_expr},
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

    const note_value = try model.e(litInt(0));
    model.exprs.items[note_value].ty = 0;
    const note_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = note_value,
        .labelled = null,
    } });

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
    body_rows[error_id] = .{ .enum_ = .{ .kind = .data, .variants = error_variants } };
    body_rows[note_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "code", .ty = ok_type, .span = span }},
        .ret = ok_type,
        .generic_params = &.{},
        .body = note_block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "result_expectation_test",
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
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const expr = body.expr orelse return error.ExpectedBodyExpression;
    return expr.*;
}

/// How an expectation call read the receiver binding.
const ReceiverLifetime = enum {
    /// Read as the value itself, which is what consumes it.
    value,
    /// Read out of a borrow through one `.*`, which is what a borrowed
    /// `&Result` has to become before a call can consume what it points at.
    borrowed,
};

/// The operands a lowered expectation call evaluates.
const ExpectationOperands = struct {
    receiver: ReceiverLifetime,
    args: []const ast.Expr,
};

/// Whether one operand reads the receiver binding, and how.
///
/// Address-of is not a read: taking a reference to the receiver would leave
/// the call consuming a pointer to the payload instead of the payload.
fn expectReceiverOperand(operand: *const ast.Expr, lifetime: *ReceiverLifetime) !bool {
    switch (operand.*) {
        .ident => |name| {
            if (!std.mem.eql(u8, name, "value")) return false;
            lifetime.* = .value;
            return true;
        },
        .unary_op => |unary| {
            if (unary.op != .deref) return false;
            if (!std.mem.eql(u8, try expectIdent(unary.operand.*), "value")) return false;
            lifetime.* = .borrowed;
            return true;
        },
        else => return false,
    }
}

/// The receiver an expectation call consumed, and the arguments it evaluated
/// alongside it.
///
/// The receiver is found by WHICH operand reads the `value` binding rather
/// than by where it sits, so the claim under test — read exactly once, and
/// read as the value the call consumes — holds whether the lowering spells it
/// as a Zig method call (`value.expect(msg)`) or as a runtime free call
/// (`r2z.result.expectErrorUnion(value, msg)`). Neither spelling is the
/// assertion here; the consumption is.
fn expectExpectationOperands(call_expr: *const ast.Expr) !ExpectationOperands {
    const call = switch (call_expr.*) {
        .call => |value| value,
        else => return error.ExpectedExpectationCall,
    };
    // A callee chain contributes its leaf: `value.expect` reads `value`,
    // `r2z.result.expectErrorUnion` reads `r2z.result`, which is not a
    // binding this call site declared.
    var leaf: *const ast.Expr = call.callee;
    while (true) {
        switch (leaf.*) {
            .field_access => |field| leaf = field.target,
            else => break,
        }
    }
    var reads: usize = 0;
    var lifetime: ReceiverLifetime = .value;
    if (try expectReceiverOperand(leaf, &lifetime)) reads += 1;
    for (call.args) |*argument| {
        if (try expectReceiverOperand(argument, &lifetime)) reads += 1;
    }
    // Reading it twice would hand the call two references to the same
    // storage; never reading it would drop the payload the caller is waiting
    // for. Exactly one read is the only shape that consumes it.
    if (reads != 1) return error.ExpectedReceiverConsumption;
    return .{ .receiver = lifetime, .args = call.args };
}

/// The message the call evaluated, located as the one argument that is still
/// the `note_message(..)` call the call site wrote.
///
/// An argument rather than a callee, and a call rather than a literal: the
/// work that produces the message happens at the call, on every path, exactly
/// as Rust evaluates the `expect` argument. A lowering that tucked the
/// message into a failure branch, or folded it to a constant, would have no
/// such argument.
fn expectEvaluatedMessage(args: []const ast.Expr) !void {
    var found: usize = 0;
    for (args) |argument| {
        const note = switch (argument) {
            .call => |nested| nested,
            else => continue,
        };
        const callee = switch (note.callee.*) {
            .ident => |name| name,
            else => continue,
        };
        if (!std.mem.eql(u8, callee, message_builder)) continue;
        if (note.args.len != 1) return error.ExpectedExpectationMessage;
        found += 1;
    }
    if (found != 1) return error.ExpectedExpectationMessage;
}

// A `Result` whose error carries a payload — `FromHexError::InvalidHexCharacter
// { c, index }`, `leb128::Error::IoError(io::Error)` — cannot be spelled as a
// Zig error set, so the value is the tagged `r2z.Result` union and the runtime
// owns the arm that hands the `Ok` payload out.
test "lower: expect on a value-carrying Result consumes the union and evaluates the message at the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expr = try resultExpectationFixture(alloc, "expect", .payload_error, false);
    const operands = try expectExpectationOperands(&expr);
    // The runtime signature consumes the union, so the receiver has to arrive
    // as the value itself rather than as a reference to it.
    try std.testing.expectEqual(ReceiverLifetime.value, operands.receiver);
    try expectEvaluatedMessage(operands.args);
}

test "lower: expect on a borrowed tagged Result reads the union out of the borrow it consumes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expr = try resultExpectationFixture(alloc, "expect", .payload_error, true);
    const operands = try expectExpectationOperands(&expr);
    // `&Result<u8, DecodeError>` borrows the union and the runtime method takes
    // the union itself, so the borrow is read through exactly one `.*`: the
    // call hands the payload over instead of a second reference to the storage
    // behind it. A method left unclassified keeps the borrow in place and calls
    // through it instead, which is the `.value` reading this refuses.
    try std.testing.expectEqual(ReceiverLifetime.borrowed, operands.receiver);
    try expectEvaluatedMessage(operands.args);
}

test "lower: expect_err on a value-carrying Result consumes the union and evaluates the message at the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expr = try resultExpectationFixture(alloc, "expect_err", .payload_error, false);
    const operands = try expectExpectationOperands(&expr);
    try std.testing.expectEqual(ReceiverLifetime.value, operands.receiver);
    try expectEvaluatedMessage(operands.args);
}

// A field-free error enum CAN be spelled as a Zig error set, and then the
// value is an error union with no runtime `Result` to call a method on. The
// `Ok` payload still has to come out and the failure still has to report the
// message the caller wrote.
test "lower: expect on a native error union consumes the union and evaluates the message at the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expr = try resultExpectationFixture(alloc, "expect", .error_set_error, false);
    // One call evaluates the receiver and the message as sibling operands, so
    // the message is built before the union is inspected rather than by
    // whichever branch the union turns out to take.
    const operands = try expectExpectationOperands(&expr);
    try std.testing.expectEqual(ReceiverLifetime.value, operands.receiver);
    try expectEvaluatedMessage(operands.args);
}

test "lower: expect on a borrowed native error union reads the union out of the borrow it consumes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expr = try resultExpectationFixture(alloc, "expect", .error_set_error, true);
    const operands = try expectExpectationOperands(&expr);
    try std.testing.expectEqual(ReceiverLifetime.borrowed, operands.receiver);
    try expectEvaluatedMessage(operands.args);
}

test "lower: expect_err on a native error union reads the union it turns back into an error tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A fieldless error enum that lowered to an error set kept its variants as
    // tags, so this receiver has a failure to hand back: the union is read out
    // of the borrow and passed on whole, and the tag it becomes is the value
    // the caller receives. A receiver that kept the borrow in place would hand
    // back a reference to storage nobody asked for.
    const expr = try resultExpectationFixture(alloc, "expect_err", .error_set_error, true);
    const operands = try expectExpectationOperands(&expr);
    try std.testing.expectEqual(ReceiverLifetime.borrowed, operands.receiver);
    try expectEvaluatedMessage(operands.args);
}

test "lower: expect_err on a native error union names the source error type it owes the caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The union carries a TAG, but `expect_err` owes the caller the Rust `E` —
    // `DecodeError` here. Naming that type as the helper's own argument is the
    // whole difference between handing back an error-set member and handing
    // back the variant the source declared, so the call has to carry it.
    const expr = try resultExpectationFixture(alloc, "expect_err", .error_set_error, false);
    const call = switch (expr) {
        .call => |value| value,
        else => return error.ExpectedExpectationCall,
    };
    if (call.generic_args.len != 1) return error.ExpectedExpectationCall;
    const named = switch (call.generic_args[0]) {
        .named => |name| name,
        else => return error.ExpectedExpectationCall,
    };
    try std.testing.expectEqualStrings("DecodeError", named);
}

/// Lower a body whose only statement is `let _ = note(1);` — a statement
/// expression whose value is dropped — and return the statement it produced.
fn wildcardLetFixture(alloc: std.mem.Allocator) !ast.Stmt {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "verify", null);
    const note_id = try addLowerEntity(&graph, .fn_, message_builder, null);
    _ = try addRootModule(&graph, .{
        .crate_name = "wildcard_let_test",
        .edition = 2021,
        .items = &.{ fn_id, note_id },
    });

    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    const note_value = try model.e(litInt(0));
    model.exprs.items[note_value].ty = 0;
    const note_block = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = note_value,
        .labelled = null,
    } });
    const argument = try model.e(litInt(1));
    model.exprs.items[argument].ty = 1;
    const initializer = try model.e(.{ .call = .{
        .call_kind = .{ .free = note_id },
        .args = &.{argument},
    } });
    // `note_message` returns `u8`, so the discarded value is a real value and
    // the statement has to reach Zig's `_ = EXPR;` rather than a bare call.
    model.exprs.items[initializer].ty = 0;
    // The pattern is a wildcard, so nothing is bound — but the initializer is
    // still a call that has to run, which is exactly where a macro's
    // statement expression keeps its side effects.
    const wildcard = try model.pat(.{ .wildcard = {} });
    const dropped = try model.stmt(.{ .let = .{
        .pattern = wildcard,
        .init = initializer,
        .ty = null,
    } });
    const statements = try alloc.alloc(ir.exprs.NodeId, 1);
    statements[0] = dropped;
    const body = try model.e(.{ .block = .{
        .statements = statements,
        .tail = null,
        .labelled = null,
    } });

    const types = [_]ir.types.Type{ u8_ty, u8_ty, unit_ty };
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = unit_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };
    body_rows[note_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "code", .ty = u8_ty, .span = span }},
        .ret = u8_ty,
        .generic_params = &.{},
        .body = note_block,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "wildcard_let_test",
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
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const fn_body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    // The body block is read directly rather than through its tail: a
    // statement-only body has no tail to reach the statement through, and the
    // statement is the whole claim this fixture makes.
    if (fn_body.stmts.len != 1) return error.ExpectedBodyExpression;
    return fn_body.stmts[0];
}

test "lower: let _ drops the value but still runs the initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `let _ = EXPR;` binds nothing, so the only observable claim is that the
    // initializer still happens. Dropping the statement instead — leaving the
    // call out of the body — would silently delete whatever the macro did,
    // which is the whole reason the statement exists.
    const statement = try wildcardLetFixture(alloc);
    const discard = switch (statement) {
        .assign => |value| value,
        else => return error.ExpectedExpectationCall,
    };
    try std.testing.expectEqualStrings("_", try expectIdent(discard.target));
    const initializer = switch (discard.val) {
        .call => |value| value,
        else => return error.ExpectedExpectationCall,
    };
    const callee = switch (initializer.callee.*) {
        .ident => |name| name,
        else => return error.ExpectedExpectationCall,
    };
    try std.testing.expectEqualStrings(message_builder, callee);
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
// itself instead of borrowing the collector — and it still does: the
// collector arm runs ahead of the member-call fall-through, so a `usize`
// receiver never reaches `r2z.alloc.vec_collect`.
//
// What changed under it is the turbofish. A call's own turbofish now outranks
// every inferred door, because the source writing `collect::<Vec<usize>>` is
// stronger evidence than anything inference can read back; `collect` here is a
// `method_ref` carrying no type parameters, so the source names one where the
// callee takes none and the lowering refuses — rustc refuses the same
// mismatch (E0107). The old expectation asserted the member call was emitted
// with its turbofish silently dropped, which is the arity mismatch that rule
// removed. The refusal still tells the two outcomes apart: had the classifier
// taken the collector arm, the fixture would have returned emitted source
// instead of an error.
test "lower: collect on a receiver that is not an iterator is not the collector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(
        error.GenericArgumentArityMismatch,
        collectFixtureSource(alloc, false, true),
    );
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

test "lower: a labelled continue restarts the loop it names, not the innermost one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `fn body() { 'outer: loop { loop { continue 'outer; } } }`. Zig's
    // `continue` always restarts the innermost loop, so the label has to
    // survive into the emitted text; dropping it restarts the inner loop
    // instead and the two shapes are not the same program.
    const exprs = [_]ir.exprs.Expr{
        strictExpr(0, .{ .block = .{
            .statements = &.{},
            .tail = 5,
            .labelled = null,
        } }),
        strictExpr(1, .{ .continue_ = .{ .label = "outer" } }),
        strictExpr(2, .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } }),
        strictExpr(3, .{ .loop_ = .{ .body = .{
            .statements = &.{},
            .tail = 2,
            .labelled = null,
        } } }),
        strictExpr(4, .{ .block = .{
            .statements = &.{},
            .tail = 3,
            .labelled = null,
        } }),
        strictExpr(5, .{ .loop_ = .{ .body = .{
            .statements = &.{},
            .tail = 4,
            .labelled = "outer",
        } } }),
    };
    const source = try emitSingleFunctionSource(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } }, &exprs, &.{});
    // The label belongs to the loop, not to the block around its body, which
    // is what lets the restart reach the loop at all.
    try std.testing.expect(std.mem.indexOf(u8, source, "outer: while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "continue :outer;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "outer: {") == null);
}

test "lower: a labelled break out of a nested loop makes the outer loop value-bearing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `fn value() -> u32 { 'outer: loop { loop { break 'outer 5; } } }`. The
    // value leaves the OUTER loop, so the outer loop is the one that has to
    // carry one. Reading the break as the inner loop's exit would leave the
    // outer loop value-free, and the function would return nothing at all.
    const types = [_]ir.types.Type{.{ .prim = .u32 }};
    const exprs = [_]ir.exprs.Expr{
        strictExpr(0, .{ .block = .{
            .statements = &.{},
            .tail = 6,
            .labelled = null,
        } }),
        .{ .id = 1, .span = span, .ty = 0, .kind = litInt(5) },
        strictExpr(2, .{ .break_ = .{ .label = "outer", .value = 1 } }),
        strictExpr(3, .{ .block = .{
            .statements = &.{},
            .tail = 2,
            .labelled = null,
        } }),
        strictExpr(4, .{ .loop_ = .{ .body = .{
            .statements = &.{},
            .tail = 3,
            .labelled = null,
        } } }),
        strictExpr(5, .{ .block = .{
            .statements = &.{},
            .tail = 4,
            .labelled = null,
        } }),
        strictExpr(6, .{ .loop_ = .{ .body = .{
            .statements = &.{},
            .tail = 5,
            .labelled = "outer",
        } } }),
    };
    const source = try emitSingleFunctionSource(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u32 },
        .body = 0,
    } }, &exprs, &types);
    // The outer loop carries the value, so it goes inside a generated labelled
    // block and the exit names that block. Nothing names `outer` afterwards —
    // the only exit left the loop by another route — so the source label is
    // not written: Zig rejects a label nothing names.
    try std.testing.expect(std.mem.indexOf(u8, source, "outer:") == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "break :__r2z_value_loop_1 5;"),
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

test "lower: a compound assignment agrees with the binary spelling of one operation on overflow mode" {
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

    // `fn <fn_name>() -> u8 { let mut x = <start>; x <op>= <operand>; x }`.
    // `ts_ext.zig` writes `.wrapping` on every `AssignExpr`, so a plain `+=`
    // really does reach the backend carrying the same overflow mode the
    // binary path reads, and the two spellings have to land on one operator.
    const compound_probes = [_]struct {
        fn_name: []const u8,
        start: i128,
        op: ir.exprs.AssignOp,
        operand: i128,
        zig: []const u8,
        trapping: []const u8,
    }{
        // Round 2 emitted the trapping operator for all three: `x += 1;` on a
        // `u8` holding 255 panicked in both gate modes where the `255 + 1`
        // probe below wrapped to 0, so one Rust operation had two answers.
        .{ .fn_name = "bump", .start = 255, .op = .add, .operand = 1, .zig = "x +%= 1;", .trapping = "x += 1;" },
        .{ .fn_name = "drop_one", .start = 0, .op = .sub, .operand = 1, .zig = "x -%= 1;", .trapping = "x -= 1;" },
        .{ .fn_name = "grow", .start = 100, .op = .mul, .operand = 4, .zig = "x *%= 4;", .trapping = "x *= 4;" },
    };
    // The binary spellings of those same three operations.
    const binary_probes = [_]struct {
        fn_name: []const u8,
        op: ir.exprs.BinaryOp,
        lhs: i128,
        rhs: i128,
        zig: []const u8,
    }{
        .{ .fn_name = "binary_add", .op = .add, .lhs = 255, .rhs = 1, .zig = "return 255 +% 1;" },
        .{ .fn_name = "binary_sub", .op = .sub, .lhs = 0, .rhs = 1, .zig = "return 0 -% 1;" },
        .{ .fn_name = "binary_mul", .op = .mul, .lhs = 100, .rhs = 4, .zig = "return 100 *% 4;" },
        // `wrapping_add`, `wrapping_sub` and `wrapping_mul` wrap under BOTH
        // Rust profiles, so they must keep the wrapping operator after any
        // change to the compound path. `ts_ext.zig` lowers all three to the
        // node the plain operator produces — a `BinaryExpr` with `.overflow =
        // .wrapping` — so these rows are the one shape they all arrive as.
        .{ .fn_name = "wrapping_add_method", .op = .add, .lhs = 7, .rhs = 3, .zig = "return 7 +% 3;" },
        .{ .fn_name = "wrapping_sub_method", .op = .sub, .lhs = 7, .rhs = 3, .zig = "return 7 -% 3;" },
        .{ .fn_name = "wrapping_mul_method", .op = .mul, .lhs = 7, .rhs = 3, .zig = "return 7 *% 3;" },
    };

    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const types = [_]ir.types.Type{u8_ty};
    var model = Model.init(alloc);

    // One `BodyKind` per graph entity, so each probe's function lands on its
    // own index and the local it binds stays bodyless.
    var bodies: std.ArrayListUnmanaged(ir.bodies.BodyKind) = .empty;
    var crate_items: std.ArrayListUnmanaged(ir.spine.EntityId) = .empty;
    try bodies.append(alloc, .none); // the root module entity

    for (compound_probes) |probe| {
        const fn_id = try addLowerEntity(&graph, .fn_, probe.fn_name, root_id);
        const local_id = try addLowerEntity(&graph, .const_, "x", root_id);
        try crate_items.append(alloc, fn_id);

        const binding = try model.pat(.{ .binding = .{
            .name = "x",
            .mode = .value,
            .mutable = true,
        } });
        const start_literal = try model.e(litInt(probe.start));
        model.exprs.items[start_literal].ty = 0;
        const let_stmt = try model.stmt(.{ .let = .{
            .pattern = binding,
            .init = start_literal,
            .ty = null,
        } });
        const target = try model.e(.{ .path = .{ .def = local_id, .generic_args = &.{} } });
        model.exprs.items[target].ty = 0;
        const operand_literal = try model.e(litInt(probe.operand));
        model.exprs.items[operand_literal].ty = 0;
        const compound = try model.e(.{ .assign = .{
            .target = target,
            .op = probe.op,
            .value = operand_literal,
            .overflow = .wrapping,
        } });
        model.exprs.items[compound].ty = null;
        const compound_stmt = try model.stmt(.{ .expr = compound });
        const tail = try model.e(.{ .path = .{ .def = local_id, .generic_args = &.{} } });
        model.exprs.items[tail].ty = 0;
        const statements = try alloc.alloc(ir.exprs.NodeId, 2);
        statements[0] = let_stmt;
        statements[1] = compound_stmt;
        const body = try model.e(.{ .block = .{
            .statements = statements,
            .tail = tail,
            .labelled = null,
        } });

        try bodies.append(alloc, .{ .fn_ = .{
            .params = &.{},
            .ret = u8_ty,
            .generic_params = &.{},
            .body = body,
            .is_allocating = false,
        } });
        try bodies.append(alloc, .none); // the bound local
    }

    for (binary_probes) |probe| {
        const fn_id = try addLowerEntity(&graph, .fn_, probe.fn_name, root_id);
        try crate_items.append(alloc, fn_id);

        const lhs = try model.e(litInt(probe.lhs));
        model.exprs.items[lhs].ty = 0;
        const rhs = try model.e(litInt(probe.rhs));
        model.exprs.items[rhs].ty = 0;
        const sum = try model.e(.{ .binary = .{
            .op = probe.op,
            .overflow = .wrapping,
            .lhs = lhs,
            .rhs = rhs,
        } });
        model.exprs.items[sum].ty = 0;
        const body = try model.e(.{ .block = .{
            .statements = &.{},
            .tail = sum,
            .labelled = null,
        } });

        try bodies.append(alloc, .{ .fn_ = .{
            .params = &.{},
            .ret = u8_ty,
            .generic_params = &.{},
            .body = body,
            .is_allocating = false,
        } });
    }

    try addBareCrate(&graph, alloc, "overflow_agreement", root_id, crate_items.items);

    const rust_ir = ir.RustIr{
        .crate_name = "overflow_agreement",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = bodies.items,
        },
    };

    const source = try emitRootSource(alloc, &rust_ir);
    for (compound_probes) |probe| {
        std.testing.expect(std.mem.indexOf(u8, source, probe.zig) != null) catch |err| {
            std.debug.print("missing compound assignment: {s}\n", .{probe.zig});
            return err;
        };
        // The trapping spelling must be gone: it is what turned `255u8 + 1`
        // and `x += 1` into two different answers.
        std.testing.expect(std.mem.indexOf(u8, source, probe.trapping) == null) catch |err| {
            std.debug.print("trapping compound assignment survived: {s}\n", .{probe.trapping});
            return err;
        };
    }
    for (binary_probes) |probe| {
        std.testing.expect(std.mem.indexOf(u8, source, probe.zig) != null) catch |err| {
            std.debug.print("missing binary expression: {s}\n", .{probe.zig});
            return err;
        };
    }
}

test "lower: a float compound assignment keeps the plain operator" {
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

    // Zig spells the wrapping compound form for integers only — `f64 +%= f64`
    // does not compile — so a float target must keep the plain operator even
    // though its `AssignExpr` carries the same `.wrapping` an integer one has.
    const fn_id = try addLowerEntity(&graph, .fn_, "drift", root_id);
    const local_id = try addLowerEntity(&graph, .const_, "x", root_id);
    try addBareCrate(&graph, alloc, "float_compound", root_id, &.{fn_id});

    const f64_ty: ir.types.Type = .{ .prim = .f64 };
    const types = [_]ir.types.Type{f64_ty};
    var model = Model.init(alloc);

    const binding = try model.pat(.{ .binding = .{
        .name = "x",
        .mode = .value,
        .mutable = true,
    } });
    const start_literal = try model.e(.{ .literal = .{ .float = .{ .text = "", .value = 1.5 } } });
    model.exprs.items[start_literal].ty = 0;
    const let_stmt = try model.stmt(.{ .let = .{
        .pattern = binding,
        .init = start_literal,
        .ty = null,
    } });
    const target = try model.e(.{ .path = .{ .def = local_id, .generic_args = &.{} } });
    model.exprs.items[target].ty = 0;
    const operand_literal = try model.e(.{ .literal = .{ .float = .{ .text = "", .value = 0.25 } } });
    model.exprs.items[operand_literal].ty = 0;
    const compound = try model.e(.{ .assign = .{
        .target = target,
        .op = .add,
        .value = operand_literal,
        .overflow = .wrapping,
    } });
    model.exprs.items[compound].ty = null;
    const compound_stmt = try model.stmt(.{ .expr = compound });
    const tail = try model.e(.{ .path = .{ .def = local_id, .generic_args = &.{} } });
    model.exprs.items[tail].ty = 0;
    const statements = try alloc.alloc(ir.exprs.NodeId, 2);
    statements[0] = let_stmt;
    statements[1] = compound_stmt;
    const body = try model.e(.{ .block = .{
        .statements = statements,
        .tail = tail,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = f64_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "float_compound",
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

    const source = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(u8, source, "var x: f64 = 1.5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "x += 0.25;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "x +%= 0.25;") == null);
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

test "lower: a binding a local closure captures by mutable reference stays a var" {
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

    // `let mut t = a; let mut f = |x| { t += x; t }; ..`. The closure body is
    // emitted at its call site, so the block's own statement list cannot show
    // the assignment and the downgrade turned `t` into a `const`. A closure
    // without `move` that writes the binding captures it by `&mut`, so the
    // write reaches the outer binding and the `var` is load-bearing.
    const closure_captures = [_]ir.exprs.Capture{.{
        .name = "t",
        .mode = .by_mut_ref,
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

test "lower: a move closure capturing a local leaves the enclosing reassignment emitted" {
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
    const base_def = try addLowerEntity(&graph, .const_, "base", root_id);
    const captured_def = try addLowerEntity(&graph, .const_, "captured", root_id);
    const add_def = try addLowerEntity(&graph, .const_, "add", root_id);
    const outer_fn = try addLowerEntity(&graph, .fn_, "outer", root_id);
    try addBareCrate(&graph, alloc, "move_closure_capture", root_id, &.{outer_fn});

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const types = [_]ir.types.Type{u32_ty};
    var model = Model.init(alloc);

    // `let mut captured = base; let add = move |x: u32| x + captured;
    //  captured = 20; add(value) + captured`
    //
    // A `move` closure takes the captured value by value, so the closure body
    // reads the `__r2z_capture_*` snapshot and never the enclosing binding.
    // The only assignment to `captured` is the one in this block, and it has
    // to be emitted: without it the local is a `var` nothing writes and Zig
    // rejects the generated function.
    const closure_captures = [_]ir.exprs.Capture{.{
        .name = "captured",
        .mode = .by_value,
        .ty = 0,
    }};
    const param_x = try model.pat(.{ .binding = .{
        .name = "x",
        .mode = .value,
        .mutable = false,
    } });
    const closure_param_ref = try model.e(.{ .path = .{ .def = add_def, .generic_args = &.{} } });
    model.exprs.items[closure_param_ref].ty = 0;
    const captured_in_closure = try model.e(.{ .path = .{ .def = captured_def, .generic_args = &.{} } });
    model.exprs.items[captured_in_closure].ty = 0;
    const closure_body_expr = try model.e(.{ .binary = .{
        .op = .add,
        .overflow = .checked,
        .lhs = closure_param_ref,
        .rhs = captured_in_closure,
    } });
    model.exprs.items[closure_body_expr].ty = 0;
    const closure = try model.e(.{ .closure = .{
        .captures = &closure_captures,
        .params = &.{param_x},
        .return_ty = 0,
        .body = .{ .statements = &.{}, .tail = closure_body_expr, .labelled = null },
        .trait = .@"fn",
    } });
    model.exprs.items[closure].ty = 0;

    const bind_captured = try model.pat(.{ .binding = .{
        .name = "captured",
        .mode = .value,
        .mutable = true,
    } });
    const init_captured = try model.e(.{ .path = .{ .def = base_def, .generic_args = &.{} } });
    model.exprs.items[init_captured].ty = 0;
    const let_captured = try model.stmt(.{ .let = .{
        .pattern = bind_captured,
        .init = init_captured,
        .ty = null,
    } });
    const bind_add = try model.pat(.{ .binding = .{
        .name = "add",
        .mode = .value,
        .mutable = false,
    } });
    const let_add = try model.stmt(.{ .let = .{
        .pattern = bind_add,
        .init = closure,
        .ty = null,
    } });

    // `captured = 20;`
    const assign_target = try model.e(.{ .path = .{ .def = captured_def, .generic_args = &.{} } });
    model.exprs.items[assign_target].ty = 0;
    const twenty = try model.e(.{ .literal = .{ .int = .{
        .text = "20",
        .value = 20,
        .base = .dec,
        .ty_suffix = null,
    } } });
    model.exprs.items[twenty].ty = 0;
    const assign_expr = try model.e(.{ .assign = .{
        .target = assign_target,
        .op = .plain,
        .value = twenty,
        .overflow = .checked,
    } });
    model.exprs.items[assign_expr].ty = null;
    const assign_stmt = try model.stmt(.{ .expr = assign_expr });

    // The tail reads `captured` back, so the value the assignment writes is
    // the one the function returns.
    const tail = try model.e(.{ .path = .{ .def = captured_def, .generic_args = &.{} } });
    model.exprs.items[tail].ty = 0;

    const outer_statements = try alloc.alloc(ir.exprs.NodeId, 3);
    outer_statements[0] = let_captured;
    outer_statements[1] = let_add;
    outer_statements[2] = assign_stmt;
    const body = try model.e(.{ .block = .{
        .statements = outer_statements,
        .tail = tail,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "base", .ty = u32_ty, .span = span };
    body_rows[outer_fn] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "move_closure_capture",
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

    // The `move` closure reads the snapshot, so the enclosing binding is only
    // written by the assignment below and stays a `var`.
    try std.testing.expect(std.mem.indexOf(u8, source, "var captured: u32 = base;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const captured: u32 = base;") == null);
    // The assignment is emitted, and the local is read after it.
    try std.testing.expect(std.mem.indexOf(u8, source, "captured = 20;") != null);
    const assignment = std.mem.indexOf(u8, source, "captured = 20;").?;
    const read_back = std.mem.lastIndexOf(u8, source, "captured").?;
    try std.testing.expect(read_back > assignment);
    // The closure body reads the snapshot, not the enclosing binding.
    try std.testing.expect(std.mem.indexOf(u8, source, "__r2z_capture_add_captured") != null);
}

test "lower: a move closure capturing a local that is never reassigned binds a const" {
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
    const base_def = try addLowerEntity(&graph, .const_, "base", root_id);
    const captured_def = try addLowerEntity(&graph, .const_, "captured", root_id);
    const outer_fn = try addLowerEntity(&graph, .fn_, "outer", root_id);
    try addBareCrate(&graph, alloc, "move_closure_unreassigned", root_id, &.{outer_fn});

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const types = [_]ir.types.Type{u32_ty};
    var model = Model.init(alloc);

    // `let mut captured = base; let add = move |x: u32| { captured += x; captured };`
    //
    // The closure owns the value, so its `+=` writes the snapshot. Nothing
    // assigns the enclosing binding, and Zig rejects a `var` that is never
    // mutated — the binding has to be a `const`.
    const closure_captures = [_]ir.exprs.Capture{.{
        .name = "captured",
        .mode = .by_value,
        .ty = 0,
    }};
    const param_x = try model.pat(.{ .binding = .{
        .name = "x",
        .mode = .value,
        .mutable = false,
    } });
    const captured_in_closure = try model.e(.{ .path = .{ .def = captured_def, .generic_args = &.{} } });
    model.exprs.items[captured_in_closure].ty = 0;
    const closure_body_expr = try model.e(.{ .assign = .{
        .target = captured_in_closure,
        .op = .add,
        .value = param_x,
        .overflow = .wrapping,
    } });
    model.exprs.items[closure_body_expr].ty = null;
    const closure_body_read = try model.e(.{ .path = .{ .def = captured_def, .generic_args = &.{} } });
    model.exprs.items[closure_body_read].ty = 0;
    const closure = try model.e(.{ .closure = .{
        .captures = &closure_captures,
        .params = &.{param_x},
        .return_ty = 0,
        .body = .{ .statements = &.{}, .tail = closure_body_read, .labelled = null },
        .trait = .fn_mut,
    } });
    model.exprs.items[closure].ty = 0;

    const bind_captured = try model.pat(.{ .binding = .{
        .name = "captured",
        .mode = .value,
        .mutable = true,
    } });
    const init_captured = try model.e(.{ .path = .{ .def = base_def, .generic_args = &.{} } });
    model.exprs.items[init_captured].ty = 0;
    const let_captured = try model.stmt(.{ .let = .{
        .pattern = bind_captured,
        .init = init_captured,
        .ty = null,
    } });
    const bind_add = try model.pat(.{ .binding = .{
        .name = "add",
        .mode = .value,
        .mutable = false,
    } });
    const let_add = try model.stmt(.{ .let = .{
        .pattern = bind_add,
        .init = closure,
        .ty = null,
    } });

    const tail = try model.e(.{ .path = .{ .def = captured_def, .generic_args = &.{} } });
    model.exprs.items[tail].ty = 0;

    const outer_statements = try alloc.alloc(ir.exprs.NodeId, 2);
    outer_statements[0] = let_captured;
    outer_statements[1] = let_add;
    const body = try model.e(.{ .block = .{
        .statements = outer_statements,
        .tail = tail,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "base", .ty = u32_ty, .span = span };
    body_rows[outer_fn] = .{ .fn_ = .{
        .params = params,
        .ret = u32_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "move_closure_unreassigned",
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
    try std.testing.expect(std.mem.indexOf(u8, source, "const captured: u32 = base;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var captured: u32 = base;") == null);
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

// ── Match and the r2z runtime import ─────────────────────────────────────────

/// The three `match` shapes the runtime-import tests pin. They differ only in
/// whether the emitted file has to name the `r2z` runtime.
const MatchRuntimeFixture = enum {
    /// `match x { Some(v) => 1, None => 0 }` over `Option<u8>`. Zig cannot
    /// destructure an optional, so the `Some` payload is read back through
    /// `r2z.option.unwrap` and the file has to import the runtime with it.
    option_payload,
    /// `match x { Some(_) => 1, None => 0 }` over `Option<u8>`. The optional
    /// lowering runs, but no arm reads a payload, so nothing names the
    /// runtime and the import must stay absent.
    option_wildcard,
    /// `match x { 0 => 1, _ => 0 }` over `u8`. The scrutinee is not an
    /// optional, so the optional lowering never runs at all.
    plain_int,
};

/// The `r2z` runtime import exactly as the emitter writes it. A file that
/// names `r2z.` and lacks this line is what `zig build` rejects with `use of
/// undeclared identifier 'r2z'`.
const runtime_import_line = "const r2z = @import(\"r2z\");";

fn runtimeImportCount(file: ast.File) usize {
    var count: usize = 0;
    for (file.imports) |entry| {
        if (std.mem.eql(u8, entry.local_name, "r2z") and
            std.mem.eql(u8, entry.module_or_path, "r2z")) count += 1;
    }
    return count;
}

/// Lower a one-function crate whose body is a single `match` and return the
/// whole package, so the test can read both the emitted source and the
/// import list the compiler is handed.
///
/// The `Option` fixtures reproduce what the frontend hands the lowerer for
/// `Some(v)`: a `struct_pat` on the `Some` variant with a single `"0"` field,
/// and a `path` pattern naming `None` — see `ts_ext`'s
/// `tuple_struct_pattern` arm.
fn lowerMatchRuntimeFixture(
    alloc: std.mem.Allocator,
    fixture: MatchRuntimeFixture,
) !ast.Package {
    const is_option = fixture != .plain_int;

    var graph = ir.graph.CrateGraph.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "classify", null);
    const param_id = try addLowerEntity(&graph, .field, "x", fn_id);
    const some_id = try addLowerEntity(&graph, .variant, "Some", null);
    const none_id = try addLowerEntity(&graph, .variant, "None", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "match_runtime_fixture",
        .edition = 2021,
        .items = &.{fn_id},
    });

    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    // `.option` holds a pointer, so the payload type has to outlive this
    // frame; a stack cell would dangle as soon as the package is returned.
    const u8_cell = try alloc.create(ir.types.Type);
    u8_cell.* = u8_ty;
    const option_u8_ty: ir.types.Type = .{ .option = u8_cell };
    // 0 = u8, 1 = Option<u8>
    const types = [_]ir.types.Type{ u8_ty, option_u8_ty };

    var model = Model.init(alloc);
    const scrutinee = try model.e(.{ .path = .{ .def = param_id, .generic_args = &.{} } });
    const scrutinee_ty: ir.spine.TypeId = if (is_option) 1 else 0;
    model.exprs.items[scrutinee].ty = scrutinee_ty;

    const some_payload = if (fixture == .option_payload)
        try model.pat(.{ .binding = .{
            .name = "v",
            .mode = .{ .value = {} },
            .mutable = false,
        } })
    else
        try model.pat(.wildcard);
    const some_fields = try alloc.alloc(ir.exprs.FieldPat, 1);
    some_fields[0] = .{ .field = "0", .pat = some_payload, .shorthand = true };
    const some_pat = if (is_option)
        try model.pat(.{ .struct_pat = .{
            .def = some_id,
            .fields = some_fields,
            .rest = false,
        } })
    else
        try model.pat(.{ .literal = .{
            .int = .{ .text = "", .value = 0, .base = .dec, .ty_suffix = null },
        } });
    const none_pat = if (is_option)
        try model.pat(.{ .path = .{ .def = none_id, .variant = "None" } })
    else
        try model.pat(.wildcard);

    const some_selectors = try alloc.alloc(ir.exprs.NodeId, 1);
    some_selectors[0] = some_pat;
    const none_selectors = try alloc.alloc(ir.exprs.NodeId, 1);
    none_selectors[0] = none_pat;
    const ir_arms = try alloc.alloc(ir.exprs.MatchArm, 2);
    ir_arms[0] = .{
        .patterns = some_selectors,
        .guard = null,
        .body = try model.e(litInt(1)),
    };
    ir_arms[1] = .{
        .patterns = none_selectors,
        .guard = null,
        .body = try model.e(litInt(0)),
    };
    const match_expr = try model.e(.{ .match = .{
        .scrutinee = scrutinee,
        .arms = ir_arms,
        .option_scrutinee = false,
    } });
    const body = try model.e(.{
        .block = .{ .statements = &.{}, .tail = match_expr, .labelled = null },
    });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{
        .name = "x",
        .ty = if (is_option) option_u8_ty else u8_ty,
        .span = span,
    };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = u8_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "match_runtime_fixture",
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

test "lower: a match on an Option imports the runtime its payload read-back names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try lowerMatchRuntimeFixture(alloc, .option_payload);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    const file = pkg.files[0];
    const source = try emit.emitFile(alloc, &file);

    // The `Some` arm reads the payload back through the runtime ...
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.option.unwrap") != null);
    // ... so the file has to bind that module. Naming `r2z.` without this
    // import is exactly the `use of undeclared identifier 'r2z'` that made
    // a correct nine-line crate fail to build.
    try std.testing.expectEqual(@as(usize, 1), runtimeImportCount(file));
    try std.testing.expect(std.mem.indexOf(u8, source, runtime_import_line) != null);
}

test "lower: a wildcard Some arm on an Option does not import the r2z runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `Some(_)` reads no payload, so the optional branch runs without ever
    // naming the runtime. The mark belongs to the payload read-back, not to
    // the `Some`/`None` desugaring as a whole.
    const pkg = try lowerMatchRuntimeFixture(alloc, .option_wildcard);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    const source = try emit.emitFile(alloc, &pkg.files[0]);

    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.") == null);
    try std.testing.expectEqual(@as(usize, 0), runtimeImportCount(pkg.files[0]));
}

test "lower: a match on a plain integer does not import the r2z runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The scrutinee is `u8`, so `option_name` stays null and the whole
    // optional lowering — including the payload read-back that carries the
    // import — is skipped.
    const pkg = try lowerMatchRuntimeFixture(alloc, .plain_int);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    const source = try emit.emitFile(alloc, &pkg.files[0]);

    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.") == null);
    try std.testing.expectEqual(@as(usize, 0), runtimeImportCount(pkg.files[0]));
}

// ── Match guards ──────────────────────────────────────────────────────────────

/// Which `match` shape the guard fixtures lower.
const GuardMatchFixture = enum {
    /// `match x { Some(v) if v <= n => v, _ => n }` over `Option<u8>`. The
    /// guard reads the payload its own arm binds, so the `r2z` read-back has
    /// to sit outside the test for `v` to be in scope when it runs.
    option_payload,
    /// `match x { 0 if x == 0 => 1, _ => 2 }` over `u8`. Not an optional, so
    /// the optional lowering is not involved at all.
    plain,
};

/// Lower a one-function crate whose body is a single guarded `match` and
/// return the package.
fn lowerGuardMatchFixture(
    alloc: std.mem.Allocator,
    fixture: GuardMatchFixture,
) !ast.Package {
    const is_option = fixture == .option_payload;

    var graph = ir.graph.CrateGraph.init(alloc);
    const fn_id = try addLowerEntity(&graph, .fn_, "classify", null);
    const x_id = try addLowerEntity(&graph, .field, "x", fn_id);
    const n_id = try addLowerEntity(&graph, .field, "n", fn_id);
    // The payload binding reaches the guard and the body as an ordinary path,
    // the same way `if let Some(v) = x` hands `v` to its then-branch.
    const v_id = try addLowerEntity(&graph, .const_, "v", null);
    const some_id = try addLowerEntity(&graph, .variant, "Some", null);
    _ = try addRootModule(&graph, .{
        .crate_name = "match_guard_fixture",
        .edition = 2021,
        .items = &.{fn_id},
    });

    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const u8_cell = try alloc.create(ir.types.Type);
    u8_cell.* = u8_ty;
    const option_u8_ty: ir.types.Type = .{ .option = u8_cell };
    // 0 = u8, 1 = Option<u8>, 2 = bool
    const bool_ty: ir.types.Type = .{ .prim = .bool };
    const types = [_]ir.types.Type{ u8_ty, option_u8_ty, bool_ty };

    var model = Model.init(alloc);

    const scrutinee = try model.e(.{ .path = .{ .def = x_id, .generic_args = &.{} } });
    const scrutinee_ty: ir.spine.TypeId = if (is_option) 1 else 0;
    model.exprs.items[scrutinee].ty = scrutinee_ty;

    // The guard: `v <= n` on the optional, `x == 0` on the plain match.
    const guard_operand = if (is_option) v_id else x_id;
    const guard_lhs = try model.e(.{ .path = .{ .def = guard_operand, .generic_args = &.{} } });
    model.exprs.items[guard_lhs].ty = 0;
    const guard_rhs = if (is_option)
        try model.e(.{ .path = .{ .def = n_id, .generic_args = &.{} } })
    else
        try model.e(litInt(0));
    model.exprs.items[guard_rhs].ty = 0;
    const guard = try model.e(.{ .binary = .{
        .op = if (is_option) .le else .eq,
        .lhs = guard_lhs,
        .rhs = guard_rhs,
        .overflow = .checked,
    } });
    model.exprs.items[guard].ty = 2;

    const payload = try model.pat(.{ .binding = .{
        .name = "v",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    const some_fields = try alloc.alloc(ir.exprs.FieldPat, 1);
    some_fields[0] = .{ .field = "0", .pat = payload, .shorthand = true };
    const guarded_pat = if (is_option)
        try model.pat(.{ .struct_pat = .{
            .def = some_id,
            .fields = some_fields,
            .rest = false,
        } })
    else
        try model.pat(.{ .literal = .{
            .int = .{ .text = "", .value = 0, .base = .dec, .ty_suffix = null },
        } });
    const fallback_pat = try model.pat(.wildcard);

    const guarded_selectors = try alloc.alloc(ir.exprs.NodeId, 1);
    guarded_selectors[0] = guarded_pat;
    const fallback_selectors = try alloc.alloc(ir.exprs.NodeId, 1);
    fallback_selectors[0] = fallback_pat;

    const guarded_value = if (is_option)
        try model.e(.{ .path = .{ .def = v_id, .generic_args = &.{} } })
    else
        try model.e(litInt(1));
    model.exprs.items[guarded_value].ty = 0;
    const fallback_value = try model.e(litInt(if (is_option) 7 else 2));
    model.exprs.items[fallback_value].ty = 0;

    const ir_arms = try alloc.alloc(ir.exprs.MatchArm, 2);
    ir_arms[0] = .{
        .patterns = guarded_selectors,
        .guard = guard,
        .body = guarded_value,
    };
    ir_arms[1] = .{
        .patterns = fallback_selectors,
        .guard = null,
        .body = fallback_value,
    };
    const match_expr = try model.e(.{ .match = .{
        .scrutinee = scrutinee,
        .arms = ir_arms,
        .option_scrutinee = false,
    } });
    model.exprs.items[match_expr].ty = 0;
    const body = try model.e(.{
        .block = .{ .statements = &.{}, .tail = match_expr, .labelled = null },
    });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const params = try alloc.alloc(ir.items.Param, 2);
    params[0] = .{
        .name = "x",
        .ty = if (is_option) option_u8_ty else u8_ty,
        .span = span,
    };
    params[1] = .{ .name = "n", .ty = u8_ty, .span = span };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = u8_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "match_guard_fixture",
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The single `match` a fixture lowers, with the `Option` wrapper peeled off
/// so a test can read the switch itself.
fn fixtureMatchExpr(file: ast.File) !ast.Match {
    for (file.decls) |decl| {
        if (decl != .fn_decl) continue;
        const fn_body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
        const tail = (fn_body.expr orelse return error.ExpectedFunctionTail).*;
        return switch (tail) {
            .match_expr => |value| value,
            // The `Option` fixtures wrap the switch in the block that binds
            // the optional subject.
            .block => |block| switch ((block.expr orelse return error.ExpectedFunctionTail).*) {
                .match_expr => |value| value,
                else => return error.ExpectedMatchBody,
            },
            else => return error.ExpectedMatchBody,
        };
    }
    return error.ExpectedMatchFunction;
}

/// The integer a lowered arm body or branch evaluates to. Switch captures
/// take the payload by value, so no field access has to guess at
/// pointer-versus-value on a union.
fn expectIntBody(body: ast.Expr) !i128 {
    const literal = switch (body) {
        .lit => |value| value,
        else => return error.ExpectedIntBody,
    };
    return switch (literal) {
        .int => |value| value,
        else => return error.ExpectedIntBody,
    };
}

fn expectIdent(body: ast.Expr) ![]const u8 {
    return switch (body) {
        .ident => |name| name,
        else => return error.ExpectedIdent,
    };
}

/// The label the ordered chain a guarded `match` lowers to carries, read back
/// out of the emitted source. Reading it back keeps a regression on the source
/// a reader sees rather than on the name the lowerer happened to pick.
fn guardChainLabel(source: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, "__r2z_match_block") orelse
        return error.MissingGuardChain;
    // The block's own label, up to the `: {` that opens it.
    const open = std.mem.indexOfPos(u8, source, start, ": {") orelse
        return error.MissingGuardChain;
    return source[start..open];
}

/// The `break :<label>` every exit the chain generates starts with.
fn guardExitPrefix(buf: []u8, label: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "break :{s}", .{label});
}

/// The exit the chain generates for an arm that yields `value`.
fn guardExit(buf: []u8, label: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "break :{s} {s};", .{ label, value });
}

/// The emitted Zig for one of the guarded-match fixture shapes.
fn guardFixtureSource(fixture: GuardMatchFixture) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const package = try lowerGuardMatchFixture(alloc, fixture);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

/// An integer literal of type `ty` in the fixture's model.
fn typedInt(
    model: *Model,
    value: i128,
    ty: ir.exprs.TypeId,
) !ir.exprs.NodeId {
    const id = try model.e(litInt(value));
    model.exprs.items[id].ty = ty;
    return id;
}

/// `lhs == rhs` in the fixture's model.
fn typedEq(
    model: *Model,
    lhs: ir.exprs.NodeId,
    rhs: ir.exprs.NodeId,
) !ir.exprs.NodeId {
    const id = try model.e(.{ .binary = .{
        .op = .eq,
        .lhs = lhs,
        .rhs = rhs,
        .overflow = .checked,
    } });
    model.exprs.items[id].ty = 1;
    return id;
}

/// The one-selector list a literal match arm dispatches on.
fn literalSelectors(alloc: std.mem.Allocator, model: *Model, value: i128) ![]const ir.exprs.NodeId {
    const pattern = try model.pat(.{ .literal = .{
        .int = .{ .text = "", .value = value, .base = .dec, .ty_suffix = null },
    } });
    const out = try alloc.alloc(ir.exprs.NodeId, 1);
    out[0] = pattern;
    return out;
}

/// The one-entry selector list a single-pattern match arm dispatches on.
fn oneSelector(alloc: std.mem.Allocator, pattern: ir.exprs.NodeId) ![]const ir.exprs.NodeId {
    const out = try alloc.alloc(ir.exprs.NodeId, 1);
    out[0] = pattern;
    return out;
}

test "lower: a guard runs after its own payload is bound and the arm's value leaves the chain" {
    const source = try guardFixtureSource(.option_payload);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // The payload read-back has to sit ahead of the test, or the guard reads a
    // name that is not in scope yet.
    const readback = std.mem.indexOf(u8, source, "const v = r2z.option.unwrap(") orelse
        return error.MissingPayloadReadBack;
    const test_position = std.mem.indexOf(u8, source, "if (v <= n)") orelse
        return error.MissingGuardTest;
    try std.testing.expect(readback < test_position);

    // What the chain carries out is the arm's own value, under the chain's own
    // label, and a passing guard is what decides it: the guarded arm yields the
    // payload it just bound, the catch-all behind it yields its own literal.
    var buf: [128]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&buf, label, "v")) != null,
    );
    buf = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&buf, label, "7")) != null,
    );
    // Two arms, two exits. A false guard produces none, and no arm leaves the
    // chain through anyone else's.
    buf = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, try guardExitPrefix(&buf, label)),
    );
    // Nothing can reach the end of the chain's block, so the fall-through past
    // the last dispatch is spelled rather than left as a hole in the block.
    try std.testing.expect(std.mem.indexOf(u8, source, "unreachable;") != null);
}

test "lower: a false match guard leaves the arm and the arm behind it gets its turn" {
    const source = try guardFixtureSource(.plain);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // One dispatch per arm, in source order, and each carries its own value out
    // of the same block. The literal selector cannot cover what follows it, so
    // its dispatch steps past itself instead of swallowing the catch-all.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(source, "switch ("));
    var buf: [128]u8 = undefined;
    const guarded = std.mem.indexOf(u8, source, try guardExit(&buf, label, "1")) orelse
        return error.MissingGuardedArm;
    buf = undefined;
    const fallback = std.mem.indexOf(u8, source, try guardExit(&buf, label, "2")) orelse
        return error.MissingFallbackArm;
    try std.testing.expect(guarded < fallback);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (x == 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "unreachable;") != null);
}

// ── The ordered chain: one dispatch per arm, in a labeled value block ────

/// The shapes that each break the ordered chain a different way.
const GuardScene = enum {
    /// `match p.value { 0 if n == 0 => 1, _ => 2 }`. The scrutinee is a place,
    /// so reading it once is a real question rather than a naming one.
    field_place,
    /// `match x { 1 if x == 1 => 10, 1 => 11, _ => 12 }`. The same literal
    /// selector twice, guarded the first time, is what a fall-through tree gets
    /// wrong: the second arm has to stay reachable behind the first arm's guard.
    repeated_selector,
    /// `match p.value { Tag(ref v) if (*v) == 0 => *v, _ => 2 }`. A capture by
    /// reference has to reach the source's own storage, so the place is aliased
    /// rather than copied.
    ref_capture,
    /// `match 7 { 7 if false => 10, 7 => 11, _ => 12 }`. A constant scrutinee
    /// and a constant guard: the guard still decides which arm runs, and the
    /// scrutinee is still read once however many dispatches read it.
    constant,
    /// `loop { match x { 0 if x == 0 => break, 1 if x == 1 => continue,
    /// _ => 9 }; }`. The arm bodies exit the source loop, which is a different
    /// target from the chain that carries them.
    nested_exit,
};

/// The emitted Zig for a guard scene, owned by the caller.
fn guardSceneSource(scene: GuardScene) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = try buildGuardSceneSource(alloc, scene);
    // The arena dies with this frame, so the caller must own the text.
    return std.testing.allocator.dupe(u8, source);
}

/// Lower a one-function crate whose body is a single guarded `match` — or, for
/// the exit scene, a loop around one — and return the emitted Zig.
fn buildGuardSceneSource(alloc: std.mem.Allocator, scene: GuardScene) ![]const u8 {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const cell_id = try addLowerEntity(&graph, .struct_, "Cell", null);
    const value_def = try addLowerEntity(&graph, .field, "value", cell_id);
    const tag_id = try addLowerEntity(&graph, .variant, "Tag", null);
    const v_def = try addLowerEntity(&graph, .const_, "v", null);
    const fn_id = try addLowerEntity(&graph, .fn_, "classify", null);
    const p_def = try addLowerEntity(&graph, .field, "p", fn_id);
    const n_def = try addLowerEntity(&graph, .field, "n", fn_id);
    const x_def = try addLowerEntity(&graph, .field, "x", fn_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "guard_scene",
        .edition = 2021,
        .items = &.{ cell_id, fn_id },
    });

    const cell_segments = [_]ir.types.PathSegment{.{ .name = "Cell", .id = cell_id }};
    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const bool_ty: ir.types.Type = .{ .prim = .bool };
    const cell_ty: ir.types.Type = .{ .path = .{ .segments = &cell_segments } };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    // 0 = u64, 1 = bool, 2 = Cell, 3 = unit.
    const types = [_]ir.types.Type{ u64_ty, bool_ty, cell_ty, unit_ty };

    // `p.value`, the place a reference capture has to keep reaching.
    const p_path = try model.e(.{ .path = .{ .def = p_def, .generic_args = &.{} } });
    model.exprs.items[p_path].ty = 2;
    const place = try model.e(.{ .field = .{
        .base = p_path,
        .field = "value",
        .resolved = value_def,
    } });
    model.exprs.items[place].ty = 0;
    const n_path = try model.e(.{ .path = .{ .def = n_def, .generic_args = &.{} } });
    model.exprs.items[n_path].ty = 0;
    const x_path = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
    model.exprs.items[x_path].ty = 0;
    // `*v`, the value a reference capture reaches.
    const v_path = try model.e(.{ .path = .{ .def = v_def, .generic_args = &.{} } });
    model.exprs.items[v_path].ty = 0;
    const v_pointee = try model.e(.{ .unary = .{ .op = .deref, .operand = v_path } });
    model.exprs.items[v_pointee].ty = 0;

    // `Tag(ref v)`, the shape a by-reference capture lowers from.
    const ref_binding = try model.pat(.{ .binding = .{
        .name = "v",
        .mode = .shared_ref,
        .mutable = false,
    } });
    const ref_fields = try alloc.alloc(ir.exprs.FieldPat, 1);
    ref_fields[0] = .{ .field = "0", .pat = ref_binding, .shorthand = false };
    const ref_pattern = try model.pat(.{ .struct_pat = .{
        .def = tag_id,
        .fields = ref_fields,
        .rest = false,
    } });
    const any_pattern = try model.pat(.wildcard);
    const ir_arms = try alloc.alloc(ir.exprs.MatchArm, 3);
    const scrutinee = switch (scene) {
        .field_place => place,
        .ref_capture => place,
        .constant => try typedInt(&model, 7, 0),
        .repeated_selector, .nested_exit => x_path,
    };
    switch (scene) {
        .field_place => ir_arms[0] = .{
            .patterns = try literalSelectors(alloc, &model, 0),
            .guard = try typedEq(&model, n_path, try typedInt(&model, 0, 0)),
            .body = try typedInt(&model, 1, 0),
        },
        .ref_capture => ir_arms[0] = .{
            .patterns = try oneSelector(alloc, ref_pattern),
            .guard = try typedEq(&model, v_pointee, try typedInt(&model, 0, 0)),
            .body = v_pointee,
        },
        .constant => {
            const false_guard = try model.e(.{ .literal = .{ .boolean = false } });
            model.exprs.items[false_guard].ty = 1;
            ir_arms[0] = .{
                .patterns = try literalSelectors(alloc, &model, 7),
                .guard = false_guard,
                .body = try typedInt(&model, 10, 0),
            };
        },
        .repeated_selector => ir_arms[0] = .{
            .patterns = try literalSelectors(alloc, &model, 1),
            .guard = try typedEq(&model, x_path, try typedInt(&model, 1, 0)),
            .body = try typedInt(&model, 10, 0),
        },
        .nested_exit => ir_arms[0] = .{
            .patterns = try literalSelectors(alloc, &model, 0),
            .guard = try typedEq(&model, x_path, try typedInt(&model, 0, 0)),
            .body = try model.e(.{ .break_ = .{ .label = null, .value = null } }),
        },
    }
    switch (scene) {
        .constant, .repeated_selector => ir_arms[1] = .{
            .patterns = try literalSelectors(alloc, &model, if (scene == .constant) 7 else 1),
            .guard = null,
            .body = try typedInt(&model, 11, 0),
        },
        .nested_exit => ir_arms[1] = .{
            .patterns = try literalSelectors(alloc, &model, 1),
            .guard = try typedEq(&model, x_path, try typedInt(&model, 1, 0)),
            .body = try model.e(.{ .continue_ = .{ .label = null } }),
        },
        .field_place, .ref_capture => ir_arms[1] = .{
            .patterns = try oneSelector(alloc, any_pattern),
            .guard = null,
            .body = try typedInt(&model, 2, 0),
        },
    }
    ir_arms[2] = .{
        .patterns = try oneSelector(alloc, any_pattern),
        .guard = null,
        // Each scene states its own catch-all: the exit scene's loop answers 9,
        // the other two answer the 12 their own source spells.
        .body = try typedInt(&model, if (scene == .nested_exit) 9 else 12, 0),
    };
    const match_expr = try model.e(.{ .match = .{
        .scrutinee = scrutinee,
        .arms = ir_arms,
        .option_scrutinee = false,
    } });
    model.exprs.items[match_expr].ty = 0;

    const body = switch (scene) {
        .nested_exit => blk: {
            // The match is a statement of the loop body, so the only value the
            // loop can produce is the one the chain hands back to it.
            const inner = try model.e(.{ .block = .{
                .statements = try alloc.dupe(ir.exprs.NodeId, &.{try model.stmt(.{ .expr = match_expr })}),
                .tail = null,
                .labelled = null,
            } });
            break :blk try model.e(.{ .loop_ = .{ .body = .{
                .statements = &.{},
                .tail = inner,
                .labelled = null,
            } } });
        },
        else => try model.e(.{ .block = .{
            .statements = &.{},
            .tail = match_expr,
            .labelled = null,
        } }),
    };

    const params = try alloc.alloc(ir.items.Param, 3);
    params[0] = .{ .name = "p", .ty = cell_ty, .span = span };
    params[1] = .{ .name = "n", .ty = u64_ty, .span = span };
    params[2] = .{ .name = "x", .ty = u64_ty, .span = span };
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[cell_id] = .{ .struct_ = .{
        .fields = &.{.{ .name = "value", .ty = u64_ty, .visibility = .public, .span = span }},
        .methods = &.{},
    } };
    body_rows[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = if (scene == .nested_exit) unit_ty else u64_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "guard_scene",
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
    return emitRootSource(alloc, &rust_ir);
}

test "lower: a guarded match reads its scrutinee once and every dispatch reads the same value" {
    const source = try guardSceneSource(.field_place);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // One read of the place, whatever the number of dispatches: the scrutinee
    // is bound ahead of the chain instead of being re-evaluated per arm.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "p.value"));
    // Both dispatches name that one binding, and both leave through the chain's
    // own label, so the fall-through reads what the first dispatch read.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(source, "switch ("));
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, try guardExitPrefix(&buf, label)),
    );
}

test "lower: a reference capture keeps reading the source's own storage" {
    const source = try guardSceneSource(.ref_capture);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // The place is taken by address, and taken once. A copy would still read
    // the place a single time, but the capture would then point into storage
    // the source never sees.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "p.value"));
    try std.testing.expect(std.mem.indexOf(u8, source, "&p.value") != null);
    // The capture is still a pointer capture, so `v` names the matched value in
    // the place the dispatches read, and the arm yields what it points at.
    try std.testing.expect(std.mem.indexOf(u8, source, "|*v|") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "v.*") != null);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, try guardExitPrefix(&buf, label)),
    );
}

test "lower: a repeated guarded selector leaves the arm behind it reachable" {
    const source = try guardSceneSource(.repeated_selector);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // The guarded arm and the plain arm behind it carry the same literal, so
    // neither may swallow the other: three dispatches, each a selector of its
    // own, each yielding its own value in the order Rust lists them.
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(source, "switch ("));
    var buf: [128]u8 = undefined;
    const guarded = std.mem.indexOf(u8, source, try guardExit(&buf, label, "10")) orelse
        return error.MissingGuardedArm;
    buf = undefined;
    const repeated = std.mem.indexOf(u8, source, try guardExit(&buf, label, "11")) orelse
        return error.MissingRepeatedArm;
    buf = undefined;
    const catch_all = std.mem.indexOf(u8, source, try guardExit(&buf, label, "12")) orelse
        return error.MissingCatchAllArm;
    try std.testing.expect(guarded < repeated);
    try std.testing.expect(repeated < catch_all);
    // The guard is still there: a false one is the only way the arm behind it
    // gets its turn, so dropping it would hand the guarded arm every value.
    try std.testing.expect(std.mem.indexOf(u8, source, "if (x == 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "unreachable;") != null);
}

test "lower: a constant guard still decides the arm and a constant scrutinee is still read once" {
    const source = try guardSceneSource(.constant);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // `if (false)` is the whole reason the second `7` arm runs, so it may not be
    // folded away and may not be dropped: either would change which arm the
    // scrutinee reaches.
    try std.testing.expect(std.mem.indexOf(u8, source, "if (false)") != null);
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(source, "switch ("));
    var buf: [128]u8 = undefined;
    const guarded = std.mem.indexOf(u8, source, try guardExit(&buf, label, "10")) orelse
        return error.MissingGuardedArm;
    buf = undefined;
    const repeated = std.mem.indexOf(u8, source, try guardExit(&buf, label, "11")) orelse
        return error.MissingRepeatedArm;
    buf = undefined;
    const catch_all = std.mem.indexOf(u8, source, try guardExit(&buf, label, "12")) orelse
        return error.MissingCatchAllArm;
    try std.testing.expect(guarded < repeated);
    try std.testing.expect(repeated < catch_all);
    // A literal scrutinee is no exception: one binding, three dispatches.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "= 7;"));
}

test "lower: a break or continue in an arm body leaves the source loop, not the chain" {
    const source = try guardSceneSource(.nested_exit);
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // The chain is a labeled block, which is the whole point: an exit in an arm
    // body that names no label belongs to the loop around it, and there is no
    // loop here for it to land on by accident.
    try std.testing.expect(std.mem.indexOf(u8, source, "continue") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "break") != null);
    // Only the catch-all's value leaves through the chain. The other two arms
    // exit the loop instead, and neither of them was retargeted onto the
    // block that carries the match's result.
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, try guardExitPrefix(&buf, label)),
    );
    buf = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&buf, label, "9")) != null,
    );
}

/// `match values[next_index(&mut index)] { Some(ref mut v) if (*v) == 0 => { *v = 5; *v }, _ => 0 }`
///
/// The index is a call, so reading the place has a side effect of its own, and
/// the capture is a mutable reference, so the write in the guarded arm has to
/// land in the slice element the source named. A chain that copied the element
/// would read the place just as once and still swallow the write.
fn indexedRefPlaceIr(alloc: std.mem.Allocator) !ir.RustIr {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const slot_id = try addLowerEntity(&graph, .enum_, "Slot", null);
    const some_id = try addLowerEntity(&graph, .variant, "Some", null);
    const v_def = try addLowerEntity(&graph, .const_, "v", null);
    const next_id = try addLowerEntity(&graph, .fn_, "next_index", null);
    const classify_id = try addLowerEntity(&graph, .fn_, "classify", null);
    const values_def = try addLowerEntity(&graph, .field, "values", classify_id);
    const index_def = try addLowerEntity(&graph, .field, "index", classify_id);
    _ = try addRootModule(&graph, .{
        .crate_name = "indexed_ref_place",
        .edition = 2021,
        .items = &.{ slot_id, next_id, classify_id },
    });

    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const bool_ty: ir.types.Type = .{ .prim = .bool };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    // Both arrays outlive this frame: the IR below returns them, and a stack
    // slice read after the frame is gone is a wild pointer, not a type.
    const slot_segments = try alloc.alloc(ir.types.PathSegment, 1);
    slot_segments[0] = .{ .name = "Slot", .id = slot_id };
    const slot_ty: ir.types.Type = .{ .path = .{ .segments = slot_segments } };
    const slot_slice = try alloc.create(ir.types.Slice);
    slot_slice.* = .{ .const_ = false, .elem = slot_ty };
    const values_box = try alloc.create(ir.types.Ref);
    values_box.* = .{ .mut = true, .pointee = .{ .slice = slot_slice } };
    const index_box = try alloc.create(ir.types.Ref);
    index_box.* = .{ .mut = true, .pointee = usize_ty };
    const values_ty: ir.types.Type = .{ .reference = values_box };
    const index_ty: ir.types.Type = .{ .reference = index_box };
    // 0 = u64, 1 = bool, 2 = usize, 3 = Slot, 4 = `&mut [Slot]`, 5 = `&mut usize`.
    const types = try alloc.alloc(ir.types.Type, 6);
    @memcpy(types, &[_]ir.types.Type{ u64_ty, bool_ty, usize_ty, slot_ty, values_ty, index_ty });

    // `values[next_index(&mut index)]`. The index is a call that borrows
    // `index` mutably, so evaluating the place is not free.
    const values_path = try model.e(.{ .path = .{ .def = values_def, .generic_args = &.{} } });
    model.exprs.items[values_path].ty = 4;
    const index_path = try model.e(.{ .path = .{ .def = index_def, .generic_args = &.{} } });
    model.exprs.items[index_path].ty = 5;
    const index_borrow = try model.e(.{ .unary = .{
        .op = .{ .ref = .mutable },
        .operand = index_path,
    } });
    model.exprs.items[index_borrow].ty = 5;
    const borrow_args = try alloc.alloc(ir.exprs.NodeId, 1);
    borrow_args[0] = index_borrow;
    const next_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = next_id },
        .args = borrow_args,
    } });
    model.exprs.items[next_call].ty = 2;
    const scrutinee = try model.e(.{ .index = .{ .base = values_path, .index = next_call } });
    model.exprs.items[scrutinee].ty = 3;

    // `Some(ref mut v)`: the only pattern shape that yields a by-reference
    // capture, and a mutable one is the only kind that can be written through.
    const mut_binding = try model.pat(.{ .binding = .{
        .name = "v",
        .mode = .mut_ref,
        .mutable = true,
    } });
    const some_fields = try alloc.alloc(ir.exprs.FieldPat, 1);
    some_fields[0] = .{ .field = "0", .pat = mut_binding, .shorthand = false };
    const some_pattern = try model.pat(.{ .struct_pat = .{
        .def = some_id,
        .fields = some_fields,
        .rest = false,
    } });
    const any_pattern = try model.pat(.wildcard);

    // `if (*v) == 0 { *v = 5; *v }`.
    const v_path = try model.e(.{ .path = .{ .def = v_def, .generic_args = &.{} } });
    model.exprs.items[v_path].ty = 0;
    const v_pointee = try model.e(.{ .unary = .{ .op = .deref, .operand = v_path } });
    model.exprs.items[v_pointee].ty = 0;
    const guard = try typedEq(&model, v_pointee, try typedInt(&model, 0, 0));
    const write = try model.e(.{ .assign = .{
        .target = v_pointee,
        .op = .plain,
        .value = try typedInt(&model, 5, 0),
        .overflow = .wrapping,
    } });
    model.exprs.items[write].ty = 0;
    const write_stmts = try alloc.alloc(ir.exprs.NodeId, 1);
    write_stmts[0] = try model.stmt(.{ .expr = write });
    const guarded_body = try model.e(.{ .block = .{
        .statements = write_stmts,
        .tail = v_pointee,
        .labelled = null,
    } });
    model.exprs.items[guarded_body].ty = 0;

    const ir_arms = try alloc.alloc(ir.exprs.MatchArm, 2);
    ir_arms[0] = .{
        .patterns = try oneSelector(alloc, some_pattern),
        .guard = guard,
        .body = guarded_body,
    };
    ir_arms[1] = .{
        .patterns = try oneSelector(alloc, any_pattern),
        .guard = null,
        .body = try typedInt(&model, 0, 0),
    };
    const match_expr = try model.e(.{ .match = .{
        .scrutinee = scrutinee,
        .arms = ir_arms,
        .option_scrutinee = false,
    } });
    model.exprs.items[match_expr].ty = 0;
    const classify_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = match_expr,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const variants = try alloc.alloc(ir.items.Variant, 1);
    variants[0] = .{
        .name = "Some",
        .fields = .{ .tuple = &.{u64_ty} },
        .discriminant = null,
    };
    body_rows[slot_id] = .{ .enum_ = .{ .kind = .data, .variants = variants } };
    const next_params = try alloc.alloc(ir.items.Param, 1);
    next_params[0] = .{ .name = "index", .ty = index_ty, .span = span };
    body_rows[next_id] = .{ .fn_ = .{
        .params = next_params,
        .ret = usize_ty,
        .generic_params = &.{},
        .body = try typedInt(&model, 0, 2),
        .is_allocating = false,
    } };
    const classify_params = try alloc.alloc(ir.items.Param, 2);
    classify_params[0] = .{ .name = "values", .ty = values_ty, .span = span };
    classify_params[1] = .{ .name = "index", .ty = index_ty, .span = span };
    body_rows[classify_id] = .{ .fn_ = .{
        .params = classify_params,
        .ret = u64_ty,
        .generic_params = &.{},
        .body = classify_body,
        .is_allocating = false,
    } };

    return .{
        .crate_name = "indexed_ref_place",
        .edition = "2021",
        .graph = graph,
        .types = types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = types,
            .bodies = body_rows,
        },
    };
}

test "lower: a reference capture through an indexed place writes the source element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rust_ir = try indexedRefPlaceIr(alloc);
    // The arena dies with this frame, so the caller must own the text.
    const source = try std.testing.allocator.dupe(u8, try emitRootSource(alloc, &rust_ir));
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // The place is aliased, and aliased once. Reading it twice would advance
    // `index` twice and match a different element than the source did; a copy
    // would read it once too, and the write below would land in the copy.
    try std.testing.expect(std.mem.indexOf(u8, source, "&values[") != null);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "values["));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "next_index(&index)"));
    // The capture is a pointer capture over that alias, so the guarded arm
    // writes through it into the slice, and what the chain carries out is the
    // element the write just reached.
    try std.testing.expect(std.mem.indexOf(u8, source, "|*v|") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "v.* = 5;") != null);
    var buf: [128]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&buf, label, "v.*")) != null,
    );
    // The write sits inside the guard: a false guard reaches the arm behind it
    // without touching the element.
    try std.testing.expect(std.mem.indexOf(u8, source, "if (v.* == 0)") != null);
}

test "lower: a match without a guard keeps its plain switch shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The whole-match arm lowering must not put an `if` around an arm that
    // carries no guard: the common case has to come out exactly as it did
    // before the guards were implemented.
    const pkg = try lowerMatchRuntimeFixture(alloc, .plain_int);
    const match_expr = try fixtureMatchExpr(pkg.files[0]);
    try std.testing.expectEqual(@as(usize, 2), match_expr.arms.len);
    try std.testing.expectEqualStrings("x", try expectIdent(match_expr.target.*));
    if (match_expr.arms[0].patterns[0] != .lit) return error.ExpectedLiteralProng;
    try std.testing.expectEqual(@as(i128, 1), try expectIntBody(match_expr.arms[0].body));
    if (match_expr.arms[1].patterns[0] != .wildcard) return error.ExpectedFallbackProng;
    try std.testing.expectEqual(@as(i128, 0), try expectIntBody(match_expr.arms[1].body));
}

// ---------------------------------------------------------------------------
// Runtime `String` receiver storage
// ---------------------------------------------------------------------------

/// Append an expression node that carries a type, returning its dense NodeId.
fn typedExpr(model: *Model, type_id: ?ir.spine.TypeId, kind: ir.exprs.ExprKind) !ir.exprs.NodeId {
    const id: ir.exprs.NodeId = @intCast(model.exprs.items.len);
    try model.exprs.append(model.a(), .{
        .id = id,
        .span = span,
        .ty = type_id,
        .kind = kind,
    });
    return id;
}

/// The method name and receiver of a `receiver.method(..)` call.
const MethodCallShape = struct {
    method: []const u8,
    receiver: []const u8,
};

/// The `receiver.method(..)` call, read from the call itself.
///
/// Zig has no method dispatch: the emitter writes `receiver.method(args)` as a
/// `call` whose callee is the `receiver.method` field access. Both halves
/// therefore come out of the one node — the call carries the arguments, and
/// the callee of that callee carries the method and its receiver.
fn expectMethodCall(call_expr: *const ast.Expr) !struct { call: ast.Call, shape: MethodCallShape } {
    const call = switch (call_expr.*) {
        .call => |value| value,
        else => return error.ExpectedMethodCall,
    };
    const field = switch (call.callee.*) {
        .field_access => |value| value,
        else => return error.ExpectedMethodCall,
    };
    return .{
        .call = call,
        .shape = .{
            .method = field.field_name,
            .receiver = try expectIdent(field.target.*),
        },
    };
}

/// The `var` local a consuming `String` receiver is bound to, and the release
/// that follows it.
const StringReceiverBinding = struct {
    name: []const u8,
    ty: []const u8,
    cleanup: ast.DeferStmt,
};

/// Read the two prelude statements a temporary `String` receiver needs: the
/// mutable local it is stored in, and the `deinit` that frees it.
fn expectStringReceiverBinding(
    binding_stmt: ast.Stmt,
    cleanup_stmt: ast.Stmt,
) !StringReceiverBinding {
    const binding = switch (binding_stmt) {
        .let_stmt => |value| value,
        else => return error.ExpectedReceiverBinding,
    };
    if (!binding.is_mut) return error.ExpectedMutableReceiver;
    const name = switch (binding.ty orelse return error.ExpectedReceiverType) {
        .named => |ty| ty,
        else => return error.ExpectedReceiverType,
    };
    const cleanup = switch (cleanup_stmt) {
        .defer_stmt => |value| value,
        else => return error.ExpectedReceiverCleanup,
    };
    // A `defer` is the drop of the temporary on every path out of the
    // expression. `errdefer` would leave the allocation behind when the
    // consuming call succeeded and something after it failed.
    if (cleanup.is_errdefer) return error.ExpectedReceiverCleanup;
    const release = switch (cleanup.expr) {
        .call => |value| value,
        else => return error.ExpectedReceiverCleanup,
    };
    const callee = switch (release.callee.*) {
        .field_access => |value| value,
        else => return error.ExpectedReceiverCleanup,
    };
    if (!std.mem.eql(u8, callee.field_name, "deinit")) return error.ExpectedReceiverCleanup;
    try std.testing.expectEqualStrings(binding.name, try expectIdent(callee.target.*));
    try std.testing.expectEqual(@as(usize, 1), release.args.len);
    try std.testing.expectEqualStrings("allocator", try expectIdent(release.args[0]));
    return .{ .name = binding.name, .ty = name, .cleanup = cleanup };
}

/// The entities a `String`-receiver fixture needs.
///
/// `String` is a runtime type the crate never declares, so `into_bytes` and
/// `as_str` reach the backend the way the frontend leaves every `String`
/// method: a synthesized method reference with no parent and no declaration,
/// resolved from the receiver type alone. `s` is the binding a `let` fixture
/// introduces, which the frontend records as a field of its callable.
const StringReceiverEntities = struct {
    graph: ir.graph.CrateGraph,
    root: ir.spine.EntityId,
    into_bytes: ir.spine.EntityId,
    as_str: ir.spine.EntityId,
    render: ir.spine.EntityId,
    bound: ir.spine.EntityId,
    /// Module entities the fixture contributes as extern runtime modules. They
    /// become module rows after the root's, in the order they were registered.
    extern_modules: std.ArrayListUnmanaged(ir.spine.EntityId) = .empty,
    string_ty: ir.types.Type,
    bytes_ty: ir.types.Type,

    fn init(alloc: std.mem.Allocator) !StringReceiverEntities {
        var graph = ir.graph.CrateGraph.init(alloc);
        const root = try graph.symbol_table.add(.{
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
        const into_bytes = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .method_ref,
            .name = "into_bytes",
            .span = span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        const as_str = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .method_ref,
            .name = "as_str",
            .span = span,
            .visibility = .public,
            .parent = null,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        const render = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .fn_,
            .name = "render",
            .span = span,
            .visibility = .public,
            .parent = root,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        const bound = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .field,
            .name = "s",
            .span = span,
            .visibility = .public,
            .parent = render,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        return .{
            .graph = graph,
            .root = root,
            .into_bytes = into_bytes,
            .as_str = as_str,
            .render = render,
            .bound = bound,
            .string_ty = .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
            .bytes_ty = .{ .external_nominal = .{
                .path = &.{ "alloc", "vec", "Vec" },
                .args = &.{.{ .prim = .u8 }},
            } },
        };
    }
};

/// `core::option::Option` as the frontend records it: two extern modules under
/// the crate root and the enum inside them. The lowering recognises the
/// synthetic external type through that path — extern module, extern root,
/// name — rather than through the variant a node spells, so a `Some(..)` whose
/// enum the graph owns is the complete form of the metadata an external nominal
/// owner would otherwise have to carry.
fn addOptionEnum(entities: *StringReceiverEntities) !ir.spine.EntityId {
    const core_id = try addLowerEntity(&entities.graph, .module, "core", entities.root);
    const option_id = try addLowerEntity(&entities.graph, .module, "option", core_id);
    const alloc = entities.graph.allocator;
    try entities.extern_modules.append(alloc, core_id);
    try entities.extern_modules.append(alloc, option_id);
    return addLowerEntity(&entities.graph, .enum_, "Option", option_id);
}

/// `render`'s lowered body, next to the whole emitted file so a test can read
/// either.
const StringReceiverLowering = struct {
    body: ast.Block,
    source: []const u8,
};

/// Lower `fn render() -> return_type { statements; tail }`.
///
/// The caller fills `model` with the expression, statement and pattern tables
/// the body indexes, and passes the fixture's type table so an expression can
/// be typed as `String`.
fn lowerStringReceiver(
    alloc: std.mem.Allocator,
    entities: *StringReceiverEntities,
    model: *Model,
    types: []const ir.types.Type,
    statements: []const ir.exprs.NodeId,
    tail: ?ir.exprs.NodeId,
    return_type: ir.types.Type,
) !StringReceiverLowering {
    const body = try typedExpr(model, null, .{ .block = .{
        .statements = statements,
        .tail = tail,
        .labelled = null,
    } });
    // One body slot per entity, indexed by entity id: the module, the two
    // synthesized method references, `render` itself, the binding that is a
    // field, and whatever a caller added after them.
    const render_body: ir.bodies.BodyKind = .{ .fn_ = .{
        .params = &.{},
        .ret = return_type,
        .body = body,
    } };
    for (entities.graph.symbol_table.entities.items, 0..) |_, slot| {
        try model.bodies.append(alloc, if (slot == @as(usize, entities.render))
            render_body
        else
            .none);
    }
    _ = try entities.graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{entities.render}),
        .attributes = &.{},
    });
    // The extern modules a fixture registered follow the root row, so the root
    // stays the dense row 0 the emitter reads as the crate root.
    for (entities.extern_modules.items) |module_id| {
        const module_entity = entities.graph.symbol_table.get(module_id) orelse
            return error.MissingEntityId;
        _ = try entities.graph.addModule(.{
            .id = 0,
            .kind = .@"inline",
            .name = module_entity.name,
            .parent = module_entity.parent,
            .source_path = null,
            .is_crate = false,
            .is_extern = true,
            .span = span,
            .items = &.{},
            .attributes = &.{},
        });
    }
    try entities.graph.addCrate(.{
        .name = "strings",
        .edition = 2021,
        .kind = .lib,
        .root = entities.root,
        .deps = &.{},
        .is_translated = true,
    });
    const rust_ir = ir.RustIr{
        .crate_name = "strings",
        .edition = "2021",
        .graph = entities.graph,
        .types = &.{},
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = types,
            .bodies = try model.bodies.toOwnedSlice(alloc),
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    for (package.files[0].decls) |decl| {
        if (decl != .fn_decl) continue;
        if (!std.mem.eql(u8, decl.fn_decl.name, "render")) continue;
        return .{
            .body = decl.fn_decl.body orelse return error.ExpectedRenderBody,
            .source = try emit.emitFile(alloc, &package.files[0]),
        };
    }
    return error.MissingRenderDeclaration;
}

test "lower: a chained String receiver is bound to mutable storage before into_bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entities = try StringReceiverEntities.init(alloc);
    var model = Model.init(alloc);
    const types = [_]ir.types.Type{entities.string_ty};

    // `String::from("foobar")` — the conversion the runtime spells
    // `try r2z.alloc.String.from_str(allocator, "foobar")`.
    const text = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "foobar" } } });
    const built = try typedExpr(&model, 0, .{ .core_call = .{
        .function = .convert_from,
        .generic_args = &.{entities.string_ty},
        .args = &.{text},
    } });
    // `String::from("foobar").into_bytes()`
    const consumed = try typedExpr(&model, null, .{ .method_call = .{
        .receiver = built,
        .receiver_mode = .value,
        .method = entities.into_bytes,
        .args = &.{},
    } });

    const lowered = try lowerStringReceiver(
        alloc,
        &entities,
        &model,
        &types,
        &.{},
        consumed,
        entities.bytes_ty,
    );

    // Zig has no address-of expression for a call result, so the receiver is
    // stored in a local the `self: *String` receiver can be taken from. That
    // local and its release are the prelude of the expression, so they wrap
    // the call rather than sit beside it.
    const tail = lowered.body.expr orelse return error.ExpectedRenderTail;
    const prelude = switch (tail.*) {
        .block => |value| value,
        else => return error.ExpectedReceiverPrelude,
    };
    try std.testing.expectEqual(@as(usize, 2), prelude.stmts.len);
    const binding = try expectStringReceiverBinding(prelude.stmts[0], prelude.stmts[1]);
    try std.testing.expectEqualStrings("__r2z_string_receiver", binding.name);
    try std.testing.expectEqualStrings("r2z.alloc.String", binding.ty);

    // The call reaches the local, not the call result it was built from.
    const receiver = prelude.expr orelse return error.ExpectedConsumingCall;
    const shape = try expectMethodCall(receiver);
    try std.testing.expectEqualStrings("into_bytes", shape.shape.method);
    try std.testing.expectEqualStrings(binding.name, shape.shape.receiver);
    try std.testing.expectEqual(@as(usize, 0), shape.call.args.len);

    // The receiver is built once, and nothing calls `into_bytes` on the call
    // result any more.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, lowered.source, "r2z.alloc.String.from_str("),
    );
    try std.testing.expect(std.mem.indexOf(u8, lowered.source, ").into_bytes()") == null);
}

test "lower: an owned String binding takes mutable storage for the transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entities = try StringReceiverEntities.init(alloc);
    var model = Model.init(alloc);
    const types = [_]ir.types.Type{entities.string_ty};

    const text = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "foobar" } } });
    const built = try typedExpr(&model, 0, .{ .core_call = .{
        .function = .convert_from,
        .generic_args = &.{entities.string_ty},
        .args = &.{text},
    } });
    // `let s = String::from("foobar");` — immutable in the source, because
    // `into_bytes` consumes it by value rather than through `&mut s`.
    const pattern = try model.pat(.{ .binding = .{
        .name = "s",
        .mode = .value,
        .mutable = false,
    } });
    const binding_stmt = try model.stmt(.{ .let = .{
        .pattern = pattern,
        .init = built,
        .ty = null,
    } });
    const receiver = try typedExpr(&model, 0, .{ .path = .{
        .def = entities.bound,
        .generic_args = &.{},
    } });
    // `s.into_bytes()`
    const consumed = try typedExpr(&model, null, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .value,
        .method = entities.into_bytes,
        .args = &.{},
    } });

    const lowered = try lowerStringReceiver(
        alloc,
        &entities,
        &model,
        &types,
        &.{binding_stmt},
        consumed,
        entities.bytes_ty,
    );

    // The binding itself has to be `var`: `const` storage is what made Zig
    // reject the call with "cast discards const qualifier".
    try std.testing.expectEqual(@as(usize, 1), lowered.body.stmts.len);
    const bound = switch (lowered.body.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.ExpectedOwnedBinding,
    };
    try std.testing.expect(bound.is_mut);
    try std.testing.expectEqualStrings("s", bound.name);
    const bound_type = switch (bound.ty orelse return error.ExpectedReceiverType) {
        .named => |ty| ty,
        else => return error.ExpectedReceiverType,
    };
    try std.testing.expectEqualStrings("r2z.alloc.String", bound_type);

    // The call stays on the binding. A by-value alias would copy the string and
    // leave `s` holding an allocation the transfer already handed away.
    const tail = lowered.body.expr orelse return error.ExpectedRenderTail;
    const shape = try expectMethodCall(tail);
    try std.testing.expectEqualStrings("into_bytes", shape.shape.method);
    try std.testing.expectEqualStrings("s", shape.shape.receiver);
    try std.testing.expect(std.mem.indexOf(u8, lowered.source, "__r2z_string_receiver") == null);
}

test "lower: a shared String method keeps the receiver it was given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entities = try StringReceiverEntities.init(alloc);
    var model = Model.init(alloc);
    const types = [_]ir.types.Type{entities.string_ty};

    const text = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "foobar" } } });
    const built = try typedExpr(&model, 0, .{ .core_call = .{
        .function = .convert_from,
        .generic_args = &.{entities.string_ty},
        .args = &.{text},
    } });
    const pattern = try model.pat(.{ .binding = .{
        .name = "s",
        .mode = .value,
        .mutable = false,
    } });
    const binding_stmt = try model.stmt(.{ .let = .{
        .pattern = pattern,
        .init = built,
        .ty = null,
    } });
    const receiver = try typedExpr(&model, 0, .{ .path = .{
        .def = entities.bound,
        .generic_args = &.{},
    } });
    // `s.as_str()` — `r2z.alloc.String` spells that receiver
    // `self: *const String`, so it needs no storage of its own.
    const viewed = try typedExpr(&model, null, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .shared,
        .method = entities.as_str,
        .args = &.{},
    } });

    const lowered = try lowerStringReceiver(
        alloc,
        &entities,
        &model,
        &types,
        &.{binding_stmt},
        viewed,
        entities.string_ty,
    );

    // No receiver prelude: the shared call is left exactly as it was written.
    // The second statement is the binding's own scope release, which is what
    // a local `String` gets when nothing takes it.
    try std.testing.expectEqual(@as(usize, 2), lowered.body.stmts.len);
    const tail = lowered.body.expr orelse return error.ExpectedRenderTail;
    const shape = try expectMethodCall(tail);
    try std.testing.expectEqualStrings("as_str", shape.shape.method);
    try std.testing.expectEqualStrings("s", shape.shape.receiver);
    try std.testing.expect(std.mem.indexOf(u8, lowered.source, "__r2z_string_receiver") == null);
    try std.testing.expect(std.mem.indexOf(u8, lowered.source, "deinit(allocator)") != null);
}

test "lower: an owned String binding nothing transfers stays immutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entities = try StringReceiverEntities.init(alloc);
    var model = Model.init(alloc);
    const types = [_]ir.types.Type{entities.string_ty};

    const text = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "foobar" } } });
    const built = try typedExpr(&model, 0, .{ .core_call = .{
        .function = .convert_from,
        .generic_args = &.{entities.string_ty},
        .args = &.{text},
    } });
    const pattern = try model.pat(.{ .binding = .{
        .name = "s",
        .mode = .value,
        .mutable = false,
    } });
    // `let s = String::from("foobar");` with nothing reaching `s` afterwards.
    const binding_stmt = try model.stmt(.{ .let = .{
        .pattern = pattern,
        .init = built,
        .ty = null,
    } });
    const unit = try typedExpr(&model, null, .unit);

    const lowered = try lowerStringReceiver(
        alloc,
        &entities,
        &model,
        &types,
        &.{binding_stmt},
        unit,
        .{ .prim = .unit },
    );

    // The mutable storage is only there for a transfer that happens. With
    // none, the binding goes back to `const` instead of leaving a `var` that
    // reads as a mutable owner nobody owns.
    // The release that follows is the binding's own drop; it runs on an alias,
    // so the binding itself stays the `const` the source wrote.
    try std.testing.expectEqual(@as(usize, 2), lowered.body.stmts.len);
    const bound = switch (lowered.body.stmts[0]) {
        .let_stmt => |value| value,
        else => return error.ExpectedOwnedBinding,
    };
    try std.testing.expect(!bound.is_mut);
    try std.testing.expectEqualStrings("s", bound.name);
}

test "lower: a consuming String receiver in argument position transfers once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entities = try StringReceiverEntities.init(alloc);
    var model = Model.init(alloc);
    const option_bytes: ir.types.Type = .{ .option = &entities.bytes_ty };
    const types = [_]ir.types.Type{ entities.string_ty, option_bytes };

    const text = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "foobar" } } });
    const built = try typedExpr(&model, 0, .{ .core_call = .{
        .function = .convert_from,
        .generic_args = &.{entities.string_ty},
        .args = &.{text},
    } });
    const consumed = try typedExpr(&model, null, .{ .method_call = .{
        .receiver = built,
        .receiver_mode = .value,
        .method = entities.into_bytes,
        .args = &.{},
    } });
    // `Some(String::from("foobar").into_bytes())`, which is how the hex crate's
    // `Ok(String::from("foobar").into_bytes())` reaches the backend. `Option` is
    // an enum the runtime owns, so the node names its definition and the graph
    // carries the extern modules that definition is reached through.
    const option_enum = try addOptionEnum(&entities);
    const wrapped = try typedExpr(&model, 1, .{ .enum_variant = .{
        .def = option_enum,
        .variant = "Some",
        .tuple_fields = &.{consumed},
        .named_fields = &.{},
    } });

    const lowered = try lowerStringReceiver(
        alloc,
        &entities,
        &model,
        &types,
        &.{},
        wrapped,
        option_bytes,
    );

    // One binding, one release, one transfer: the temporary is never built
    // twice and never freed twice, wherever the call sits.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, lowered.source, "var __r2z_string_receiver"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, lowered.source, "__r2z_string_receiver.deinit(allocator)"),
    );
    try std.testing.expect(std.mem.indexOf(u8, lowered.source, "__r2z_string_receiver.into_bytes()") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered.source, ").into_bytes()") == null);
}

// ---------------------------------------------------------------------------
// Blanket dispatch and generic callable parameters
// ---------------------------------------------------------------------------

/// The opaque bound a helper's callable parameter is declared with.
const CallableParamShape = enum {
    /// `impl FnOnce(&str) -> T`, which the IR keeps as a bare bound over
    /// `core::ops::FnOnce` with no signature attached.
    bare_closure,
    /// `FnOnce(..)` carrying a function-pointer argument, so the signature is
    /// already in the IR and has to survive lowering.
    closure_with_signature,
    /// `impl Iterator`, which is opaque but is not callable at all.
    non_callable,
};

fn findFnDecl(file: ast.File, name: []const u8) !ast.FnDecl {
    for (file.decls) |decl| {
        if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, name)) return decl.fn_decl;
    }
    return error.MissingFunctionDeclaration;
}

/// The name a `.named` type spells. A regression that changes the emitted
/// type's SHAPE has to fail the assertion that reads it, not trap inside the
/// union.
fn expectNamedType(ty: ast.Type) ![]const u8 {
    return switch (ty) {
        .named => |name| name,
        else => error.ExpectedNamedType,
    };
}

/// `fn test_hash<T: Eq + Debug>(hash_func: impl FnOnce(&str) -> T, source_str:
/// &str, expected: T)`, which is const-fnv1a-hash/src/lib.rs:79, together with
/// its two statements: `let hashed = hash_func(source_str);` and
/// `let bit_size = core::mem::size_of::<T>();`. The callable parameter reaches
/// the IR as an opaque bound that inference never resolved, and refusing that
/// type refused the whole crate over a helper the source spells plainly.
fn lowerGenericCallableHelperFixture(
    alloc: std.mem.Allocator,
    shape: CallableParamShape,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    const helper_id = try addLowerEntity(&graph, .fn_, "test_hash", null);
    const hash_func_field = try addLowerEntity(&graph, .field, "hash_func", helper_id);
    const source_str_field = try addLowerEntity(&graph, .field, "source_str", helper_id);

    _ = try addRootModule(&graph, .{
        .crate_name = "generic_helper",
        .edition = 2021,
        .items = &.{helper_id},
    });

    const param_segment = try alloc.alloc(ir.types.PathSegment, 1);
    param_segment[0] = .{ .name = "T", .id = null };
    const param_ty: ir.types.Type = .{ .path = .{ .segments = param_segment } };
    const str_ty: ir.types.Type = .{ .slice = try alloc.create(ir.types.Slice) };
    @constCast(str_ty.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    const usize_ty: ir.types.Type = .{ .prim = .usize };

    const bound_path: []const []const u8 = switch (shape) {
        .bare_closure => try alloc.dupe([]const u8, &.{ "core", "ops", "FnOnce" }),
        .closure_with_signature => try alloc.dupe([]const u8, &.{"FnOnce"}),
        .non_callable => try alloc.dupe([]const u8, &.{ "core", "iter", "Iterator" }),
    };
    const bound_segments = try alloc.alloc(ir.types.PathSegment, bound_path.len);
    for (bound_path, 0..) |name, index| bound_segments[index] = .{ .name = name, .id = null };
    const signature: ir.types.FnPtr = .{ .params = &.{str_ty}, .ret = param_ty };
    const bound_args: []const ir.types.Type = switch (shape) {
        .closure_with_signature => try alloc.dupe(ir.types.Type, &.{.{ .fn_ptr = &signature }}),
        else => try alloc.dupe(ir.types.Type, &.{}),
    };
    const bound_list = try alloc.alloc(ir.types.Bound, 1);
    bound_list[0] = .{ .path = .{ .segments = bound_segments }, .args = bound_args };
    const callable_ty: ir.types.Type = .{ .@"opaque" = .{
        .bounds = bound_list,
        .concrete = null,
    } };

    const types = [_]ir.types.Type{ param_ty, callable_ty, str_ty, unit_ty, usize_ty };

    var model = Model.init(alloc);
    const source_str_node = try typedExpr(&model, 2, .{ .path = .{
        .def = source_str_field,
        .generic_args = &.{},
    } });
    const hashed_init = try typedExpr(&model, null, .{ .call = .{
        .call_kind = .{ .free = hash_func_field },
        .args = &.{source_str_node},
    } });
    const hashed_let = try model.stmt(.{ .let = .{
        .pattern = try model.pat(.{ .binding = .{
            .name = "hashed",
            .mode = .value,
            .mutable = false,
        } }),
        .init = hashed_init,
        .ty = null,
    } });
    // The lexical `T` is the whole point: `size_of::<T>()` names the
    // parameter, and it has to reach the emitted `r2z.memory.size_of(T)`
    // as that parameter rather than as something resolved to concrete.
    const bit_size_let = try model.stmt(.{ .let = .{
        .pattern = try model.pat(.{ .binding = .{
            .name = "bit_size",
            .mode = .value,
            .mutable = false,
        } }),
        .init = try typedExpr(&model, 4, .{ .core_call = .{
            .function = .mem_size_of,
            .generic_args = &.{param_ty},
        } }),
        .ty = null,
    } });
    const helper_body = try typedExpr(&model, 3, .{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{ hashed_let, bit_size_let }),
        .tail = null,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const helper_params = try alloc.alloc(ir.items.Param, 3);
    helper_params[0] = .{ .name = "hash_func", .ty = callable_ty, .span = span };
    helper_params[1] = .{ .name = "source_str", .ty = str_ty, .span = span };
    helper_params[2] = .{ .name = "expected", .ty = param_ty, .span = span };
    body_rows[helper_id] = .{ .fn_ = .{
        .params = helper_params,
        .ret = unit_ty,
        .generic_params = &.{"T"},
        .body = helper_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "generic_helper",
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

test "lower: a generic helper with an impl FnOnce parameter emits a normal callable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try lowerGenericCallableHelperFixture(alloc, .bare_closure);

    // `#[cfg(test)] mod tests { fn test_hash(..) }` is a plain function; only
    // `#[test]` makes a Zig `test`. Reading the name as the attribute dropped
    // the helper and every one of the three tests that call it.
    const fn_decl = try findFnDecl(pkg.files[0], "test_hash");
    try std.testing.expectError(
        error.TestDeclarationMissing,
        testDeclByName(pkg.files[0], "test_hash"),
    );

    try std.testing.expectEqual(@as(usize, 4), fn_decl.params.len);
    try std.testing.expectEqualStrings("T", fn_decl.params[0].name);
    try std.testing.expect(fn_decl.params[0].is_comptime);
    try std.testing.expectEqualStrings("hash_func", fn_decl.params[1].name);
    try std.testing.expectEqualStrings("source_str", fn_decl.params[2].name);
    try std.testing.expectEqualStrings("expected", fn_decl.params[3].name);
    // The bound carries no signature, so the parameter is whatever the call
    // site passes; `expected` is the same lexical `T`.
    try std.testing.expectEqualStrings("anytype", try expectNamedType(fn_decl.params[1].ty));
    try std.testing.expectEqualStrings("T", try expectNamedType(fn_decl.params[3].ty));

    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.memory.size_of(T)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "comptime T: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "hash_func(source_str)") != null);
}

test "lower: a callable parameter with a resolved signature keeps that signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try lowerGenericCallableHelperFixture(alloc, .closure_with_signature);
    const callable_ty = (try findFnDecl(pkg.files[0], "test_hash")).params[1].ty;
    if (callable_ty != .fn_ptr) return error.ExpectedFunctionPointerParameter;
    // The signature the IR already carried, including its lexical result type.
    try std.testing.expectEqual(@as(usize, 1), callable_ty.fn_ptr.params.len);
    const param_ty = callable_ty.fn_ptr.params[0];
    if (param_ty != .slice) return error.ExpectedSliceParameter;
    try std.testing.expect(param_ty.slice.is_const);
    try std.testing.expectEqualStrings("T", try expectNamedType(callable_ty.fn_ptr.ret.*));
}

test "lower: an opaque non-callable parameter is still refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(
        error.UnresolvedOpaqueType,
        lowerGenericCallableHelperFixture(alloc, .non_callable),
    );
}

/// Which declaration a blanket method call reaches the impl's method through.
const BlanketCallShape = enum {
    /// The impl's own `fn`, which is what a call inside a generic wrapper
    /// resolves to when the receiver is a type parameter.
    impl_fn,
    /// A synthesized trait `.method_ref` parented to the implemented trait.
    trait_method_ref,
};

/// `impl<T: AsRef<[u8]>> ToHex for U { fn encode_hex<Out>(&self) -> Out }`
/// beside `fn encode<T: AsRef<[u8]>>(data: T) -> String { data.encode_hex() }`,
/// which is hex/src/lib.rs:137 and :259. The impl spells its own parameter `U`
/// and the wrapper spells its own `T` on purpose: a blanket call that binds
/// the impl's name where the caller's belongs is a call to the wrong
/// declaration, not a call to no declaration at all.
///
/// `rival_impls` is how many further blanket impls of the SAME trait exist.
/// Zero rivals is the ordinary case for either call shape; two is the pair the
/// resolver refuses as ambiguous.
fn lowerBlanketWrapperFixture(
    alloc: std.mem.Allocator,
    call_shape: BlanketCallShape,
    rival_impls: usize,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);

    const trait_id = try addLowerEntity(&graph, .trait_, "ToHex", null);
    const impl_id = try addLowerEntity(&graph, .impl_, "ToHex for U", null);
    const method_id = try addLowerEntity(&graph, .fn_, "encode_hex", impl_id);
    // A wrapper reaches the method through the impl's own `fn` in one shape
    // and through a synthesized trait `.method_ref` in the other. Both are
    // what a real resolver hands over, and the branch must not care which.
    const method_ref_id = try addLowerEntity(&graph, .method_ref, "encode_hex", trait_id);
    const encode_id = try addLowerEntity(&graph, .fn_, "encode", null);
    const data_field = try addLowerEntity(&graph, .field, "data", encode_id);

    var rival_method_ids: [2]ir.spine.EntityId = undefined;
    var rival_impl_ids: [2]ir.spine.EntityId = undefined;
    for (0..rival_impls) |index| {
        rival_impl_ids[index] = try addLowerEntity(&graph, .impl_, "ToHex for Rival", null);
        rival_method_ids[index] = try addLowerEntity(
            &graph,
            .fn_,
            "encode_hex",
            rival_impl_ids[index],
        );
    }

    var root_items: [4]ir.spine.EntityId = undefined;
    var root_item_count: usize = 2;
    root_items[0] = impl_id;
    root_items[1] = encode_id;
    for (0..rival_impls) |index| {
        root_items[root_item_count] = rival_impl_ids[index];
        root_item_count += 1;
    }
    _ = try addRootModule(&graph, .{
        .crate_name = "blanket_wrapper",
        .edition = 2021,
        .items = root_items[0..root_item_count],
    });

    const caller_param = try alloc.alloc(ir.types.PathSegment, 1);
    caller_param[0] = .{ .name = "T", .id = null };
    const caller_ty: ir.types.Type = .{ .path = .{ .segments = caller_param } };
    const impl_param = try alloc.alloc(ir.types.PathSegment, 1);
    impl_param[0] = .{ .name = "U", .id = null };
    const impl_ty: ir.types.Type = .{ .path = .{ .segments = impl_param } };
    const out_segment = try alloc.alloc(ir.types.PathSegment, 1);
    out_segment[0] = .{ .name = "Out", .id = null };
    const out_ty: ir.types.Type = .{ .path = .{ .segments = out_segment } };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
    } };
    const self_ref: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(self_ref.reference).* = .{ .mut = false, .pointee = impl_ty };

    const types = [_]ir.types.Type{ caller_ty, impl_ty, out_ty, string_ty, self_ref };

    var model = Model.init(alloc);
    const data_node = try typedExpr(&model, 0, .{ .path = .{
        .def = data_field,
        .generic_args = &.{},
    } });
    // `-> String` is the only place the callee's own `Out` is named, so this
    // is the binding path: the call writes no turbofish.
    const call_node = try typedExpr(&model, 3, .{ .method_call = .{
        .receiver = data_node,
        .receiver_mode = .shared,
        .method = switch (call_shape) {
            .impl_fn => method_id,
            .trait_method_ref => method_ref_id,
        },
        .args = &.{},
    } });
    const encode_body = try typedExpr(&model, 3, .{ .block = .{
        .statements = &.{},
        .tail = call_node,
        .labelled = null,
    } });

    const bound_slice: ir.types.Type = .{ .slice = try alloc.create(ir.types.Slice) };
    @constCast(bound_slice.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const as_ref_bound = ir.types.Bound{
        .path = .{ .segments = &.{
            .{ .name = "core", .id = null },
            .{ .name = "convert", .id = null },
            .{ .name = "AsRef", .id = null },
        } },
        .args = &.{bound_slice},
    };
    const trait_segments = [_]ir.types.PathSegment{.{ .name = "ToHex", .id = trait_id }};

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;

    // `blanketImplMethod` reads the impl's own association list, so the
    // declaration has to name its method there as well as by parent edge.
    const impl_generics = try alloc.alloc(ir.types.GenericParam, 1);
    impl_generics[0] = .{ .type_ = .{ .name = "U", .bounds = &.{as_ref_bound} } };
    body_rows[impl_id] = .{ .impl_ = .{
        .self_ty = impl_ty,
        .trait_path = .{ .segments = &trait_segments },
        .generics = .{ .params = impl_generics, .where_clauses = &.{} },
        .assoc_items = &.{method_id},
    } };

    const self_params = try alloc.alloc(ir.items.Param, 1);
    self_params[0] = .{ .name = "self", .ty = self_ref, .span = span };
    // The method allocates its result, so the call site owes it an allocator
    // and the wrapper owes one of its own in turn.
    const method_body = try typedExpr(&model, 2, .{ .unit = {} });
    body_rows[method_id] = .{ .fn_ = .{
        .params = self_params,
        .ret = out_ty,
        .generic_params = &.{"Out"},
        .body = method_body,
        .is_allocating = true,
    } };

    const wrapper_params = try alloc.alloc(ir.items.Param, 1);
    wrapper_params[0] = .{ .name = "data", .ty = caller_ty, .span = span };
    body_rows[encode_id] = .{ .fn_ = .{
        .params = wrapper_params,
        .ret = string_ty,
        .generic_params = &.{"T"},
        .body = encode_body,
        .is_allocating = false,
    } };

    for (0..rival_impls) |index| {
        const rival_generics = try alloc.alloc(ir.types.GenericParam, 1);
        rival_generics[0] = .{ .type_ = .{ .name = "U", .bounds = &.{as_ref_bound} } };
        body_rows[rival_impl_ids[index]] = .{ .impl_ = .{
            .self_ty = impl_ty,
            .trait_path = .{ .segments = &trait_segments },
            .generics = .{ .params = rival_generics, .where_clauses = &.{} },
            .assoc_items = &.{rival_method_ids[index]},
        } };
        const rival_params = try alloc.alloc(ir.items.Param, 1);
        rival_params[0] = .{ .name = "self", .ty = self_ref, .span = span };
        body_rows[rival_method_ids[index]] = .{ .fn_ = .{
            .params = rival_params,
            .ret = out_ty,
            .generic_params = &.{"Out"},
            .body = method_body,
            .is_allocating = true,
        } };
    }

    const rust_ir = ir.RustIr{
        .crate_name = "blanket_wrapper",
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// A generic wrapper that reaches a blanket impl's method must dispatch to the
// hoisted free function, and it must do so whichever of the two declarations
// the resolver attached to the call: the impl's own `fn`, or a synthesized
// trait `.method_ref` parented to the trait the impl provides. Selecting that
// branch on the entity's kind refused the `fn` half and left it emitting
// `data.encode_hex(..)` as a Zig member call, which no `[]const u8` has a
// field for.
test "lower: a blanket impl method call dispatches to the hoisted function from either declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_]BlanketCallShape{ .impl_fn, .trait_method_ref }) |call_shape| {
        const pkg = try lowerBlanketWrapperFixture(alloc, call_shape, 0);

        // The impl's own parameter leads the hoisted signature, then the
        // method's, then the allocator the allocating method takes, then the
        // receiver.
        const hoisted = try findFnDecl(pkg.files[0], "encode_hex");
        try std.testing.expectEqual(@as(usize, 4), hoisted.params.len);
        try std.testing.expectEqualStrings("U", hoisted.params[0].name);
        try std.testing.expect(hoisted.params[0].is_comptime);
        try std.testing.expectEqualStrings("Out", hoisted.params[1].name);
        try std.testing.expect(hoisted.params[1].is_comptime);
        try std.testing.expectEqualStrings("allocator", hoisted.params[2].name);
        try std.testing.expectEqualStrings("self", hoisted.params[3].name);
        const receiver_ty = hoisted.params[3].ty;
        if (receiver_ty != .ptr) return error.ExpectedReceiverPointer;
        try std.testing.expect(receiver_ty.ptr.is_const);
        try std.testing.expectEqualStrings("U", try expectNamedType(receiver_ty.ptr.elem.*));

        // The wrapper is generic in the CALLER's `T`, and the hoisted call
        // passes that `T` — not the impl's `U` — as the self type argument.
        const wrapper = try findFnDecl(pkg.files[0], "encode");
        try std.testing.expectEqual(@as(usize, 3), wrapper.params.len);
        try std.testing.expectEqualStrings("T", wrapper.params[0].name);
        try std.testing.expect(wrapper.params[0].is_comptime);
        // The allocating method forces the wrapper to declare an allocator of
        // its own, ahead of its value parameter.
        try std.testing.expectEqualStrings("allocator", wrapper.params[1].name);
        try std.testing.expectEqualStrings("data", wrapper.params[2].name);

        const body = wrapper.body orelse return error.MissingWrapperBody;
        const tail = body.expr orelse return error.MissingWrapperTail;
        if (tail.* != .unary_op or tail.unary_op.op != .try_op) {
            return error.ExpectedFallibleHoistedCall;
        }
        const call = tail.unary_op.operand.*;
        if (call != .call) return error.ExpectedDirectHoistedCall;
        // A Zig member call would carry the receiver as a `field_access`
        // callee instead of naming the hoisted function.
        try std.testing.expectEqualStrings("encode_hex", try expectIdent(call.call.callee.*));

        const generic_args = call.call.generic_args;
        try std.testing.expectEqual(@as(usize, 2), generic_args.len);
        try std.testing.expectEqualStrings("T", try expectNamedType(generic_args[0]));
        try std.testing.expectEqualStrings(
            "r2z.alloc.String",
            try expectNamedType(generic_args[1]),
        );

        // The allocator leads, then the receiver by address: the hoisted
        // declaration puts it immediately before the first value parameter.
        try std.testing.expectEqual(@as(usize, 2), call.call.args.len);
        try std.testing.expectEqualStrings("allocator", try expectIdent(call.call.args[0]));
        const receiver = call.call.args[1];
        if (receiver != .unary_op or receiver.unary_op.op != .addr_of) {
            return error.ExpectedAddressOfReceiver;
        }
        try std.testing.expectEqualStrings("data", try expectIdent(receiver.unary_op.operand.*));
    }
}

// Two blanket impls of one trait provide `encode_hex` for the same receiver
// shape, so the call names its method ambiguously. Dispatching either of them
// would call a declaration the source never named.
test "lower: two blanket impls of one trait leave the call undispatched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try lowerBlanketWrapperFixture(alloc, .trait_method_ref, 2);

    const wrapper = try findFnDecl(pkg.files[0], "encode");
    const body = wrapper.body orelse return error.MissingWrapperBody;
    const tail = body.expr orelse return error.MissingWrapperTail;
    const call = switch (tail.*) {
        .unary_op => |unary| unary.operand.*,
        else => tail.*,
    };
    if (call != .call) return error.ExpectedCall;
    // No impl was chosen, so the call is still the receiver member call the
    // general path emits — the shape the resolver refuses upstream.
    if (call.call.callee.* != .field_access) return error.ExpectedUndispatchedCall;
    try std.testing.expectEqualStrings("encode_hex", call.call.callee.field_access.field_name);
}

// ── A shift is typed by its left operand ─────────────────────────────────────

/// Type-table indices for `lowerShiftFixture`. Rust types an integer literal
/// from its context, so a shift fixture has to name the shifted type on the
/// left operand the way the frontend records it.
const shift_i8: ir.spine.TypeId = 0;
const shift_i16: ir.spine.TypeId = 1;
const shift_i32: ir.spine.TypeId = 2;
const shift_u8: ir.spine.TypeId = 3;
const shift_u32: ir.spine.TypeId = 4;
const shift_u64: ir.spine.TypeId = 5;
const shift_i128: ir.spine.TypeId = 6;

/// One lowered function that is a single Rust shift, with every operand
/// spelled as the case asks: a comptime literal, a negated literal, or a
/// parameter.
const ShiftCase = struct {
    name: []const u8,
    /// Index into `lowerShiftFixture`'s type table, in the `TypeId` the IR
    /// records an expression's type by.
    ty_index: ir.spine.TypeId,
    /// The same type as a Zig primitive, asserted on the emitted operand.
    prim: ast.Prim,
    op: ir.exprs.BinaryOp,
    lhs: enum { literal, negated_literal, param },
    lhs_value: i128,
    rhs: enum { literal, param },
    rhs_value: i128,
};

const ShiftFixture = struct {
    file: ast.File,
    source: []const u8,
};

/// The tail expression of the named lowered function.
fn findShiftTail(file: ast.File, name: []const u8) !ast.Expr {
    for (file.decls) |decl| {
        if (decl != .fn_decl) continue;
        if (!std.mem.eql(u8, decl.fn_decl.name, name)) continue;
        const body = decl.fn_decl.body orelse return error.MissingShiftBody;
        const tail = body.expr orelse return error.MissingShiftTail;
        return tail.*;
    }
    return error.MissingShiftFunction;
}

/// Lowers a crate whose functions are one shift each, and returns the root
/// file with its emitted source. A literal amount carries `i32`, the type the
/// frontend gives a bare integer, and a runtime amount is a `u32` parameter.
fn lowerShiftFixture(alloc: std.mem.Allocator, cases: []const ShiftCase) !ShiftFixture {
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
    const n_def = try addLowerEntity(&graph, .const_, "n", root_id);
    const items = try alloc.alloc(ir.spine.EntityId, cases.len);
    for (cases, items) |case, *item| {
        item.* = try addLowerEntity(&graph, .fn_, case.name, root_id);
    }
    try addBareCrate(&graph, alloc, "shift_typed", root_id, items);

    const types = [_]ir.types.Type{
        .{ .prim = .i8 },
        .{ .prim = .i16 },
        .{ .prim = .i32 },
        .{ .prim = .u8 },
        .{ .prim = .u32 },
        .{ .prim = .u64 },
        .{ .prim = .i128 },
    };
    var model = Model.init(alloc);
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;

    for (cases, items) |case, *item| {
        var params: std.ArrayListUnmanaged(ir.items.Param) = .empty;
        const lhs = switch (case.lhs) {
            .literal, .negated_literal => plain: {
                const value = try model.e(.{ .literal = .{ .int = .{
                    .text = try std.fmt.allocPrint(alloc, "{d}", .{case.lhs_value}),
                    .value = case.lhs_value,
                    .base = .dec,
                    .ty_suffix = null,
                } } });
                model.exprs.items[value].ty = case.ty_index;
                if (case.lhs == .literal) break :plain value;
                const negated = try model.e(.{ .unary = .{ .op = .negate, .operand = value } });
                model.exprs.items[negated].ty = case.ty_index;
                break :plain negated;
            },
            .param => binding: {
                try params.append(alloc, .{
                    .name = "x",
                    .ty = types[case.ty_index],
                    .span = span,
                });
                const path = try model.e(.{ .path = .{ .def = x_def, .generic_args = &.{} } });
                model.exprs.items[path].ty = case.ty_index;
                break :binding path;
            },
        };
        const rhs = switch (case.rhs) {
            .literal => amount: {
                const value = try model.e(.{ .literal = .{ .int = .{
                    .text = try std.fmt.allocPrint(alloc, "{d}", .{case.rhs_value}),
                    .value = case.rhs_value,
                    .base = .dec,
                    .ty_suffix = null,
                } } });
                model.exprs.items[value].ty = shift_i32;
                break :amount value;
            },
            .param => count: {
                try params.append(alloc, .{
                    .name = "n",
                    .ty = types[shift_u32],
                    .span = span,
                });
                const path = try model.e(.{ .path = .{ .def = n_def, .generic_args = &.{} } });
                model.exprs.items[path].ty = shift_u32;
                break :count path;
            },
        };
        const tail = try model.e(.{ .binary = .{
            .op = case.op,
            .overflow = .wrapping,
            .lhs = lhs,
            .rhs = rhs,
        } });
        model.exprs.items[tail].ty = case.ty_index;
        const body = try model.e(.{ .block = .{
            .statements = &.{},
            .tail = tail,
            .labelled = null,
        } });
        body_rows[item.*] = .{ .fn_ = .{
            .params = params.items,
            .ret = types[case.ty_index],
            .generic_params = &.{},
            .body = body,
            .is_allocating = false,
        } };
    }

    const rust_ir = ir.RustIr{
        .crate_name = "shift_typed",
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
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    return .{
        .file = package.files[0],
        .source = try emit.emitFile(alloc, &package.files[0]),
    };
}

/// The left operand of `shift` must hold `prim` before Zig shifts it. A
/// `comptime_int` left operand shifts at arbitrary precision instead, so
/// `1i8 << 7` reaches the `i8` return as `128` instead of `-128`.
fn expectShiftOperandType(shift: ast.Expr, prim: ast.Prim) !void {
    if (shift != .bin_op) return error.ExpectedShift;
    const lhs = shift.bin_op.lhs.*;
    if (lhs != .cast) return error.ShiftOperandNotTyped;
    if (lhs.cast.target != .prim) return error.ShiftOperandTargetNotPrimitive;
    try std.testing.expectEqual(prim, lhs.cast.target.prim);
}

test "lower: a signed shift holds the Rust operand type before the shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Rust types the literal from the shift and shifts inside that type, so
    // `1i8 << 7` is `-128`, `1i32 << 31` is `i32::MIN`, `1i128 << 127` is
    // `i128::MIN`, and `-8i8 >> 2` is `-2` by arithmetic shift. A
    // `comptime_int` left operand hands the enclosing signed type a positive
    // value it cannot represent, so the sign bit of every signed width is a
    // Zig rejection rather than a value.
    const cases = [_]ShiftCase{
        .{
            .name = "sign_bit_i8",
            .ty_index = shift_i8,
            .prim = .i8,
            .op = .shl,
            .lhs = .literal,
            .lhs_value = 1,
            .rhs = .literal,
            .rhs_value = 7,
        },
        .{
            .name = "sign_bit_i32",
            .ty_index = shift_i32,
            .prim = .i32,
            .op = .shl,
            .lhs = .literal,
            .lhs_value = 1,
            .rhs = .literal,
            .rhs_value = 31,
        },
        .{
            .name = "sign_bit_i128",
            .ty_index = shift_i128,
            .prim = .i128,
            .op = .shl,
            .lhs = .literal,
            .lhs_value = 1,
            .rhs = .literal,
            .rhs_value = 127,
        },
        .{
            .name = "arith_shr",
            .ty_index = shift_i8,
            .prim = .i8,
            .op = .shr,
            .lhs = .negated_literal,
            .lhs_value = 8,
            .rhs = .literal,
            .rhs_value = 2,
        },
    };
    const fixture = try lowerShiftFixture(alloc, &cases);

    for (cases) |case| {
        const tail = try findShiftTail(fixture.file, case.name);
        try expectShiftOperandType(tail, case.prim);
    }
    // The bare comptime shift is the defect itself: `1 << @intCast(7)` is a
    // `128` at the point the `i8` return coerces it, and no amount narrowing
    // rescues it. Any typed spelling of the operand keeps a `)` in its way.
    try std.testing.expect(std.mem.indexOf(u8, fixture.source, "1 << @intCast(7)") == null);
}

test "lower: a wide or runtime-counted shift shifts the operand it was given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]ShiftCase{
        // `1u8 << 7` is `128`: an unsigned width is a width, not a detour
        // through a signed comptime value.
        .{
            .name = "u8_width",
            .ty_index = shift_u8,
            .prim = .u8,
            .op = .shl,
            .lhs = .literal,
            .lhs_value = 1,
            .rhs = .literal,
            .rhs_value = 7,
        },
        // A runtime count can only shift a value that already has a type, and
        // that type is the shifted width, not the amount's.
        .{
            .name = "u64_count",
            .ty_index = shift_u64,
            .prim = .u64,
            .op = .shl,
            .lhs = .literal,
            .lhs_value = 1,
            .rhs = .param,
            .rhs_value = 0,
        },
        // A left operand that already carries its type must not gain a
        // conversion: the shift is a runtime shift either way, so `@as(i16, x)`
        // would be a no-op every reader re-checks.
        .{
            .name = "runtime_shr",
            .ty_index = shift_i16,
            .prim = .i16,
            .op = .shr,
            .lhs = .param,
            .lhs_value = 0,
            .rhs = .param,
            .rhs_value = 0,
        },
    };
    const fixture = try lowerShiftFixture(alloc, &cases);

    for (cases[0..2]) |case| {
        const tail = try findShiftTail(fixture.file, case.name);
        try expectShiftOperandType(tail, case.prim);
    }
    const runtime = try findShiftTail(fixture.file, "runtime_shr");
    if (runtime != .bin_op) return error.ExpectedShift;
    if (runtime.bin_op.lhs.* != .ident) return error.ShiftOperandConverted;
    try std.testing.expectEqualStrings("x", runtime.bin_op.lhs.ident);
}

// ── `collect` target resolution, deposit, and the exits a `Result` collect owns ──

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

/// Source and adapter shapes whose exits must leave the collect.
const CollectScene = enum {
    /// The whole function body.
    result_tail,
    /// An empty source, which has to reach the same answer a full one does
    /// and release nothing.
    result_empty,
    /// `flat_map` first, so an adapter's own loop sits between the deposit and
    /// the loop the collect owns.
    result_flat_map,
    /// A `?` in the adapter body: a collection error, not a function return.
    result_adapter_question_mark,
    /// A loop the adapter body opens for itself, above the `?` it carries.
    result_adapter_loop_question_mark,
};

/// Lower `(0..3).map(..).collect::<Result<Vec<u32>, ParseError>>()` in the
/// shape `scene` asks for, and return the emitted file. The `result_empty`
/// scene walks `0..0` instead, which has to reach the same answer.
///
/// Type indices: 0 `u32`, 1 `usize`, 2 `()`, 3 `Vec<u32>`, 4 `ParseError`,
/// 5 `Result<u32, ParseError>`, 6 `Result<Vec<u32>, ParseError>`.
fn collectResultFixtureSource(alloc: std.mem.Allocator, scene: CollectScene) ![]const u8 {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const error_id = try addLowerEntity(&graph, .enum_, "ParseError", root_id);
    const collect_id = try addLowerEntity(&graph, .fn_, "collect_first", root_id);
    // The item's own source, declared rather than called into the void: every
    // call in this file names a function the file itself defines, so the
    // emitted crate is one a reader can check end to end.
    const item_id = try addLowerEntity(&graph, .fn_, "classify", root_id);
    // `Ok(..)` is a node of the runtime's own `Result`, which the lowering
    // recognises through an extern module rather than by name.
    const core_id = try addLowerEntity(&graph, .module, "core", root_id);
    const result_module_id = try addLowerEntity(&graph, .module, "result", core_id);
    const result_enum_id = try addLowerEntity(&graph, .enum_, "Result", result_module_id);
    try addBareCrate(&graph, alloc, "collect_result", root_id, &.{
        error_id,
        collect_id,
        item_id,
    });
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

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    const element_args = try alloc.alloc(ir.types.Type, 1);
    element_args[0] = u32_ty;
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = element_args,
    } };
    const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
    err_segments[0] = .{ .name = "ParseError", .id = error_id };
    const err_ty: ir.types.Type = .{ .path = .{ .segments = err_segments } };
    const item_arms = try alloc.create(ir.types.Result);
    item_arms.* = .{ .ok = u32_ty, .err = err_ty, .is_error_unionable = false };
    const item_ty: ir.types.Type = .{ .result = item_arms };
    const collect_arms = try alloc.create(ir.types.Result);
    collect_arms.* = .{ .ok = vec_ty, .err = err_ty, .is_error_unionable = false };
    const collect_ty: ir.types.Type = .{ .result = collect_arms };
    const types = [_]ir.types.Type{
        u32_ty, usize_ty, unit_ty,    vec_ty,
        err_ty, item_ty,  collect_ty,
    };

    const range_start = try model.e(litInt(0));
    model.exprs.items[range_start].ty = 1;
    const range_end = try model.e(litInt(if (scene == .result_empty) 0 else 3));
    model.exprs.items[range_end].ty = 1;
    const source = try model.e(.{ .range = .{
        .start = range_start,
        .end = range_end,
        .inclusive = false,
    } });
    model.exprs.items[source].ty = 1;

    // One `Result`-returning call per use: the emitter walks a shared tree, so
    // a node reused at two sites prints one value at both.
    const item_call = try model.e(.{ .call = .{
        .call_kind = .{ .free = item_id },
        .args = &.{},
    } });

    // `classify`'s own body: `Ok(1)`. The declared helper means the file the
    // assertions below read is one a reader can check end to end.
    const payload = try model.e(litInt(1));
    model.exprs.items[payload].ty = 0;
    const payload_fields = try alloc.alloc(ir.exprs.NodeId, 1);
    payload_fields[0] = payload;
    const classify_body = try model.e(.{ .enum_variant = .{
        .def = result_enum_id,
        .variant = "Ok",
        .tuple_fields = payload_fields,
        .named_fields = &.{},
    } });
    model.exprs.items[classify_body].ty = 5;
    model.exprs.items[item_call].ty = 5;
    const item_param = try model.pat(.wildcard);

    var map_body_statements: []const ir.exprs.NodeId = &.{};
    const map_tail = item_call;
    if (scene == .result_adapter_question_mark or
        scene == .result_adapter_loop_question_mark)
    {
        const propagate_inner = try model.e(.{ .call = .{
            .call_kind = .{ .free = item_id },
            .args = &.{},
        } });
        model.exprs.items[propagate_inner].ty = 5;
        const propagate = try model.e(.{ .try_ = .{ .inner = propagate_inner } });
        model.exprs.items[propagate].ty = 5;
        const propagate_stmt = try model.stmt(.{ .expr = propagate });
        const closure_statements = try alloc.alloc(ir.exprs.NodeId, 2);
        if (scene == .result_adapter_loop_question_mark) {
            // `for _ in 0..2 {}` — a loop the adapter body opens for itself,
            // which a bare `break` from the `?` below would stop instead of the
            // collect's own loop.
            const loop_start = try model.e(litInt(0));
            model.exprs.items[loop_start].ty = 1;
            const loop_end = try model.e(litInt(2));
            model.exprs.items[loop_end].ty = 1;
            const loop_range = try model.e(.{ .range = .{
                .start = loop_start,
                .end = loop_end,
                .inclusive = false,
            } });
            model.exprs.items[loop_range].ty = 1;
            const loop_pattern = try model.pat(.wildcard);
            const loop = try model.e(.{ .for_ = .{
                .pattern = loop_pattern,
                .iterable = loop_range,
                .body = .{ .statements = &.{}, .tail = null, .labelled = null },
                .iter_kind = .{ .range = {} },
            } });
            model.exprs.items[loop].ty = 2;
            // The loop comes FIRST, so the propagation is emitted with a loop
            // already open above it in the emitted body. A bare `break` would
            // stop that loop instead of the collect's.
            closure_statements[0] = try model.stmt(.{ .expr = loop });
            closure_statements[1] = propagate_stmt;
            map_body_statements = closure_statements[0..2];
        } else {
            closure_statements[0] = propagate_stmt;
            map_body_statements = closure_statements[0..1];
        }
    }
    const map_closure = ir.exprs.ClosureExpr{
        .captures = &.{},
        .params = &.{item_param},
        .return_ty = 5,
        .body = .{
            .statements = map_body_statements,
            .tail = map_tail,
            .labelled = null,
        },
        .trait = .@"fn",
    };

    // `flat_map(|_| 0..2)` walks a second iterable, so the deposit it carries
    // runs one loop deeper than the collect's own.
    const flat_param = try model.pat(.wildcard);
    const flat_start = try model.e(litInt(0));
    model.exprs.items[flat_start].ty = 1;
    const flat_end = try model.e(litInt(2));
    model.exprs.items[flat_end].ty = 1;
    const flat_range = try model.e(.{ .range = .{
        .start = flat_start,
        .end = flat_end,
        .inclusive = false,
    } });
    model.exprs.items[flat_range].ty = 1;
    const flat_closure = ir.exprs.ClosureExpr{
        .captures = &.{},
        .params = &.{flat_param},
        .return_ty = 1,
        .body = .{ .statements = &.{}, .tail = flat_range, .labelled = null },
        .trait = .@"fn",
    };

    const adapters = try alloc.alloc(ir.exprs.IteratorAdapter, if (scene == .result_flat_map) @as(usize, 2) else 1);
    if (scene == .result_flat_map) {
        adapters[0] = .{ .flat_map = flat_closure };
        adapters[1] = .{ .map = .{ .closure = map_closure } };
    } else {
        adapters[0] = .{ .map = .{ .closure = map_closure } };
    }
    const chain = try model.e(.{ .iterator_chain = .{
        .source = source,
        .adapters = adapters,
        .terminal = .collect_vec,
    } });
    model.exprs.items[chain].ty = 6;

    // The collect remains the function's tail value.
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = chain,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 6;

    const error_variants = try alloc.alloc(ir.items.Variant, 1);
    error_variants[0] = .{
        .name = "InvalidDigit",
        .fields = .none,
        .discriminant = null,
    };

    // The synthetic `Result` that the `Ok(..)` node belongs to. The extern
    // module pair above is what the lowering matches to recognise it as the
    // runtime's tagged `Result`; these variants are what it reads when it gets
    // there the other way round, by looking the variant up on the owning enum.
    // Declaring them means an `Ok(..)` node can only ever find its one tuple
    // field, never refuse because the fixture left the enum body empty.
    const result_variants = try alloc.alloc(ir.items.Variant, 2);
    const ok_payload = try alloc.alloc(ir.types.Type, 1);
    ok_payload[0] = u32_ty;
    const err_payload = try alloc.alloc(ir.types.Type, 1);
    err_payload[0] = err_ty;
    result_variants[0] = .{
        .name = "Ok",
        .fields = .{ .tuple = ok_payload },
        .discriminant = null,
    };
    result_variants[1] = .{
        .name = "Err",
        .fields = .{ .tuple = err_payload },
        .discriminant = null,
    };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[collect_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = collect_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = true,
    } };
    body_rows[item_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = item_ty,
        .generic_params = &.{},
        .body = classify_body,
        .is_allocating = false,
    } };
    body_rows[error_id] = .{ .enum_ = .{ .kind = .data, .variants = error_variants } };
    body_rows[result_enum_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = result_variants,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "collect_result",
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
    return emitRootSource(alloc, &rust_ir);
}

// ── Where a `Result` collect's exits go ─────────────────────────────────────

/// The label the collect's exits name, read out of the emitted file rather
/// than assumed. What the tests below are about is that every exit reaches
/// the block the collect owns, so none of them may quote a name the generator
/// happens to pick today.
fn collectExitLabel(alloc: std.mem.Allocator, source: []const u8, after: usize) ![]const u8 {
    const rest = source[after..];
    const at = std.mem.indexOf(u8, rest, "break :") orelse return error.MissingCollectExit;
    const start = at + "break :".len;
    var end = start;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
    if (end == start) return error.MissingCollectExit;
    return try std.fmt.allocPrint(alloc, "{s}", .{rest[start..end]});
}

/// Where the block carrying `label` opens, written the way the emitter writes
/// it. A label nothing opens is a label an exit cannot reach.
fn collectExitBlockAt(
    alloc: std.mem.Allocator,
    source: []const u8,
    label: []const u8,
) !usize {
    const opened = try std.fmt.allocPrint(alloc, "{s}: {{", .{label});
    return std.mem.indexOf(u8, source, opened) orelse error.MissingCollectExitBlock;
}

/// The statement the emitted text runs after `at`, with its own indentation
/// removed. What follows an unconditional exit is what Zig refuses to
/// compile, so the statement itself is read rather than a search for it.
fn emittedStatementAfter(source: []const u8, at: usize) ![]const u8 {
    const line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse
        return error.MissingCollectExit;
    return std.mem.trim(u8, source[line_end + 1 ..], " \t");
}

/// The one emitted function, so a test that asks whether the collect returns
/// from ITS function does not trip over the ones it calls or is called by.
fn emittedFunction(source: []const u8, name: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, name) orelse return error.MissingFunction;
    const end = std.mem.indexOfPos(u8, source, start + name.len, "\n}") orelse
        return error.MissingFunction;
    return source[start..end];
}

/// How many loops the emitted text opens. A bare `break` claims the nearest
/// one, so what an exit has to step over is counted rather than assumed.
fn countEmittedLoops(source: []const u8) usize {
    return countOccurrences(source, "while (") + countOccurrences(source, "for (");
}

// An empty source never records an error. It still has to reach the `Ok`
// answer a full one reaches and release nothing, which is why the outcome is
// the error local's test and never a count of items.
test "lower: an empty Result collect reaches the Ok answer and releases nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const empty = try collectResultFixtureSource(alloc, .result_empty);
    const full = try collectResultFixtureSource(alloc, .result_tail);
    // The bound the loop walks to is the only thing the source length changes.
    try std.testing.expect(std.mem.indexOf(u8, empty, "__r2z_range_end: usize = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "__r2z_range_end: usize = 3;") != null);
    // Everything the collect DECIDES is therefore the same decision for both,
    // and each of those decisions is stated in absolute terms rather than only
    // as a difference: two releases (the `errdefer` and the `Err` arm, neither
    // of which an empty source reaches), one outcome test, one deposit site.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(empty, "deinit(allocator)"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(full, "deinit(allocator)"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(empty, "if (__r2z_collect_error != null)"),
    );
    try std.testing.expectEqual(
        countOccurrences(full, "if (__r2z_collect_error != null)"),
        countOccurrences(empty, "if (__r2z_collect_error != null)"),
    );
    // The empty one still owns the collection and still hands it on, and the
    // error local it never wrote is still what the outcome reads.
    try std.testing.expect(std.mem.indexOf(u8, empty, ".Ok = __r2z_owner") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        empty,
        ".Err = r2z.option.unwrap(__r2z_collect_error)",
    ) != null);
}

// An adapter that walks a second iterable puts a loop between the deposit and
// the loop the collect owns. The exit names the block OUTSIDE both, so it
// leaves the adapter's as well: what used to need a guard after every nested
// loop is one label now, and the nesting can be any depth.
test "lower: a flat_map adapter's inner loop cannot swallow an item error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try collectResultFixtureSource(alloc, .result_flat_map);
    const record = std.mem.indexOf(
        u8,
        source,
        "__r2z_collect_error = __r2z_item_value.unwrap_err();",
    ) orelse return error.MissingItemError;
    const exit = try collectExitLabel(alloc, source, record);
    // Both loops are inside the one block the exit names, and the exit is
    // inside both: the adapter's loop and the collect's own.
    const block_at = try collectExitBlockAt(alloc, source, exit);
    try std.testing.expect(countEmittedLoops(source[block_at..record]) >= 2);
    // One decision about the outcome and no guard after the nested loop: there
    // is nothing left for a guard to catch.
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "if (__r2z_collect_error != null)"),
    );
}

// A `?` in an adapter body leaves the CLOSURE in Rust, and `collect` turns
// that into the collection's own `Err`. Emitting a function-level `return`
// there would leave the function from a value position, and emitting nothing
// would lose the error.
test "lower: a ? in an adapter body reports in the collection, not the function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try collectResultFixtureSource(alloc, .result_adapter_question_mark);
    const record = std.mem.indexOf(u8, source, "__r2z_collect_error = __r2z_try_err;") orelse
        return error.MissingRecordedError;
    // The propagation leaves through the block the collect owns, so the
    // enclosing function keeps running.
    const exit = try collectExitLabel(alloc, source, record);
    try std.testing.expect(try collectExitBlockAt(alloc, source, exit) < record);
    const outcome = std.mem.indexOf(u8, source, ".Err = r2z.option.unwrap(") orelse
        return error.MissingCollectOutcome;
    // The `?` reports in the collection: from where it records the error to
    // where the collection reports it, nothing leaves the function. This
    // function's own `return` of the collect is ahead of both, because the
    // The `?` reports in the collection: from where it records the error to
    // where the collection reports it, nothing leaves the function. The one
    // `return` in that window is the function handing back the collect, which
    // is what the source does.
    const window = source[record..outcome];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, window, "return "));
    try std.testing.expect(std.mem.indexOf(u8, window, "return if (") != null);
    // The `?` sits in a `switch` whose other arm is the unwrapped payload, so
    // its own arm has to be a value of that type or no value at all. The
    // labeled exit is that value: the arm diverges on it, and nothing may run
    // after it, because Zig rejects a statement that follows an unconditional
    // exit.
    try std.testing.expect(std.mem.startsWith(
        u8,
        try emittedStatementAfter(source, record),
        "break :",
    ));
    // The collection still reports the error it recorded.
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        ".Err = r2z.option.unwrap(__r2z_collect_error)",
    ) != null);
}

// A loop written inside the adapter body used to make this lowering refuse,
// because a bare `break` reached that loop instead of the collect's. Naming
// the block the collect owns makes the case ordinary: the `?` records the
// error, the loop the body opened is stepped over, and the collect reports.
test "lower: a ? behind a loop in an adapter body leaves the collect, not the loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try collectResultFixtureSource(alloc, .result_adapter_loop_question_mark);
    const record = std.mem.indexOf(u8, source, "__r2z_collect_error = __r2z_try_err;") orelse
        return error.MissingRecordedError;
    const exit = try collectExitLabel(alloc, source, record);
    const block_at = try collectExitBlockAt(alloc, source, exit);
    // The body opened a loop before the `?` it carries, so that loop and the
    // collect's own both sit between the block and the propagation itself. A
    // bare `break` would have stopped the nearer of the two.
    try std.testing.expect(countEmittedLoops(source[block_at..record]) >= 2);
    // The arm the `?` produced diverges, exactly as it does without the loop:
    // the loop the body opened changes nothing about where the error goes.
    try std.testing.expect(std.mem.startsWith(
        u8,
        try emittedStatementAfter(source, record),
        "break :",
    ));
    // The collection reports the error, and the enclosing function keeps
    // running rather than returning.
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        ".Err = r2z.option.unwrap(__r2z_collect_error)",
    ) != null);
    const outcome = std.mem.indexOf(u8, source, ".Err = r2z.option.unwrap(") orelse
        return error.MissingCollectOutcome;
    // Nothing between the record and the collection's own `Err` leaves the
    // function: the loop the body opened changes where nothing goes. The one
    // `return` in that window is the function handing back the collect.
    const window = source[record..outcome];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, window, "return "));
    try std.testing.expect(std.mem.indexOf(u8, window, "return if (") != null);
}

// ── a `collect` whose target is a bare type parameter ─────────────────────

/// Lower `fn collect_chars<T: FromIterator<char>>() -> T` collecting a range,
/// and return the emitted file.
///
/// `bound` selects whether the callable carries the `FromIterator` bound. The
/// bound is what names the ITEM type; it says nothing about which container
/// `T` is, so the emitted body has to serve a `String` instantiation and a
/// `Vec<char>` one from the same source text.
fn genericCollectFixtureSource(alloc: std.mem.Allocator, bound: bool) ![]const u8 {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const collect_id = try addLowerEntity(&graph, .fn_, "collect_chars", root_id);
    try addBareCrate(&graph, alloc, "generic_collect", root_id, &.{collect_id});

    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const char_ty: ir.types.Type = .{ .prim = .char };
    // A single segment with no entity behind it is a type parameter, and the
    // only shape a bare `T` target can take in this IR.
    const param_segments = try alloc.alloc(ir.types.PathSegment, 1);
    param_segments[0] = .{ .name = "T", .id = null };
    const param_ty: ir.types.Type = .{ .path = .{ .segments = param_segments } };

    const from_iterator_args = try alloc.alloc(ir.types.Type, 1);
    from_iterator_args[0] = char_ty;
    const from_iterator = ir.types.Bound{
        .path = .{ .segments = &.{.{ .name = "FromIterator", .id = null }} },
        .args = from_iterator_args,
    };
    const bounds = try alloc.alloc(ir.types.Bound, if (bound) @as(usize, 1) else 0);
    if (bound) bounds[0] = from_iterator;
    const generic_params = try alloc.alloc(ir.types.GenericParam, 1);
    generic_params[0] = .{ .type_ = .{ .name = "T", .bounds = bounds } };
    const generics = ir.types.Generics{
        .params = generic_params,
        .where_clauses = &.{},
    };
    const types = [_]ir.types.Type{ usize_ty, char_ty, param_ty };

    const range_start = try model.e(litInt(0));
    model.exprs.items[range_start].ty = 0;
    const range_end = try model.e(litInt(3));
    model.exprs.items[range_end].ty = 0;
    const source = try model.e(.{ .range = .{
        .start = range_start,
        .end = range_end,
        .inclusive = false,
    } });
    model.exprs.items[source].ty = 0;
    const chain = try model.e(.{ .iterator_chain = .{
        .source = source,
        .adapters = &.{},
        .terminal = .collect_vec,
    } });
    model.exprs.items[chain].ty = 2;
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = chain,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 2;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[collect_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = param_ty,
        .generic_params = &.{"T"},
        .generics = generics,
        .body = body,
        .is_allocating = true,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "generic_collect",
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
    return emitRootSource(alloc, &rust_ir);
}

// `fn collect_chars<T: FromIterator<char>>() -> T` is emitted once and
// instantiated as `String` by one caller and as `Vec<char>` by the next, so
// the body cannot pick a container operation from the item type: `char` is
// what both hold. The comparison that chooses is comptime, so Zig keeps the
// branch that matches and never analyzes the one that names a method the
// other container does not have.
test "lower: a collect into a type parameter dispatches its deposit at comptime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try genericCollectFixtureSource(alloc, true);
    // The owner is a bare `T` and the empty value comes from the instantiation.
    try std.testing.expect(std.mem.indexOf(u8, source, "comptime T: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var __r2z_owner: T = T.empty;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "errdefer __r2z_owner.deinit(allocator);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@TypeOf(__r2z_owner)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "== r2z.alloc.String") != null);
    // One deposit per container, and no alias that gives `String` an `append`
    // or a `Vec` a `push`.
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, ".push(allocator, __r2z_item_value)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, ".append(allocator, __r2z_item_value)"),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "String.append") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "String.push") == null);
    // The item is bound to one name both branches deposit, so the two call
    // sites cannot end up sharing a mutable expression node.
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "const __r2z_item_value = "),
    );
}

// The negative that keeps the bound meaningful. `FromIterator<Item>` is what
// names what the collection holds, and a bare type parameter target has nothing
// else to say; without it the item type is unstated, and the lowering refuses
// rather than collecting into a container whose element nothing names.
test "lower: a collect into a type parameter with no FromIterator bound is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(
        error.UnsupportedCollectionType,
        genericCollectFixtureSource(alloc, false),
    );
}

// The concrete half of the pair the comptime dispatch chooses between: a
// `String` target has no `append`, so its deposit is `push` of a codepoint.
// The `Vec` half is the `append` every other test above already reads, and
// this is the one that would break if the two targets ever collapsed into a
// single operation.
test "lower: a collect into a String pushes a codepoint instead of appending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const collect_id = try addLowerEntity(&graph, .fn_, "collect_string", root_id);
    try addBareCrate(&graph, alloc, "string_collect", root_id, &.{collect_id});

    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const char_ty: ir.types.Type = .{ .prim = .char };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const types = [_]ir.types.Type{ usize_ty, char_ty, string_ty };

    const range_start = try model.e(litInt(0));
    model.exprs.items[range_start].ty = 0;
    const range_end = try model.e(litInt(3));
    model.exprs.items[range_end].ty = 0;
    const source = try model.e(.{ .range = .{
        .start = range_start,
        .end = range_end,
        .inclusive = false,
    } });
    model.exprs.items[source].ty = 0;
    const chain = try model.e(.{ .iterator_chain = .{
        .source = source,
        .adapters = &.{},
        .terminal = .collect_vec,
    } });
    model.exprs.items[chain].ty = 2;
    const body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = chain,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 2;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[collect_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = string_ty,
        .generic_params = &.{},
        .body = body,
        .is_allocating = true,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "string_collect",
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

    const source_text = try emitRootSource(alloc, &rust_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source_text,
        "var __r2z_owner: r2z.alloc.String = r2z.alloc.String.empty;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source_text,
        "errdefer __r2z_owner.deinit(allocator);",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source_text, ".push(allocator, __r2z_range_cursor)"),
    );
    // No `append`, and no comptime branch either: the target named the
    // container, so the loop has nothing to decide.
    try std.testing.expect(std.mem.indexOf(u8, source_text, ".append(allocator,") == null);
    try std.testing.expect(std.mem.indexOf(u8, source_text, "@TypeOf") == null);
}

// A `Vec` literal and a `collect` build their containers through the same
// `append(allocator, <value>)` call, so one reused `ast.Expr` would print the
// last value at every position and the package would still compile. Three
// DISTINCT values in order is the only shape that fails when they are shared.
test "lower: a vec literal and a collect keep their append arguments distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const make_id = try addLowerEntity(&graph, .fn_, "make", root_id);
    try addBareCrate(&graph, alloc, "collect_arguments", root_id, &.{make_id});

    const u32_ty: ir.types.Type = .{ .prim = .u32 };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const element_args = try alloc.alloc(ir.types.Type, 1);
    element_args[0] = u32_ty;
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = element_args,
    } };
    const types = [_]ir.types.Type{ u32_ty, usize_ty, vec_ty };

    const first = try model.e(litInt(1));
    model.exprs.items[first].ty = 0;
    const second = try model.e(litInt(100));
    model.exprs.items[second].ty = 0;
    const third = try model.e(litInt(2));
    model.exprs.items[third].ty = 0;
    const literal = try model.e(.{ .vec_lit = .{
        .elements = &.{ first, second, third },
        .repeat = null,
    } });
    model.exprs.items[literal].ty = 2;

    const range_start = try model.e(litInt(0));
    model.exprs.items[range_start].ty = 1;
    const range_end = try model.e(litInt(3));
    model.exprs.items[range_end].ty = 1;
    const source_range = try model.e(.{ .range = .{
        .start = range_start,
        .end = range_end,
        .inclusive = false,
    } });
    model.exprs.items[source_range].ty = 1;
    const chain = try model.e(.{ .iterator_chain = .{
        .source = source_range,
        .adapters = &.{},
        .terminal = .collect_vec,
    } });
    model.exprs.items[chain].ty = 2;
    const collected = try model.e(.{ .return_ = .{ .value = chain } });
    model.exprs.items[collected].ty = 2;
    // The literal belongs to the body: an expression no body reaches emits
    // nothing, and what this test is about is the three values reaching three
    // separate deposits.
    const literal_pattern = try model.pat(.{ .binding = .{
        .name = "literal",
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    const literal_statement = try model.stmt(.{ .let = .{
        .pattern = literal_pattern,
        .init = literal,
        .ty = null,
    } });
    const body_statements = try alloc.alloc(ir.exprs.NodeId, 1);
    body_statements[0] = literal_statement;
    const make_body = try model.e(.{ .block = .{
        .statements = body_statements,
        .tail = collected,
        .labelled = null,
    } });
    model.exprs.items[make_body].ty = 2;

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[make_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = vec_ty,
        .generic_params = &.{},
        .body = make_body,
        .is_allocating = true,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "collect_arguments",
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

    const source = try emitRootSource(alloc, &rust_ir);
    const append_first = std.mem.indexOf(u8, source, "append(allocator, 1)") orelse
        return error.MissingFirstElement;
    const append_second = std.mem.indexOf(u8, source, "append(allocator, 100)") orelse
        return error.MissingSecondElement;
    const append_third = std.mem.indexOf(u8, source, "append(allocator, 2)") orelse
        return error.MissingThirdElement;
    try std.testing.expect(append_first < append_second);
    try std.testing.expect(append_second < append_third);
    // The collect's own deposit is a different argument, built from its own
    // range cursor: the literal's values never reach it.
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "append(allocator, __r2z_range_cursor)",
    ) != null);
    try std.testing.expect(countOccurrences(source, "append(allocator, ") == 4);
}

// ── Written receivers and written parameters ───────────────────────────────
// Zig parameters are const. A binding the body writes therefore cannot be the
// signature parameter: it becomes an immutable `_x` plus a `var x` local. What
// counts as "writes the binding" is the whole of the repair — a field or an
// element of an owned value does, a place behind a pointer the binding already
// holds does not.

/// What a receiver fixture writes, so one builder covers a written by-value
/// receiver, an untouched one, and a borrowed one.
const ReceiverWrite = enum {
    /// `self.k = 1` through an owned receiver.
    owned_field,
    /// The receiver is only read.
    untouched,
    /// `self.k = 1` through a `&mut self` receiver.
    borrowed_field,
};

/// Lower `impl Counter { fn bump(self) -> u64 }` in the shape named by
/// `write`, and return the emitted source. `shadowed_self` adds a body binding
/// spelled `_self`, which the signature must not also claim.
fn emitReceiverWriteFixture(
    backing: std.mem.Allocator,
    write: ReceiverWrite,
    shadowed_self: bool,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const struct_id = try addLowerEntity(&graph, .struct_, "Counter", root_id);
    const method_id = try addLowerEntity(&graph, .fn_, "bump", struct_id);
    const self_def = try addLowerEntity(&graph, .field, "self", method_id);
    const k_def = try addLowerEntity(&graph, .field, "k", struct_id);
    if (shadowed_self) _ = try addLowerEntity(&graph, .field, "_self", method_id);

    const counter_segments = [_]ir.types.PathSegment{.{ .name = "Counter", .id = struct_id }};
    const counter_ty: ir.types.Type = .{ .path = .{ .segments = &counter_segments } };
    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const types = [_]ir.types.Type{ counter_ty, u64_ty };

    var statements: std.ArrayListUnmanaged(ir.exprs.NodeId) = .empty;
    const tail_base = try model.e(.{ .path = .{ .def = self_def, .generic_args = &.{} } });
    model.exprs.items[tail_base].ty = 0;
    const tail = try model.e(.{ .field = .{
        .base = tail_base,
        .field = "k",
        .resolved = k_def,
    } });
    model.exprs.items[tail].ty = 1;

    if (write != .untouched) {
        const target_base = try model.e(.{ .path = .{ .def = self_def, .generic_args = &.{} } });
        model.exprs.items[target_base].ty = 0;
        const target = try model.e(.{ .field = .{
            .base = target_base,
            .field = "k",
            .resolved = k_def,
        } });
        model.exprs.items[target].ty = 1;
        const value = try model.e(litInt(1));
        model.exprs.items[value].ty = 1;
        const assignment = try model.e(.{ .assign = .{
            .target = target,
            .op = .plain,
            .value = value,
            .overflow = .wrapping,
        } });
        model.exprs.items[assignment].ty = 1;
        try statements.append(alloc, try model.stmt(.{ .expr = assignment }));
    }

    const body = try model.e(.{ .block = .{
        .statements = statements.items,
        .tail = tail,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 1;

    const methods = [_]ir.bodies.StructMethod{.{
        .name = "bump",
        .visibility = .public,
        .params = &.{},
        .ret = u64_ty,
        .body = body,
        .receiver = switch (write) {
            .borrowed_field => .mut_ref,
            else => .owned,
        },
    }};

    const body_table = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_table) |*slot| slot.* = .none;
    body_table[struct_id] = .{ .struct_ = .{
        .fields = &.{.{ .name = "k", .ty = u64_ty, .visibility = .public, .span = span }},
        .methods = &methods,
    } };
    body_table[method_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "self", .ty = counter_ty, .span = span }},
        .ret = u64_ty,
        .body = body,
        .is_allocating = false,
    } };

    _ = try graph.addModule(.{
        .id = root_id,
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
        .name = "receiver_write",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "receiver_write",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_table,
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return backing.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

// `self.k = self.k + 1` on `mut self` reaches Zig as a field write on the
// receiver. An immutable `self: Counter` parameter cannot carry it, so the
// signature takes a copy and the body owns the mutable one.
test "lower: a written by-value receiver becomes a mutable local over an immutable parameter" {
    const source = try emitReceiverWriteFixture(std.testing.allocator, .owned_field, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_self: Counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var self: Counter = _self;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "self.k = 1;") != null);
}

// A receiver nothing writes is already immutable, and adding the copy would
// hand Zig a `var` no line ever mutates.
test "lower: an untouched by-value receiver keeps the plain parameter" {
    const source = try emitReceiverWriteFixture(std.testing.allocator, .untouched, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "self: Counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_self") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var self") == null);
}

// `&mut self` is already a Zig pointer: the field write goes through it.
test "lower: a written borrowed receiver keeps the pointer parameter" {
    const source = try emitReceiverWriteFixture(std.testing.allocator, .borrowed_field, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "self: *Counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_self") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var self") == null);
}

// The signature name is `_self` only while the body leaves it free.
test "lower: the receiver copy signature steps past a body binding named _self" {
    const source = try emitReceiverWriteFixture(std.testing.allocator, .owned_field, true);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_self_1: Counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var self: Counter = _self_1;") != null);
}

/// The parameter shape a write fixture binds. The first three name a value the
/// parameter owns; the last three reach their place through a pointer the
/// parameter already holds, where Zig writes without the binding.
const ParamWriteKind = enum {
    owned_struct_field,
    owned_nested_field,
    owned_array_index,
    mut_reference_field,
    mut_slice_index,
    raw_pointer_deref,
};

/// Lower `fn write(p: T) -> u64` with one assignment through `p` in the named
/// shape, and return the emitted source. `as_method` binds the same signature
/// as an inherent method parameter instead of a free function's.
fn emitParamWriteFixture(
    backing: std.mem.Allocator,
    kind: ParamWriteKind,
    as_method: bool,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const wrapper_id = try addLowerEntity(&graph, .struct_, "Wrapper", root_id);
    const inner_id = try addLowerEntity(&graph, .struct_, "Inner", root_id);
    const value_def = try addLowerEntity(&graph, .field, "value", wrapper_id);
    const inner_def = try addLowerEntity(&graph, .field, "inner", wrapper_id);
    const inner_value_def = try addLowerEntity(&graph, .field, "value", inner_id);
    const callable_id = try addLowerEntity(&graph, .fn_, "write", if (as_method) wrapper_id else root_id);
    const param_def = try addLowerEntity(&graph, .field, "p", callable_id);

    const wrapper_segments = [_]ir.types.PathSegment{.{ .name = "Wrapper", .id = wrapper_id }};
    const inner_segments = [_]ir.types.PathSegment{.{ .name = "Inner", .id = inner_id }};
    const wrapper_ty: ir.types.Type = .{ .path = .{ .segments = &wrapper_segments } };
    const inner_ty: ir.types.Type = .{ .path = .{ .segments = &inner_segments } };
    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const array_box = try alloc.create(ir.types.Array);
    array_box.* = .{ .elem = u64_ty, .len = .{ .literal = 3 } };
    const ref_box = try alloc.create(ir.types.Ref);
    ref_box.* = .{ .mut = true, .pointee = wrapper_ty };
    const slice_box = try alloc.create(ir.types.Slice);
    slice_box.* = .{ .const_ = false, .elem = u64_ty };
    const raw_box = try alloc.create(ir.types.RawPtr);
    raw_box.* = .{ .mut = true, .pointee = u64_ty };
    const array_ty: ir.types.Type = .{ .array = array_box };
    const ref_ty: ir.types.Type = .{ .reference = ref_box };
    const slice_ty: ir.types.Type = .{ .slice = slice_box };
    const raw_ty: ir.types.Type = .{ .raw_ptr = raw_box };
    const types = [_]ir.types.Type{ wrapper_ty, u64_ty, inner_ty, array_ty, ref_ty, slice_ty, raw_ty };

    // The declared type decides whether the written place belongs to the
    // binding; the id is the type-table index the body's `p` path carries, in
    // the `TypeId` the IR records an expression's type by.
    const param_shape: struct { ty: ir.types.Type, id: ir.exprs.TypeId } = switch (kind) {
        .owned_struct_field, .owned_nested_field => .{ .ty = wrapper_ty, .id = 0 },
        .owned_array_index => .{ .ty = array_ty, .id = 3 },
        .mut_reference_field => .{ .ty = ref_ty, .id = 4 },
        .mut_slice_index => .{ .ty = slice_ty, .id = 5 },
        .raw_pointer_deref => .{ .ty = raw_ty, .id = 6 },
    };

    const param_path = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[param_path].ty = param_shape.id;
    const index_literal = try model.e(litInt(0));
    model.exprs.items[index_literal].ty = 1;
    const value = try model.e(litInt(1));
    model.exprs.items[value].ty = 1;
    const target: ir.exprs.NodeId = switch (kind) {
        .owned_struct_field, .mut_reference_field => try model.e(.{ .field = .{
            .base = param_path,
            .field = "value",
            .resolved = value_def,
        } }),
        .owned_nested_field => inner_value_def_target: {
            const middle = try model.e(.{ .field = .{
                .base = param_path,
                .field = "inner",
                .resolved = inner_def,
            } });
            break :inner_value_def_target try model.e(.{ .field = .{
                .base = middle,
                .field = "value",
                .resolved = inner_value_def,
            } });
        },
        .owned_array_index, .mut_slice_index => try model.e(.{ .index = .{
            .base = param_path,
            .index = index_literal,
        } }),
        .raw_pointer_deref => try model.e(.{ .unary = .{ .op = .deref, .operand = param_path } }),
    };
    model.exprs.items[target].ty = 1;

    const assignment = try model.e(.{ .assign = .{
        .target = target,
        .op = .plain,
        .value = value,
        .overflow = .wrapping,
    } });
    model.exprs.items[assignment].ty = 1;
    const statements = try alloc.alloc(ir.exprs.NodeId, 1);
    statements[0] = try model.stmt(.{ .expr = assignment });
    const body = try model.e(.{ .block = .{
        .statements = statements,
        .tail = target,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 1;

    const callable_params = try alloc.alloc(ir.items.Param, 1);
    callable_params[0] = .{ .name = "p", .ty = param_shape.ty, .span = span };
    const callable_body: ir.bodies.BodyKind = .{ .fn_ = .{
        .params = callable_params,
        .ret = u64_ty,
        .body = body,
        .is_allocating = false,
    } };
    const methods = [_]ir.bodies.StructMethod{.{
        .name = "write",
        .visibility = .public,
        .params = callable_params,
        .ret = u64_ty,
        .body = body,
        .receiver = null,
    }};

    const struct_methods: []const ir.bodies.StructMethod = if (as_method) methods[0..] else &.{};
    const module_items: []const ir.spine.EntityId = if (as_method)
        &.{wrapper_id}
    else
        &.{ wrapper_id, callable_id };

    const body_table = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_table) |*slot| slot.* = .none;
    body_table[wrapper_id] = .{ .struct_ = .{
        .fields = &.{
            .{ .name = "value", .ty = u64_ty, .visibility = .public, .span = span },
            .{ .name = "inner", .ty = inner_ty, .visibility = .public, .span = span },
        },
        .methods = struct_methods,
    } };
    body_table[inner_id] = .{ .struct_ = .{
        .fields = &.{.{ .name = "value", .ty = u64_ty, .visibility = .public, .span = span }},
    } };
    body_table[callable_id] = callable_body;

    _ = try graph.addModule(.{
        .id = root_id,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = module_items,
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "param_write",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIr{
        .crate_name = "param_write",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_table,
        },
    };
    const package = try lower.lowerRustIr(alloc, &rust_ir, null);
    // The arena dies with this frame, so the caller must own the text.
    return backing.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

// `w.value = 1` writes a place the by-value parameter owns. Zig cannot write
// through a const parameter, so the binding needs the copy.
test "lower: a by-value struct parameter written through a field gets a mutable local" {
    const source = try emitParamWriteFixture(std.testing.allocator, .owned_struct_field, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_p: Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var p: Wrapper = _p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "p.value = 1;") != null);
}

// The chain `p.inner.value = 1` is still a place the parameter owns: the walk
// has to follow every projection back to the binding, not just the first.
test "lower: a nested owned-field write reaches the by-value parameter" {
    const source = try emitParamWriteFixture(std.testing.allocator, .owned_nested_field, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_p: Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var p: Wrapper = _p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "p.inner.value = 1;") != null);
}

// A by-value array is a Zig value too, and `a[0] = 1` writes it.
test "lower: a by-value array parameter written by index gets a mutable local" {
    const source = try emitParamWriteFixture(std.testing.allocator, .owned_array_index, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_p: [3]u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var p: [3]u64 = _p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "p[0] = 1;") != null);
}

// `&mut Wrapper` is a Zig pointer. `p.value = 1` already writes through it, and
// a copy would be a `var` nothing mutates.
test "lower: a written pointee behind a reference parameter needs no mutable local" {
    const source = try emitParamWriteFixture(std.testing.allocator, .mut_reference_field, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "p: *Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_p") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var p") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "p.value = 1;") != null);
}

// A mutable slice is the same story: the elements live behind the pointer the
// slice holds.
test "lower: an element write through a mutable slice parameter needs no mutable local" {
    const source = try emitParamWriteFixture(std.testing.allocator, .mut_slice_index, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "p: []u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_p") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var p") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "p[0] = 1;") != null);
}

// `*p = 1` writes the pointee outright, which no binding mutability reaches.
// The declared pointer TYPE is not spelled here: a Rust raw pointer lowers to
// an alignment-1 many-item pointer, and pinning that spelling would test the
// emitter's pointer rendering rather than the decision under test.
test "lower: a deref assignment through a raw pointer parameter needs no mutable local" {
    const source = try emitParamWriteFixture(std.testing.allocator, .raw_pointer_deref, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_p") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var p") == null);
}

// ── A `String` parameter the body consumes or mutates ──────────────────────
// `r2z.alloc.String` spells `into_bytes`, `clear` and the rest with a
// `self: *String` receiver, so the call reaches the string through a mutable
// pointer. Zig parameters are const, so such a parameter arrives as an
// immutable `_s` and the body works on a `var s`, exactly as a written
// parameter does. The shared views are the other half of the rule: `len` is
// `*const String`, so it must NOT produce that `var`.

/// What the `String`-parameter fixture's body does with the parameter.
const StringParamUse = enum {
    /// `s.into_bytes()`, which transfers the string's storage out.
    into_bytes,
    /// `s.clear()`, which reshapes the string in place.
    clear,
    /// `s.len()`, which only reads through `*const String`.
    len,
    /// `s.clear()` through a `&mut String` parameter.
    reference_clear,
};

/// Lower `fn use_string(s: T)` with the use named by `use`, and return the
/// emitted source. The parameter is an owned `String` unless the use asks for
/// `&mut`. `shadowed` adds a body binding spelled `_s`, which the copy's
/// signature name has to step past.
fn emitStringParamUseFixture(
    backing: std.mem.Allocator,
    use: StringParamUse,
    shadowed: bool,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const callable_id = try addLowerEntity(&graph, .fn_, "use_string", root_id);
    const param_def = try addLowerEntity(&graph, .field, "s", callable_id);
    if (shadowed) _ = try addLowerEntity(&graph, .field, "_s", callable_id);
    const into_bytes = try addLowerEntity(&graph, .method_ref, "into_bytes", null);
    const clear = try addLowerEntity(&graph, .method_ref, "clear", null);
    const len = try addLowerEntity(&graph, .method_ref, "len", null);

    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const byte_args = try alloc.alloc(ir.types.Type, 1);
    byte_args[0] = .{ .prim = .u8 };
    const bytes_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = byte_args,
    } };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const borrowed_string: ir.types.Ref = .{ .mut = true, .pointee = string_ty };
    const ref_string_ty: ir.types.Type = .{ .reference = &borrowed_string };
    // 0: String, 1: Vec<u8>, 2: usize, 3: &mut String.
    const types = [_]ir.types.Type{ string_ty, bytes_ty, usize_ty, ref_string_ty };

    const param_path = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[param_path].ty = if (use == .reference_clear) 3 else 0;
    const call = try model.e(.{ .method_call = .{
        .receiver = param_path,
        .receiver_mode = switch (use) {
            .into_bytes => .value,
            .len => .shared,
            .clear, .reference_clear => .mutable,
        },
        .method = switch (use) {
            .into_bytes => into_bytes,
            .len => len,
            .clear, .reference_clear => clear,
        },
        .args = &.{},
    } });
    model.exprs.items[call].ty = switch (use) {
        .into_bytes => 1,
        .len => 2,
        .clear, .reference_clear => null,
    };

    // `clear` and `into_bytes` leave the function nothing to return, so the
    // call is a statement there; `len`'s value is the result.
    const call_is_statement = use == .clear or use == .reference_clear;
    var statements: std.ArrayListUnmanaged(ir.exprs.NodeId) = .empty;
    defer statements.deinit(alloc);
    if (shadowed) {
        const shadow_pattern = try model.pat(.{ .binding = .{
            .name = "_s",
            .mode = .value,
            .mutable = false,
        } });
        const seven = try model.e(litInt(7));
        model.exprs.items[seven].ty = 2;
        try statements.append(alloc, try model.stmt(.{ .let = .{
            .pattern = shadow_pattern,
            .init = seven,
            .ty = null,
        } }));
    }
    if (call_is_statement) {
        try statements.append(alloc, try model.stmt(.{ .expr = call }));
    }

    const body = try model.e(.{ .block = .{
        .statements = statements.items,
        .tail = if (call_is_statement) null else call,
        .labelled = null,
    } });
    model.exprs.items[body].ty = model.exprs.items[call].ty;

    const callable_params = try alloc.alloc(ir.items.Param, 1);
    callable_params[0] = .{
        .name = "s",
        .ty = if (use == .reference_clear) ref_string_ty else string_ty,
        .span = span,
    };
    const body_table = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_table) |*slot| slot.* = .none;
    body_table[callable_id] = .{ .fn_ = .{
        .params = callable_params,
        .ret = switch (use) {
            .into_bytes => bytes_ty,
            .len => usize_ty,
            .clear, .reference_clear => .{ .prim = .unit },
        },
        .body = body,
        .is_allocating = false,
    } };
    try addBareCrate(&graph, alloc, "string_param_use", root_id, &.{callable_id});

    const rust_ir = ir.RustIr{
        .crate_name = "string_param_use",
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
    // The arena dies with this frame, so the caller must own the text.
    return backing.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

// `s.into_bytes()` transfers the string's storage out through `self: *String`.
// The parameter is const in Zig, so the body owns a `var` copy of it — and the
// call reaches that copy, not a fresh alias that would leave the allocation
// with two names.
test "lower: an owned String parameter consumed by into_bytes takes mutable storage" {
    const source = try emitStringParamUseFixture(std.testing.allocator, .into_bytes, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_s: r2z.alloc.String") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var s: r2z.alloc.String = _s;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "s.into_bytes()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "__r2z_string_receiver") == null);
}

// `s.clear()` reshapes the string in place, and that is `self: *String` too.
// Nothing is transferred here, so the copy is the only name for the storage
// from the moment it is made.
test "lower: an owned String parameter mutated by clear takes mutable storage" {
    const source = try emitStringParamUseFixture(std.testing.allocator, .clear, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_s: r2z.alloc.String") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var s: r2z.alloc.String = _s;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "s.clear()") != null);
}

// `s.len()` takes `*const String`, which a Zig parameter already is. A copy
// here would be a `var` no call ever reaches.
test "lower: an owned String parameter only read keeps the plain parameter" {
    const source = try emitStringParamUseFixture(std.testing.allocator, .len, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "s: r2z.alloc.String") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_s:") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var s") == null);
}

// `&mut String` arrives as `*String`, and Zig writes through it from an
// immutable parameter binding. Copying it would need storage the borrow never
// had.
test "lower: a String parameter reached through &mut String stays borrowed" {
    const source = try emitStringParamUseFixture(std.testing.allocator, .reference_clear, false);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "s: *r2z.alloc.String") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_s:") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var s") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "s.clear()") != null);
}

// A body binding spelled `_s` already owns that identifier, so the parameter's
// immutable copy has to step to `_s_1`. The body still reads `s`, and both
// names are distinct declarations. The body binding itself never reaches the
// emitted file — nothing reads it — so the collision is proved by the two
// names above rather than by the dropped declaration.
test "lower: a consumed String parameter steps past a body binding named _s" {
    const source = try emitStringParamUseFixture(std.testing.allocator, .into_bytes, true);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_s_1: r2z.alloc.String") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var s: r2z.alloc.String = _s_1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "s.into_bytes()") != null);
}

// ── A copied parameter keeps its identity when the copy is renamed ----------
// `fn take(pair: (u64, u64)) -> u64 { let _pair = 7; pair.0 = 1; let (a, _) =
// pair; a }` — the body binding `_pair` pushes the parameter's immutable copy
// to `_pair_1`, and the destructuring still has to see `pair` as a parameter.
// Treating the parameter as an ordinary expression instead binds its value to
// a `_tuple` alias, which for an owned value is a second name for it.

/// Lower the fixture above and return the emitted source.
fn emitTupleParamCopyFixture(backing: std.mem.Allocator) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const callable_id = try addLowerEntity(&graph, .fn_, "take", root_id);
    const param_def = try addLowerEntity(&graph, .field, "pair", callable_id);
    _ = try addLowerEntity(&graph, .field, "_pair", callable_id);
    const first_def = try addLowerEntity(&graph, .field, "a", callable_id);
    const element_def = try addLowerEntity(&graph, .field, "0", null);

    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const tuple_ty: ir.types.Type = .{ .tuple = &.{ u64_ty, u64_ty } };
    // 0: (u64, u64), 1: u64.
    const types = [_]ir.types.Type{ tuple_ty, u64_ty };

    const param_path = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[param_path].ty = 0;
    const element = try model.e(.{ .field = .{
        .base = param_path,
        .field = "0",
        .resolved = element_def,
    } });
    model.exprs.items[element].ty = 1;
    const one = try model.e(litInt(1));
    model.exprs.items[one].ty = 1;
    const assignment = try model.e(.{ .assign = .{
        .target = element,
        .op = .plain,
        .value = one,
        .overflow = .wrapping,
    } });
    model.exprs.items[assignment].ty = 1;

    const shadow_pat = try model.pat(.{ .binding = .{
        .name = "_pair",
        .mode = .value,
        .mutable = false,
    } });
    const seven = try model.e(litInt(7));
    model.exprs.items[seven].ty = 1;
    const shadow_stmt = try model.stmt(.{ .let = .{
        .pattern = shadow_pat,
        .init = seven,
        .ty = null,
    } });

    const first_pat = try model.pat(.{ .binding = .{
        .name = "a",
        .mode = .value,
        .mutable = false,
    } });
    const ignored_pat = try model.pat(.{ .wildcard = {} });
    const pair_pat = try model.pat(.{ .tuple = .{
        .elements = &.{ first_pat, ignored_pat },
        .rest = false,
    } });
    const destructure = try model.stmt(.{ .let = .{
        .pattern = pair_pat,
        .init = param_path,
        .ty = null,
    } });

    const first_path = try model.e(.{ .path = .{ .def = first_def, .generic_args = &.{} } });
    model.exprs.items[first_path].ty = 1;

    const statements = try alloc.alloc(ir.exprs.NodeId, 3);
    statements[0] = shadow_stmt;
    statements[1] = try model.stmt(.{ .expr = assignment });
    statements[2] = destructure;
    const body = try model.e(.{ .block = .{
        .statements = statements,
        .tail = first_path,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 1;

    const callable_params = try alloc.alloc(ir.items.Param, 1);
    callable_params[0] = .{ .name = "pair", .ty = tuple_ty, .span = span };
    const body_table = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_table) |*slot| slot.* = .none;
    body_table[callable_id] = .{ .fn_ = .{
        .params = callable_params,
        .ret = u64_ty,
        .body = body,
        .is_allocating = false,
    } };
    try addBareCrate(&graph, alloc, "tuple_param_copy", root_id, &.{callable_id});

    const rust_ir = ir.RustIr{
        .crate_name = "tuple_param_copy",
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
    // The arena dies with this frame, so the caller must own the text.
    return backing.dupe(u8, try emit.emitFile(alloc, &package.files[0]));
}

test "lower: a renamed parameter copy still destructures the parameter itself" {
    const source = try emitTupleParamCopyFixture(std.testing.allocator);
    defer std.testing.allocator.free(source);
    // The copy stepped past the body binding, and the write reached the copy.
    // A tuple element is a field named after its index, which Zig writes
    // `@"0"`.
    try std.testing.expect(std.mem.indexOf(u8, source, "_pair_1: struct { u64, u64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var pair: struct { u64, u64 } = _pair_1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pair.@\"0\" = 1;") != null);
    // The destructuring read the parameter instead of aliasing it into a
    // `_tuple` local, which `pair[0]` and the missing alias show.
    try std.testing.expect(std.mem.indexOf(u8, source, "= pair[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_tuple") == null);
}

// ── Owned containers: cow copies, transfers, and iterator extends ──

/// `Cow<'a, str>`, which lowers to the runtime's `r2z.alloc.CowStr`.
///
/// The nominal and its one argument are arena-allocated rather than written as
/// anonymous array literals: a literal holding a function call is a temporary,
/// and the slice would be left pointing at storage that is gone by the time the
/// type is read back.
fn cowStrType(alloc: std.mem.Allocator) !ir.types.Type {
    const borrowed_path = try alloc.dupe([]const u8, &.{ "core", "primitive", "str" });
    const cow_path = try alloc.dupe([]const u8, &.{ "alloc", "borrow", "Cow" });
    const cow_args = try alloc.alloc(ir.types.Type, 1);
    cow_args[0] = .{ .external_nominal = .{
        .path = borrowed_path,
        .args = try alloc.alloc(ir.types.Type, 0),
    } };
    return .{ .external_nominal = .{ .path = cow_path, .args = cow_args } };
}

/// Lower `fn run(value: Cow<'a, str>) -> Cow<'a, str> { value.<method>() }`
/// and return the emitted body expression.
///
/// `value` is a binding, so the receiver is a place. What comes back therefore
/// describes WHICH runtime constructor the method name selects and what that
/// constructor is handed — the decision this lowering makes — rather than any
/// owner it had to build for a receiver with no place of its own.
fn cowMethodFixture(alloc: std.mem.Allocator, method_name: []const u8) !ast.Expr {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const fn_id = try addLowerEntity(&graph, .fn_, "run", root_id);
    const method_id = try addLowerEntity(&graph, .method_ref, method_name, fn_id);
    const value_id = try addLowerEntity(&graph, .const_, "value", root_id);
    try addBareCrate(&graph, alloc, "cow_method_test", root_id, &.{fn_id});

    const cow_ty = try cowStrType(alloc);
    const types = [_]ir.types.Type{cow_ty};

    const receiver = try model.e(.{ .path = .{ .def = value_id, .generic_args = &.{} } });
    model.exprs.items[receiver].ty = 0;
    const call = try model.e(.{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .value,
        .method = method_id,
        .args = &.{},
    } });
    model.exprs.items[call].ty = 0;
    const block = try model.e(.{ .block = .{ .statements = &.{}, .tail = call, .labelled = null } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{.{ .name = "value", .ty = cow_ty, .span = span }},
        .ret = cow_ty,
        .generic_params = &.{},
        .body = block,
        .is_allocating = false,
    } };
    body_rows[value_id] = .{ .const_ = .{ .ty = cow_ty, .init = receiver } };

    const rust_ir = ir.RustIr{
        .crate_name = "cow_method_test",
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
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const expr = body.expr orelse return error.ExpectedBodyExpression;
    return expr.*;
}

/// Lower `fn run(value: Vec<u8>, source: <source_ty>) { value.extend(source); }`
/// and return the emitted body expression.
fn vecExtendFixture(alloc: std.mem.Allocator, source_ty: ir.types.Type) !ast.Expr {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const fn_id = try addLowerEntity(&graph, .fn_, "run", root_id);
    const method_id = try addLowerEntity(&graph, .method_ref, "extend", fn_id);
    const value_id = try addLowerEntity(&graph, .const_, "value", root_id);
    const source_id = try addLowerEntity(&graph, .const_, "source", root_id);
    try addBareCrate(&graph, alloc, "vec_extend_test", root_id, &.{fn_id});

    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const vec_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{u8_ty},
    } };
    // 0 = `Vec<u8>`, 1 = the source, 2 = `u8`.
    const types = [_]ir.types.Type{ vec_ty, source_ty, u8_ty };

    const receiver = try model.e(.{ .path = .{ .def = value_id, .generic_args = &.{} } });
    model.exprs.items[receiver].ty = 0;
    const source = try model.e(.{ .path = .{ .def = source_id, .generic_args = &.{} } });
    model.exprs.items[source].ty = 1;
    const call = try model.e(.{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .value,
        .method = method_id,
        .args = &.{source},
    } });
    model.exprs.items[call].ty = 0;
    const block = try model.e(.{ .block = .{ .statements = &.{}, .tail = call, .labelled = null } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = &.{
            .{ .name = "value", .ty = vec_ty, .span = span },
            .{ .name = "source", .ty = source_ty, .span = span },
        },
        .ret = .{ .prim = .unit },
        .generic_params = &.{},
        .body = block,
        .is_allocating = false,
    } };
    body_rows[value_id] = .{ .const_ = .{ .ty = vec_ty, .init = receiver } };
    body_rows[source_id] = .{ .const_ = .{ .ty = source_ty, .init = source } };

    const rust_ir = ir.RustIr{
        .crate_name = "vec_extend_test",
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
    const decl = package.files[0].decls[0];
    if (decl != .fn_decl) return error.ExpectedFunctionDeclaration;
    const body = decl.fn_decl.body orelse return error.ExpectedFunctionBody;
    const expr = body.expr orelse return error.ExpectedBodyExpression;
    return expr.*;
}

/// A lowered call read back as the runtime helper or method it reaches, the
/// operands it was handed, and whether it is reached through `try`.
const RuntimeCallShape = struct {
    /// The callee spelled as a dotted path, the runtime name this lowering
    /// selected.
    callee: []const u8,
    /// The arguments the call was handed.
    args: []const ast.Expr,
    /// Whether the call is reached through `try`, which is what an allocating
    /// runtime entry point always is.
    is_try: bool,
};

/// Read one lowered `try <callee>(<args>)` call. Failing here means the
/// lowering reached some other shape entirely, which every rule below treats
/// as the answer it is guarding against.
fn expectRuntimeCall(expr: ast.Expr) !RuntimeCallShape {
    var body = expr;
    var is_try = false;
    if (expr == .unary_op and expr.unary_op.op == .try_op) {
        is_try = true;
        body = expr.unary_op.operand.*;
    }
    const call = switch (body) {
        .call => |value| value,
        else => return error.ExpectedRuntimeCall,
    };
    const callee = switch (call.callee.*) {
        .ident => |name| name,
        .field_access => |field| field.field_name,
        else => return error.ExpectedRuntimeCall,
    };
    return .{ .callee = callee, .args = call.args, .is_try = is_try };
}

/// The name one operand reads, or null when it reads something else.
fn operandIdent(expr: ast.Expr) ?[]const u8 {
    return switch (expr) {
        .ident => |name| name,
        else => null,
    };
}

test "lower: a Cow's to_owned copies the cow instead of consuming it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `impl<T: Clone> ToOwned for T { type Owned = T }` is the impl that answers
    // this name for a `Cow`, so the result is a copy of the SAME cow taken
    // through `&self`. Answering it with the consuming conversion would move a
    // value Rust only read, and answering it with the receiver itself would
    // hand two owners the same allocation the moment both are released — so
    // the runtime's own deep copy is the only faithful shape, and it allocates.
    const call = try expectRuntimeCall(try cowMethodFixture(alloc, "to_owned"));
    try std.testing.expectEqualStrings("clone", call.callee);
    try std.testing.expect(call.is_try);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualStrings("allocator", operandIdent(call.args[0]) orelse return error.ExpectedAllocatorOperand);
}

test "lower: a Cow's into_owned stays the consuming half" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The other name IS the consuming conversion: it moves the cow and yields
    // the payload it was guarding. Sharing an answer with `to_owned` is what
    // would consume a borrow, so this one has to keep reaching `into_owned`.
    const call = try expectRuntimeCall(try cowMethodFixture(alloc, "into_owned"));
    try std.testing.expectEqualStrings("into_owned", call.callee);
    try std.testing.expect(call.is_try);
}

test "lower: a Cow's as_bytes still reads the arm it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Splitting the two halves must not touch the read-only accessor: it
    // answers through the borrowed view, allocates nothing, and is not a
    // `try`.
    const call = try expectRuntimeCall(try cowMethodFixture(alloc, "as_bytes"));
    try std.testing.expectEqualStrings("as_ref", call.callee);
    try std.testing.expect(!call.is_try);
    try std.testing.expectEqual(@as(usize, 0), call.args.len);
}

test "lower: extending a Vec from a slice reaches the runtime vector helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A slice is the shape the runtime could already copy in whole, and it has
    // to keep working through the same call an iterator uses: the helper is
    // what decides, not a second rule here.
    const slice_source: ir.types.Type = .{ .slice = blk: {
        const slice_info = try alloc.create(ir.types.Slice);
        slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
        break :blk slice_info;
    } };
    const call = try expectRuntimeCall(try vecExtendFixture(alloc, slice_source));
    try std.testing.expectEqualStrings("r2z.alloc.vec_extend", call.callee);
    try std.testing.expect(call.is_try);
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    try std.testing.expectEqualStrings("allocator", operandIdent(call.args[0]) orelse return error.ExpectedAllocatorOperand);
    try std.testing.expectEqualStrings("source", operandIdent(call.args[2]) orelse return error.ExpectedSourceOperand);
}

test "lower: extending a Vec from an iterator is lowered rather than refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Rust's `extend` takes any `IntoIterator`, and the original percent
    // decoder hands it a struct that is not a sequence at all. A source that
    // is not a slice and not an array used to be refused here; refusing it
    // dropped a call the source compiles, so the runtime helper's own
    // sequence-or-iterator rule is the only decision left to make.
    const iterator_source: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "Iter" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const call = try expectRuntimeCall(try vecExtendFixture(alloc, iterator_source));
    try std.testing.expectEqualStrings("r2z.alloc.vec_extend", call.callee);
    try std.testing.expect(call.is_try);
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    try std.testing.expectEqualStrings("source", operandIdent(call.args[2]) orelse return error.ExpectedSourceOperand);
}

test "lower: an owned receiver is handed to the runtime by address, never copied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The helper grows the caller's vector in place, so the operand is the
    // address of the vector itself. A copy would leave the caller holding a
    // second owner of the same bytes, and nothing would release the prefix
    // that was appended to.
    const iterator_source: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "Iter" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const call = try expectRuntimeCall(try vecExtendFixture(alloc, iterator_source));
    const destination = switch (call.args[1]) {
        .unary_op => |unary| unary,
        else => return error.ExpectedAddressOperand,
    };
    try std.testing.expectEqual(ast.UnaryOpKind.addr_of, destination.op);
    try std.testing.expectEqualStrings("value", operandIdent(destination.operand.*) orelse return error.ExpectedReceiverOperand);
}
