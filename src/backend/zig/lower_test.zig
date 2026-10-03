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
///
/// Every slice and name handed to `addModule`/`addUse` is retained by the
/// graph (and freed by `CrateGraph.deinit`), so each one is duplicated into
/// the caller's allocator: a stack-backed array literal would dangle as soon
/// as this helper returns.
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
        .name = try alloc.dupe(u8, ""),
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
        .name = try alloc.dupe(u8, "util"),
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
        .name = try alloc.dupe(u8, "helper"),
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
        .name = try alloc.dupe(u8, "dup"),
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
        .name = try alloc.dupe(u8, ""),
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
        .local_name = try alloc.dupe(u8, "helper"),
        .is_pub_export = true,
        .span = span,
    });

    const use_dup_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = try alloc.dupe(u8, ""),
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
        .local_name = try alloc.dupe(u8, "dup"),
        .is_pub_export = true,
        .span = span,
    });

    const use_wild_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = try alloc.dupe(u8, ""),
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
        .local_name = try alloc.dupe(u8, "_"),
        .is_pub_export = true,
        .span = span,
    });

    const use_glob_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .use_,
        .name = try alloc.dupe(u8, ""),
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
        .local_name = try alloc.dupe(u8, "Foo"),
        .is_pub_export = true,
        .span = span,
    });

    const api_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "api"),
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
        .name = try alloc.dupe(u8, ""),
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
        .local_name = try alloc.dupe(u8, "helper"),
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
        .name = try alloc.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{
            util_id,
            dup_id,
            use_helper_id,
            use_dup_id,
            use_wild_id,
            use_glob_id,
            api_id,
        }),
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try alloc.dupe(u8, "util"),
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{helper_id}),
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try alloc.dupe(u8, "api"),
        .parent = root_id,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(ir.spine.EntityId, &.{api_use_id}),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = try alloc.dupe(u8, "usecrate"),
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{child_id}),
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{ glob_id, translated_id }),
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
    // The glob use resolved to the parent module, and a resolved use names
    // nothing the child declares: `Translated` is the one declaration the file
    // carries.
    try std.testing.expectEqual(@as(usize, 1), file.decls.len);
    // A struct the source declared with no members has exactly one lowered
    // form — a `const` naming the anonymous struct — because an empty
    // `struct_decl` is not a container at all. The declaration is read by its
    // name, which every memberless spelling shares.
    if (file.decls[0] != .const_decl) return error.ChildModuleMissing;
    try std.testing.expectEqualStrings("Translated", file.decls[0].const_decl.name);
    if (file.decls[0].const_decl.init != .type_value or
        file.decls[0].const_decl.init.type_value != .anon_struct)
    {
        return error.ChildModuleMissing;
    }
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

// ── std and alloc spell ONE `Vec` ──────────────────────────────────────────

// `test/crates/generic-owner-transfer/src/lib.rs:19-20` spells both of its
// containers `std::`: `use std::string::String;` and `use std::vec::Vec;`. The
// `String` import was admitted — `isRuntimeTypeImport`'s `is_alloc` arm covers
// both roots — and the `Vec` one was not, because `isAllocVecPath` matched the
// `alloc` root only. So the import fell past every arm of that function to
// `return error.UnsupportedExternalUse` and refused a crate with ZERO
// dependencies over a type this file lowers to `std.ArrayListUnmanaged` for the
// other spelling.
//
// The pairs below are every container and element spelling the corpus imports,
// and each pair has to import through the SAME policy — an admission that only
// one root reaches would leave the other spelling a refusal dressed as
// support.
test "lower: the std and alloc spellings of every corpus container import alike" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const spellings = [_]struct { path: []const []const u8, name: []const u8 }{
        // `std::vec::Vec` — generic-owner-transfer/src/lib.rs:20.
        .{ .path = &.{ "std", "vec", "Vec" }, .name = "Vec" },
        .{ .path = &.{ "alloc", "vec", "Vec" }, .name = "Vec" },
        // `std::string::String` — generic-owner-transfer/src/lib.rs:19.
        .{ .path = &.{ "std", "string", "String" }, .name = "String" },
        .{ .path = &.{ "alloc", "string", "String" }, .name = "String" },
        // hex/src/lib.rs:43 imports both of these through one `use alloc::{…}`.
        .{ .path = &.{ "alloc", "string", "ToString" }, .name = "ToString" },
        .{ .path = &.{ "std", "string", "ToString" }, .name = "ToString" },
        // syn/tests/common/eq.rs:180 and syn/tests/test_round_trip.rs:38.
        .{ .path = &.{ "std", "borrow", "Cow" }, .name = "Cow" },
        .{ .path = &.{ "alloc", "borrow", "Cow" }, .name = "Cow" },
        // cow-handoff/src/lib.rs, the mapped collections.
        .{ .path = &.{ "std", "collections", "HashMap" }, .name = "HashMap" },
        .{ .path = &.{ "alloc", "collections", "HashMap" }, .name = "HashMap" },
        .{ .path = &.{ "core", "collections", "HashMap" }, .name = "HashMap" },
        .{ .path = &.{ "std", "collections", "HashSet" }, .name = "HashSet" },
        .{ .path = &.{ "alloc", "collections", "HashSet" }, .name = "HashSet" },
        .{ .path = &.{ "core", "collections", "HashSet" }, .name = "HashSet" },
        // The builder argument a map carries — `std::hash::{Hasher,
        // BuildHasherDefault}` is the corpus's own spelling.
        .{ .path = &.{ "std", "hash", "BuildHasherDefault" }, .name = "BuildHasherDefault" },
        .{ .path = &.{ "core", "hash", "BuildHasherDefault" }, .name = "BuildHasherDefault" },
    };
    for (spellings) |case| {
        var graph = ir.graph.CrateGraph.init(alloc);
        var bodies: ir.bodies.Bodies = undefined;
        try buildSingleExternalUseModel(alloc, &graph, &bodies, case.path, case.name, false);
        const rust_ir = ir.RustIr{
            .crate_name = "external_uses",
            .edition = "2021",
            .graph = graph,
            .types = &.{},
            .bodies = bodies,
        };
        // Admitting the import means DECLARING NOTHING: the nominal lowering
        // is what adds the `r2z` import, and a lexical `use` of a runtime type
        // has no declaration of its own to emit.
        const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
        for (pkg.files[0].imports) |import| {
            try std.testing.expect(!std.mem.eql(u8, import.local_name, case.name));
        }
    }
}

// The import is only the first of the four answers that disagreed. A type
// spelled `std::vec::Vec` also has to REACH a lowering: `lowerExternalNominal`
// answers `alloc::vec::Vec` with `std.ArrayListUnmanaged` through the same
// predicate, and a `std` spelling that missed it named nothing at all. The
// parameter and the return are both the vector, so the fixture would be
// incomplete if only one of them were checked.
test "lower: a Vec declared through either root lowers to one and the same package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The same function built twice, once with the spelling `use std::vec::Vec`
    // writes and once with the spelling `use alloc::vec::Vec` writes. The two
    // inputs differ in exactly the one thing the source changed, so every other
    // byte of the generated package has to match — which is a stronger claim
    // than checking either spelling alone, because it fails if EITHER root
    // reaches a different arm anywhere in the pipeline.
    var rendered: [2][]const u8 = undefined;
    for ([_][]const u8{ "alloc", "std" }, 0..) |root, index| {
        var graph = ir.graph.CrateGraph.init(alloc);
        var model = Model.init(alloc);
        const root_id = try addLowerEntity(&graph, .module, "", null);
        const function_id = try addLowerEntity(&graph, .fn_, "take_list", root_id);

        const vector_type: ir.types.Type = .{ .external_nominal = .{
            .path = &.{ root, "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } };
        const body = try model.e(.unit);
        try addBareCrate(&graph, alloc, "vec_spelling", root_id, &.{function_id});
        while (model.bodies.items.len <= function_id) {
            try model.bodies.append(model.a(), .{ .none = {} });
        }
        // `is_allocating` is left FALSE on purpose: an owned parameter makes the
        // callable allocating on its own, and `paramsOwnRuntimeContainer` is
        // that gate. Setting it here would hide the very decision under test,
        // which is why the `std` spelling used to leak its allocation.
        model.bodies.items[function_id] = .{ .fn_ = .{
            .params = &.{.{
                .name = "list",
                .ty = vector_type,
                .span = span,
            }},
            .ret = vector_type,
            .body = body,
            .is_allocating = false,
        } };

        const rust_ir = ir.RustIr{
            .crate_name = "vec_spelling",
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
        const source = try emitRootSource(alloc, &rust_ir);

        // The type the vector lowers to. BOTH the parameter and the return go
        // through `lowerExternalNominal`, so both spellings have to reach it —
        // and `lowerRuntimeGenericExternalType` is what adds the r2z import, so
        // a lowering that missed it would leave the package naming nothing.
        try std.testing.expect(std.mem.indexOf(u8, source, "std.ArrayListUnmanaged(u8)") != null);
        // An owned parameter declares the allocator ahead of itself, and that
        // argument count is what every call to this function is built against.
        try std.testing.expect(std.mem.indexOf(u8, source, "allocator: std.mem.Allocator") != null);
        rendered[index] = source;
    }
    try std.testing.expectEqualStrings(rendered[0], rendered[1]);
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

/// `buildSingleExternalUseModel` plus one DECLARED dependency, so the
/// dependency-rooted arm has something to resolve the root against.
///
/// The dependency is declared in the crate manifest rather than recognised by
/// its spelling: a crate this build has never heard of becomes a dependency
/// because the manifest says so, not because its name looks like one.
fn buildDependencyExternalUseModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
    path: []const []const u8,
    local_name: []const u8,
    alias: []const u8,
    package: []const u8,
) !void {
    try buildSingleExternalUseModel(alloc, graph, bodies, path, local_name, false);
    // A dependency is DECLARED by name alone or BOUND at runtime, and only the
    // second can carry a root this pipeline is able to drop: the bound form's
    // surface already lives in `r2z`, so admitting the root admits nothing
    // that has to be vendored. The proof is the version requirement plus the
    // frontend's answer that this build's RESOLVED feature set for the
    // dependency is certainly empty. Without both the declaration only says
    // the crate is reachable, and the root still needs a source tree.
    graph.crates.items[0].deps = try alloc.dupe(ir.graph.CrateDep, &.{.{
        .extern_name = package,
        .local_alias = alias,
        .id = 1,
        .version = "0.5",
        .resolved_features_known_empty = true,
    }});
}

// `std::io::BufRead` is a bound, not a type: the runtime reaches `fill_buf` and
// `consume` through the receiver it already knows, so admitting the import is
// admitting nothing. Refusing it would make every `BufRead` method
// unrecognisable and drop the bound the source actually wrote.
test "lower: a private std::io::BufRead import lowers with no declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "std", "io", "BufRead" },
        "BufRead",
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
    try std.testing.expectEqual(@as(usize, 0), pkg.files[0].decls.len);
    for (pkg.files[0].imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "BufRead"));
    }
}

// `BufReader` IS a runtime type, but the import is still not what introduces
// it: the nominal lowering adds `r2z.io.BufReader` where a `BufReader` is
// actually named, and an import that named it here would double it.
test "lower: a private std::io::BufReader import lowers with no declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "std", "io", "BufReader" },
        "BufReader",
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
    try std.testing.expectEqual(@as(usize, 0), pkg.files[0].decls.len);
    for (pkg.files[0].imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "BufReader"));
    }
}

// Admitting the two above is not a namespace catch-all. `std::io::Seek` has no
// bound and no runtime counterpart, so admitting it would turn a precise
// refusal into a silently dropped import — and the generated package would
// then name a type the translator never defined. This is the same invariant the
// collections cases above keep for their own namespace.
test "lower: an std::io item with no bound and no runtime counterpart is still refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "std", "io", "Seek" },
        "Seek",
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

// A declared dependency is admitted as a ROOT the manifest names, and still
// declares nothing: the trait it brings is a bound the runtime resolves from
// the receiver, exactly like `BufRead`. Both halves are asserted — no
// declaration invented, and no import the root file did not ask for.
test "lower: a dependency-rooted import declares nothing and still binds the crate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildDependencyExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "rand_core", "RngCore" },
        "RngCore",
        "rand_core",
        "rand_core",
    );
    const rust_ir = ir.RustIr{
        .crate_name = "external_uses",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = bodies,
    };
    const pkg = try lower.lowerRustIr(alloc, &rust_ir, null);
    try std.testing.expectEqual(@as(usize, 0), pkg.files[0].decls.len);
    for (pkg.files[0].imports) |import| {
        try std.testing.expect(!std.mem.eql(u8, import.local_name, "RngCore"));
    }
}

// And that arm is bounded by the manifest, not by the spelling. A root that is
// neither core/std/alloc nor a declared dependency stays a precise refusal.
test "lower: an undeclared root is still refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var bodies: ir.bodies.Bodies = undefined;
    try buildSingleExternalUseModel(
        alloc,
        &graph,
        &bodies,
        &.{ "not_a_dependency", "RngCore" },
        "RngCore",
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
                try std.testing.expectEqual(@as(u64, 256), rp.len);
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
            // `VecLit.repeat` is a `?VecRepeatCount`, and a count the translator
            // already holds is its `literal` arm. `ArrayExpr.repeat` is the
            // plain `?u64` and needs no such wrapper.
            .repeat = .{ .literal = 3 },
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
    /// The declared type of the captured parameter. null → `u8`, which is not
    /// an owner and so exercises the descriptor-copy path.
    capture_ty: ?ir.types.Type = null,
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
    /// Type the receiver EXPRESSION carries, when it is not the type the
    /// enclosing signature declares. `null` → `receiver_ty`, which is what
    /// every caller wants until it is testing a receiver the signature never
    /// had to spell — the case where the two answers can disagree.
    receiver_expr_ty: ?ir.types.Type = null,
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

    // 0: the receiver, 1: the captured parameter's own declared type. The
    // capture record names the second one, because whether a capture is an
    // OWNER is decided from its declared type and not from what it is called.
    const types_store = try alloc.alloc(ir.types.Type, 2);
    types_store[0] = fixture.receiver_expr_ty orelse fixture.receiver_ty;
    types_store[1] = fixture.capture_ty orelse fixture.receiver_ty;

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
            .ty = 1,
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
        two[1] = .{ .name = fixture.capture_name.?, .ty = fixture.capture_ty orelse .{ .prim = .u8 }, .span = span };
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

// `String::from_utf8(..)` carries its `Result` as a `core::result::Result`
// EXTERNAL NOMINAL, not as the IR's own `.result` descriptor, and that is the
// spelling most corpus crates carry. `lookupRecognizedStdMethod` has always
// classified the method on that spelling; `taggedResultType` is what the
// combinator then asks for the payload pair, and it used to answer null here,
// so `map_err(..)?` raised `error.UnsupportedStandardMethod` over a method the
// frontend had already RESOLVED. Both answers now come from
// `canonicalExternalMethodType`, so this is the positive case the fix exists
// for: the Ok arm is re-wrapped rather than the whole call refused.
test "lower: map_err on a core::result::Result nominal expands to a tagged rewrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ok_ty: ir.types.Type = .{ .prim = .u8 };
    // A payload-carrying error half, which is what `String::from_utf8` really
    // carries: it can never be a Zig error set, so the rebuilt type is the
    // tagged `r2z.Result` that HOLDS the error value rather than an error union
    // that would drop it. The assertion on the re-wrap type below is what
    // actually reads that distinction off the emitted AST.
    const err_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "FromUtf8Error" },
        .args = &.{},
    } };
    const result_args = [_]ir.types.Type{ ok_ty, err_ty };
    const result_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "result", "Result" },
        .args = &result_args,
    } };

    const expr = try lowerClosureCombinatorExpr(alloc, .{
        .method_name = "map_err",
        .receiver_ty = result_ty,
        .param_name = "byte",
    });
    if (expr != .match_expr) return error.ExpectedResultMapErrSwitch;
    const arms = expr.match_expr.arms;
    if (arms.len != 2) return error.ExpectedTwoSwitchArms;
    // `map_err` maps the Err arm and passes Ok through, so the mapped prong is
    // FIRST here — the mirror of the `map` test above.
    if (arms[0].patterns.len != 1 or arms[0].patterns[0] != .enum_literal or
        !std.mem.eql(u8, arms[0].patterns[0].enum_literal, "Err"))
    {
        return error.ExpectedErrProng;
    }
    const err_capture = arms[0].capture orelse return error.ExpectedErrPayloadCapture;
    if (!std.mem.eql(u8, err_capture.name, "__r2z_in_byte_err")) {
        return error.ExpectedErrPayloadName;
    }
    if (arms[1].patterns.len != 1 or arms[1].patterns[0] != .enum_literal or
        !std.mem.eql(u8, arms[1].patterns[0].enum_literal, "Ok"))
    {
        return error.ExpectedOkProng;
    }
    const ok_capture = arms[1].capture orelse return error.ExpectedOkPayloadCapture;
    if (!std.mem.eql(u8, ok_capture.name, "__r2z_in_byte")) return error.ExpectedOkPayloadName;
    if (arms[1].body != .struct_init) return error.ExpectedRewrappedOkArm;
    const rewrapped = arms[1].body.struct_init;
    // A field-bearing literal without a type name is not a valid AST node, and
    // the named type is the only place the rebuilt pair is visible at all.
    const rewrap_type = rewrapped.type_name orelse return error.ExpectedTypedResultLiteral;
    if (rewrap_type != .generic) return error.ExpectedTaggedResultRewrap;
    if (!std.mem.eql(u8, rewrap_type.generic.name, "r2z.Result")) {
        return error.ExpectedResultUnionName;
    }
    if (rewrapped.fields.len != 1) return error.ExpectedSingleResultField;
    if (!std.mem.eql(u8, rewrapped.fields[0].name, "Ok")) return error.ExpectedOkFieldName;
    if (rewrapped.fields[0].expr != .ident or
        !std.mem.eql(u8, rewrapped.fields[0].expr.ident, ok_capture.name))
    {
        return error.ExpectedOkFieldFromCapture;
    }
}

// The other half of the same predicate, and the only refusal the new
// `.external_nominal` arm owns outright. `lookupRecognizedStdMethod` and
// `taggedResultType` now ask `canonicalExternalMethodType` the same question,
// so a NOMINAL SPELLING can no longer make them disagree — the one place they
// still differ is arity, which the path-only predicate does not look at.
// A `core::result::Result` carrying one or three arguments is therefore
// classified as a `Result` method and reaches the combinator, and there
// `taggedResultType` must refuse rather than read `args[0]`/`args[1]` off a
// list that does not hold them.
//
// The declared parameter keeps the well-formed two-argument type on purpose:
// it is what makes this exercise `taggedResultType` rather than
// `lowerExternalNominal`, which rejects a malformed arity on its own and
// would otherwise raise first.
test "lower: a core::result::Result nominal of the wrong arity refuses the rewrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ok_ty: ir.types.Type = .{ .prim = .u8 };
    const err_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "FromUtf8Error" },
        .args = &.{},
    } };
    const well_formed = [_]ir.types.Type{ ok_ty, err_ty };

    const one_arg = [_]ir.types.Type{ok_ty};
    try std.testing.expectError(
        error.UnsupportedStandardMethod,
        lowerClosureCombinatorExpr(alloc, .{
            .method_name = "map_err",
            .receiver_ty = .{ .external_nominal = .{
                .path = &.{ "core", "result", "Result" },
                .args = &well_formed,
            } },
            .receiver_expr_ty = .{ .external_nominal = .{
                .path = &.{ "core", "result", "Result" },
                .args = &one_arg,
            } },
            .param_name = "byte",
        }),
    );

    const three_args = [_]ir.types.Type{ ok_ty, err_ty, ok_ty };
    try std.testing.expectError(
        error.UnsupportedStandardMethod,
        lowerClosureCombinatorExpr(alloc, .{
            .method_name = "map_err",
            .receiver_ty = .{ .external_nominal = .{
                .path = &.{ "core", "result", "Result" },
                .args = &well_formed,
            } },
            .receiver_expr_ty = .{ .external_nominal = .{
                .path = &.{ "core", "result", "Result" },
                .args = &three_args,
            } },
            .param_name = "byte",
        }),
    );
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{struct_id}),
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{struct_id}),
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{ support_id, private_fn_id, test_fn_id, support_use_id }),
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{remote_id}),
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{ struct_id, caller_id }),
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

/// The IR of `test/crates/hex/src/error.rs:47`: a data-carrying error enum,
/// its `Display` impl, and a `#[test]` that asserts on `to_string()`.
///
/// The `to_string()` node carries NO type, and that is the whole point. Nothing
/// in the source names the blanket `ToString::to_string` result — no signature
/// in the crate declares it — so the frontend leaves the call unannotated and
/// the comparison that consumes it has to learn from the lowering's OWN
/// recognition of the method that the call BUILDS an owned `String`. Reading
/// only the annotation hands that `String` to `r2z.ops.binary` by value, and
/// nothing in the emitted test releases it: the assertions all pass and every
/// one of them leaks a block the runtime handed over.
fn lowerDisplayAssertionPackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    // No module entity of its own: `addRootModule` below creates the crate
    // root and parents every item that has no parent yet, which is what hex's
    // own sidecar shows for the `error` module. Declaring a second module
    // entity with the same `(parent, name)` leaves two entities that both
    // answer to the one root row, and `moduleEntityId` resolves the file's
    // module id to whichever it meets first.
    const fault_id = try addLowerEntity(&graph, .enum_, "Fault", null);
    // The impl hangs off the TYPE, not off the module: `hoistTargetFor` answers
    // an impl with its own parent, and that parent is what decides where the
    // `format` hook lands. A module there makes it a module-scope free function,
    // so `Fault` never declares `format` and `r2z.format`'s protocol refuses
    // the value. This is hex's own topology — impl entity 9 is parented at the
    // `FromHexError` entity 7.
    const display_id = try addLowerEntity(&graph, .impl_, "fmt::Display for Fault", fault_id);
    // `declaresDisplayFmt` reads the IMPL entity's name and looks for a `fmt`
    // member under it, so this is the spelling hex's own source produces.
    const fmt_id = try addLowerEntity(&graph, .fn_, "fmt", display_id);
    const to_string_id = try addLowerEntity(&graph, .method_ref, "to_string", null);
    const test_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "test_display",
        .span = span,
        .visibility = .private,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        // `#[test]`, not the `test_` in the name, is what makes a Zig test.
        .attributes = &.{.{ .name = "test", .meta = "", .known = true }},
    });
    const writer_field = try addLowerEntity(&graph, .field, "f", fmt_id);

    // `fmt` is an `impl` member, not a module item — hex's `error` module lists
    // the enum and its `use` rows, and neither the impl nor `fmt` is among them.
    // `lowerModule` walks the items and, unlike `lowerRootFileFromSymbolTable`,
    // has no nested-method skip, so listing it emits a second module-scope
    // `fmt` beside the `format` member `collectHoistedMethods` already hoisted
    // onto `Fault`.
    _ = try addRootModule(&graph, .{
        .crate_name = "faults",
        .edition = 2021,
        .items = &.{ fault_id, display_id, test_id },
    });

    const fault_type: ir.types.Type = .{ .path = .{
        .segments = try alloc.dupe(ir.types.PathSegment, &.{
            .{ .name = "Fault", .id = fault_id },
        }),
    } };
    const types_store = try alloc.alloc(ir.types.Type, 4);
    types_store[0] = fault_type;
    types_store[1] = .{ .reference = &.{ .mut = false, .pointee = fault_type } };
    types_store[2] = .{ .reference = &.{ .mut = true, .pointee = .{ .external_nominal = .{
        .path = &.{ "core", "fmt", "Formatter" },
        .args = &.{},
    } } } };
    types_store[3] = .{ .external_nominal = .{
        .path = &.{ "core", "fmt", "Result" },
        .args = &.{},
    } };

    // `write!(f, "odd")`: the `Display` body, so the rendered value is exactly
    // what the assertion names and a wrong release cannot hide behind it.
    const writer = try model.e(.{ .path = .{ .def = writer_field, .generic_args = &.{} } });
    const write_body = try model.e(.{ .format_write = .{
        .writer = writer,
        .template = "odd",
        .args = &.{},
    } });
    const fmt_body = try model.e(.{ .block = .{
        .statements = &.{},
        .tail = write_body,
        .labelled = null,
    } });

    const odd = try model.e(.{ .enum_variant = .{
        .def = fault_id,
        .variant = "Odd",
        .tuple_fields = &.{},
        .named_fields = &.{},
    } });
    const rendered = try model.e(.{ .method_call = .{
        .receiver = odd,
        .receiver_mode = .value,
        .method = to_string_id,
        .args = &.{},
    } });
    const expected = try model.e(.{ .literal = .{ .string = .{ .bytes = "odd" } } });
    const condition = try model.e(.{ .binary = .{
        .op = .eq,
        .overflow = .wrapping,
        .lhs = rendered,
        .rhs = expected,
    } });
    const assertion_reason = try std.fmt.allocPrint(alloc, "assertion:{d}", .{condition});
    const marker = try model.e(.{ .unsupported = .{
        .reason = assertion_reason,
        .suggested_version = .v1,
    } });
    // The marker is a STATEMENT, not the block's tail: `assert_eq!` reaches the
    // backend as a statement whose value is the macro call, which is exactly
    // what hex's own AST golden records for `test_display` — an `expr_stmt`
    // beside the allocator binding in `body.stmts`, with no tail. A tail would
    // park the whole claim these tests make — the release the comparison's
    // owner carries — in the block's `expr`, where no walk of the test's
    // statement list can see it.
    const assertion = try model.stmt(.{ .expr = marker });
    const test_body = try model.e(.{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{assertion}),
        .tail = null,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fault_id] = .{ .enum_ = .{
        .kind = .data,
        .variants = try alloc.dupe(ir.items.Variant, &.{
            .{ .name = "At", .discriminant = null, .fields = .{ .named = try alloc.dupe(ir.items.Field, &.{
                .{
                    .name = "index",
                    .ty = .{ .prim = .usize },
                    .visibility = .private,
                    .span = span,
                },
            }) } },
            .{ .name = "Odd", .discriminant = null, .fields = .{ .none = {} } },
        }),
    } };
    body_rows[display_id] = .{ .impl_ = .{
        .self_ty = fault_type,
        .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
            .{ .name = "fmt", .id = null },
            .{ .name = "Display", .id = null },
        }) },
        .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{fmt_id}),
    } };
    body_rows[fmt_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "self", .ty = types_store[1], .span = span },
            .{ .name = "f", .ty = types_store[2], .span = span },
        }),
        .ret = types_store[3],
        .body = fmt_body,
    } };
    body_rows[test_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = test_body,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "faults",
        .edition = "2021",
        .graph = graph,
        .types = types_store,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = types_store,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// The owning half of the rule, read off the emitted AST rather than off text:
// the `to_string()` result is bound to a MUTABLE local and a `defer` releases
// it. A `defer`, not a statement after the comparison: the assertion returns
// early when the comparison is false, so a release that ran only on the way
// out of the success path would leak on the failure path too.
test "lower: a comparison against an unannotated to_string call owns its result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerDisplayAssertionPackage(alloc);

    const emitted = try emit.emitFile(alloc, &package.files[0]);
    var bound_owned_operand = false;
    var released_on_every_path = false;
    for (package.files[0].tests) |test_decl| {
        for (test_decl.body.stmts) |statement| {
            const comparison = switch (statement) {
                .expr_stmt => |expression| switch (expression.*) {
                    .unary_op => |unary| switch (unary.operand.*) {
                        .call => |call| switch (call.args[0]) {
                            .block => |block| block,
                            else => continue,
                        },
                        else => continue,
                    },
                    else => continue,
                },
                else => continue,
            };
            for (comparison.stmts) |inner| {
                const binding = switch (inner) {
                    .let_stmt => |let_stmt| let_stmt,
                    else => continue,
                };
                const bound_type = switch (binding.ty orelse continue) {
                    .named => |name| name,
                    else => continue,
                };
                if (!std.mem.eql(u8, bound_type, "r2z.alloc.String")) continue;
                // `dropTemporary` takes `*T` and `deinit` writes through it, so
                // a binding the release cannot name is a binding that cannot
                // be released.
                if (!binding.is_mut) continue;
                bound_owned_operand = true;
                for (comparison.stmts) |release| {
                    const deferred = switch (release) {
                        .defer_stmt => |defer_stmt| defer_stmt,
                        else => continue,
                    };
                    // `errdefer` runs on the error exits only. An assertion
                    // that PASSES takes neither, so an `errdefer` release is
                    // a release that never happens.
                    if (deferred.is_errdefer) continue;
                    const callee = switch (deferred.expr) {
                        .call => |call| call.callee.*,
                        else => continue,
                    };
                    const named = switch (callee) {
                        .ident => |name| name,
                        else => continue,
                    };
                    if (std.mem.eql(u8, named, "r2z.alloc.dropTemporary")) {
                        released_on_every_path = true;
                    }
                }
            }
        }
    }
    // The emitted text is printed only to show WHERE the typed walk found
    // nothing; the verdict itself is the walk above.
    if (!bound_owned_operand or !released_on_every_path) {
        std.debug.print("emitted:\n{s}\n", .{emitted});
    }
    try std.testing.expect(bound_owned_operand);
    try std.testing.expect(released_on_every_path);
}

// The runtime half: the generated test is compiled and RUN, so
// `std.testing.allocator` gets the last word. An emitted-text or typed-AST
// assertion can only claim a release is PRESENT; only a run can say the block
// the runtime handed over was actually given back EXACTLY ONCE, on the path
// the source takes. A release armed over storage that has already moved out
// aborts here, and so does one that was never armed at all.
fn runGeneratedPackageTests(alloc: std.mem.Allocator, package: ast.Package) !void {
    const test_io = std.testing.io;

    // `std.testing.tmpDir` stages under `.zig-cache/tmp` relative to the working
    // directory, which is local disk under this repository's documented
    // workflow: `tools/zig-pinned.sh` moves both cache directories there and the
    // README asks for a UID-owned local source copy precisely because the
    // checkout itself is an NFSv3 mount, where Zig's atomic write is
    // `renameat2(RENAME_EXCHANGE)` and aborts with EINVAL. The CHILD compiler's
    // caches are redirected into this staging tree as well, so nothing it
    // writes can land on the checkout.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = try std.fmt.allocPrint(alloc, "r2z-generated-leak-{s}", .{std.fmt.bytesToHex(seed, .lower)});
    try tmp.dir.createDirPath(test_io, nonce);
    defer tmp.dir.deleteTree(test_io, nonce) catch {};
    const staging = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{nonce});

    var dir = std.Io.Dir.cwd();
    for (package.files) |*file| {
        const source = try emit.emitFile(alloc, file);
        const path = try std.fs.path.join(alloc, &.{ staging, file.path });
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(test_io, parent);
        const out = try dir.createFile(test_io, path, .{});
        defer out.close(test_io);
        try out.writeStreamingAll(test_io, source);
    }

    const root_module = try std.fs.path.join(alloc, &.{ staging, "src/root.zig" });
    const cache_dir = try std.fs.path.join(alloc, &.{ staging, ".zig-cache" });
    const global_cache_dir = try std.fs.path.join(alloc, &.{ staging, ".zig-global-cache" });

    // `-M<name>=<path>` in ONE argument, the spelling `build.zig` uses for
    // every generated-package consumer, with `--dep r2z` in front of the module
    // that imports it.
    const root_arg = try std.fmt.allocPrint(alloc, "-Mroot={s}", .{root_module});
    const result = try std.process.run(alloc, test_io, .{
        .argv = &.{
            @import("toolchain").zig_executable,
            "test",
            "--cache-dir",
            cache_dir,
            "--global-cache-dir",
            global_cache_dir,
            "--dep",
            "r2z",
            root_arg,
            "--dep",
            "r2z",
            "-Mr2z=r2z-core/src/root.zig",
        },
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("generated package failed:\n{s}{s}\n", .{ result.stdout, result.stderr });
    return error.GeneratedPackageTestFailed;
}

test "lower: the generated test for an unannotated to_string call leaks nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try runGeneratedPackageTests(alloc, try lowerDisplayAssertionPackage(alloc));
}

// ── A by-value owner PARAMETER spent by a consuming runtime accessor ────────

/// Whether `expr` names the binding, or the address of it.
///
/// `r2z.alloc.takeOwned(T, &handle)` is handed the PLACE it empties, so the
/// emitted argument is `&handle`; a by-value move names the binding bare.
/// They are the same claim, and a walk that accepts only one spelling answers
/// a question about a shape the lowering does not emit.
fn placeNamesBinding(expr: ast.Expr, name: []const u8) bool {
    return switch (expr) {
        .ident => |value| std.mem.eql(u8, value, name),
        .unary_op => |unary| unary.op == .addr_of and
            placeNamesBinding(unary.operand.*, name),
        else => false,
    };
}

/// The expressions one statement evaluates, in the order it evaluates them.
///
/// A BINDING's initialiser counts. The transfer this walk is asked about sits
/// inside the `let` a comparison makes of an owned operand — the emitted shape
/// is `var x: T = r2z.alloc.takeOwned(T, &place).unwrap(allocator);` — so a
/// walk that reads only `expr_stmt` cannot see the one call the claim is
/// about.
fn statementExpressions(stmt: ast.Stmt) [2]ast.Expr {
    return switch (stmt) {
        .expr_stmt => |expression| .{ expression.*, .unit },
        .let_stmt => |let_stmt| .{ let_stmt.init, .unit },
        .defer_stmt => |defer_stmt| .{ defer_stmt.expr, .unit },
        .assign => |assign_stmt| .{ assign_stmt.val, assign_stmt.target },
    };
}

/// Whether `expr` contains a call to `callee` that is handed `argument`.
///
/// The ownership claim these tests make is a CLAIM ABOUT THE EMITTED AST, so it
/// is read off the AST: one call, one argument, placed at the named binding. It
/// is deliberately not a search over rendered text, which would re-pin whatever
/// spacing the emitter happens to produce today. The walk has to reach EVERY
/// position the emitter can put a call in, or it answers "absent" for a frame
/// that in fact empties its owner — the failure this test exists to catch,
/// reported from the wrong side.
fn callsWithArgument(expr: ast.Expr, callee: []const u8, argument: []const u8) bool {
    switch (expr) {
        .call => |call| {
            const named = switch (call.callee.*) {
                .ident => |name| name,
                else => "",
            };
            if (std.mem.eql(u8, named, callee)) {
                for (call.args) |arg| {
                    if (placeNamesBinding(arg, argument)) return true;
                }
            }
            // The callee is walked as well as the arguments: a member call
            // carries its receiver there, and a consuming accessor emits the
            // transfer that empties the owner as exactly that receiver —
            // `r2z.alloc.takeOwned(T, &value).unwrap(allocator)`. An
            // argument-only walk cannot see a call that is never an argument.
            if (callsWithArgument(call.callee.*, callee, argument)) return true;
            for (call.args) |arg| {
                if (callsWithArgument(arg, callee, argument)) return true;
            }
        },
        .unary_op => |unary| return callsWithArgument(unary.operand.*, callee, argument),
        .field_access => |access| return callsWithArgument(access.target.*, callee, argument),
        .block => |block| {
            for (block.stmts) |stmt| {
                for (statementExpressions(stmt)) |value| {
                    if (callsWithArgument(value, callee, argument)) return true;
                }
            }
            const value = block.expr orelse return false;
            return callsWithArgument(value.*, callee, argument);
        },
        else => {},
    }
    return false;
}

/// The IR of `test/crates/compat`'s `temporary_moved_result_equal` frame, the
/// one forwarding layer above it, and the `#[test]` that drives them.
///
/// ```rust
/// fn same_result() -> Result<String, u8> { Ok(String::from("same")) }
///
/// fn moved_result_equal(value: Result<String, u8>) -> bool {
///     value.unwrap() == "same"
/// }
///
/// fn moved_result_caller(value: Result<String, u8>) -> bool {
///     moved_result_equal(value)
/// }
/// ```
///
/// The parameter is an owner this frame OWNS: Rust moved the bytes in, so the
/// frame's body has to release them and the lowering arms
/// `defer r2z.alloc.dropTemporary(allocator, &value)` over it. `Result::unwrap`
/// declares `self`, so that call SPENDS the receiver, and the payload it hands
/// back is the same allocation the alias still names. The runtime helper is a
/// by-value method call, so it copies the union and empties nothing; reading
/// the receiver as a borrow leaves the armed release pointed at storage the
/// comparison's own release frees a second time. Every assertion still passes
/// and the test allocator aborts on the double free.
fn lowerMovedResultPackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root_id = try addRootModule(&graph, .{
        .crate_name = "moved_result",
        .edition = 2021,
        .items = &.{},
    });
    const core_id = try addLowerEntity(&graph, .module, "core", root_id);
    const result_module_id = try addLowerEntity(&graph, .module, "result", core_id);
    const result_enum_id = try addLowerEntity(&graph, .enum_, "Result", result_module_id);
    const build_id = try addLowerEntity(&graph, .fn_, "same_result", root_id);
    const equal_id = try addLowerEntity(&graph, .fn_, "moved_result_equal", root_id);
    // A parameter binding is a `.field` under its own callable: that is what
    // `LocalBindingNames` claims it by, and the owner release keys on the
    // entity rather than on the spelling.
    const equal_value_id = try addLowerEntity(&graph, .field, "value", equal_id);
    const caller_id = try addLowerEntity(&graph, .fn_, "moved_result_caller", root_id);
    const caller_value_id = try addLowerEntity(&graph, .field, "value", caller_id);
    const check_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = "moved_result_check",
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{.{ .name = "test", .meta = "", .known = true }},
    });
    // `unwrap` has no declaration in the crate, so the backend has to classify
    // it from the receiver's type alone — and so has to classify its ownership.
    const unwrap_id = try addLowerEntity(&graph, .method_ref, "unwrap", null);

    graph.modules.items[0].items = try alloc.dupe(
        ir.spine.EntityId,
        &.{ build_id, equal_id, caller_id, check_id },
    );
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

    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const result_type: ir.types.Type = .{ .result = try alloc.create(ir.types.Result) };
    @constCast(result_type.result).* = .{
        .ok = string_ty,
        .err = .{ .prim = .u8 },
        // The error type is a primitive, so this `Result` is the tagged
        // `r2z.Result` union and carries real methods — which is the whole
        // point: the accessor has to be recognised from the receiver's type.
        .is_error_unionable = false,
    };
    const types = try alloc.alloc(ir.types.Type, 2);
    types[0] = result_type;
    types[1] = string_ty;

    // `Ok(String::from("same"))`
    const text = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "same" } } });
    const built = try typedExpr(&model, 1, .{ .core_call = .{
        .function = .convert_from,
        .generic_args = &.{string_ty},
        .args = &.{text},
    } });
    const ok_payload = try alloc.alloc(ir.exprs.NodeId, 1);
    ok_payload[0] = built;
    const ok_value = try typedExpr(&model, 0, .{ .enum_variant = .{
        .def = result_enum_id,
        .variant = "Ok",
        .tuple_fields = ok_payload,
        .named_fields = &.{},
    } });
    const build_body = try typedExpr(&model, null, .{ .block = .{
        .statements = &.{},
        .tail = ok_value,
        .labelled = null,
    } });

    // `value.unwrap() == "same"`
    const equal_receiver = try typedExpr(&model, 0, .{ .path = .{
        .def = equal_value_id,
        .generic_args = &.{},
    } });
    const unwrapped = try typedExpr(&model, 1, .{ .method_call = .{
        .receiver = equal_receiver,
        .receiver_mode = .value,
        .method = unwrap_id,
        .args = &.{},
    } });
    const expected = try typedExpr(&model, null, .{ .literal = .{ .string = .{ .bytes = "same" } } });
    const comparison = try typedExpr(&model, null, .{ .binary = .{
        .op = .eq,
        .overflow = .wrapping,
        .lhs = unwrapped,
        .rhs = expected,
    } });
    const equal_body = try typedExpr(&model, null, .{ .block = .{
        .statements = &.{},
        .tail = comparison,
        .labelled = null,
    } });

    // `moved_result_equal(value)`
    const caller_argument = try typedExpr(&model, 0, .{ .path = .{
        .def = caller_value_id,
        .generic_args = &.{},
    } });
    const forwarded_args = try alloc.alloc(ir.exprs.NodeId, 1);
    forwarded_args[0] = caller_argument;
    const forwarded = try typedExpr(&model, null, .{ .call = .{
        .call_kind = .{ .free = equal_id },
        .args = forwarded_args,
    } });
    const caller_body = try typedExpr(&model, null, .{ .block = .{
        .statements = &.{},
        .tail = forwarded,
        .labelled = null,
    } });

    // `assert!(moved_result_caller(same_result()))`. `same_result` is declared
    // with no value parameter — it BUILDS the result — so the call passes no
    // argument either. Passing one would emit a call whose arity no
    // declaration matches.
    const built_call = try typedExpr(&model, null, .{ .call = .{
        .call_kind = .{ .free = build_id },
        .args = &.{},
    } });
    const called_args = try alloc.alloc(ir.exprs.NodeId, 1);
    called_args[0] = built_call;
    const called = try typedExpr(&model, null, .{ .call = .{
        .call_kind = .{ .free = caller_id },
        .args = called_args,
    } });
    const assertion_reason = try std.fmt.allocPrint(alloc, "assertion:{d}", .{called});
    const marker = try typedExpr(&model, null, .{ .unsupported = .{
        .reason = assertion_reason,
        .suggested_version = .v1,
    } });
    const check_body = try typedExpr(&model, null, .{ .block = .{
        .statements = &.{},
        .tail = marker,
        .labelled = null,
    } });

    const variants = try alloc.alloc(ir.items.Variant, 2);
    variants[0] = .{
        .name = "Ok",
        .fields = .{ .tuple = try alloc.dupe(ir.types.Type, &.{string_ty}) },
        .discriminant = null,
    };
    variants[1] = .{
        .name = "Err",
        .fields = .{ .tuple = try alloc.dupe(ir.types.Type, &.{.{ .prim = .u8 }}) },
        .discriminant = null,
    };

    const owner_param = try alloc.dupe(ir.items.Param, &.{.{ .name = "value", .ty = result_type, .span = span }});

    // The body table is indexed by EntityId, and the extern `core`/`result`
    // module entities are entities too, so cover the whole symbol table.
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[result_enum_id] = .{ .enum_ = .{ .kind = .data, .variants = variants } };
    body_rows[build_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = result_type,
        .generic_params = &.{},
        .body = build_body,
        .is_allocating = false,
    } };
    body_rows[equal_id] = .{ .fn_ = .{
        .params = owner_param,
        .ret = .{ .prim = .bool },
        .generic_params = &.{},
        .body = equal_body,
        .is_allocating = false,
    } };
    body_rows[caller_id] = .{ .fn_ = .{
        .params = owner_param,
        .ret = .{ .prim = .bool },
        .generic_params = &.{},
        .body = caller_body,
        .is_allocating = false,
    } };
    body_rows[check_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = check_body,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "moved_result",
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// The owning half, read off the emitted AST: the frame releases the parameter
// it was handed, and the read that spends it goes through the transfer that
// empties it, so the two never name the same allocation.
test "lower: a Result parameter spent by unwrap is emptied before its own release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerMovedResultPackage(alloc);
    var frame: ?ast.Block = null;
    for (package.files[0].decls) |decl| {
        if (decl != .fn_decl) continue;
        if (!std.mem.eql(u8, decl.fn_decl.name, "moved_result_equal")) continue;
        frame = decl.fn_decl.body;
    }
    const body = frame orelse return error.MissingMovedResultFrame;

    var released_parameter = false;
    for (body.stmts) |stmt| {
        const deferred = switch (stmt) {
            .defer_stmt => |value| value,
            else => continue,
        };
        // `errdefer` runs on the error exits only; this frame returns a plain
        // `bool`, so an `errdefer` release is a release that never happens.
        if (deferred.is_errdefer) continue;
        const call = switch (deferred.expr) {
            .call => |value| value,
            else => continue,
        };
        const named = switch (call.callee.*) {
            .ident => |name| name,
            else => continue,
        };
        if (std.mem.eql(u8, named, "r2z.alloc.dropTemporary")) released_parameter = true;
    }
    try std.testing.expect(released_parameter);

    const tail = body.expr orelse return error.MissingMovedResultTail;
    try std.testing.expect(callsWithArgument(
        tail.*,
        "r2z.alloc.takeOwned",
        "value",
    ));
}

// The runtime half: the generated test is compiled and RUN under
// `std.testing.allocator`, which aborts the moment the payload this frame was
// handed is released twice — or the moment it is never released.
test "lower: the generated moved-result test releases the payload exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try runGeneratedPackageTests(alloc, try lowerMovedResultPackage(alloc));
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

// ── A turbofished trait-method call ─────────────────────────────────────────

/// Which declaration the turbofish of a `.encode_hex::<String>()` call is
/// checked against.
///
/// Every arm writes the SAME call — the same receiver, the same one-element
/// turbofish — so the acceptance and the two refusals below differ only in
/// what the callee declares. Nothing else moves.
const TurbofishCallee = enum {
    /// `trait ToHex { fn encode_hex<Out: FromIterator<char>>(&self) -> Out; }`
    /// reached through the trait's `.method_ref`: a call-site reference with
    /// no body of its own, whose signature lives on the trait that declares
    /// it. hex/src/lib.rs:76 arrives in exactly this shape.
    trait_method,
    /// The same trait, its method declared with NO type parameter. The source
    /// then names one where the callee takes none, which rustc refuses as
    /// E0107 and so must this.
    callee_takes_none,
    /// A `.method_ref` no entity in the crate declares — the shape
    /// `resolveMethods` deliberately leaves a standard-library method in.
    /// There is no arity to check it against and none is owed.
    undeclared,
};

/// `struct Bytes;` beside
/// `trait ToHex { fn encode_hex<Out>(&self) -> Out; }` and
/// `impl ToHex for Bytes`, with `fn render(x: &Bytes)` whose only statement
/// is `x.encode_hex::<String>()`.
///
/// The receiver is a declared type rather than a literal, so the blanket-impl
/// dispatch stays out of the way and the arity the callee is checked against is
/// the one read off the `.method_ref`'s OWN owner. That is the shape whose
/// count the backend used to answer as zero whatever the trait declared, which
/// refused the call over a count `ir.validate` had already read as one.
fn lowerTraitTurbofishFixture(
    alloc: std.mem.Allocator,
    callee: TurbofishCallee,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root = try addLowerEntity(&graph, .module, "", null);
    const trait_id = try addLowerEntity(&graph, .trait_, "ToHex", root);
    const bytes_id = try addLowerEntity(&graph, .struct_, "Bytes", root);
    const impl_id = try addLowerEntity(&graph, .impl_, "ToHex for Bytes", bytes_id);
    const impl_fn_id = try addLowerEntity(&graph, .fn_, "encode_hex", impl_id);
    const caller_id = try addLowerEntity(&graph, .fn_, "render", root);
    const value_field = try addLowerEntity(&graph, .field, "x", caller_id);
    const method_ref_id = try addLowerEntity(&graph, .method_ref, "encode_hex", switch (callee) {
        .trait_method, .callee_takes_none => trait_id,
        // Owned by the callable the call is written in, which declares no
        // method of that name: nothing in this crate declares the callee.
        .undeclared => caller_id,
    });

    // `addBareCrate` parents nothing itself, so the module items are named
    // here. The impl's own `fn` is not one of them: it belongs to the impl,
    // and the impl belongs to `Bytes`.
    try addBareCrate(&graph, alloc, "trait_turbofish", root, &.{
        trait_id,
        bytes_id,
        impl_id,
        caller_id,
    });

    // 0: `Bytes`, 1: `&Bytes`, 2: the `String` the turbofish names,
    // 3: `Out`, 4: unit for the impl's own body.
    const bytes_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "Bytes", .id = bytes_id }},
    ) } };
    const bytes_ref: ir.types.Type = .{ .reference = &.{ .mut = false, .pointee = bytes_ty } };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const out_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "Out", .id = null }},
    ) } };
    const types = [_]ir.types.Type{
        bytes_ty,
        bytes_ref,
        string_ty,
        out_ty,
        .{ .prim = .unit },
    };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;

    // The trait holds the signature the `.method_ref` names; a `.method_ref`
    // body is `.none` by construction, so this list is the only place the
    // callee's arity is written down.
    body_rows[trait_id] = .{ .trait_ = .{
        .name = "ToHex",
        .methods = try alloc.dupe(ir.bodies.TraitMethodSig, &.{.{
            .name = "encode_hex",
            .ret = out_ty,
            .generic_params = if (callee == .callee_takes_none)
                &.{}
            else
                try alloc.dupe([]const u8, &.{"Out"}),
        }}),
    } };
    body_rows[bytes_id] = .{ .struct_ = .{ .layout = .unit } };
    body_rows[impl_id] = .{ .impl_ = .{
        .self_ty = bytes_ty,
        .trait_path = .{ .segments = &.{.{ .name = "ToHex", .id = trait_id }} },
        .assoc_items = &.{impl_fn_id},
    } };

    const unit_expr = try typedExpr(&model, 4, .{ .unit = {} });
    const impl_body = try typedExpr(&model, 4, .{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    body_rows[impl_fn_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "self", .ty = bytes_ref, .span = span },
        }),
        .ret = out_ty,
        .generic_params = if (callee == .callee_takes_none)
            &.{}
        else
            try alloc.dupe([]const u8, &.{"Out"}),
        .body = impl_body,
        .is_allocating = false,
    } };

    const receiver = try typedExpr(&model, 1, .{ .path = .{
        .def = value_field,
        .generic_args = &.{},
    } });
    const call = try typedExpr(&model, 2, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .value,
        .method = method_ref_id,
        .generic_args = try alloc.dupe(ir.types.Type, &.{string_ty}),
        .args = &.{},
    } });
    const caller_body = try typedExpr(&model, 2, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });
    body_rows[caller_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "x", .ty = bytes_ref, .span = span },
        }),
        .ret = string_ty,
        .body = caller_body,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "trait_turbofish",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The call `function` is written as, read back through whatever block and
/// `try` the lowering wrapped it in on the way out.
fn turbofishCall(file: ast.File, function: []const u8) !ast.Call {
    for (file.decls) |decl| {
        const fn_decl = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, fn_decl.name, function)) continue;
        const body = fn_decl.body orelse return error.ExpectedTurbofishCallee;
        return unwrapTurbofishCall((body.expr orelse return error.ExpectedTurbofishCallee).*);
    }
    return error.ExpectedTurbofishCallee;
}

fn unwrapTurbofishCall(expr: ast.Expr) !ast.Call {
    var current = expr;
    for (0..8) |_| {
        switch (current) {
            .block => |block| current = (block.expr orelse return error.ExpectedTurbofishCallee).*,
            .unary_op => |unary_op| if (unary_op.op == .try_op) {
                current = unary_op.operand.*;
            } else return error.ExpectedTurbofishCallee,
            .call => |call| return call,
            else => return error.ExpectedTurbofishCallee,
        }
    }
    return error.ExpectedTurbofishCallee;
}

// The source wrote one type argument and the callee declares one parameter,
// so the emitted call carries exactly that one — in the callee's own
// declaration order, which for a single parameter is the only order there is.
// A backend that answered the `.method_ref`'s arity as zero would refuse the
// crate here, before anything reached the emitted call at all.
test "lower: a turbofished trait-method call keeps the argument the source named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerTraitTurbofishFixture(alloc, .trait_method);
    const call = try turbofishCall(package.files[0], "render");
    try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
    if (call.generic_args[0] != .named) return error.ExpectedTurbofishArgument;
    try std.testing.expectEqualStrings("r2z.alloc.String", call.generic_args[0].named);
}

// The contract above must not become a blanket accept. `x.encode_hex::<String>()`
// over a trait whose `encode_hex` declares no type parameter names one where
// the callee takes none, and the lowering has to refuse rather than emit a
// call with an argument the declaration never named.
test "lower: a turbofish naming a parameter the trait method does not declare is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(
        error.GenericArgumentArityMismatch,
        lowerTraitTurbofishFixture(alloc, .callee_takes_none),
    );
}

// And a `.method_ref` this crate declares nothing for is the standard-library
// shape: there is no arity to check it against and none is owed, so the count
// stays zero and the same mismatch is still refused.
test "lower: a turbofish on a method this crate does not declare is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(
        error.GenericArgumentArityMismatch,
        lowerTraitTurbofishFixture(alloc, .undeclared),
    );
}

/// `[0x66, 0x6f].encode_hex::<String>()` over
/// `impl<T: AsRef<[u8]>> ToHex for T { fn encode_hex<Out>(&self) -> Out }`,
/// which is hex/src/lib.rs:516 inside the blanket impl at :137.
///
/// The receiver is an UNSUFFIXED array literal, so inference has already
/// written down `[2]i32` by the time the lowering reads it. That `i32` is the
/// fallback Rust applies before any context can pin an element type, not a
/// choice the source made: the bound's `u8` is what types the self type, the
/// literal's own length is what sizes it, and the source's turbofish is what
/// types the method's one parameter.
fn lowerBlanketTurbofishFixture(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root = try addLowerEntity(&graph, .module, "", null);
    const trait_id = try addLowerEntity(&graph, .trait_, "ToHex", root);
    const impl_id = try addLowerEntity(&graph, .impl_, "ToHex for T", root);
    const impl_fn_id = try addLowerEntity(&graph, .fn_, "encode_hex", impl_id);
    const caller_id = try addLowerEntity(&graph, .fn_, "render", root);
    const method_ref_id = try addLowerEntity(&graph, .method_ref, "encode_hex", trait_id);

    try addBareCrate(&graph, alloc, "blanket_turbofish", root, &.{
        trait_id,
        impl_id,
        caller_id,
    });

    // 0: the `[2]i32` inference leaves on an unsuffixed literal, 1: the
    // `String` the turbofish names, 2: `T`, 3: `Out`, 4: unit.
    const fallback_array = ir.types.Array{
        .elem = .{ .prim = .i32 },
        .len = .{ .literal = 2 },
    };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const self_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "T", .id = null }},
    ) } };
    const out_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "Out", .id = null }},
    ) } };
    const types = [_]ir.types.Type{
        .{ .array = &fallback_array },
        string_ty,
        self_ty,
        out_ty,
        .{ .prim = .unit },
    };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;

    body_rows[trait_id] = .{ .trait_ = .{
        .name = "ToHex",
        .methods = try alloc.dupe(ir.bodies.TraitMethodSig, &.{.{
            .name = "encode_hex",
            .ret = out_ty,
            .generic_params = try alloc.dupe([]const u8, &.{"Out"}),
        }}),
    } };

    // `T: AsRef<[u8]>` is the DECLARED bound, and the element type of the
    // concrete self type is read from it rather than from the magnitudes of
    // the values at the call site.
    const bound_slice: ir.types.Type = .{ .slice = try alloc.create(ir.types.Slice) };
    @constCast(bound_slice.slice).* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    body_rows[impl_id] = .{ .impl_ = .{
        .self_ty = self_ty,
        .trait_path = .{ .segments = &.{.{ .name = "ToHex", .id = trait_id }} },
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "T",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = &.{
                .{ .name = "core", .id = null },
                .{ .name = "convert", .id = null },
                .{ .name = "AsRef", .id = null },
            } }, .args = &.{bound_slice} }}),
        } }}), .where_clauses = &.{} },
        .assoc_items = &.{impl_fn_id},
    } };

    const unit_expr = try typedExpr(&model, 4, .{ .unit = {} });
    const impl_body = try typedExpr(&model, 4, .{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    const self_ref: ir.types.Type = .{ .reference = try alloc.create(ir.types.Ref) };
    @constCast(self_ref.reference).* = .{ .mut = false, .pointee = self_ty };
    body_rows[impl_fn_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "self", .ty = self_ref, .span = span },
        }),
        .ret = out_ty,
        .generic_params = try alloc.dupe([]const u8, &.{"Out"}),
        .body = impl_body,
        .is_allocating = false,
    } };

    const elements = try alloc.dupe(ir.exprs.NodeId, &.{
        try model.e(litInt(0x66)),
        try model.e(litInt(0x6f)),
    });
    const receiver = try typedExpr(&model, 0, .{ .array = .{
        .elements = elements,
        .repeat = null,
    } });
    const call = try typedExpr(&model, 1, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .value,
        .method = method_ref_id,
        .generic_args = try alloc.dupe(ir.types.Type, &.{string_ty}),
        .args = &.{},
    } });
    const caller_body = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });
    body_rows[caller_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = string_ty,
        .body = caller_body,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "blanket_turbofish",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// A blanket impl's method is hoisted as a free function carrying the impl's
// own `T` and then the method's own parameters, and the receiver the call
// passes is the SELF type — `[2]u8`, the bound's element with the literal's
// own length. Both halves of that are load-bearing: a self type read off the
// `i32` fallback would make the binding the call reads the receiver back
// through a `[2]i32` the callee's `*const T` never accepts.
test "lower: a blanket turbofished call types its receiver from the declared bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerBlanketTurbofishFixture(alloc);
    const call = try turbofishCall(package.files[0], "render");
    // The impl's inherited `T` leads, the method's own parameter follows, and
    // the source named `String` for the second.
    try std.testing.expectEqual(@as(usize, 2), call.generic_args.len);
    if (call.generic_args[0] != .array) return error.ExpectedBlanketSelfType;
    try std.testing.expectEqual(@as(u64, 2), call.generic_args[0].array.len);
    if (call.generic_args[0].array.elem.* != .prim) return error.ExpectedBlanketSelfType;
    try std.testing.expectEqual(ast.Prim.u8, call.generic_args[0].array.elem.*.prim);
    if (call.generic_args[1] != .named) return error.ExpectedTurbofishArgument;
    try std.testing.expectEqualStrings("r2z.alloc.String", call.generic_args[1].named);
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
    // The parameter record and its bounds are arena-owned: the lowering reads
    // both out of the body row long after this literal's own storage is gone.
    const generics = ir.types.Generics{
        .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "T",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = &.{
                .{ .name = "core", .id = null },
                .{ .name = "convert", .id = null },
                .{ .name = "AsRef", .id = null },
            } }, .args = &.{bound_slice} }}),
        } }}),
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

// This deliberately hostile raw IR has overlapping blanket impls and an
// unbounded caller parameter: it is not a program Rust would accept. The
// backend must diagnose the ambiguity, never choose one source declaration.
test "lower: overlapping blanket impl raw IR reports ambiguity without dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try lowerBlanketWrapperFixture(alloc, .trait_method_ref, 2);

    const wrapper = try findFnDecl(pkg.files[0], "encode");
    const body = wrapper.body orelse return error.MissingWrapperBody;
    // A sole compile-error expression proves there is no chosen impl call in
    // a prelude, branch, callee, or argument. A generic missing-impl refusal
    // is not an ambiguity diagnostic.
    try std.testing.expectEqual(@as(usize, 0), body.stmts.len);
    const refusal = body.expr orelse return error.MissingAmbiguityDiagnostic;
    if (refusal.* != .builtin) return error.ExpectedAmbiguityDiagnostic;
    try std.testing.expectEqualStrings("compileError", refusal.builtin.name);
    try std.testing.expectEqual(@as(usize, 1), refusal.builtin.args.len);
    const diagnostic = refusal.builtin.args[0];
    if (diagnostic != .lit or diagnostic.lit != .str) return error.ExpectedAmbiguityMessage;
    try std.testing.expectEqualStrings(
        "ambiguous source trait method implementation for instantiated receiver",
        diagnostic.lit.str,
    );
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
        .items = try alloc.dupe(ir.spine.EntityId, &.{struct_id}),
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
/// package the lowering built. The parameter is an owned `String` unless the
/// use asks for `&mut`. `shadowed` adds a body binding spelled `_s`, which the
/// copy's signature name has to step past.
///
/// The tree is allocated from `alloc`, which the caller owns and keeps: the
/// owner contract below is a relation between DECLARATIONS and the expressions
/// that name them, and a match on emitted text cannot say which declaration a
/// name belongs to.
fn lowerStringParamUseFixture(
    alloc: std.mem.Allocator,
    use: StringParamUse,
    shadowed: bool,
) !ast.Package {
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// Lower the fixture above and return the emitted source.
fn emitStringParamUseFixture(
    backing: std.mem.Allocator,
    use: StringParamUse,
    shadowed: bool,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const package = try lowerStringParamUseFixture(arena.allocator(), use, shadowed);
    // The arena dies with this frame, so the caller must own the text.
    return backing.dupe(u8, try emit.emitFile(arena.allocator(), &package.files[0]));
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

/// The one parameter a source parameter arrives in, read off an emitted
/// signature without assuming what the lowering spelled it. A comptime type
/// parameter is an artefact of the generic lowering rather than a source
/// parameter, and a second value parameter would make "the parameter"
/// ambiguous — both are refused here instead of guessed at.
fn soleValueParameter(decl: ast.FnDecl) !ast.FnParam {
    var found: ?ast.FnParam = null;
    for (decl.params) |param| {
        if (param.is_comptime) continue;
        if (found != null) return error.AmbiguousValueParameter;
        found = param;
    }
    return found orelse error.MissingValueParameter;
}

/// The identifier an expression reads its receiver through. A method call
/// spells the receiver in the callee's field access and a bare field read is
/// that field access itself, so both name the same place; every other shape
/// reads no receiver and answers null.
fn receiverIdent(expression: ast.Expr) ?[]const u8 {
    const target: *const ast.Expr = switch (expression) {
        .field_access => |access| access.target,
        .call => |call_expr| switch (call_expr.callee.*) {
            .field_access => |access| access.target,
            else => return null,
        },
        else => return null,
    };
    if (target.* != .ident) return null;
    return target.ident;
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

    // The same rule read off the tree, so it cannot pass by spelling: the
    // parameter keeps its own name, is a POINTER to the runtime string, and
    // the frame declares nothing and releases nothing. A borrow owns no
    // allocation, so a `defer` here would free what the caller still holds.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const package = try lowerStringParamUseFixture(alloc, .reference_clear, false);
    const decl = try findFnDecl(package.files[0], "use_string");
    const parameter = try soleValueParameter(decl);
    try std.testing.expect(parameter.ty == .ptr);
    const body = decl.body orelse return error.EmptyTranslatedBody;
    var body_expr: ?*const ast.Expr = null;
    for (body.stmts) |statement| {
        if (statement == .defer_stmt) return error.BorrowedParameterIsReleased;
        if (statement == .let_stmt) return error.BorrowedParameterIsCopied;
        if (statement == .expr_stmt) body_expr = statement.expr_stmt;
    }
    // The method reaches the borrow through the parameter itself, so the
    // plain signature is load-bearing rather than decorative.
    const receiver = receiverIdent((body_expr orelse return error.EmptyTranslatedBody).*) orelse
        return error.BodyReadHasNoReceiver;
    try std.testing.expectEqualStrings(parameter.name, receiver);
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

/// Lower a shared `len()` read from a const-reference sequence parameter.
fn borrowedSequenceLenFixture(alloc: std.mem.Allocator, sequence_ty: ir.types.Type) !ast.FnDecl {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const run = try addLowerEntity(&graph, .fn_, "run", root);
    const value = try addLowerEntity(&graph, .field, "value", run);
    const len = try addLowerEntity(&graph, .method_ref, "len", null);
    try addBareCrate(&graph, alloc, "borrowed_sequence_len", root, &.{run});

    const borrowed_ty: ir.types.Type = .{ .reference = &.{ .mut = false, .pointee = sequence_ty } };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const types = [_]ir.types.Type{ borrowed_ty, usize_ty };
    const receiver = try typedExpr(&model, 0, .{ .path = .{ .def = value, .generic_args = &.{} } });
    const call = try typedExpr(&model, 1, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .shared,
        .method = len,
        .args = &.{},
    } });
    const block = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[run] = .{ .fn_ = .{
        .params = &.{.{ .name = "value", .ty = borrowed_ty, .span = span }},
        .ret = usize_ty,
        .generic_params = &.{},
        .body = block,
        .is_allocating = false,
    } };
    const rust_ir = ir.RustIr{
        .crate_name = "borrowed_sequence_len",
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
    return findFnDecl(package.files[0], "run");
}

test "lower: borrowed Vec len reads the original parameter items without allocation or copying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const decl = try borrowedSequenceLenFixture(arena.allocator(), .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{u8_ty},
    } });
    // The only parameter is the source borrow: no allocator is introduced.
    try std.testing.expectEqual(@as(usize, 1), decl.params.len);
    try std.testing.expectEqualStrings("value", decl.params[0].name);
    const body = decl.body orelse return error.ExpectedFunctionBody;
    try std.testing.expectEqual(@as(usize, 0), body.stmts.len);
    const result = body.expr orelse return error.ExpectedBodyExpression;
    const length = switch (result.*) {
        .field_access => |field| field,
        else => return error.ExpectedLengthField,
    };
    try std.testing.expectEqualStrings("len", length.field_name);
    const items = switch (length.target.*) {
        .field_access => |field| field,
        else => return error.ExpectedVecItemsField,
    };
    try std.testing.expectEqualStrings("items", items.field_name);
    // A direct source identifier rules out a runtime call or temporary copy.
    try std.testing.expectEqualStrings(decl.params[0].name, try expectIdent(items.target.*));
}

test "lower: borrowed slice len reads the original parameter directly without allocation or copying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decl = try borrowedSequenceLenFixture(arena.allocator(), .{ .slice = &.{
        .const_ = true,
        .elem = .{ .prim = .u8 },
    } });
    try std.testing.expectEqual(@as(usize, 1), decl.params.len);
    try std.testing.expectEqualStrings("value", decl.params[0].name);
    const body = decl.body orelse return error.ExpectedFunctionBody;
    try std.testing.expectEqual(@as(usize, 0), body.stmts.len);
    const result = body.expr orelse return error.ExpectedBodyExpression;
    const length = switch (result.*) {
        .field_access => |field| field,
        else => return error.ExpectedLengthField,
    };
    try std.testing.expectEqualStrings("len", length.field_name);
    // Unlike Vec, a slice has its length on the source itself, not `.items`.
    try std.testing.expectEqualStrings(decl.params[0].name, try expectIdent(length.target.*));
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

// ── A `BufRead` receiver is reached by the handle it actually has ───────────
// Both halves of the runtime's pair write through a pointer: the slice arm
// does `reader.* = reader.*[count..]` and the object arm calls a `*Self`
// method. So the emitted argument is a pointer — but WHICH spelling depends on
// the representation the receiver actually has, and `&` alone does not say it:
// `lowerType` spells `&[u8]` as the `[]const u8` descriptor itself, and a bare
// type parameter says nothing at all.

/// What shape of `BufRead` receiver the fixture hands the runtime.
const BufReadReceiver = enum {
    /// `fn drain<R: BufRead>(mut reader: R)` — one emitted body must serve
    /// thin pointer handles, owned readers, and slice descriptor values.
    generic_parameter,
    /// `fn drain<R: BufRead>(reader: &mut R)` — the declared bound identifies
    /// the method while the thin reference is already its mutable handle.
    explicit_pointer,
    /// A resolved `impl BufRead` whose concrete representation is `&[u8]`.
    /// The descriptor itself belongs to this frame and needs mutable storage.
    slice_descriptor,
};

/// Lower `fn drain(..)` calling `fill_buf` followed by `consume(1)`, with the
/// receiver's representation and declared bound named by `kind`.
fn emitBufReadReceiverFixture(
    backing: std.mem.Allocator,
    kind: BufReadReceiver,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();

    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root_id = try addLowerEntity(&graph, .module, "", null);
    const callable_id = try addLowerEntity(&graph, .fn_, "drain", root_id);
    const param_def = try addLowerEntity(&graph, .field, "reader", callable_id);
    const consume = try addLowerEntity(&graph, .method_ref, "consume", callable_id);
    const fill_buf = try addLowerEntity(&graph, .method_ref, "fill_buf", callable_id);

    const byte_slice: ir.types.Type = .{ .slice = &.{
        .const_ = true,
        .elem = .{ .prim = .u8 },
    } };
    // 0: R, 1: byte slice, 2: &mut R, 3: bound-carrying slice descriptor,
    // 4: usize, 5: unit.
    const generic_param: ir.types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "R", .id = null },
    } } };
    const slice_reference: ir.types.Ref = .{ .mut = false, .pointee = byte_slice };
    const reader_reference: ir.types.Ref = .{ .mut = true, .pointee = generic_param };
    const buf_read_bound: ir.types.Bound = .{
        .path = .{ .segments = &.{
            .{ .name = "std", .id = null },
            .{ .name = "io", .id = null },
            .{ .name = "BufRead", .id = null },
        } },
        .args = &.{},
    };
    const types = [_]ir.types.Type{
        generic_param,
        byte_slice,
        .{ .reference = &reader_reference },
        // `ir.types.Opaque` is a VALUE, not a pointer: `bounds` and `concrete`
        // are the ones that are spelled through a reference.
        .{ .@"opaque" = .{
            .bounds = &.{buf_read_bound},
            .concrete = &.{ .reference = &slice_reference },
        } },
        .{ .prim = .usize },
        .{ .prim = .unit },
    };

    const param_type: ir.types.Type = switch (kind) {
        .generic_parameter => generic_param,
        .explicit_pointer => types[2],
        .slice_descriptor => types[3],
    };
    const receiver_type_id: ir.exprs.TypeId = switch (kind) {
        .generic_parameter => 0,
        .explicit_pointer => 2,
        .slice_descriptor => 3,
    };
    const generic_params = [_][]const u8{"R"};
    const generics: ir.types.Generics = .{
        .params = &.{.{ .type_ = .{
            .name = "R",
            .bounds = &.{buf_read_bound},
        } }},
        .where_clauses = &.{},
    };

    const param_path = try model.e(.{ .path = .{ .def = param_def, .generic_args = &.{} } });
    model.exprs.items[param_path].ty = receiver_type_id;
    const one = try model.e(litInt(1));
    model.exprs.items[one].ty = 4;
    const call = try model.e(.{ .method_call = .{
        .receiver = param_path,
        .receiver_mode = .mutable,
        .method = consume,
        .args = &.{one},
    } });
    model.exprs.items[call].ty = 5;
    const call_stmt = try model.stmt(.{ .expr = call });
    const fill_call = try model.e(.{ .method_call = .{
        .receiver = param_path,
        .receiver_mode = .mutable,
        .method = fill_buf,
        .args = &.{},
    } });
    const fill_stmt = try model.stmt(.{ .expr = fill_call });
    const body = try model.e(.{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{ fill_stmt, call_stmt }),
        .tail = null,
        .labelled = null,
    } });
    model.exprs.items[body].ty = 5;

    const callable_params = try alloc.alloc(ir.items.Param, 1);
    callable_params[0] = .{ .name = "reader", .ty = param_type, .span = span };
    const body_table = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_table) |*slot| slot.* = .none;
    body_table[callable_id] = .{ .fn_ = .{
        .params = callable_params,
        .ret = .{ .prim = .unit },
        .body = body,
        .generic_params = &generic_params,
        .generics = generics,
        .is_allocating = false,
    } };
    try addBareCrate(&graph, alloc, "bufread_receiver", root_id, &.{callable_id});

    const rust_ir = ir.RustIr{
        .crate_name = "bufread_receiver",
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
    return backing.dupe(u8, try emitRootSource(alloc, &rust_ir));
}

// Generic readers select their representation at comptime. Thin pointers pass
// the signature argument itself; owned values and slices get mutable local
// storage. The pointer instantiation's local is void, not a copied handle.
test "lower: a generic BufRead receiver selects pointer or mutable value storage at comptime" {
    const source = try emitBufReadReceiverFixture(std.testing.allocator, .generic_parameter);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_reader: R") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@typeInfo(@TypeOf(_reader))") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".pointer =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".slice => false") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@as(void, {})") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "else _reader") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "else &reader") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.io.fill_buf(if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "_reader: *R") == null);
}

// A thin pointer to a sized reader is itself the handle, and its address would
// be a pointer to a pointer.
test "lower: a BufRead receiver that is already a pointer is passed through untouched" {
    const source = try emitBufReadReceiverFixture(std.testing.allocator, .explicit_pointer);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.io.consume(reader, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "&reader") == null);
}

// `&[u8]` is a descriptor VALUE in Zig, not a pointer: `lowerType` spells the
// fat borrow as the `[]const u8` itself, so the runtime writes THROUGH it
// (`reader.* = reader.*[count..]`). This frame therefore owns the descriptor
// it advances and needs mutable storage for it — reading the IR's
// `.reference` alone would have called it a pointer and emitted a call the
// runtime cannot serve.
test "lower: a fat-borrow BufRead receiver is a descriptor, so it is reached by address" {
    const source = try emitBufReadReceiverFixture(std.testing.allocator, .slice_descriptor);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "_reader: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var reader: []const u8 = _reader;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.io.consume(&reader, 1)") != null);
}

fn emitPrimitiveBuiltinFixture(backing: std.mem.Allocator, function: ir.exprs.CoreFunction) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "primitive", root);
    const parameter = try addLowerEntity(&graph, .field, "value", callable);
    const integer: ir.types.Type = .{ .prim = .u64 };
    const bytes: ir.types.Type = .{ .array = &.{
        .elem = .{ .prim = .u8 },
        .len = .{ .literal = 8 },
    } };
    const types = [_]ir.types.Type{ integer, bytes };
    const decoding = function == .prim_from_le_bytes;
    const uninit = function == .maybe_uninit_uninit;
    const value = try model.e(.{ .path = .{ .def = parameter, .generic_args = &.{} } });
    model.exprs.items[value].ty = if (decoding) 1 else 0;
    const body = try model.e(.{ .core_call = .{
        .function = function,
        .generic_args = &.{integer},
        .args = if (uninit) &.{} else &.{value},
    } });
    model.exprs.items[body].ty = if (decoding or uninit) 0 else 1;
    const rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (rows) |*row| row.* = .none;
    rows[callable] = .{ .fn_ = .{
        .params = if (uninit) &.{} else &.{.{
            .name = "value",
            .ty = if (decoding) bytes else integer,
            .span = span,
        }},
        .ret = if (decoding or uninit) integer else bytes,
        .body = body,
    } };
    try addBareCrate(&graph, alloc, "primitive_builtin", root, &.{callable});
    const rust_ir = ir.RustIr{
        .crate_name = "primitive_builtin",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = rows,
        },
    };
    return backing.dupe(u8, try emitRootSource(alloc, &rust_ir));
}

test "lower: integer LE byte conversions select explicit endian on every target" {
    inline for (.{ ir.exprs.CoreFunction.prim_from_le_bytes, ir.exprs.CoreFunction.prim_to_le_bytes }) |function| {
        const source = try emitPrimitiveBuiltinFixture(std.testing.allocator, function);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "std.builtin.Endian.little") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, if (function == .prim_from_le_bytes) "std.mem.readInt" else "std.mem.writeInt") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "transmute") == null);
    }
}

test "lower: MaybeUninit uninit remains typed uninitialized storage" {
    const source = try emitPrimitiveBuiltinFixture(std.testing.allocator, .maybe_uninit_uninit);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "@as(u64, undefined)") != null);
}

fn emitTraitBuiltinFixture(backing: std.mem.Allocator, function: ir.exprs.CoreFunction) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const alloc = arena.allocator();
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "trait_builtin", root);
    const receiver_def = try addLowerEntity(&graph, .field, "receiver", callable);
    const value_def = try addLowerEntity(&graph, .field, "value", callable);
    const receiver_type: ir.types.Type = .{ .reference = &.{
        .mut = true,
        .pointee = .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    } };
    const value_type: ir.types.Type = if (function == .hash_write_primitive)
        .{ .prim = .u64 }
    else
        .{ .reference = &.{
            .mut = true,
            .pointee = .{ .slice = &.{ .const_ = false, .elem = .{ .prim = .u8 } } },
        } };
    const unit: ir.types.Type = .{ .prim = .unit };
    const types = [_]ir.types.Type{ receiver_type, value_type, unit };
    const receiver = try model.e(.{ .path = .{ .def = receiver_def, .generic_args = &.{} } });
    model.exprs.items[receiver].ty = 0;
    const value = try model.e(.{ .path = .{ .def = value_def, .generic_args = &.{} } });
    model.exprs.items[value].ty = 1;
    const body = try model.e(.{ .core_call = .{
        .function = function,
        .generic_args = if (function == .hash_write_primitive) &.{.{ .prim = .u64 }} else &.{},
        .args = &.{ receiver, value },
    } });
    model.exprs.items[body].ty = 2;
    const rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (rows) |*row| row.* = .none;
    rows[callable] = .{ .fn_ = .{
        .params = &.{
            .{ .name = "receiver", .ty = receiver_type, .span = span },
            .{ .name = "value", .ty = value_type, .span = span },
        },
        .ret = unit,
        .generic_params = &.{"T"},
        .body = body,
    } };
    try addBareCrate(&graph, alloc, "trait_builtin", root, &.{callable});
    const rust_ir = ir.RustIr{
        .crate_name = "trait_builtin",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = try model.pats.toOwnedSlice(alloc),
            .types = &types,
            .bodies = rows,
        },
    };
    return backing.dupe(u8, try emitRootSource(alloc, &rust_ir));
}

test "lower: Hasher default primitive write uses native bytes without an allocator" {
    const source = try emitTraitBuiltinFixture(std.testing.allocator, .hash_write_primitive);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "receiver.write(std.mem.asBytes(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ": u64 = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Endian.little") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "allocator:") == null);
}

test "lower: RngCore fill default calls the runtime implementation without allocation" {
    const source = try emitTraitBuiltinFixture(std.testing.allocator, .rng_fill_bytes_via_next);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.random.fill_bytes_via_next(receiver, value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "allocator:") == null);
}

// ── Shared assertions for canonical trait defaults ─────────────────────────

/// The NAME an emitted call reaches: `Counter.zero()` answers `zero`, a hoisted
/// module-scope function answers its own declaration name, and a generic
/// parameter answers the parameter.
///
/// Every assertion below is about WHICH declaration answers a source default,
/// so it reads the target's identity rather than a full spelling that is free
/// to change without changing the program.
fn calleeName(target: ast.Expr) ?[]const u8 {
    return switch (target) {
        .ident => |name| name,
        .field_access => |access| access.field_name,
        else => null,
    };
}

/// The `.named` type an expression carries in `type_value` position: the
/// lexical parameter, or the concrete type a comptime branch selects.
fn typeValueName(expr: ast.Expr) ?[]const u8 {
    if (expr != .type_value) return null;
    return switch (expr.type_value) {
        .named => |name| name,
        else => null,
    };
}

/// Whether `expr` is the comptime type comparison that keeps a source
/// implementation reachable only for the instantiation it is written for.
fn isTypeSelection(expr: ast.Expr, param: []const u8, self_type: []const u8) bool {
    if (expr != .bin_op) return false;
    const comparison = expr.bin_op;
    if (comparison.op != .equal) return false;
    const lhs = typeValueName(comparison.lhs.*) orelse return false;
    const rhs = typeValueName(comparison.rhs.*) orelse return false;
    return std.mem.eql(u8, lhs, param) and std.mem.eql(u8, rhs, self_type);
}

/// Whether `expr` is an `if` whose condition selects a source implementation for
/// exactly one instantiation of a still-generic receiver.
fn typeSelectionBranches(expr: ast.Expr, param: []const u8, self_type: []const u8) ?struct { ast.Expr, ast.Expr } {
    if (expr != .if_expr) return null;
    const selection = expr.if_expr;
    if (!isTypeSelection(selection.cond.*, param, self_type)) return null;
    const otherwise = selection.else_body orelse return null;
    return .{ selection.then_body.*, otherwise.* };
}

/// The integer arm of the `@typeInfo` guard a GENERIC numeric default is
/// wrapped in, or the expression itself when the receiver was already known to
/// be an integer and no guard was needed.
///
/// The guard exists because a type parameter may instantiate to a custom
/// source type, where a built-in integer default means nothing. Both shapes
/// answer the same question, so an assertion about the fallback reads whichever
/// one was emitted and checks the guard separately where the guard is the
/// contract.
fn integerFallbackOf(expr: ast.Expr) ast.Expr {
    if (expr != .match_expr) return expr;
    const guarded = expr.match_expr;
    if (guarded.target.* != .builtin) return expr;
    if (!std.mem.eql(u8, guarded.target.builtin.name, "typeInfo")) return expr;
    if (guarded.arms.len != 2) return expr;
    return guarded.arms[0].body;
}

/// The custom-type arm of that guard: a `@compileError` carrying one message.
/// A source type with no `Zero`/`One`/`Bounded` implementation has to fail to
/// instantiate, not silently answer with an integer default.
fn expectCustomTypeRefusal(expr: ast.Expr) !void {
    if (expr != .match_expr) return error.ExpectedCustomNumericTypeGuard;
    const guarded = expr.match_expr;
    if (guarded.target.* != .builtin) return error.ExpectedCustomNumericTypeGuard;
    if (!std.mem.eql(u8, guarded.target.builtin.name, "typeInfo")) return error.ExpectedCustomNumericTypeGuard;
    if (guarded.arms.len != 2) return error.ExpectedCustomNumericTypeGuard;
    if (guarded.arms[0].patterns.len != 1 or guarded.arms[1].patterns.len != 1)
        return error.ExpectedCustomNumericTypeGuard;
    switch (guarded.arms[0].patterns[0]) {
        .enum_literal => |name| if (!std.mem.eql(u8, name, "int"))
            return error.ExpectedCustomNumericTypeGuard,
        else => return error.ExpectedCustomNumericTypeGuard,
    }
    switch (guarded.arms[1].patterns[0]) {
        .wildcard => {},
        else => return error.ExpectedCustomNumericTypeGuard,
    }
    const refusal = guarded.arms[1].body;
    if (refusal != .builtin) return error.ExpectedCustomNumericTypeGuard;
    if (!std.mem.eql(u8, refusal.builtin.name, "compileError")) return error.ExpectedCustomNumericTypeGuard;
    if (refusal.builtin.args.len != 1) return error.ExpectedCustomNumericTypeGuard;
    if (refusal.builtin.args[0] != .lit or refusal.builtin.args[0].lit != .str)
        return error.ExpectedCustomNumericTypeGuard;
    if (refusal.builtin.args[0].lit.str.len == 0) return error.ExpectedCustomNumericTypeGuard;
}

/// The single expression a lowered callable body evaluates to.
fn fnBodyExpr(decl: ast.FnDecl) !ast.Expr {
    const body = decl.body orelse return error.EmptyTranslatedBody;
    return (body.expr orelse return error.EmptyTranslatedBody).*;
}

/// The statements of a lowered callable body, for the defaults that bind a
/// temporary rather than evaluate to one expression.
fn fnBodyStmts(decl: ast.FnDecl) ![]const ast.Stmt {
    const body = decl.body orelse return error.EmptyTranslatedBody;
    if (body.expr != null) return error.ExpectedStatementBody;
    if (body.stmts.len == 0) return error.EmptyTranslatedBody;
    return body.stmts;
}

/// The built-in answer for a `num_traits` default: `std.math.minInt`/`maxInt`
/// for the bounded pair, a typed zero or one for the identity pair.
fn expectNumericFallback(expr: ast.Expr, case: NumericTagCase, type_name: []const u8) !void {
    const fallback = integerFallbackOf(expr);
    const target = if (case.zig_call) |zig_call| blk: {
        if (fallback != .call) return error.ExpectedNumericFallback;
        if (fallback.call.args.len != 0) return error.ExpectedNumericFallback;
        if (fallback.call.generic_args.len != 1) return error.ExpectedNumericFallback;
        try std.testing.expectEqualStrings(zig_call, calleeName(fallback.call.callee.*) orelse
            return error.ExpectedNumericFallback);
        break :blk fallback.call.generic_args[0];
    } else blk: {
        if (fallback != .cast) return error.ExpectedNumericFallback;
        if (fallback.cast.operand.* != .lit or fallback.cast.operand.lit != .int)
            return error.ExpectedNumericFallback;
        try std.testing.expectEqual(case.literal, fallback.cast.operand.lit.int);
        break :blk fallback.cast.target;
    };
    // The fallback is asked about ONE type: a concrete integer at a call site,
    // the lexical parameter inside a generic one. A fallback that had resolved
    // the type to something else would answer a question nobody asked.
    switch (target) {
        .named => |name| try std.testing.expectEqualStrings(type_name, name),
        .prim => |primitive| try std.testing.expectEqualStrings(type_name, @tagName(primitive)),
        else => return error.ExpectedNumericFallback,
    }
}

/// The four canonical `num_traits` defaults and the source identity each one
/// resolves through. `zig_call` is null exactly when the built-in answer is a
/// typed literal rather than a Zig intrinsic.
const NumericTagCase = struct {
    function: ir.exprs.CoreFunction,
    /// The source method a `num_traits` implementation declares for it.
    method: []const u8,
    /// The trait identity such an implementation has to prove.
    trait_name: []const u8,
    /// The module `num_traits` keeps that trait under.
    module_name: []const u8,
    zig_call: ?[]const u8,
    literal: i128,
};

const numeric_tag_cases = [_]NumericTagCase{
    .{
        .function = .numeric_min_value,
        .method = "min_value",
        .trait_name = "Bounded",
        .module_name = "bounds",
        .zig_call = "std.math.minInt",
        .literal = 0,
    },
    .{
        .function = .numeric_max_value,
        .method = "max_value",
        .trait_name = "Bounded",
        .module_name = "bounds",
        .zig_call = "std.math.maxInt",
        .literal = 0,
    },
    .{
        .function = .numeric_zero,
        .method = "zero",
        .trait_name = "Zero",
        .module_name = "identities",
        .zig_call = null,
        .literal = 0,
    },
    .{
        .function = .numeric_one,
        .method = "one",
        .trait_name = "One",
        .module_name = "identities",
        .zig_call = null,
        .literal = 1,
    },
};

/// The receiver a canonical numeric default is asked about, and the source
/// graph that stands beside it.
const NumericTagScene = enum {
    /// `fn limit() -> u8`: the answer is already known to be an integer.
    concrete_integer,
    /// `fn limit<I>() -> I`, whose instantiation the file still has to make.
    lexical_parameter,
    /// The lexical parameter plus `impl num_traits::<Trait> for Counter`.
    source_impl_canonical,
    /// The same implementation reached through `num_traits::<module>::<Trait>`.
    source_impl_module_path,
    /// The same implementation, reached through a crate-local trait that merely
    /// shares the name. Two different traits; only the canonical one answers.
    local_trait_homonym,
    /// `fn counter_min() -> Counter`: the receiver IS the implemented type, so
    /// there is nothing left to select at comptime.
    concrete_source_type,
    /// A type that is neither an integer nor implemented at all.
    non_numeric_argument,
    /// A value argument the tag never takes, which the arity check refuses.
    unexpected_value_argument,
    /// No type argument at all.
    missing_type_argument,
};

/// The trait path an `impl` in `scene` writes to prove it implements the
/// canonical trait. Identity is resolved from the path, so a crate-local trait
/// of the same name answers with its OWN id and is a different trait.
fn sourceTraitSegments(
    alloc: std.mem.Allocator,
    case: NumericTagCase,
    scene: NumericTagScene,
    local_trait: ?ir.spine.EntityId,
) ![]const ir.types.PathSegment {
    const segments: []const ir.types.PathSegment = switch (scene) {
        .local_trait_homonym => &.{.{ .name = case.trait_name, .id = local_trait }},
        .source_impl_module_path => &.{
            .{ .name = "num_traits", .id = null },
            .{ .name = case.module_name, .id = null },
            .{ .name = case.trait_name, .id = null },
        },
        else => &.{
            .{ .name = "num_traits", .id = null },
            .{ .name = case.trait_name, .id = null },
        },
    };
    return alloc.dupe(ir.types.PathSegment, segments);
}

/// `fn limit(..) -> T` whose only statement asks the canonical numeric-trait
/// default for `T`, with the receiver and the surrounding source graph named by
/// `scene`.
///
/// The lexical scenes also carry `limit_u8`, `limit_i32` and `limit_usize`,
/// which instantiate the generic at an unsigned, a signed and a
/// target-dependent width. The comptime branch is only a real consumer of the
/// emitted default once something instantiates it.
fn numericTagFixture(
    alloc: std.mem.Allocator,
    case: NumericTagCase,
    scene: NumericTagScene,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const limit = try addLowerEntity(&graph, .fn_, "limit", root);

    const generic = scene == .lexical_parameter or scene == .source_impl_canonical or
        scene == .source_impl_module_path or scene == .local_trait_homonym;
    const concrete_impl = scene == .source_impl_canonical or
        scene == .source_impl_module_path or scene == .local_trait_homonym or
        scene == .concrete_source_type;
    const instantiation_widths = [_]ir.types.Prim{ .u8, .i32, .usize };

    // ── Entities ─────────────────────────────────────────────────────────
    // Every entity is declared before the body table is sized: the table is
    // indexed by entity id, so a row added after the fact has nowhere to land.
    const items = try alloc.alloc(ir.spine.EntityId, 8);
    items[0] = limit;
    var item_count: usize = 1;
    var counter: ir.spine.EntityId = 0;
    var impl_id: ir.spine.EntityId = 0;
    var impl_method: ir.spine.EntityId = 0;
    var local_trait: ir.spine.EntityId = 0;
    if (concrete_impl) {
        counter = try addLowerEntity(&graph, .struct_, "Counter", root);
        const impl_name = try std.fmt.allocPrint(alloc, "{s} for Counter", .{case.trait_name});
        impl_id = try addLowerEntity(&graph, .impl_, impl_name, counter);
        impl_method = try addLowerEntity(&graph, .fn_, case.method, impl_id);
        items[item_count] = counter;
        item_count += 1;
        items[item_count] = impl_id;
        item_count += 1;
        if (scene == .local_trait_homonym) {
            local_trait = try addLowerEntity(&graph, .trait_, case.trait_name, root);
            items[item_count] = local_trait;
            item_count += 1;
        }
    }
    var callers: [instantiation_widths.len]ir.spine.EntityId = undefined;
    if (generic) {
        for (instantiation_widths, 0..) |prim, index| {
            callers[index] = try addLowerEntity(&graph, .fn_, try std.fmt.allocPrint(
                alloc,
                "limit_{s}",
                .{@tagName(prim)},
            ), root);
            items[item_count] = callers[index];
            item_count += 1;
        }
    }

    // ── Types ────────────────────────────────────────────────────────────
    // 0: the type the tag is asked about, 1: unit, 2: the local
    // implementation's self type, 3..: one instantiation record per width.
    var types = [_]ir.types.Type{
        switch (scene) {
            .concrete_integer => .{ .prim = .u8 },
            .non_numeric_argument => .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
            .concrete_source_type => .{ .path = .{ .segments = &.{} } },
            else => .{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                &.{.{ .name = "I", .id = null }},
            ) } },
        },
        .{ .prim = .unit },
        .{ .path = .{ .segments = &.{} } },
        .{ .prim = .u8 },
        .{ .prim = .u8 },
        .{ .prim = .u8 },
    };
    if (concrete_impl) {
        types[2] = .{ .path = .{ .segments = try alloc.dupe(
            ir.types.PathSegment,
            &.{.{ .name = "Counter", .id = counter }},
        ) } };
        if (scene == .concrete_source_type) types[0] = types[2];
    }
    const source_type = types[0];

    // ── Expressions ──────────────────────────────────────────────────────
    const tag_generic_args: []const ir.types.Type = if (scene == .missing_type_argument)
        &.{}
    else
        try alloc.dupe(ir.types.Type, &.{source_type});
    const literal = try typedExpr(&model, 1, litInt(0));
    const tag_args: []const ir.exprs.NodeId = if (scene == .unexpected_value_argument)
        &.{literal}
    else
        &.{};
    const tag = try typedExpr(&model, 0, .{ .core_call = .{
        .function = case.function,
        .generic_args = tag_generic_args,
        .args = tag_args,
    } });
    const limit_body = try typedExpr(&model, 0, .{ .block = .{
        .statements = &.{},
        .tail = tag,
        .labelled = null,
    } });

    // The record on the instantiation call is what tells the backend which
    // instantiation the source asked for, exactly as `limit::<u8>()` does.
    var caller_bodies: [instantiation_widths.len]ir.exprs.NodeId = undefined;
    for (instantiation_widths, 0..) |prim, index| {
        types[index + 3] = .{ .generic_inst = .{
            .decl = limit,
            .args = .{ .params = try alloc.dupe(ir.types.Type, &.{.{ .prim = prim }}) },
        } };
        const call = try typedExpr(&model, @intCast(index + 3), .{ .call = .{
            .call_kind = .{ .free = limit },
            .args = &.{},
        } });
        caller_bodies[index] = try typedExpr(&model, null, .{ .block = .{
            .statements = &.{},
            .tail = call,
            .labelled = null,
        } });
    }

    var impl_method_body: ir.exprs.NodeId = 0;
    if (concrete_impl) {
        const value = try typedExpr(&model, 2, .{ .struct_lit = .{ .def = counter, .fields = &.{}, .base = null } });
        impl_method_body = try typedExpr(&model, 2, .{ .block = .{
            .statements = &.{},
            .tail = value,
            .labelled = null,
        } });
    }

    // ── Bodies ───────────────────────────────────────────────────────────
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[limit] = .{ .fn_ = .{
        .params = &.{},
        .ret = source_type,
        .generic_params = if (generic) &.{"I"} else &.{},
        .generics = if (generic) .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "I",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{
                .segments = try sourceTraitSegments(alloc, case, if (scene == .source_impl_module_path)
                    .source_impl_module_path
                else
                    .source_impl_canonical, null),
            } }}),
        } }}), .where_clauses = &.{} } else null,
        .body = limit_body,
    } };
    if (concrete_impl) {
        body_rows[counter] = .{ .struct_ = .{
            .methods = try alloc.dupe(ir.bodies.StructMethod, &.{.{
                .name = case.method,
                .visibility = .public,
                .params = &.{},
                .ret = types[2],
                .body = impl_method_body,
                .receiver = null,
            }}),
        } };
        body_rows[impl_method] = .{ .fn_ = .{
            .params = &.{},
            .ret = types[2],
            .body = impl_method_body,
        } };
        body_rows[impl_id] = .{ .impl_ = .{
            .self_ty = types[2],
            .trait_path = .{ .segments = try sourceTraitSegments(
                alloc,
                case,
                scene,
                if (scene == .local_trait_homonym) local_trait else null,
            ) },
            .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{impl_method}),
        } };
    }
    if (scene == .local_trait_homonym) {
        body_rows[local_trait] = .{ .trait_ = .{ .name = case.trait_name } };
    }
    if (generic) {
        for (instantiation_widths, 0..) |prim, index| {
            body_rows[callers[index]] = .{ .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = prim },
                .body = caller_bodies[index],
            } };
        }
    }

    try addBareCrate(&graph, alloc, "numeric_tag", root, items[0..item_count]);
    const rust_ir = ir.RustIr{
        .crate_name = "numeric_tag",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// ── Canonical numeric-trait defaults ───────────────────────────────────────

// `u8::MIN`, `u8::MAX`, `T::zero()` and `T::one()` on a concrete integer are
// the Zig answer and nothing else: there is no receiver to dispatch on and no
// implementation to prefer.
test "lower: every canonical numeric default answers a concrete integer with the built-in value" {
    inline for (numeric_tag_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try numericTagFixture(alloc, case, .concrete_integer);
        const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "limit"));
        try expectNumericFallback(body, case, "u8");

        // A receiver that is already an integer needs no comptime guard, and
        // the emitted file says so in Zig rather than in a trace form.
        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "@typeInfo") == null);
        if (case.zig_call) |zig_call| {
            try std.testing.expect(std.mem.indexOf(u8, source, zig_call) != null);
        }
    }
}

// `I` may instantiate to a type that is not an integer. `std.math.minInt(I)`
// and `@as(I, 0)` mean nothing there, so the built-in answer is reached only
// for an actual integer and a custom type fails with a message instead of
// silently receiving an integer default.
test "lower: a generic numeric default is guarded so a custom source type cannot answer with an integer" {
    inline for (numeric_tag_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try numericTagFixture(alloc, case, .lexical_parameter);
        const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "limit"));
        try expectCustomTypeRefusal(body);
        try expectNumericFallback(body, case, "I");
    }
}

// A crate's own `num_traits` implementation is the answer the source asked
// for. The default is only what happens when nothing else claims the type, so
// it has to sit behind the selection rather than replace it — and the module
// `num_traits` keeps the trait under names the same implementation.
test "lower: a canonical num_traits implementation is selected before the built-in numeric default" {
    inline for (numeric_tag_cases) |case| {
        inline for ([_]NumericTagScene{ .source_impl_canonical, .source_impl_module_path }) |scene| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const pkg = try numericTagFixture(alloc, case, scene);
            const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "limit"));
            const branches = typeSelectionBranches(body, "I", "Counter") orelse
                return error.ExpectedSourceTypeSelection;
            // The branch reaches the SOURCE function, and takes no receiver:
            // the type it returns IS the instantiation.
            if (branches[0] != .call) return error.ExpectedSourceOverride;
            try std.testing.expectEqualStrings(case.method, calleeName(branches[0].call.callee.*) orelse
                return error.ExpectedSourceOverride);
            try std.testing.expectEqual(@as(usize, 0), branches[0].call.args.len);
            // Everything the branch did not claim keeps the built-in answer,
            // guard included.
            try expectCustomTypeRefusal(branches[1]);
            try expectNumericFallback(branches[1], case, "I");
        }
    }
}

// The selection is assembled from the answer it wraps, so the two must not
// share storage: an `else` that IS the slot the `if` is being written into has
// already lost one of the two answers before anything reads them. The pointers
// below are read back through the declaration AFTER a second crate has been
// lowered into the same arena, so a tree that only held together while the
// builder was on the stack cannot pass.
test "lower: a bounded numeric source selection keeps its fallback in its own storage" {
    inline for (numeric_tag_cases) |case| {
        // `min_value` and `max_value` are the bounded pair: the defaults whose
        // built-in answer is a `std.math` helper rather than a typed literal.
        if (case.zig_call) |zig_call| {
            inline for ([_]NumericTagScene{ .source_impl_canonical, .source_impl_module_path }) |scene| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                const pkg = try numericTagFixture(alloc, case, scene);
                // The declaration's own slot, not a copy of the tail: every
                // assertion below is about the storage the builder returns.
                const limit = try findFnDecl(pkg.files[0], "limit");
                const body = limit.body orelse return error.EmptyTranslatedBody;
                const root = body.expr orelse return error.EmptyTranslatedBody;
                // The answer the SOURCE asked for is the root. The built-in
                // default only survives behind that selection.
                if (root.* != .if_expr) return error.ExpectedSourceTypeSelection;
                const selection = root.*.if_expr;
                const fallback = selection.else_body orelse return error.ExpectedElseBranch;
                // Three answers, three slots. A fallback that IS the root, or
                // the branch, is a second reading of one overwritten node.
                try std.testing.expect(fallback != root);
                try std.testing.expect(selection.then_body != root);
                try std.testing.expect(selection.then_body != fallback);
                // WHICH declaration answers each side: the branch is the source
                // implementation the crate itself wrote, the fallback is the
                // guarded built-in default every other instantiation keeps.
                const branches = typeSelectionBranches(root.*, "I", "Counter") orelse
                    return error.ExpectedSourceTypeSelection;
                if (branches[0] != .call) return error.ExpectedSourceOverride;
                try std.testing.expectEqualStrings(case.method, calleeName(branches[0].call.callee.*) orelse
                    return error.ExpectedSourceOverride);
                try std.testing.expectEqual(@as(usize, 0), branches[0].call.args.len);
                // The fallback is a `@typeInfo` guard whose integer arm asks the
                // helper about ONE type, held in that arm's own generic slot.
                try expectCustomTypeRefusal(branches[1]);
                try expectNumericFallback(branches[1], case, "I");
                var std_imports: usize = 0;
                for (pkg.files[0].imports) |import| {
                    if (std.mem.eql(u8, import.local_name, "std") and
                        std.mem.eql(u8, import.module_or_path, "std"))
                    {
                        std_imports += 1;
                    }
                }
                try std.testing.expectEqual(@as(usize, 1), std_imports);

                // Another crate — the other bounded default, asked of a
                // concrete integer, so its root is a plain helper call with no
                // selection and no guard — is lowered through the same builder
                // into the SAME arena before the first package is read again.
                inline for (numeric_tag_cases) |other| {
                    if (other.zig_call != null and !std.mem.eql(u8, other.method, case.method)) {
                        _ = try numericTagFixture(alloc, other, .concrete_integer);
                    }
                }

                // What the builder returned is still finite, still its own
                // storage, and still answers the same two questions.
                if (root.* != .if_expr) return error.ExpectedSourceTypeSelection;
                try std.testing.expect(fallback != root);
                try expectCustomTypeRefusal(fallback.*);
                try expectNumericFallback(fallback.*, case, "I");

                const source = try emit.emitFile(alloc, &pkg.files[0]);
                const std_import = "const std = @import(\"std\");";
                try std.testing.expect(std.mem.indexOf(u8, source, "I == Counter") != null);
                try std.testing.expect(std.mem.indexOf(u8, source, zig_call) != null);
                try std.testing.expect(std.mem.indexOf(u8, source, std_import) != null);
            }
        }
    }
}

// A crate that declares its own `trait Bounded` is a different trait that
// happens to share a name. Selecting its implementation would hand a custom
// type the built-in integer default the guard exists to withhold.
test "lower: a crate-local trait that shares a numeric trait's name never answers it" {
    inline for (numeric_tag_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try numericTagFixture(alloc, case, .local_trait_homonym);
        const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "limit"));
        try std.testing.expect(typeSelectionBranches(body, "I", "Counter") == null);
        try expectCustomTypeRefusal(body);
        try expectNumericFallback(body, case, "I");

        // The homonym is a real declaration and still emits, but nothing calls
        // it through a `Counter` value: identity, not spelling, decides.
        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "Counter.") == null);
    }
}

// When the receiver IS the implemented type there is nothing left to select:
// the comptime comparison would be a constant the emitter already knows.
test "lower: a concrete implemented type answers its own trait implementation directly" {
    inline for (numeric_tag_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try numericTagFixture(alloc, case, .concrete_source_type);
        const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "limit"));
        if (body != .call) return error.ExpectedSourceOverride;
        try std.testing.expectEqualStrings(case.method, calleeName(body.call.callee.*) orelse
            return error.ExpectedSourceOverride);
        try std.testing.expectEqual(@as(usize, 0), body.call.args.len);
    }
}

// A type that is neither an integer nor implemented has no honest answer, and
// the guard can only report it once the instantiation is known. Refusing is
// what keeps `@as(I, 0)` from being emitted for a type it cannot hold.
test "lower: a numeric default for a type that is neither an integer nor implemented is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedNumericTraitImpl,
        numericTagFixture(arena.allocator(), numeric_tag_cases[0], .non_numeric_argument),
    );
}

// Every one of these tags is a type-level constant: it takes a type and no
// value. A value argument or a missing type argument is malformed IR, not a
// translation choice.
test "lower: a numeric default refuses a value argument or a missing type argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (numeric_tag_cases) |case| {
        try std.testing.expectError(
            error.InvalidCoreCallArity,
            numericTagFixture(alloc, case, .unexpected_value_argument),
        );
        try std.testing.expectError(
            error.InvalidCoreCallArity,
            numericTagFixture(alloc, case, .missing_type_argument),
        );
    }
}

// The emitted comptime branch is only a real consumer of the default once
// something instantiates it. These callers are that something: an unsigned
// width, a signed width, and a pointer-sized one whose extent is the target's.
test "lower: the generic numeric default is instantiated at signed, unsigned and target widths" {
    inline for (numeric_tag_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try numericTagFixture(alloc, case, .lexical_parameter);
        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "comptime I: type") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "limit(u8)") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "limit(i32)") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "limit(usize)") != null);
    }
}

// ── `<[T]>::first` is one shared optional borrow ───────────────────────────

/// Where the borrow `first()` returns comes from.
const SliceFirstReceiver = enum {
    /// `fn head(bytes: &[T]) -> Option<&T>` — the borrow as it arrived.
    borrowed_param,
    /// `fn head(state: &State) -> Option<&T> { state.bytes.first() }` — the
    /// same borrow reached through a field, so the binding has to name the
    /// PLACE rather than re-derive a value from it.
    field_place,
};

/// Lower `fn head(..) -> Option<&T>` whose only statement is `first()`, over
/// `element` elements reached the way `receiver` describes.
fn sliceFirstPackage(
    alloc: std.mem.Allocator,
    element: ir.types.Prim,
    receiver: SliceFirstReceiver,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const head = try addLowerEntity(&graph, .fn_, "head", root);
    const bytes_field = try addLowerEntity(&graph, .field, "bytes", head);
    const state_field = try addLowerEntity(&graph, .field, "state", head);
    const first = try addLowerEntity(&graph, .method_ref, "first", head);

    const element_ty: ir.types.Type = .{ .prim = element };
    const slice_ty: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = element_ty } };
    // 0: T, 1: `&[T]`, 2: the borrowed parameter, 3: `Option<&T>`,
    // 4: `State`, 5: `&State`.
    var types = [_]ir.types.Type{
        element_ty,
        slice_ty,
        .{ .reference = &.{ .mut = false, .pointee = slice_ty } },
        .{ .option = &.{ .reference = &.{ .mut = false, .pointee = element_ty } } },
        .{ .path = .{ .segments = &.{} } },
        .{ .reference = &.{ .mut = false, .pointee = .{ .path = .{ .segments = &.{} } } } },
    };
    var state_id: ir.spine.EntityId = 0;
    if (receiver == .field_place) {
        state_id = try addLowerEntity(&graph, .struct_, "State", root);
        types[4] = .{ .path = .{ .segments = try alloc.dupe(
            ir.types.PathSegment,
            &.{.{ .name = "State", .id = state_id }},
        ) } };
        types[5] = .{ .reference = &.{ .mut = false, .pointee = types[4] } };
    }

    const receiver_node = switch (receiver) {
        .borrowed_param => try typedExpr(&model, 2, .{ .path = .{ .def = bytes_field, .generic_args = &.{} } }),
        .field_place => blk: {
            const state = try typedExpr(&model, 5, .{ .path = .{ .def = state_field, .generic_args = &.{} } });
            break :blk try typedExpr(&model, 1, .{ .field = .{
                .base = state,
                .field = "bytes",
                .resolved = bytes_field,
            } });
        },
    };
    const call = try typedExpr(&model, 3, .{ .method_call = .{
        .receiver = receiver_node,
        .receiver_mode = .shared,
        .method = first,
        .args = &.{},
    } });
    const body = try typedExpr(&model, 3, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = switch (receiver) {
        .borrowed_param => .{ .name = "bytes", .ty = types[2], .span = span },
        .field_place => .{ .name = "state", .ty = types[5], .span = span },
    };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[head] = .{ .fn_ = .{
        .params = params,
        .ret = types[3],
        .body = body,
    } };
    if (receiver == .field_place) {
        body_rows[state_id] = .{ .struct_ = .{ .fields = try alloc.dupe(ir.items.Field, &.{
            .{ .name = "bytes", .ty = types[1], .visibility = .public, .span = span },
        }) } };
    }

    try addBareCrate(&graph, alloc, "slice_first", root, if (receiver == .field_place)
        try alloc.dupe(ir.spine.EntityId, &.{ head, state_id })
    else
        try alloc.dupe(ir.spine.EntityId, &.{head}));
    const rust_ir = ir.RustIr{
        .crate_name = "slice_first",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// The same contract when the borrow is reached through a field. What the
// returned pointer names is the field's storage, so the binding has to spell
// the place rather than lower the receiver a second time.
test "lower: a slice first through a field keeps the borrow identity of that field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sliceFirstPackage(alloc, .u8, .field_place);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "head"));
    if (body != .block or body.block.stmts.len != 1) return error.ExpectedSharedSliceBinding;
    const binding = body.block.stmts[0];
    if (binding != .let_stmt) return error.ExpectedSharedSliceBinding;
    const place = binding.let_stmt.init;
    if (place != .field_access) return error.ExpectedReceiverIdentity;
    try std.testing.expectEqualStrings("bytes", place.field_access.field_name);
    try std.testing.expectEqualStrings("state", operandIdent(place.field_access.target.*) orelse
        return error.ExpectedReceiverIdentity);

    const optional = body.block.expr.?.*;
    if (optional != .cast or optional.cast.target != .opt) return error.ExpectedOptionalFirst;
    const otherwise = optional.cast.operand.*.if_expr.else_body orelse return error.ExpectedOptionalFirst;
    const element_zero = otherwise.unary_op.operand.*;
    try std.testing.expectEqualStrings(binding.let_stmt.name, operandIdent(element_zero.builtin.args[0]) orelse
        return error.ExpectedReceiverIdentity);
}

// The emitted file is Zig, and this is the shape it has to have for a
// borrowed parameter: the optional pointer is the value, `len` decides which
// arm answers, and nothing copies the sequence.
test "lower: a slice first emits an optional pointer over the receiver's own slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sliceFirstPackage(alloc, .u8, .borrowed_param);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "?*const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "bytes.len == 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "null") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[0]") != null);
}

// ── Checked arithmetic on a generic bound ───────────────────────────────────

/// One `num_traits` checked operation and the runtime helper that answers it.
const CheckedCase = struct {
    method: []const u8,
    trait_name: []const u8,
    runtime: []const u8,
};

const checked_cases = [_]CheckedCase{
    .{ .method = "checked_add", .trait_name = "CheckedAdd", .runtime = "r2z.checkedAdd" },
    .{ .method = "checked_sub", .trait_name = "CheckedSub", .runtime = "r2z.checkedSub" },
    .{ .method = "checked_mul", .trait_name = "CheckedMul", .runtime = "r2z.checkedMul" },
};

/// Which spelling of the checked bound the source declares, or the crate-local
/// trait that merely shares its name.
const CheckedBound = enum {
    /// `num_traits::ops::checked::CheckedAdd` and its siblings.
    canonical_ops_module,
    /// `num_traits::CheckedAdd` — the same trait at its root.
    canonical_root,
    /// A trait this crate declares, which is a different trait.
    local_homonym,
};

/// Lower `fn checked<I: ..>(a: &I, b: &I) -> Option<I> { a.checked_*(b) }`
/// plus one caller per concrete width, so the emitted comptime branch is a
/// real instantiation at a signed, an unsigned and a target-dependent width.
fn checkedArithmeticPackage(
    alloc: std.mem.Allocator,
    case: CheckedCase,
    bound: CheckedBound,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "checked", root);
    const a_def = try addLowerEntity(&graph, .field, "a", callable);
    const b_def = try addLowerEntity(&graph, .field, "b", callable);

    var local_trait: ir.spine.EntityId = 0;
    var method_parent = callable;
    if (bound == .local_homonym) {
        local_trait = try addLowerEntity(&graph, .trait_, case.trait_name, root);
        // The method the source wrote resolves through the trait it declared,
        // so the callee entity belongs to THAT trait and to nothing else.
        method_parent = local_trait;
    }
    const method = try addLowerEntity(&graph, .method_ref, case.method, method_parent);

    const instantiation_widths = [_]ir.types.Prim{ .u8, .i32, .usize };
    var callers: [instantiation_widths.len]ir.spine.EntityId = undefined;
    var caller_a: [instantiation_widths.len]ir.exprs.NodeId = undefined;
    var caller_b: [instantiation_widths.len]ir.exprs.NodeId = undefined;
    var caller_calls: [instantiation_widths.len]ir.exprs.NodeId = undefined;
    for (instantiation_widths, 0..) |prim, index| {
        callers[index] = try addLowerEntity(&graph, .fn_, try std.fmt.allocPrint(
            alloc,
            "checked_{s}",
            .{@tagName(prim)},
        ), root);
        caller_a[index] = try addLowerEntity(&graph, .field, "a", callers[index]);
        caller_b[index] = try addLowerEntity(&graph, .field, "b", callers[index]);
    }

    const lexical = ir.types.Type{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "I", .id = null }},
    ) } };
    const borrow: ir.types.Type = .{ .reference = &.{ .mut = false, .pointee = lexical } };
    const result: ir.types.Type = .{ .option = &lexical };
    // 0: I, 1: `&I`, 2: `Option<I>`, 3..: the per-width borrows, results and
    // instantiation records the callers need.
    const width_entries: usize = instantiation_widths.len * 3;
    const types = try alloc.alloc(ir.types.Type, 3 + width_entries);
    types[0] = lexical;
    types[1] = borrow;
    types[2] = result;
    for (instantiation_widths, 0..) |prim, index| {
        // Every carrier here is arena-backed rather than a block-scoped
        // temporary: the type table outlives this loop and outlives this frame's
        // inner blocks, and a pointer to a per-iteration local would not.
        const wide = try alloc.create(ir.types.Type);
        wide.* = .{ .prim = prim };
        const wide_ref = try alloc.create(ir.types.Ref);
        wide_ref.* = .{ .mut = false, .pointee = wide.* };
        const wide_result = try alloc.create(ir.types.Type);
        wide_result.* = .{ .option = wide };
        types[3 + index] = .{ .reference = wide_ref };
        types[3 + instantiation_widths.len + index] = wide_result.*;
        types[3 + 2 * instantiation_widths.len + index] = .{ .generic_inst = .{
            .decl = callable,
            .args = .{ .params = try alloc.dupe(ir.types.Type, &.{wide.*}) },
        } };
    }

    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = a_def, .generic_args = &.{} } });
    const argument = try typedExpr(&model, 1, .{ .path = .{ .def = b_def, .generic_args = &.{} } });
    const call = try typedExpr(&model, 2, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .shared,
        .method = method,
        .args = try alloc.dupe(ir.exprs.NodeId, &.{argument}),
    } });
    const body = try typedExpr(&model, 2, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    for (instantiation_widths, 0..) |_, index| {
        const wide_borrow: ir.exprs.TypeId = @intCast(3 + index);
        const wide_result: ir.exprs.TypeId = @intCast(3 + instantiation_widths.len + index);
        const wide_inst: ir.exprs.TypeId = @intCast(3 + 2 * instantiation_widths.len + index);
        const left = try typedExpr(&model, wide_borrow, .{ .path = .{ .def = caller_a[index], .generic_args = &.{} } });
        const right = try typedExpr(&model, wide_borrow, .{ .path = .{ .def = caller_b[index], .generic_args = &.{} } });
        const instantiated = try typedExpr(&model, wide_inst, .{ .call = .{
            .call_kind = .{ .free = callable },
            .args = try alloc.dupe(ir.exprs.NodeId, &.{ left, right }),
        } });
        caller_calls[index] = try typedExpr(&model, wide_result, .{ .block = .{
            .statements = &.{},
            .tail = instantiated,
            .labelled = null,
        } });
    }

    const bound_segments: []const ir.types.PathSegment = switch (bound) {
        .local_homonym => &.{.{ .name = case.trait_name, .id = local_trait }},
        .canonical_root => &.{
            .{ .name = "num_traits", .id = null },
            .{ .name = case.trait_name, .id = null },
        },
        .canonical_ops_module => &.{
            .{ .name = "num_traits", .id = null },
            .{ .name = "ops", .id = null },
            .{ .name = "checked", .id = null },
            .{ .name = case.trait_name, .id = null },
        },
    };
    const params = try alloc.alloc(ir.items.Param, 2);
    params[0] = .{ .name = "a", .ty = types[1], .span = span };
    params[1] = .{ .name = "b", .ty = types[1], .span = span };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = params,
        .ret = types[2],
        .generic_params = &.{"I"},
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "I",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                bound_segments,
            ) } }}),
        } }}), .where_clauses = &.{} },
        .body = body,
    } };
    if (bound == .local_homonym) {
        body_rows[local_trait] = .{ .trait_ = .{ .name = case.trait_name } };
    }
    for (instantiation_widths, 0..) |_, index| {
        const caller_params = try alloc.alloc(ir.items.Param, 2);
        caller_params[0] = .{ .name = "a", .ty = types[3 + index], .span = span };
        caller_params[1] = .{ .name = "b", .ty = types[3 + index], .span = span };
        body_rows[callers[index]] = .{ .fn_ = .{
            .params = caller_params,
            .ret = types[3 + instantiation_widths.len + index],
            .body = caller_calls[index],
        } };
    }

    const items = try alloc.alloc(ir.spine.EntityId, 1 + instantiation_widths.len + @intFromBool(bound == .local_homonym));
    items[0] = callable;
    @memcpy(items[1..][0..instantiation_widths.len], &callers);
    if (bound == .local_homonym) items[items.len - 1] = local_trait;
    try addBareCrate(&graph, alloc, "checked_arithmetic", root, items);

    const rust_ir = ir.RustIr{
        .crate_name = "checked_arithmetic",
        .edition = "2021",
        .graph = graph,
        .types = types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// `a.checked_add(b)` on a `&I` is one runtime helper, named for the lexical
// type: the helper is generic in `I` and has to be instantiated with the same
// `I` the receiver was declared with. Both arguments arrive borrowed, so what
// the helper reads are the values behind them.
test "lower: a generic checked operation reaches the runtime helper with the lexical type argument" {
    inline for (checked_cases) |case| {
        inline for ([_]CheckedBound{ .canonical_ops_module, .canonical_root }) |bound| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const pkg = try checkedArithmeticPackage(alloc, case, bound);
            const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "checked"));
            // A type parameter may instantiate to something the runtime cannot
            // overflow-check, so the helper is reached only for an integer.
            try expectCustomTypeRefusal(body);
            const helper = integerFallbackOf(body);
            if (helper != .call) return error.ExpectedCheckedRuntimeCall;
            try std.testing.expectEqualStrings(case.runtime, calleeName(helper.call.callee.*) orelse
                return error.ExpectedCheckedRuntimeCall);
            try std.testing.expectEqual(@as(usize, 1), helper.call.generic_args.len);
            try std.testing.expectEqualStrings("I", try expectNamedType(helper.call.generic_args[0]));
            try std.testing.expectEqual(@as(usize, 2), helper.call.args.len);
            // Both arguments were borrowed, and the helper wants the values.
            const names = [_][]const u8{ "a", "b" };
            for (helper.call.args, names) |argument, name| {
                if (argument != .unary_op or argument.unary_op.op != .deref)
                    return error.ExpectedBorrowedCheckedArgument;
                try std.testing.expectEqualStrings(name, operandIdent(argument.unary_op.operand.*) orelse
                    return error.ExpectedBorrowedCheckedArgument);
            }
        }
    }
}

// A trait this crate declares that happens to share a checked trait's name is
// a different trait with different impls. Reaching the runtime helper for it
// would answer a source method that was never written.
test "lower: a crate-local trait that shares a checked trait's name never reaches the runtime helper" {
    inline for (checked_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try checkedArithmeticPackage(alloc, case, .local_homonym);
        const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "checked"));
        if (body != .builtin) return error.ExpectedSourceTraitRefusal;
        try std.testing.expectEqualStrings("compileError", body.builtin.name);
        if (body.builtin.args.len != 1 or body.builtin.args[0] != .lit or body.builtin.args[0].lit != .str)
            return error.ExpectedSourceTraitRefusal;
        if (body.builtin.args[0].lit.str.len == 0) return error.ExpectedSourceTraitRefusal;

        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "r2z.checked") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "compileError") != null);
    }
}

// The comptime branch is only a real consumer once something instantiates it.
// These callers instantiate it at an unsigned, a signed and a pointer-sized
// width, which is exactly the set of widths the helper has to be generic in.
test "lower: the generic checked helper is instantiated at signed, unsigned and target widths" {
    inline for (checked_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pkg = try checkedArithmeticPackage(alloc, case, .canonical_ops_module);
        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "comptime I: type") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "checked(u8, a, b)") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "checked(i32, a, b)") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "checked(usize, a, b)") != null);
        // The helper is the runtime's own, so the file has to import it.
        try std.testing.expectEqual(@as(usize, 1), runtimeImportCount(pkg.files[0]));
    }
}

// ── `Hasher::write_N` on a generic receiver ────────────────────────────────

/// One `core::hash::Hasher` method and the shape of the call that reaches it.
const HasherMethodCase = struct {
    method: []const u8,
    /// The primitive the default `write_N` body writes, or null for the two
    /// methods that carry no integer of their own.
    primitive: ?ir.types.Prim,
    /// The declared type of the value argument, or null when the call takes
    /// none at all.
    argument: ?ir.types.Prim,
    /// Whether the argument is the borrowed byte sequence `write` takes.
    argument_is_slice: bool = false,
};

const hasher_method_cases = [_]HasherMethodCase{
    .{ .method = "write_u64", .primitive = .u64, .argument = .u64 },
    .{ .method = "write_u8", .primitive = .u8, .argument = .u8 },
    .{ .method = "write", .primitive = null, .argument = .u8, .argument_is_slice = true },
    .{ .method = "finish", .primitive = null, .argument = null },
};

/// What the source's own `core::hash::Hasher` implementation declares beside
/// the call. Every implementation also supplies required `write` and `finish`.
const HasherSource = enum {
    /// Nothing: the default is the only answer there is.
    none,
    /// The primitive write the call names.
    primitive_write,
    /// No primitive override: the default routes through byte-level `write`.
    byte_write,
    /// Both, where the primitive write is the one that answers.
    both,
    /// The method that carries no integer at all.
    finish_only,
    /// The byte-level `write` on a self type with no declaration of its own,
    /// so the method lands at module scope under its own emitted name.
    byte_write_hoisted,
};

/// Lower `fn hash<H: core::hash::Hasher>(state: &mut H, value: ..)` with the
/// named method call beside the source implementation `source` describes.
/// A `finish` scene returns its u64 instead of discarding it.
fn genericHasherPackage(
    alloc: std.mem.Allocator,
    case: HasherMethodCase,
    source: HasherSource,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const hash = try addLowerEntity(&graph, .fn_, "hash", root);
    const state_def = try addLowerEntity(&graph, .field, "state", hash);
    const value_def = try addLowerEntity(&graph, .field, "value", hash);
    // The method_ref belongs to no trait THIS crate declares: the bound is the
    // external `core::hash::Hasher`, so the source's own impl is what has to be
    // found by identity rather than by where the callee hangs.
    const method = try addLowerEntity(&graph, .method_ref, case.method, hash);

    const unit: ir.types.Type = .{ .prim = .unit };
    const byte_slice: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    // 0: H, 1: `&mut H`, 2: the value argument, 3: unit, 4: the implementation's
    // self type, 5: `&mut Self`, 6: the borrowed bytes `write` takes, 7: u64.
    var types = [_]ir.types.Type{
        .{ .path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{.{ .name = "H", .id = null }}) } },
        .{ .reference = &.{ .mut = true, .pointee = .{ .path = .{ .segments = &.{} } } } },
        .{ .prim = case.argument orelse .u8 },
        unit,
        .{ .path = .{ .segments = &.{} } },
        .{ .reference = &.{ .mut = true, .pointee = .{ .path = .{ .segments = &.{} } } } },
        byte_slice,
        .{ .prim = .u64 },
    };
    types[1] = .{ .reference = &.{ .mut = true, .pointee = types[0] } };
    if (case.argument_is_slice) types[2] = byte_slice;
    if (case.primitive) |primitive| types[2] = .{ .prim = primitive };

    // ── The source implementation ───────────────────────────────────────
    var self_type: ir.spine.EntityId = 0;
    var impl_id: ir.spine.EntityId = 0;
    var declared: [3]ir.spine.EntityId = undefined;
    var declared_count: usize = 0;
    const hoisted_self = source == .byte_write_hoisted;
    if (source != .none) {
        if (hoisted_self) {
            // `ir.types.Type.array` is a POINTER, so the record is allocated
            // directly rather than through a helper that already wrapped it.
            const array = try alloc.create(ir.types.Array);
            array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 8 } };
            types[4] = .{ .array = array };
        } else {
            self_type = try addLowerEntity(&graph, .struct_, "SeaHasher", root);
            types[4] = .{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                &.{.{ .name = "SeaHasher", .id = self_type }},
            ) } };
        }
        types[5] = .{ .reference = &.{ .mut = true, .pointee = types[4] } };
        impl_id = try addLowerEntity(&graph, .impl_, if (hoisted_self)
            "Hasher for [u8; 8]"
        else
            "Hasher for SeaHasher", if (hoisted_self) root else self_type);
    }

    const declares_primitive = source == .primitive_write or source == .both;
    // `write` and `finish` are required even when this scene exercises only
    // the primitive override or the finish call.
    const declares_byte_write = source != .none;
    const declares_finish = source != .none;
    const unit_tail = try typedExpr(&model, 3, .{ .unit = {} });
    const zero_tail = try typedExpr(&model, 7, litInt(0));
    const returns_hash = std.mem.eql(u8, case.method, "finish");
    const result_type: ir.exprs.TypeId = if (returns_hash) 7 else 3;
    if (declares_primitive) {
        declared[declared_count] = try addLowerEntity(&graph, .fn_, case.method, impl_id);
        declared_count += 1;
    }
    if (declares_byte_write) {
        declared[declared_count] = try addLowerEntity(&graph, .fn_, "write", impl_id);
        declared_count += 1;
    }
    if (declares_finish) {
        declared[declared_count] = try addLowerEntity(&graph, .fn_, "finish", impl_id);
        declared_count += 1;
    }

    // ── The call ────────────────────────────────────────────────────────
    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = state_def, .generic_args = &.{} } });
    const argument: ?ir.exprs.NodeId = if (case.argument == null) null else try typedExpr(&model, 2, .{
        .path = .{ .def = value_def, .generic_args = &.{} },
    });
    const call = try typedExpr(&model, result_type, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = if (returns_hash) .shared else .mutable,
        .method = method,
        .args = if (argument) |node|
            try alloc.dupe(ir.exprs.NodeId, &.{node})
        else
            &.{},
    } });
    const body = try typedExpr(&model, result_type, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    // ── Bodies ──────────────────────────────────────────────────────────
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    const hash_params = try alloc.alloc(ir.items.Param, if (case.argument == null) 1 else 2);
    hash_params[0] = .{ .name = "state", .ty = types[1], .span = span };
    if (case.argument != null) hash_params[1] = .{ .name = "value", .ty = types[2], .span = span };
    body_rows[hash] = .{ .fn_ = .{
        .params = hash_params,
        .ret = types[result_type],
        .generic_params = &.{"H"},
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "H",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                &.{
                    .{ .name = "core", .id = null },
                    .{ .name = "hash", .id = null },
                    .{ .name = "Hasher", .id = null },
                },
            ) } }}),
        } }}), .where_clauses = &.{} },
        .body = body,
    } };

    if (source != .none) {
        const items = try alloc.alloc(ir.spine.EntityId, 3);
        items[0] = hash;
        items[1] = impl_id;
        items[2] = if (hoisted_self) root else self_type;
        try addBareCrate(&graph, alloc, "generic_hasher", root, items[0..(if (hoisted_self) 2 else 3)]);
        body_rows[impl_id] = .{ .impl_ = .{
            .self_ty = types[4],
            .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
                .{ .name = "core", .id = null },
                .{ .name = "hash", .id = null },
                .{ .name = "Hasher", .id = null },
            }) },
            .assoc_items = try alloc.dupe(ir.spine.EntityId, declared[0..declared_count]),
        } };
        const mirrors = try alloc.alloc(ir.bodies.StructMethod, if (hoisted_self) 0 else declared_count);
        for (declared[0..declared_count], 0..) |decl, index| {
            const name = graph.symbol_table.get(decl).?.name;
            // Each declared method keeps the signature the trait gives it: the
            // primitive write takes that integer, `write` takes borrowed
            // bytes, and `finish` takes nothing at all.
            const takes_nothing = std.mem.eql(u8, name, "finish");
            const value_ty: ir.types.Type = if (std.mem.eql(u8, name, "write"))
                types[6]
            else
                .{ .prim = case.primitive orelse .u64 };
            const declared_params = try alloc.alloc(ir.items.Param, if (takes_nothing) 1 else 2);
            declared_params[0] = .{
                .name = "self",
                .ty = if (takes_nothing)
                    .{ .reference = &.{ .mut = false, .pointee = types[4] } }
                else
                    types[5],
                .span = span,
            };
            if (!takes_nothing) declared_params[1] = .{ .name = "bytes", .ty = value_ty, .span = span };
            const method_body = try typedExpr(&model, if (takes_nothing) 7 else 3, .{ .block = .{
                .statements = &.{},
                .tail = if (takes_nothing) zero_tail else unit_tail,
                .labelled = null,
            } });
            body_rows[decl] = .{ .fn_ = .{
                .params = declared_params,
                .ret = if (takes_nothing) types[7] else unit,
                .body = method_body,
            } };
            if (!hoisted_self) mirrors[index] = .{
                .name = name,
                .visibility = .public,
                .params = declared_params[1..],
                .ret = body_rows[decl].fn_.ret,
                .body = method_body,
                .receiver = if (takes_nothing) .ref_ else .mut_ref,
            };
        }
        if (!hoisted_self) body_rows[self_type] = .{ .struct_ = .{ .methods = mirrors } };
    } else {
        try addBareCrate(&graph, alloc, "generic_hasher", root, try alloc.dupe(
            ir.spine.EntityId,
            &.{hash},
        ));
    }

    const rust_ir = ir.RustIr{
        .crate_name = "generic_hasher",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The `receiver.write(bytes)` a Hasher default body ends with, checked against
/// the receiver it borrowed and the binding whose own storage the bytes are.
fn hasherWriteCall(stmt: ast.Stmt, receiver_name: []const u8, value_binding: []const u8) !ast.Call {
    if (stmt != .expr_stmt) return error.ExpectedHasherWrite;
    const call = stmt.expr_stmt.*;
    if (call != .call) return error.ExpectedHasherWrite;
    const write = call.call;
    if (write.callee.* != .field_access) return error.ExpectedHasherWrite;
    if (!std.mem.eql(u8, write.callee.field_access.field_name, "write")) return error.ExpectedHasherWrite;
    const receiver = calleeName(write.callee.field_access.target.*) orelse return error.ExpectedHasherWrite;
    if (!std.mem.eql(u8, receiver, receiver_name)) return error.ExpectedHasherWrite;
    if (write.args.len != 1 or write.args[0] != .call) return error.ExpectedHasherWrite;
    const bytes = write.args[0].call;
    if (bytes.callee.* != .ident or !std.mem.eql(u8, bytes.callee.ident, "std.mem.asBytes"))
        return error.ExpectedHasherWrite;
    if (bytes.args.len != 1 or bytes.args[0] != .unary_op or bytes.args[0].unary_op.op != .addr_of)
        return error.ExpectedHasherWrite;
    // The bytes are the storage of the value that was bound for exactly this
    // write, so `std.mem.asBytes` is handed its address and not a copy.
    const addressed = operandIdent(bytes.args[0].unary_op.operand.*) orelse return error.ExpectedHasherWrite;
    if (!std.mem.eql(u8, addressed, value_binding)) return error.ExpectedHasherWrite;
    return write;
}

// Rust's `Hasher::write_uN` default writes the value's OWN bytes, which are
// native-endian. There is no endian conversion to emit and nothing to
// allocate: the value is bound at its own declared type and its address is
// handed to the hasher the source borrowed.
test "lower: a generic Hasher write_N default writes the value's own native bytes" {
    inline for ([_]ir.types.Prim{ .u64, .u8, .usize }) |primitive| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const case = HasherMethodCase{
            .method = try std.fmt.allocPrint(alloc, "write_{s}", .{@tagName(primitive)}),
            .primitive = primitive,
            .argument = primitive,
        };
        const pkg = try genericHasherPackage(alloc, case, .none);
        const stmts = try fnBodyStmts(try findFnDecl(pkg.files[0], "hash"));
        try std.testing.expectEqual(@as(usize, 2), stmts.len);
        const binding = stmts[0];
        if (binding != .let_stmt) return error.ExpectedNativeByteBinding;
        if (binding.let_stmt.ty == null or binding.let_stmt.ty.? != .prim)
            return error.ExpectedNativeByteBinding;
        try std.testing.expectEqual(@as(ast.Prim, @field(ast.Prim, @tagName(primitive))), binding.let_stmt.ty.?.prim);
        try std.testing.expectEqualStrings("value", operandIdent(binding.let_stmt.init) orelse
            return error.ExpectedNativeByteBinding);
        _ = try hasherWriteCall(stmts[1], "state", binding.let_stmt.name);

        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.asBytes") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "Endian") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "nativeToLittle") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "allocator:") == null);
        try std.testing.expectEqual(@as(usize, 0), runtimeImportCount(pkg.files[0]));
    }
}

// A source implementation of the primitive write is the answer the crate wrote
// down. It has to win only for its own receiver, and everything else still
// gets the default bytes — which is why the default sits in the else arm of a
// comptime type comparison rather than replacing the call.
test "lower: a source Hasher implementation answers write_N before the default bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try genericHasherPackage(alloc, hasher_method_cases[0], .both);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "hash"));
    const branches = typeSelectionBranches(body, "H", "SeaHasher") orelse
        return error.ExpectedHasherTypeSelection;
    if (branches[0] != .call) return error.ExpectedSourceOverride;
    try std.testing.expectEqualStrings("write_u64", calleeName(branches[0].call.callee.*) orelse
        return error.ExpectedSourceOverride);
    try std.testing.expectEqual(@as(usize, 1), branches[0].call.args.len);
    // The branch calls the source's own method ON THE RECEIVER, which is the
    // only thing that can be a `Hasher` for this instantiation.
    if (branches[0].call.callee.* != .field_access) return error.ExpectedSourceOverride;
    try std.testing.expectEqualStrings("state", operandIdent(branches[0].call.callee.field_access.target.*) orelse
        return error.ExpectedSourceOverride);

    // Everything the branch did not claim keeps the default bytes.
    if (branches[1] != .block) return error.ExpectedNativeByteDefault;
    const fallback = branches[1].block;
    if (fallback.stmts.len != 2) return error.ExpectedNativeByteDefault;
    const binding = fallback.stmts[0];
    if (binding != .let_stmt) return error.ExpectedNativeByteBinding;
    _ = try hasherWriteCall(fallback.stmts[1], "state", binding.let_stmt.name);

    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write_u64(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write(") != null);
}

// With no primitive write of its own, the crate's `write` is still the answer
// for its own hasher. Its self type here has no declaration, so the method
// landed at module scope under its own emitted name. Only the matching array
// instantiation can call that declaration; every other H reaches its own
// `write` member with the same native bytes.
test "lower: an absent write_N reaches the source's own hoisted write declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try genericHasherPackage(alloc, hasher_method_cases[0], .byte_write_hoisted);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "hash"));
    if (body != .if_expr) return error.ExpectedHasherTypeSelection;
    const selection = body.if_expr;
    if (selection.cond.* != .bin_op or selection.cond.bin_op.op != .equal)
        return error.ExpectedHasherTypeSelection;
    try std.testing.expectEqualStrings("H", typeValueName(selection.cond.bin_op.lhs.*) orelse
        return error.ExpectedHasherTypeSelection);
    // The self type this branch claims is the one the impl declared, and it is
    // compared as a type rather than by name.
    if (selection.cond.bin_op.rhs.* != .type_value) return error.ExpectedHasherTypeSelection;
    if (selection.cond.bin_op.rhs.type_value != .array) return error.ExpectedHasherTypeSelection;
    try std.testing.expectEqual(@as(u64, 8), selection.cond.bin_op.rhs.type_value.array.len);
    const array_element = selection.cond.bin_op.rhs.type_value.array.elem.*;
    if (array_element != .prim) return error.ExpectedHasherTypeSelection;
    try std.testing.expectEqual(ast.Prim.u8, array_element.prim);

    // Both arms borrow the exact primitive binding. Only the array arm can
    // hand the receiver to the source's module-hoisted array declaration.
    for ([_]*const ast.Expr{ selection.then_body, selection.else_body orelse return error.ExpectedHasherWrite }, 0..) |arm, index| {
        if (arm.* != .block or arm.block.stmts.len != 2) return error.ExpectedNativeByteDefault;
        const binding = arm.block.stmts[0];
        if (binding != .let_stmt) return error.ExpectedNativeByteBinding;
        if (binding.let_stmt.ty == null or binding.let_stmt.ty.? != .prim)
            return error.ExpectedNativeByteBinding;
        try std.testing.expectEqual(ast.Prim.u64, binding.let_stmt.ty.?.prim);
        try std.testing.expectEqualStrings("value", operandIdent(binding.let_stmt.init) orelse
            return error.ExpectedNativeByteBinding);
        if (index == 1) {
            // The fallback is the actual instantiated H, never the array.
            _ = try hasherWriteCall(arm.block.stmts[1], "state", binding.let_stmt.name);
            continue;
        }
        const write_stmt = arm.block.stmts[1];
        if (write_stmt != .expr_stmt or write_stmt.expr_stmt.* != .call) return error.ExpectedHasherWrite;
        const write = write_stmt.expr_stmt.call;
        // The selected array declaration takes this receiver's own storage.
        if (write.callee.* != .ident or !std.mem.eql(u8, write.callee.ident, "write"))
            return error.ExpectedHoistedWriteTarget;
        try std.testing.expectEqual(@as(usize, 2), write.args.len);
        if (write.args[0] != .unary_op or write.args[0].unary_op.op != .addr_of)
            return error.ExpectedHoistedWriteTarget;
        // `state` is already a pointer: borrow its pointee, not the handle.
        const addressed_receiver = write.args[0].unary_op.operand.*;
        if (addressed_receiver != .unary_op or addressed_receiver.unary_op.op != .deref)
            return error.ExpectedHoistedWriteTarget;
        try std.testing.expectEqualStrings("state", operandIdent(addressed_receiver.unary_op.operand.*) orelse
            return error.ExpectedHoistedWriteTarget);
        if (write.args[1] != .call or write.args[1].call.callee.* != .ident or
            !std.mem.eql(u8, write.args[1].call.callee.ident, "std.mem.asBytes"))
        {
            return error.ExpectedHoistedWriteTarget;
        }
        const bytes = write.args[1].call;
        if (bytes.args.len != 1 or bytes.args[0] != .unary_op or bytes.args[0].unary_op.op != .addr_of)
            return error.ExpectedHoistedWriteTarget;
        try std.testing.expectEqualStrings(binding.let_stmt.name, operandIdent(write.args[1].call.args[0].unary_op.operand.*) orelse
            return error.ExpectedHoistedWriteTarget);
    }

    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Endian") == null);
}

// `write` and `finish` carry no integer of their own, so there is no default
// body to reach for: the receiver answers them directly, and a crate that
// implements them gets its own method for its own receiver.
test "lower: a generic Hasher write and finish stay the receiver's own methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // No source implementation: no selection, no default, just the call.
    for ([_]HasherMethodCase{ hasher_method_cases[2], hasher_method_cases[3] }) |case| {
        var scene = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scene.deinit();
        const pkg = try genericHasherPackage(scene.allocator(), case, .none);
        const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "hash"));
        if (body != .call) return error.ExpectedMemberCall;
        try std.testing.expectEqualStrings(case.method, calleeName(body.call.callee.*) orelse
            return error.ExpectedMemberCall);
        if (body.call.callee.* != .field_access) return error.ExpectedMemberCall;
        try std.testing.expectEqualStrings("state", operandIdent(body.call.callee.field_access.target.*) orelse
            return error.ExpectedMemberCall);
    }

    // With a source implementation the same call is claimed for that hasher.
    const pkg = try genericHasherPackage(alloc, hasher_method_cases[3], .finish_only);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "hash"));
    const branches = typeSelectionBranches(body, "H", "SeaHasher") orelse
        return error.ExpectedHasherTypeSelection;
    if (branches[0] != .call) return error.ExpectedSourceOverride;
    try std.testing.expectEqualStrings("finish", calleeName(branches[0].call.callee.*) orelse
        return error.ExpectedSourceOverride);
    try std.testing.expectEqual(@as(usize, 0), branches[0].call.args.len);
    if (branches[1] != .call) return error.ExpectedMemberCall;
    try std.testing.expectEqualStrings("finish", calleeName(branches[1].call.callee.*) orelse
        return error.ExpectedMemberCall);
}

// ── A source trait's associated function ───────────────────────────────────

/// The implementations a `I::digits()` call can be answered by.
const AssociatedImplShape = enum {
    /// `impl DigitCount for Counter { fn digits() -> usize }`
    concrete,
    /// `impl<T: DigitBase> DigitCount for T { fn digits() -> usize }` — the
    /// unique blanket that answers for EVERY instantiation.
    blanket,
    /// Two blanket impls of the same associated function.
    two_blankets,
    /// A blanket impl beside a concrete one for the same function.
    blanket_and_concrete,
};

/// Lower `fn count<I: DigitCount>() -> usize { I::digits() }`, where the call
/// records its Self type on the generic instantiation record the way the
/// frontend does for a bound-associated function.
fn sourceAssociatedPackage(alloc: std.mem.Allocator, shape: AssociatedImplShape) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const count = try addLowerEntity(&graph, .fn_, "count", root);
    const trait_id = try addLowerEntity(&graph, .trait_, "DigitCount", root);
    // The method belongs to the trait, which is what makes this an associated
    // function of `Self` rather than a free function.
    const assoc_method = try addLowerEntity(&graph, .method_ref, "digits", trait_id);

    // Only the impls this SHAPE declares exist. An impl block the crate never
    // wrote has no entity and no body row, and hoisting walks the whole symbol
    // table rather than a module's item list — so an entity left here without a
    // body is a declaration the lowering reaches and has nothing to lower.
    const declares_concrete = shape == .concrete or shape == .blanket_and_concrete;
    const declares_blanket_one = shape == .blanket or shape == .two_blankets or
        shape == .blanket_and_concrete;
    const declares_blanket_two = shape == .two_blankets;

    var counter: ir.spine.EntityId = 0;
    var concrete_impl: ir.spine.EntityId = 0;
    var concrete_fn: ir.spine.EntityId = 0;
    if (declares_concrete) {
        counter = try addLowerEntity(&graph, .struct_, "Counter", root);
        // A trait impl over a type THIS crate declares is parented to it and
        // named `Trait for Self`, which is what lets `digits` be a member of
        // `Counter` rather than a free function beside an empty nominal.
        concrete_impl = try addLowerEntity(&graph, .impl_, "DigitCount for Counter", counter);
        concrete_fn = try addLowerEntity(&graph, .fn_, "digits", concrete_impl);
    }
    // `impl<T: DigitBase> DigitCount for T` resolves `T` to no declaration, so
    // the frontend leaves the impl parented to the module that declares it.
    var blanket_one: ir.spine.EntityId = 0;
    var blanket_one_fn: ir.spine.EntityId = 0;
    if (declares_blanket_one) {
        blanket_one = try addLowerEntity(&graph, .impl_, "DigitCount for T", root);
        blanket_one_fn = try addLowerEntity(&graph, .fn_, "digits", blanket_one);
    }
    var blanket_two: ir.spine.EntityId = 0;
    var blanket_two_fn: ir.spine.EntityId = 0;
    if (declares_blanket_two) {
        blanket_two = try addLowerEntity(&graph, .impl_, "DigitCount for T", root);
        blanket_two_fn = try addLowerEntity(&graph, .fn_, "digits", blanket_two);
    }

    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const lexical: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "I", .id = null }},
    ) } };
    // 0: I, 1: usize, 2: `Counter`, 3: the blanket self type, 4: the call's own
    // instantiation record — the generic_inst of the TRAIT METHOD it names,
    // which is what tells the backend which `Self` the call was written for.
    const types = [_]ir.types.Type{
        lexical,
        usize_ty,
        .{ .path = .{ .segments = try alloc.dupe(
            ir.types.PathSegment,
            &.{.{ .name = "Counter", .id = if (declares_concrete) counter else null }},
        ) } },
        .{ .path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{.{ .name = "T", .id = null }}) } },
        .{ .generic_inst = .{
            .decl = assoc_method,
            .args = .{ .params = try alloc.dupe(ir.types.Type, &.{lexical}) },
        } },
    };

    const call = try typedExpr(&model, 4, .{ .call = .{
        .call_kind = .{ .associated = assoc_method },
        .args = &.{},
    } });
    const body = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    const digits_tail = try typedExpr(&model, 1, litInt(3));
    const digits_body = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = digits_tail,
        .labelled = null,
    } });

    const trait_path = ir.types.Path{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
        .{ .name = "DigitCount", .id = trait_id },
    }) };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[count] = .{ .fn_ = .{
        .params = &.{},
        .ret = usize_ty,
        .generic_params = &.{"I"},
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "I",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                trait_path.segments,
            ) } }}),
        } }}), .where_clauses = &.{} },
        .body = body,
    } };
    body_rows[trait_id] = .{ .trait_ = .{
        .name = "DigitCount",
        .methods = &.{.{ .name = "digits", .ret = usize_ty }},
    } };
    const declared_functions = [_]struct { ir.spine.EntityId, bool }{
        .{ concrete_fn, declares_concrete },
        .{ blanket_one_fn, declares_blanket_one },
        .{ blanket_two_fn, declares_blanket_two },
    };
    for (declared_functions) |entry| {
        if (!entry[1]) continue;
        body_rows[entry[0]] = .{ .fn_ = .{
            .params = &.{},
            .ret = usize_ty,
            .body = digits_body,
        } };
    }
    if (declares_concrete) {
        // `struct Counter;` — a unit struct, which the frontend records with
        // `.layout = .unit` and no fields — plus the `digits` its impl
        // contributes. The member is what gives the nominal something to
        // render; a unit struct with no methods is an empty container, and an
        // empty container is not a Zig declaration. An associated function has
        // no `self`, so the record carries no receiver.
        const counter_methods = try alloc.alloc(ir.bodies.StructMethod, 1);
        counter_methods[0] = .{
            .name = "digits",
            .visibility = .public,
            .params = &.{},
            .ret = usize_ty,
            .body = digits_body,
        };
        body_rows[counter] = .{ .struct_ = .{
            .layout = .unit,
            .methods = counter_methods,
        } };
    }
    // Arena-owned, like every other generic record in this file: the parameter
    // list outlives the literal the fixture writes it from, and a slice of a
    // stack temporary is not storage the lowering may read.
    const blanket_generics: ir.types.Generics = .{
        .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "T",
            .bounds = &.{},
        } }}),
        .where_clauses = &.{},
    };
    if (declares_concrete) {
        body_rows[concrete_impl] = .{ .impl_ = .{
            .self_ty = types[2],
            .trait_path = trait_path,
            .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{concrete_fn}),
        } };
    }
    if (declares_blanket_one) {
        body_rows[blanket_one] = .{ .impl_ = .{
            .self_ty = types[3],
            .trait_path = trait_path,
            .generics = blanket_generics,
            .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{blanket_one_fn}),
        } };
    }
    if (declares_blanket_two) {
        body_rows[blanket_two] = .{ .impl_ = .{
            .self_ty = types[3],
            .trait_path = trait_path,
            .generics = blanket_generics,
            .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{blanket_two_fn}),
        } };
    }

    var items: std.ArrayListUnmanaged(ir.spine.EntityId) = .empty;
    defer items.deinit(alloc);
    try items.appendSlice(alloc, &.{ count, trait_id });
    if (declares_concrete) {
        try items.appendSlice(alloc, &.{ counter, concrete_impl });
    }
    if (declares_blanket_one) {
        try items.append(alloc, blanket_one);
    }
    if (declares_blanket_two) {
        try items.append(alloc, blanket_two);
    }
    try addBareCrate(&graph, alloc, "source_associated", root, items.items);

    const rust_ir = ir.RustIr{
        .crate_name = "source_associated",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// `I::digits()` records the `Self` type on the call, so the answer is chosen by
// the instantiation rather than by what the method returns or by a same-named
// function in another impl. A concrete implementation answers for its own type
// and refuses every other one: there is no built-in default for a source trait.
test "lower: a source trait's associated function is selected by the instantiated Self type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sourceAssociatedPackage(alloc, .concrete);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "count"));
    const branches = typeSelectionBranches(body, "I", "Counter") orelse
        return error.ExpectedSelfTypeSelection;
    if (branches[0] != .call) return error.ExpectedSourceOverride;
    try std.testing.expectEqualStrings("digits", calleeName(branches[0].call.callee.*) orelse
        return error.ExpectedSourceOverride);
    // An associated function of `Self` takes no receiver: the type it is
    // written for IS the receiver.
    try std.testing.expectEqual(@as(usize, 0), branches[0].call.args.len);
    // The else arm is a refusal, not an integer-shaped answer.
    if (branches[1] != .builtin or !std.mem.eql(u8, branches[1].builtin.name, "compileError"))
        return error.ExpectedAssociatedRefusal;
    if (branches[1].builtin.args.len != 1 or branches[1].builtin.args[0] != .lit or
        branches[1].builtin.args[0].lit != .str or branches[1].builtin.args[0].lit.str.len == 0)
    {
        return error.ExpectedAssociatedRefusal;
    }

    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "compileError") != null);
    // The implementation is the crate's own declaration, reached through the
    // type it was written for. That is the SHAPE of the callee, not the way it
    // is spelled: a field access whose target is the instantiated `Self` type
    // itself, so no other impl of the same trait could have answered the name.
    if (branches[0].call.callee.* != .field_access) return error.ExpectedSourceOverride;
    const implementation = branches[0].call.callee.field_access;
    try std.testing.expectEqualStrings("digits", implementation.field_name);
    if (implementation.target.* != .type_value) return error.ExpectedSourceOverride;
    try std.testing.expectEqualStrings("Counter", try expectNamedType(implementation.target.type_value));
}

// A blanket impl IS every instantiation of the receiver, so there is no type
// comparison left to make and no arm that could refuse. The call names the
// hoisted declaration and instantiates it with the lexical `Self`.
test "lower: a unique blanket impl answers the associated function for every instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sourceAssociatedPackage(alloc, .blanket);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "count"));
    if (body != .call) return error.ExpectedBlanketAssociatedCall;
    try std.testing.expectEqualStrings("digits", calleeName(body.call.callee.*) orelse
        return error.ExpectedBlanketAssociatedCall);
    try std.testing.expectEqual(@as(usize, 0), body.call.args.len);
    try std.testing.expectEqual(@as(usize, 1), body.call.generic_args.len);
    try std.testing.expectEqualStrings("I", try expectNamedType(body.call.generic_args[0]));
}

// Two answers for one function is not a choice the backend may make. Choosing
// the first would silently pick an implementation the source never preferred,
// and choosing the last would depend on declaration order.
test "lower: two impls that both answer one associated function are ambiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(
        error.AmbiguousTraitImplMatch,
        sourceAssociatedPackage(alloc, .two_blankets),
    );
    // A blanket beside a concrete one is the same question: the blanket already
    // answers for the concrete type's instantiation.
    try std.testing.expectError(
        error.AmbiguousTraitImplMatch,
        sourceAssociatedPackage(alloc, .blanket_and_concrete),
    );
}

// ── The receiver a default body has to reach ───────────────────────────────

/// How the receiver a default body is handed is spelled: a thin pointer the
/// source borrowed, an owned place this frame owns, or an owned value this
/// frame built.
const ReceiverShape = struct {
    /// The source parameter the receiver is reached through, and whether that
    /// parameter is itself the handle.
    param: []const u8,
    borrowed_pointer: bool,
};

/// Lower `fn record(..)` whose only statement is the canonical Hasher
/// primitive-write tag over the receiver `shape` describes.
///
/// The receiver shapes differ in what has to survive the write: a thin pointer
/// is already the handle and is forwarded unchanged, an owned place keeps its
/// storage through the address of the place itself, and an owned value this
/// frame built has no storage to borrow and is bound as a variable.
fn receiverShapePackage(alloc: std.mem.Allocator, shape: ReceiverShape) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const record = try addLowerEntity(&graph, .fn_, "record", root);
    const handle_def = try addLowerEntity(&graph, .field, shape.param, record);
    const value_def = try addLowerEntity(&graph, .field, "value", record);
    const sea = try addLowerEntity(&graph, .struct_, "SeaHasher", root);
    const wrapper = try addLowerEntity(&graph, .struct_, "Wrapper", root);
    const inner_def = try addLowerEntity(&graph, .field, "inner", wrapper);

    const unit: ir.types.Type = .{ .prim = .unit };
    const bytes: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const sea_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "SeaHasher", .id = sea }},
    ) } };
    const wrapper_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "Wrapper", .id = wrapper }},
    ) } };
    // 0: u64, 1: `SeaHasher`, 2: `&SeaHasher`, 3: `Wrapper`, 4: unit,
    // 5: the borrowed bytes a `write` takes.
    const types = [_]ir.types.Type{
        .{ .prim = .u64 },
        sea_ty,
        .{ .reference = &.{ .mut = true, .pointee = sea_ty } },
        wrapper_ty,
        unit,
        bytes,
    };

    const receiver: ir.exprs.NodeId = switch (shape.borrowed_pointer) {
        true => try typedExpr(&model, 2, .{ .path = .{ .def = handle_def, .generic_args = &.{} } }),
        false => blk: {
            // An owned place: a field of the wrapper the frame was handed.
            const owner = try typedExpr(&model, 3, .{ .path = .{ .def = handle_def, .generic_args = &.{} } });
            break :blk try typedExpr(&model, 1, .{ .field = .{
                .base = owner,
                .field = "inner",
                .resolved = inner_def,
            } });
        },
    };
    const value = try typedExpr(&model, 0, .{ .path = .{ .def = value_def, .generic_args = &.{} } });
    const call = try typedExpr(&model, 4, .{ .core_call = .{
        .function = .hash_write_primitive,
        .generic_args = try alloc.dupe(ir.types.Type, &.{.{ .prim = .u64 }}),
        .args = try alloc.dupe(ir.exprs.NodeId, &.{ receiver, value }),
    } });
    const body = try typedExpr(&model, 4, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    const params = try alloc.dupe(ir.items.Param, &.{
        // The receiver parameter is the handle itself when the source borrowed
        // one, and an owned value this frame has to bind otherwise.
        .{ .name = shape.param, .ty = types[if (shape.borrowed_pointer) 2 else 3], .span = span },
        .{ .name = "value", .ty = types[0], .span = span },
    });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[record] = .{ .fn_ = .{
        .params = params,
        .ret = unit,
        .body = body,
    } };
    // A `write` the receiver's own type declares, so the member call the
    // default body emits has a declaration to reach.
    const write_body = try typedExpr(&model, 4, .{ .block = .{
        .statements = &.{},
        .tail = try typedExpr(&model, 4, .{ .unit = {} }),
        .labelled = null,
    } });
    const write_method: ir.bodies.StructMethod = .{
        .name = "write",
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "bytes", .ty = types[5], .span = span },
        }),
        .ret = unit,
        .body = write_body,
        .receiver = .mut_ref,
    };
    body_rows[sea] = .{ .struct_ = .{
        .methods = try alloc.dupe(ir.bodies.StructMethod, &.{write_method}),
    } };
    body_rows[wrapper] = .{ .struct_ = .{ .fields = try alloc.dupe(ir.items.Field, &.{
        .{ .name = "inner", .ty = types[1], .visibility = .public, .span = span },
    }) } };

    try addBareCrate(&graph, alloc, "receiver_shape", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{ record, sea, wrapper },
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "receiver_shape",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// A `&mut T` parameter IS the handle in Zig. Reading through it and handing
// the value on would produce `*const T` where the source promised `&mut`, and
// the runtime helpers that advance the reader write through it.
test "lower: a default body forwards a borrowed pointer receiver unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try receiverShapePackage(alloc, .{ .param = "state", .borrowed_pointer = true });
    const stmts = try fnBodyStmts(try findFnDecl(pkg.files[0], "record"));
    // No rebinding at all: the receiver arrives as the parameter did.
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    const binding = stmts[0];
    if (binding != .let_stmt) return error.ExpectedNativeByteBinding;
    try std.testing.expectEqualStrings("value", operandIdent(binding.let_stmt.init) orelse
        return error.ExpectedNativeByteBinding);
    const write = stmts[1];
    if (write != .expr_stmt or write.expr_stmt.* != .call) return error.ExpectedHasherWrite;
    const callee = write.expr_stmt.call.callee.*;
    if (callee != .field_access or !std.mem.eql(u8, callee.field_access.field_name, "write"))
        return error.ExpectedHasherWrite;
    const target = callee.field_access.target.*;
    // The pointer, not the value it points at.
    if (target != .ident) return error.ExpectedReceiverIdentity;
    try std.testing.expectEqualStrings("state", target.ident);
}

// An owned place is not a handle: the write needs the hasher, and the frame
// owns it, so the default binds a POINTER to the place rather than a copy of
// what it holds. A copy would write into storage the caller still owns.
test "lower: a default body binds an owned place by address instead of copying it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try receiverShapePackage(alloc, .{ .param = "holder", .borrowed_pointer = false });
    const stmts = try fnBodyStmts(try findFnDecl(pkg.files[0], "record"));
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    const receiver_binding = stmts[0];
    if (receiver_binding != .let_stmt) return error.ExpectedReceiverIdentity;
    // The frame owns the place but does not write to it through this binding.
    try std.testing.expect(!receiver_binding.let_stmt.is_mut);
    const place = receiver_binding.let_stmt.init;
    if (place != .unary_op or place.unary_op.op != .addr_of) return error.ExpectedReceiverIdentity;
    if (place.unary_op.operand.* != .field_access) return error.ExpectedReceiverIdentity;
    try std.testing.expectEqualStrings("inner", place.unary_op.operand.field_access.field_name);
    try std.testing.expectEqualStrings("holder", operandIdent(place.unary_op.operand.field_access.target.*) orelse
        return error.ExpectedReceiverIdentity);

    const value_binding = stmts[1];
    if (value_binding != .let_stmt) return error.ExpectedNativeByteBinding;
    _ = try hasherWriteCall(stmts[2], receiver_binding.let_stmt.name, value_binding.let_stmt.name);
}

// ── A reader parameter that names a generated binding ──────────────────────

/// Lower `fn drain(..) -> ()` calling `fill_buf` then `consume(1)` on a
/// `BufRead` receiver whose parameter is spelled `param` and is either the
/// handle itself or a value the frame has to bind.
fn bufReadPointerPackage(
    alloc: std.mem.Allocator,
    param: []const u8,
    borrowed_pointer: bool,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const drain = try addLowerEntity(&graph, .fn_, "drain", root);
    const reader_def = try addLowerEntity(&graph, .field, param, drain);
    const consume = try addLowerEntity(&graph, .method_ref, "consume", drain);
    const fill_buf = try addLowerEntity(&graph, .method_ref, "fill_buf", drain);

    const lexical: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "R", .id = null }},
    ) } };
    const byte_slice: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const bound: ir.types.Bound = .{ .path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
        .{ .name = "std", .id = null },
        .{ .name = "io", .id = null },
        .{ .name = "BufRead", .id = null },
    }) }, .args = &.{} };
    // 0: R, 1: the byte slice, 2: `&mut R`, 3: usize, 4: unit.
    const types = [_]ir.types.Type{
        lexical,
        byte_slice,
        .{ .reference = &.{ .mut = true, .pointee = lexical } },
        .{ .prim = .usize },
        .{ .prim = .unit },
    };

    const receiver = try typedExpr(&model, if (borrowed_pointer) 2 else 0, .{
        .path = .{ .def = reader_def, .generic_args = &.{} },
    });
    const one = try typedExpr(&model, 3, litInt(1));
    const consume_call = try typedExpr(&model, 4, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .mutable,
        .method = consume,
        .args = try alloc.dupe(ir.exprs.NodeId, &.{one}),
    } });
    const fill_call = try typedExpr(&model, 4, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .mutable,
        .method = fill_buf,
        .args = &.{},
    } });
    const body = try typedExpr(&model, 4, .{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{
            try model.stmt(.{ .expr = fill_call }),
            try model.stmt(.{ .expr = consume_call }),
        }),
        .tail = null,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[drain] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = param, .ty = types[if (borrowed_pointer) 2 else 0], .span = span }}),
        .ret = types[4],
        .generic_params = &.{"R"},
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "R",
            .bounds = try alloc.dupe(ir.types.Bound, &.{bound}),
        } }}), .where_clauses = &.{} },
        .body = body,
    } };
    try addBareCrate(&graph, alloc, "bufread_pointer", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{drain},
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "bufread_pointer",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// `&mut R` is the handle: the runtime helpers advance the reader through it,
// so the original pointer is what reaches them and not a value read out of it.
test "lower: a BufRead receiver that is already a pointer is forwarded to the runtime unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try bufReadPointerPackage(alloc, "reader", true);
    const decl = try findFnDecl(pkg.files[0], "drain");
    // `R` is emitted as a comptime type parameter of its own, so the SOURCE
    // parameter is the one beside it. Reading index 0 would compare the
    // runtime's reader argument against the generic's spelling.
    if (decl.params.len != 2) return error.ExpectedReceiverParameter;
    if (!decl.params[0].is_comptime or decl.params[1].is_comptime) return error.ExpectedReceiverParameter;
    const reader_param = decl.params[1];
    const stmts = try fnBodyStmts(decl);
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    var advanced: usize = 0;
    for (stmts) |stmt| {
        if (stmt != .expr_stmt or stmt.expr_stmt.* != .call) return error.ExpectedRuntimeCall;
        const call = stmt.expr_stmt.call;
        const callee = calleeName(call.callee.*) orelse return error.ExpectedRuntimeCall;
        if (!std.mem.startsWith(u8, callee, "r2z.io.")) return error.ExpectedRuntimeCall;
        // `fill_buf` hands back a view and takes the reader by address inside
        // its own expression; `consume` names the reader as its own argument,
        // and it is the one that proves nothing read out of the pointer.
        if (call.args.len != 2) continue;
        advanced += 1;
        if (call.args[0] != .ident) return error.ExpectedReceiverIdentity;
        try std.testing.expectEqualStrings(reader_param.name, call.args[0].ident);
    }
    try std.testing.expectEqual(@as(usize, 1), advanced);
}

/// The capture the `@typeInfo` guard a conditional reader copy is selected by
/// binds, or null when `expr` is not that guard.
///
/// The guard asks whether the receiver already IS a thin pointer, which only
/// reflection can answer, and it answers it in a capture the emitter mints.
/// That capture is the emitter's OWN binding: it shares a namespace with every
/// name the source wrote, so a source that already claimed the spelling is
/// exactly the case this name has to survive.
fn bufReadThinPointerCapture(expr: ast.Expr) ?[]const u8 {
    if (expr != .match_expr) return null;
    const guarded = expr.match_expr;
    if (guarded.target.* != .builtin) return null;
    if (!std.mem.eql(u8, guarded.target.builtin.name, "typeInfo")) return null;
    if (guarded.target.builtin.args.len != 1) return null;
    if (guarded.target.builtin.args[0] != .builtin) return null;
    if (!std.mem.eql(u8, guarded.target.builtin.args[0].builtin.name, "TypeOf")) return null;
    if (guarded.arms.len != 2) return null;
    const pointer = guarded.arms[0];
    if (pointer.patterns.len != 1) return null;
    if (pointer.patterns[0] != .enum_literal) return null;
    if (!std.mem.eql(u8, pointer.patterns[0].enum_literal, "pointer")) return null;
    return (pointer.capture orelse return null).name;
}

// A Rust parameter is allowed to be called anything, including the name the
// emitter wants to use for the binding it introduces. Reusing it would shadow
// the parameter and make the body read — and write — a different reader.
test "lower: a source parameter named like a generated reader binding is alpha-renamed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const reserved = "__r2z_bufread_pointer";
    const pkg = try bufReadPointerPackage(alloc, reserved, false);
    const decl = try findFnDecl(pkg.files[0], "drain");
    // `R` is emitted as a comptime type parameter of its own, so the SOURCE
    // parameter is the one beside it.
    if (decl.params.len != 2) return error.ExpectedReceiverParameter;
    if (!decl.params[0].is_comptime or decl.params[1].is_comptime) return error.ExpectedReceiverParameter;
    const reader_param = decl.params[1];

    // The frame owns the reader by value, so it binds it in the BODY, under the
    // name the source gave it. The signature keeps a name of its own: one
    // identifier cannot be both the parameter and the local that shadows it,
    // and a body reading that local would read — and write — a reader the
    // caller never passed.
    const stmts = try fnBodyStmts(decl);
    if (stmts.len != 3) return error.ExpectedReceiverBinding;
    const binding = stmts[0];
    if (binding != .let_stmt) return error.ExpectedReceiverBinding;
    try std.testing.expectEqualStrings(reserved, binding.let_stmt.name);
    try std.testing.expect(!std.mem.eql(u8, reader_param.name, binding.let_stmt.name));

    // The copy itself is CONDITIONAL, because a bare type parameter may
    // instantiate as a thin pointer and a thin pointer is already its own
    // handle: a copy of it would be a pointer to a pointer. So the pointer
    // instantiation's storage is void and every other one is the parameter
    // itself — the guard the sibling generic-reader scene pins.
    const selection = binding.let_stmt.init;
    if (selection != .if_expr) return error.ExpectedReceiverBinding;
    if (selection.if_expr.then_body.* != .unit) return error.ExpectedReceiverBinding;
    const otherwise = selection.if_expr.else_body orelse return error.ExpectedReceiverBinding;
    try std.testing.expectEqualStrings(reader_param.name, operandIdent(otherwise.*) orelse
        return error.ExpectedReceiverBinding);

    // And the guard's own capture is minted fresh: the source parameter has
    // already claimed the spelling the emitter wanted for it.
    const capture = bufReadThinPointerCapture(selection.if_expr.cond.*) orelse
        return error.ExpectedReceiverBinding;
    try std.testing.expect(std.mem.startsWith(u8, capture, reserved));
    try std.testing.expect(!std.mem.eql(u8, capture, reserved));
}

// ── A generic `H: core::hash::Hasher` and the hashers that answer it ────────

/// The source graph standing beside a `H: core::hash::Hasher` receiver.
///
/// Every scene retains the canonical bound and canonical method provenance.
/// The homonym scene also declares and implements a different local trait for
/// SeaHasher; that legal impl must never supply the canonical call.
const SourceHasherScene = enum {
    /// `impl core::hash::Hasher for SeaHasher` declaring `write_u64`, `write`
    /// and `finish`. The primitive write is the source's own answer.
    primitive_override,
    /// The same implementation WITHOUT the primitive write: the default bytes
    /// have to route through the `write` it does declare.
    byte_write_only,
    /// Canonical byte-write implementations coexist with a local Hasher trait
    /// whose genuine `write_u64` implementation must not hijack the default.
    local_trait_homonym,
};

/// Lower `pub fn digest<H: core::hash::Hasher>(state: &mut H, value: u64)`
/// whose only statement is `state.write_u64(value)`, beside two real hashers
/// and the two callers that instantiate the generic at each of them.
fn sourceHasherPackage(alloc: std.mem.Allocator, scene: SourceHasherScene) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const digest = try addLowerEntity(&graph, .fn_, "digest", root);
    const state_def = try addLowerEntity(&graph, .field, "state", digest);
    const value_def = try addLowerEntity(&graph, .field, "value", digest);

    var local_trait: ir.spine.EntityId = 0;
    if (scene == .local_trait_homonym)
        local_trait = try addLowerEntity(&graph, .trait_, "Hasher", root);
    // Like genericHasherPackage, this reference comes from the external
    // canonical trait, never from the crate-local homonym.
    const write_u64_ref = try addLowerEntity(&graph, .method_ref, "write_u64", digest);

    const sea = try addLowerEntity(&graph, .struct_, "SeaHasher", root);
    const checksum = try addLowerEntity(&graph, .struct_, "Checksum", root);
    const sea_impl = try addLowerEntity(&graph, .impl_, "Hasher for SeaHasher", sea);
    const checksum_impl = try addLowerEntity(&graph, .impl_, "Hasher for Checksum", checksum);
    const homonym_impl = if (scene == .local_trait_homonym)
        try addLowerEntity(&graph, .impl_, "Hasher for SeaHasher", sea)
    else
        0;
    const sea_write_u64 = if (scene == .primitive_override)
        try addLowerEntity(&graph, .fn_, "write_u64", sea_impl)
    else
        0;
    const sea_write = try addLowerEntity(&graph, .fn_, "write", sea_impl);
    const sea_finish = try addLowerEntity(&graph, .fn_, "finish", sea_impl);
    const checksum_write = try addLowerEntity(&graph, .fn_, "write", checksum_impl);
    const checksum_finish = try addLowerEntity(&graph, .fn_, "finish", checksum_impl);
    const homonym_write_u64 = if (scene == .local_trait_homonym)
        try addLowerEntity(&graph, .fn_, "write_u64", homonym_impl)
    else
        0;

    const sea_caller = try addLowerEntity(&graph, .fn_, "digest_sea", root);
    const checksum_caller = try addLowerEntity(&graph, .fn_, "digest_checksum", root);
    const sea_state = try addLowerEntity(&graph, .field, "state", sea_caller);
    const sea_value = try addLowerEntity(&graph, .field, "value", sea_caller);
    const checksum_state = try addLowerEntity(&graph, .field, "state", checksum_caller);
    const checksum_value = try addLowerEntity(&graph, .field, "value", checksum_caller);

    const lexical: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "H", .id = null }},
    ) } };
    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const bytes: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    // 0: H, 1: `&mut H`, 2: u64, 3: `SeaHasher`, 4: `&mut SeaHasher`,
    // 5: `Checksum`, 6: `&mut Checksum`, 7: `&[u8]`, 8: unit,
    // 9/10: the instantiation record each caller records.
    var types = [_]ir.types.Type{
        lexical,
        .{ .reference = &.{ .mut = true, .pointee = lexical } },
        u64_ty,
        .{ .path = .{ .segments = try alloc.dupe(
            ir.types.PathSegment,
            &.{.{ .name = "SeaHasher", .id = sea }},
        ) } },
        undefined,
        .{ .path = .{ .segments = try alloc.dupe(
            ir.types.PathSegment,
            &.{.{ .name = "Checksum", .id = checksum }},
        ) } },
        undefined,
        bytes,
        .{ .prim = .unit },
        undefined,
        undefined,
    };
    // The borrows and the instantiation records both name the hasher they are
    // about, so they are filled in after the table itself exists rather than
    // out of its own initializer.
    types[4] = .{ .reference = &.{ .mut = true, .pointee = types[3] } };
    types[6] = .{ .reference = &.{ .mut = true, .pointee = types[5] } };
    types[9] = .{ .generic_inst = .{
        .decl = digest,
        .args = .{ .params = try alloc.dupe(ir.types.Type, &.{types[3]}) },
    } };
    types[10] = .{ .generic_inst = .{
        .decl = digest,
        .args = .{ .params = try alloc.dupe(ir.types.Type, &.{types[5]}) },
    } };

    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = state_def, .generic_args = &.{} } });
    const value = try typedExpr(&model, 2, .{ .path = .{ .def = value_def, .generic_args = &.{} } });
    const call = try typedExpr(&model, 8, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .mutable,
        .method = write_u64_ref,
        .args = try alloc.dupe(ir.exprs.NodeId, &.{value}),
    } });
    const body = try typedExpr(&model, 8, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    // Each declared hasher method keeps the signature the trait gives it, so
    // the emitted file is a program a caller could actually have written.
    const unit_tail = try typedExpr(&model, 8, .{ .unit = {} });
    const zero_tail = try typedExpr(&model, 2, litInt(0));
    var caller_bodies: [2]ir.exprs.NodeId = undefined;
    const caller_specs = [_]struct {
        caller: ir.spine.EntityId,
        state: ir.spine.EntityId,
        value: ir.spine.EntityId,
        handle_type: ir.exprs.TypeId,
        record: ir.exprs.TypeId,
    }{
        .{ .caller = sea_caller, .state = sea_state, .value = sea_value, .handle_type = 4, .record = 9 },
        .{ .caller = checksum_caller, .state = checksum_state, .value = checksum_value, .handle_type = 6, .record = 10 },
    };
    for (caller_specs, 0..) |spec, index| {
        const left = try typedExpr(&model, spec.handle_type, .{
            .path = .{ .def = spec.state, .generic_args = &.{} },
        });
        const right = try typedExpr(&model, 2, .{ .path = .{ .def = spec.value, .generic_args = &.{} } });
        const site = try typedExpr(&model, spec.record, .{ .call = .{
            .call_kind = .{ .free = digest },
            .args = try alloc.dupe(ir.exprs.NodeId, &.{ left, right }),
        } });
        caller_bodies[index] = try typedExpr(&model, 8, .{ .block = .{
            .statements = &.{},
            .tail = site,
            .labelled = null,
        } });
    }

    const bound_segments: []const ir.types.PathSegment = &.{
        .{ .name = "core", .id = null },
        .{ .name = "hash", .id = null },
        .{ .name = "Hasher", .id = null },
    };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[digest] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "state", .ty = types[1], .span = span },
            .{ .name = "value", .ty = types[2], .span = span },
        }),
        .ret = types[8],
        .generic_params = &.{"H"},
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "H",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                bound_segments,
            ) } }}),
        } }}), .where_clauses = &.{} },
        .body = body,
    } };

    // Both hashers really implement `core::hash::Hasher`, and `finish` has NO
    // default in that trait: an implementation that declared only `write`
    // would not be a `Hasher` at all.
    const declared: []const struct { ir.spine.EntityId, ir.exprs.TypeId, ir.exprs.NodeId, ir.types.Type } = blk: {
        var list = std.ArrayListUnmanaged(struct {
            ir.spine.EntityId,
            ir.exprs.TypeId,
            ir.exprs.NodeId,
            ir.types.Type,
        }).empty;
        defer list.deinit(alloc);
        if (scene == .primitive_override) {
            try list.append(alloc, .{ sea_write_u64, 4, unit_tail, types[2] });
        }
        try list.append(alloc, .{ sea_write, 4, unit_tail, types[7] });
        try list.append(alloc, .{ sea_finish, 4, zero_tail, types[2] });
        try list.append(alloc, .{ checksum_write, 6, unit_tail, types[7] });
        try list.append(alloc, .{ checksum_finish, 6, zero_tail, types[2] });
        break :blk try list.toOwnedSlice(alloc);
    };
    var sea_methods: std.ArrayListUnmanaged(ir.bodies.StructMethod) = .empty;
    var checksum_methods: std.ArrayListUnmanaged(ir.bodies.StructMethod) = .empty;
    for (declared) |entry| {
        const entity = graph.symbol_table.get(entry[0]).?;
        const is_finish = std.mem.eql(u8, entity.name, "finish");
        // `finish` takes nothing beyond `self`; every other method takes the
        // bytes or the integer it is declared with.
        const params = try alloc.alloc(ir.items.Param, if (is_finish) 1 else 2);
        params[0] = .{
            .name = "self",
            .ty = if (is_finish)
                .{ .reference = &.{ .mut = false, .pointee = types[entry[1]].reference.pointee } }
            else
                types[entry[1]],
            .span = span,
        };
        if (!is_finish) params[1] = .{ .name = "bytes", .ty = entry[3], .span = span };
        body_rows[entry[0]] = .{ .fn_ = .{
            .params = params,
            .ret = if (is_finish) types[2] else types[8],
            .body = try typedExpr(&model, if (is_finish) 2 else 8, .{
                .block = .{ .statements = &.{}, .tail = entry[2], .labelled = null },
            }),
        } };
        const mirror: ir.bodies.StructMethod = .{
            .name = entity.name,
            .visibility = .public,
            .params = params[1..],
            .ret = body_rows[entry[0]].fn_.ret,
            .body = body_rows[entry[0]].fn_.body,
            .receiver = if (is_finish) .ref_ else .mut_ref,
        };
        if (entry[1] == 4)
            try sea_methods.append(alloc, mirror)
        else
            try checksum_methods.append(alloc, mirror);
    }

    const trait_path = ir.types.Path{ .segments = try alloc.dupe(ir.types.PathSegment, bound_segments) };
    body_rows[sea_impl] = .{ .impl_ = .{
        .self_ty = types[3],
        .trait_path = trait_path,
        .assoc_items = try alloc.dupe(ir.spine.EntityId, if (scene == .primitive_override)
            &.{ sea_write_u64, sea_write, sea_finish }
        else
            &.{ sea_write, sea_finish }),
    } };
    body_rows[checksum_impl] = .{ .impl_ = .{
        .self_ty = types[5],
        .trait_path = trait_path,
        .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{ checksum_write, checksum_finish }),
    } };
    if (scene == .local_trait_homonym) {
        body_rows[local_trait] = .{ .trait_ = .{
            .name = "Hasher",
            .methods = &.{.{
                .name = "write_u64",
                .params = &.{.{ .name = "value", .ty = types[2], .span = span }},
                .ret = types[8],
                .receiver = .mut_ref,
            }},
        } };
        body_rows[homonym_impl] = .{ .impl_ = .{
            .self_ty = types[3],
            .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{.{ .name = "Hasher", .id = local_trait }}) },
            .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{homonym_write_u64}),
        } };
        body_rows[homonym_write_u64] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "self", .ty = types[4], .span = span },
                .{ .name = "value", .ty = types[2], .span = span },
            }),
            .ret = types[8],
            .body = try typedExpr(&model, 8, .{ .block = .{
                .statements = &.{},
                .tail = unit_tail,
                .labelled = null,
            } }),
        } };
        try sea_methods.append(alloc, .{
            .name = "write_u64",
            .visibility = .public,
            .params = body_rows[homonym_write_u64].fn_.params[1..],
            .ret = types[8],
            .body = body_rows[homonym_write_u64].fn_.body,
            .receiver = .mut_ref,
        });
    }
    body_rows[sea] = .{ .struct_ = .{ .methods = try sea_methods.toOwnedSlice(alloc) } };
    body_rows[checksum] = .{ .struct_ = .{ .methods = try checksum_methods.toOwnedSlice(alloc) } };

    for (caller_specs, 0..) |spec, index| {
        body_rows[spec.caller] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "state", .ty = types[spec.handle_type], .span = span },
                .{ .name = "value", .ty = types[2], .span = span },
            }),
            .ret = types[8],
            .body = caller_bodies[index],
        } };
    }

    const items = try alloc.alloc(ir.spine.EntityId, if (scene == .local_trait_homonym) 9 else 8);
    items[0] = digest;
    items[1] = sea;
    items[2] = sea_impl;
    items[3] = checksum;
    items[4] = checksum_impl;
    items[5] = sea_caller;
    items[6] = checksum_caller;
    var item_count: usize = 7;
    if (scene == .local_trait_homonym) {
        items[item_count] = local_trait;
        item_count += 1;
        items[item_count] = homonym_impl;
        item_count += 1;
    }
    try addBareCrate(&graph, alloc, "source_hasher", root, items[0..item_count]);

    const rust_ir = ir.RustIr{
        .crate_name = "source_hasher",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// A `@compileError` carrying one message: the instantiation has no answer,
/// and saying so is the only honest emission.
fn expectCompileErrorRefusal(expr: ast.Expr) !void {
    if (expr != .builtin) return error.ExpectedCompileErrorRefusal;
    if (!std.mem.eql(u8, expr.builtin.name, "compileError")) return error.ExpectedCompileErrorRefusal;
    if (expr.builtin.args.len != 1 or expr.builtin.args[0] != .lit or expr.builtin.args[0].lit != .str)
        return error.ExpectedCompileErrorRefusal;
    if (expr.builtin.args[0].lit.str.len == 0) return error.ExpectedCompileErrorRefusal;
}

/// The refusal a receiver with no implementation ends in: a bare
/// `@compileError`, or the fallback arm of a chain that forwards what it can
/// first. Both answer the same question, and the chain is the better program
/// when it is there.
fn expectUnknownReceiverRefusal(expr: ast.Expr) !void {
    if (expr == .match_expr) {
        const guarded = expr.match_expr;
        if (guarded.arms.len == 0) return error.ExpectedCompileErrorRefusal;
        return expectCompileErrorRefusal(guarded.arms[guarded.arms.len - 1].body);
    }
    if (expr == .if_expr) {
        const otherwise = expr.if_expr.else_body orelse return error.ExpectedCompileErrorRefusal;
        return expectUnknownReceiverRefusal(otherwise.*);
    }
    return expectCompileErrorRefusal(expr);
}

// The generic is a contract only once real source reaches it. `digest_sea` and
// `digest_checksum` are two ordinary callers that instantiate it at the two
// hashers the crate really declares, and they are what makes the comptime
// branch something a compiler has to answer rather than something nobody asked.
test "lower: a generic Hasher is instantiated by the callers that parameterise the source's hashers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sourceHasherPackage(alloc, .primitive_override);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "comptime H: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "digest(SeaHasher, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "digest(Checksum, ") != null);
    // Both hashers really implement the canonical trait, so both have a `write`
    // to answer the default through.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "pub fn write("));
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn finish(") != null);
}

// The source's own primitive write is the answer the crate wrote down, and it
// wins only for the hasher it was written for. Everything else still gets the
// default bytes, which is why the default sits behind the selection.
test "lower: a generic Hasher prefers the source's primitive write to the default bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sourceHasherPackage(alloc, .primitive_override);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "digest"));
    var selection = body;
    while (selection == .if_expr and !isTypeSelection(selection.if_expr.cond.*, "H", "SeaHasher"))
        selection = (selection.if_expr.else_body orelse return error.ExpectedHasherTypeSelection).*;
    const branches = typeSelectionBranches(selection, "H", "SeaHasher") orelse
        return error.ExpectedHasherTypeSelection;
    if (branches[0] != .call) return error.ExpectedSourceOverride;
    try std.testing.expectEqualStrings("write_u64", calleeName(branches[0].call.callee.*) orelse
        return error.ExpectedSourceOverride);
    try std.testing.expectEqual(@as(usize, 1), branches[0].call.args.len);
    if (branches[0].call.callee.* != .field_access) return error.ExpectedSourceOverride;
    // The call is made on the hasher the source borrowed, which is the only
    // thing that can be a `Hasher` for this instantiation.
    try std.testing.expectEqualStrings("state", operandIdent(branches[0].call.callee.field_access.target.*) orelse
        return error.ExpectedSourceOverride);
    var otherwise = branches[1];
    while (otherwise == .if_expr)
        otherwise = (otherwise.if_expr.else_body orelse return error.ExpectedNativeByteDefault).*;
    if (otherwise != .block) return error.ExpectedNativeByteDefault;
    const fallback = otherwise.block;
    if (fallback.stmts.len != 2) return error.ExpectedNativeByteDefault;
    const binding = fallback.stmts[0];
    if (binding != .let_stmt) return error.ExpectedNativeByteBinding;
    _ = try hasherWriteCall(fallback.stmts[1], "state", binding.let_stmt.name);
}

// A hasher that declares only the byte-level `write` still owns the answer for
// its own type. Its `write_u64` has no source declaration, so the default goes
// through ITS `write` rather than through whatever `write_u64` the
// instantiation happens to expose.
test "lower: a generic Hasher routes the default bytes through the source's own write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sourceHasherPackage(alloc, .byte_write_only);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write_u64(") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "pub fn write("));
    // The bytes are still the value's own; only their destination changed.
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.asBytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "digest(SeaHasher, ") != null);
}

// A crate-local `trait Hasher` is a different trait that happens to share a
// name. Its implementation is a real declaration and still emits, but the
// canonical bound never promised it, so the canonical route must not reach it.
test "lower: a crate-local trait that shares the Hasher trait's name never answers it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try sourceHasherPackage(alloc, .local_trait_homonym);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "digest"));
    // Canonical source implementations remain selectable. Even for SeaHasher,
    // the local primitive method must not replace the canonical byte default.
    var selection = body;
    while (selection == .if_expr and !isTypeSelection(selection.if_expr.cond.*, "H", "SeaHasher"))
        selection = (selection.if_expr.else_body orelse return error.ExpectedHasherTypeSelection).*;
    const branches = typeSelectionBranches(selection, "H", "SeaHasher") orelse
        return error.ExpectedHasherTypeSelection;
    if (branches[0] != .block or branches[0].block.stmts.len != 2)
        return error.ExpectedNativeByteDefault;
    const binding = branches[0].block.stmts[0];
    if (binding != .let_stmt or binding.let_stmt.ty == null or binding.let_stmt.ty.? != .prim)
        return error.ExpectedNativeByteBinding;
    try std.testing.expectEqual(ast.Prim.u64, binding.let_stmt.ty.?.prim);
    _ = try hasherWriteCall(branches[0].block.stmts[1], "state", binding.let_stmt.name);
    var fallback = branches[1];
    while (fallback == .if_expr)
        fallback = (fallback.if_expr.else_body orelse return error.ExpectedNativeByteDefault).*;
    if (fallback != .block or fallback.block.stmts.len != 2)
        return error.ExpectedNativeByteDefault;
    const fallback_binding = fallback.block.stmts[0];
    if (fallback_binding != .let_stmt) return error.ExpectedNativeByteBinding;
    _ = try hasherWriteCall(fallback.block.stmts[1], "state", fallback_binding.let_stmt.name);

    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write_u64(") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "pub fn write("));
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.asBytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "state.write_u64(") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "SeaHasher.write_u64(") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "allocator:") == null);
    try std.testing.expectEqual(@as(usize, 0), runtimeImportCount(pkg.files[0]));
}

// ── The `write_N` core tag: the source override, then the default ──────────

/// What the source declares beside a `Hasher::write_N` core tag.
const PrimitiveTagScene = enum {
    /// Nothing: the default writes the value's own bytes and that is all.
    none,
    /// This primitive override beside the trait's required `write` and `finish`.
    primitive_override,
    /// No primitive override: the default routes through required `write`.
    byte_write_only,
};

/// Lower `fn record(state: SeaHasher, value: P)` whose only statement is the
/// `write_N` core tag for the primitive `primitive`.
fn hasherPrimitiveTagPackage(
    alloc: std.mem.Allocator,
    primitive: ir.types.Prim,
    scene: PrimitiveTagScene,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const record = try addLowerEntity(&graph, .fn_, "record", root);
    const state_def = try addLowerEntity(&graph, .field, "state", record);
    const value_def = try addLowerEntity(&graph, .field, "value", record);
    const sea = try addLowerEntity(&graph, .struct_, "SeaHasher", root);

    const unit: ir.types.Type = .{ .prim = .unit };
    const primitive_ty: ir.types.Type = .{ .prim = primitive };
    const bytes: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const sea_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "SeaHasher", .id = sea }},
    ) } };
    // 0: the primitive, 1: `SeaHasher`, 2: `&mut SeaHasher`, 3: unit,
    // 4: the borrowed bytes a `write` takes, 5: finish's u64.
    const types = [_]ir.types.Type{
        primitive_ty,
        sea_ty,
        .{ .reference = &.{ .mut = true, .pointee = sea_ty } },
        unit,
        bytes,
        .{ .prim = .u64 },
    };

    var impl_id: ir.spine.EntityId = 0;
    var declared: ir.spine.EntityId = 0;
    var required_write: ir.spine.EntityId = 0;
    var finish: ir.spine.EntityId = 0;
    if (scene != .none) {
        impl_id = try addLowerEntity(&graph, .impl_, "Hasher for SeaHasher", sea);
        declared = try addLowerEntity(&graph, .fn_, if (scene == .primitive_override)
            try std.fmt.allocPrint(alloc, "write_{s}", .{@tagName(primitive)})
        else
            "write", impl_id);
        required_write = if (scene == .primitive_override)
            try addLowerEntity(&graph, .fn_, "write", impl_id)
        else
            declared;
        finish = try addLowerEntity(&graph, .fn_, "finish", impl_id);
    }

    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = state_def, .generic_args = &.{} } });
    const value = try typedExpr(&model, 0, .{ .path = .{ .def = value_def, .generic_args = &.{} } });
    const call = try typedExpr(&model, 3, .{ .core_call = .{
        .function = .hash_write_primitive,
        .generic_args = try alloc.dupe(ir.types.Type, &.{primitive_ty}),
        .args = try alloc.dupe(ir.exprs.NodeId, &.{ receiver, value }),
    } });
    const body = try typedExpr(&model, 3, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    var declared_body: ir.exprs.NodeId = 0;
    if (scene != .none) {
        declared_body = try typedExpr(&model, 3, .{ .block = .{
            .statements = &.{},
            .tail = try typedExpr(&model, 3, .{ .unit = {} }),
            .labelled = null,
        } });
    }

    const params = try alloc.dupe(ir.items.Param, &.{
        .{ .name = "state", .ty = types[1], .span = span },
        .{ .name = "value", .ty = types[0], .span = span },
    });
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[record] = .{ .fn_ = .{
        .params = params,
        .ret = unit,
        .body = body,
    } };
    // `struct SeaHasher;` in the scene that declares no `Hasher` impl: a unit
    // struct, which is what the frontend records for a declaration with no
    // field list. The type still has to exist — it is the receiver's own.
    body_rows[sea] = .{ .struct_ = .{ .layout = .unit } };
    if (scene != .none) {
        // The declared method keeps the signature the trait gives it: the
        // primitive write takes that integer, `write` takes borrowed bytes.
        body_rows[declared] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "self", .ty = types[2], .span = span },
                .{ .name = "bytes", .ty = if (scene == .primitive_override) types[0] else types[4], .span = span },
            }),
            .ret = unit,
            .body = declared_body,
        } };
        if (required_write != declared) body_rows[required_write] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "self", .ty = types[2], .span = span },
                .{ .name = "bytes", .ty = types[4], .span = span },
            }),
            .ret = unit,
            .body = declared_body,
        } };
        body_rows[finish] = .{ .fn_ = .{
            .params = &.{.{ .name = "self", .ty = .{ .reference = &.{ .mut = false, .pointee = sea_ty } }, .span = span }},
            .ret = types[5],
            .body = try typedExpr(&model, 5, .{ .block = .{
                .statements = &.{},
                .tail = try typedExpr(&model, 5, litInt(0)),
                .labelled = null,
            } }),
        } };
        const methods: []const ir.spine.EntityId = if (required_write == declared)
            &.{ declared, finish }
        else
            &.{ declared, required_write, finish };
        const mirrors = try alloc.alloc(ir.bodies.StructMethod, methods.len);
        for (methods, 0..) |method_id, index| {
            const method_fn = body_rows[method_id].fn_;
            mirrors[index] = .{
                .name = graph.symbol_table.get(method_id).?.name,
                .visibility = .public,
                .params = method_fn.params[1..],
                .ret = method_fn.ret,
                .body = method_fn.body,
                .receiver = if (method_id == finish) .ref_ else .mut_ref,
            };
        }
        body_rows[sea] = .{ .struct_ = .{ .layout = .unit, .methods = mirrors } };
        body_rows[impl_id] = .{ .impl_ = .{
            .self_ty = types[1],
            .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
                .{ .name = "core", .id = null },
                .{ .name = "hash", .id = null },
                .{ .name = "Hasher", .id = null },
            }) },
            .assoc_items = try alloc.dupe(ir.spine.EntityId, methods),
        } };
    }

    const items = try alloc.alloc(ir.spine.EntityId, 3);
    items[0] = record;
    items[1] = sea;
    items[2] = impl_id;
    try addBareCrate(
        &graph,
        alloc,
        "hasher_primitive_tag",
        root,
        items[0..(if (scene == .none) @as(usize, 2) else 3)],
    );

    const rust_ir = ir.RustIr{
        .crate_name = "hasher_primitive_tag",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// The primitive the tag names is the primitive that is written. A `usize`
// value is pointer-sized and a `u64` value is not, so binding the value at
// anything but its own type hands the hasher a different number of bytes on a
// different target — a program that compiles and computes the wrong value.
test "lower: the primitive write tag binds its value at the exact primitive it was asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for ([_]ir.types.Prim{ .u8, .u64, .usize, .i32 }) |primitive| {
        const pkg = try hasherPrimitiveTagPackage(alloc, primitive, .none);
        const stmts = try fnBodyStmts(try findFnDecl(pkg.files[0], "record"));
        try std.testing.expectEqual(@as(usize, 2), stmts.len);
        const binding = stmts[0];
        if (binding != .let_stmt) return error.ExpectedNativeByteBinding;
        if (binding.let_stmt.ty == null or binding.let_stmt.ty.? != .prim)
            return error.ExpectedNativeByteBinding;
        try std.testing.expectEqual(
            @as(ast.Prim, @field(ast.Prim, @tagName(primitive))),
            binding.let_stmt.ty.?.prim,
        );
        // `std.mem.asBytes` is handed the ADDRESS of that binding, so the bytes
        // are the value's own and exactly as wide as it is.
        _ = try hasherWriteCall(stmts[1], "state", binding.let_stmt.name);

        const source = try emit.emitFile(alloc, &pkg.files[0]);
        try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.asBytes") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "Endian") == null);
    }
}

// The source's own primitive write is the answer the crate wrote down, so the
// default bytes are not reached at all for that hasher. The default belongs to
// the hasher types the source never claimed.
test "lower: the primitive write tag prefers the source's own override to the default bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try hasherPrimitiveTagPackage(alloc, .u64, .primitive_override);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write_u64(") != null);
    // The override replaces the default rather than preceding it: a file that
    // still writes the raw bytes would hash two things.
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.asBytes") == null);
}

// A source that declares only the byte-level `write` still owns the answer for
// its own hasher: the default bytes go through ITS declaration rather than
// through whatever `write` the instantiation happens to expose.
test "lower: the primitive write tag routes through the source's byte write when it declares no primitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try hasherPrimitiveTagPackage(alloc, .u64, .byte_write_only);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write_u64(") == null);
    // The bytes are still the value's own; only their destination changed.
    try std.testing.expect(std.mem.indexOf(u8, source, "std.mem.asBytes") != null);
}

// With nothing in the source to claim the answer, nothing in the emitted file
// may claim a `write` the crate never declared.
test "lower: the primitive write tag invents no hasher method of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try hasherPrimitiveTagPackage(alloc, .u64, .none);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write(") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn write_u64(") == null);
    try std.testing.expectEqual(@as(usize, 0), runtimeImportCount(pkg.files[0]));
}

// ── A generic `T: core::hash::Hash` hashing into a generic `H: Hasher` ───────

/// What the source declares beside a `T: core::hash::Hash` receiver.
const GenericHashScene = enum {
    /// Nothing: every instantiation is a primitive, and an unknown one is
    /// refused.
    no_source_hash,
    /// `impl core::hash::Hash for Bytes { fn hash(&self, state: &mut SeaHasher) }`
    /// forwarding to the hasher's own `write`.
    source_hash_forwards_write,
    /// The same implementation answering with an exact primitive write instead.
    source_hash_exact_write,
};

/// One primitive a generic `Hash` receiver can forward.
const HashPrimitiveCase = struct {
    /// The Rust primitive the source names, and the exact identity the
    /// descriptor's `scalar` tag has to carry for it.
    ir: ir.types.Prim,
    /// The Zig type the descriptor carries for it. `lowerPrim` spells Rust's
    /// `char` as `u21`; every other primitive keeps its own name.
    zig: ast.Prim,
};

/// The primitives a generic `Hash` receiver can forward.
const hash_primitive_cases = [_]HashPrimitiveCase{
    .{ .ir = .u8, .zig = .u8 },
    .{ .ir = .u64, .zig = .u64 },
    .{ .ir = .usize, .zig = .usize },
    .{ .ir = .i32, .zig = .i32 },
    .{ .ir = .bool, .zig = .bool },
    // `char` is a 32-bit code point in Rust and a `u21` in Zig, so the runtime
    // type it reaches through is `u21` while the tag stays `char`.
    .{ .ir = .char, .zig = .u21 },
};

/// Lower `pub fn hash_of<T: core::hash::Hash, H: core::hash::Hasher>(value: &T,
/// state: &mut H) -> u64` whose only statement is `value.hash(state)`, beside a
/// real `SeaHasher`, a real `Bytes` that implements `Hash`, and the callers that
/// instantiate the generic at each primitive.
fn genericHashPackage(alloc: std.mem.Allocator, scene: GenericHashScene) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "hash_of", root);
    const value_def = try addLowerEntity(&graph, .field, "value", callable);
    const state_def = try addLowerEntity(&graph, .field, "state", callable);
    const hash_ref = try addLowerEntity(&graph, .method_ref, "hash", callable);
    // `Hash::hash` returns nothing, so the wrapper that returns `u64` finishes
    // the hasher itself. That is what puts the dispatch in statement position
    // and leaves `finish` as the body tail.
    const finish_ref = try addLowerEntity(&graph, .method_ref, "finish", callable);

    // `struct SeaHasher;` is a unit nominal, and its `Hasher` implementation is
    // parented to it: the shape `finalizePendingImpls` leaves behind, where the
    // impl's methods are recorded on the struct's own body and the struct renders
    // them rather than the module hoisting them beside it.
    const sea = try addLowerEntity(&graph, .struct_, "SeaHasher", root);
    const sea_impl = try addLowerEntity(&graph, .impl_, "Hasher for SeaHasher", sea);
    const sea_write = try addLowerEntity(&graph, .fn_, "write", sea_impl);
    // The primitive write is in the crate only in the scene whose `Hash`
    // implementation names it. An absent method stays absent rather than leaving
    // a reference with nothing declared behind it.
    const sea_write_u64 = if (scene == .source_hash_exact_write)
        try addLowerEntity(&graph, .fn_, "write_u64", sea_impl)
    else
        0;
    const sea_finish = try addLowerEntity(&graph, .fn_, "finish", sea_impl);

    // `struct Bytes { data: &'static [u8], tag: u64 }` — the value whose own
    // `Hash` implementation the scenes write, and whose fields are what that
    // implementation forwards.
    const bytes = try addLowerEntity(&graph, .struct_, "Bytes", root);
    const data_field = try addLowerEntity(&graph, .field, "data", bytes);
    const tag_field = try addLowerEntity(&graph, .field, "tag", bytes);

    // `impl core::hash::Hash for Bytes`, parented to the MODULE rather than to
    // `Bytes`, so `hash` hoists to module scope and its call hands the receiver
    // over BY ADDRESS ahead of the source arguments. The `no_source_hash` scene
    // declares no implementation at all, and therefore no method with it.
    var bytes_impl: ir.spine.EntityId = 0;
    var bytes_hash: ir.spine.EntityId = 0;
    var hash_self: ir.spine.EntityId = 0;
    var hash_state: ir.spine.EntityId = 0;
    var write_ref: ir.spine.EntityId = 0;
    var write_u64_ref: ir.spine.EntityId = 0;
    if (scene != .no_source_hash) {
        bytes_impl = try addLowerEntity(&graph, .impl_, "Hash for Bytes", root);
        bytes_hash = try addLowerEntity(&graph, .fn_, "hash", bytes_impl);
        hash_self = try addLowerEntity(&graph, .field, "self", bytes_hash);
        hash_state = try addLowerEntity(&graph, .field, "state", bytes_hash);
        write_ref = try addLowerEntity(&graph, .method_ref, "write", bytes_hash);
        write_u64_ref = try addLowerEntity(&graph, .method_ref, "write_u64", bytes_hash);
    }

    var caller_ids: [hash_primitive_cases.len]ir.spine.EntityId = undefined;
    var caller_value: [hash_primitive_cases.len]ir.exprs.NodeId = undefined;
    var caller_state: [hash_primitive_cases.len]ir.exprs.NodeId = undefined;
    for (hash_primitive_cases, 0..) |case, index| {
        caller_ids[index] = try addLowerEntity(&graph, .fn_, try std.fmt.allocPrint(
            alloc,
            "hash_{s}",
            .{@tagName(case.ir)},
        ), root);
        caller_value[index] = try addLowerEntity(&graph, .field, "value", caller_ids[index]);
        caller_state[index] = try addLowerEntity(&graph, .field, "state", caller_ids[index]);
    }

    const lexical_t: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "T", .id = null }},
    ) } };
    const lexical_h: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "H", .id = null }},
    ) } };
    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const bytes_ty: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const sea_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "SeaHasher", .id = sea }},
    ) } };
    const bytes_ty_nominal: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "Bytes", .id = bytes }},
    ) } };
    // 0: T, 1: `&T`, 2: H, 3: `&mut H`, 4: u64, 5: `SeaHasher`, 6: `&mut
    // SeaHasher`, 7: `Bytes`, 8: `&Bytes`, 9: `&[u8]`, 10: unit, 11: `&SeaHasher`
    // — the receiver `finish` is declared over — and from 12 one borrowed
    // primitive plus one instantiation record per caller.
    const caller_type_count = 2 * hash_primitive_cases.len;
    var types = [_]ir.types.Type{
        lexical_t,
        .{ .reference = &.{ .mut = false, .pointee = lexical_t } },
        lexical_h,
        .{ .reference = &.{ .mut = true, .pointee = lexical_h } },
        u64_ty,
        sea_ty,
        .{ .reference = &.{ .mut = true, .pointee = sea_ty } },
        bytes_ty_nominal,
        .{ .reference = &.{ .mut = false, .pointee = bytes_ty_nominal } },
        bytes_ty,
        .{ .prim = .unit },
        .{ .reference = &.{ .mut = false, .pointee = sea_ty } },
    } ++ ([_]ir.types.Type{.{ .prim = .u8 }} ** caller_type_count);

    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = value_def, .generic_args = &.{} } });
    const state = try typedExpr(&model, 3, .{ .path = .{ .def = state_def, .generic_args = &.{} } });
    const call = try typedExpr(&model, 4, .{
        .method_call = .{
            .receiver = receiver,
            .receiver_mode = .shared,
            .method = hash_ref,
            .args = try alloc.dupe(ir.exprs.NodeId, &.{state}),
            // `Hash::hash<H: Hasher>` names its own parameter, and `state` is the
            // argument that fills it.
            .generic_args = try alloc.dupe(ir.types.Type, &.{lexical_h}),
        },
    });
    // `Hash::hash` returns nothing, so a wrapper that returns `u64` does it in
    // two statements and finishes the hasher once at the end. That is what puts
    // the dispatch in STATEMENT position and leaves `finish` as the body tail.
    const finish_call = try typedExpr(&model, 4, .{ .method_call = .{
        .receiver = state,
        .receiver_mode = .mutable,
        .method = finish_ref,
        .args = &.{},
    } });
    const body = try typedExpr(&model, 4, .{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{try model.stmt(.{ .expr = call })}),
        .tail = finish_call,
        .labelled = null,
    } });

    var caller_bodies: [hash_primitive_cases.len]ir.exprs.NodeId = undefined;
    for (hash_primitive_cases, 0..) |case, index| {
        const wide = try alloc.create(ir.types.Type);
        wide.* = .{ .prim = case.ir };
        const wide_ref = try alloc.create(ir.types.Ref);
        wide_ref.* = .{ .mut = false, .pointee = wide.* };
        types[12 + 2 * index] = .{ .reference = wide_ref };
        types[13 + 2 * index] = .{ .generic_inst = .{
            .decl = callable,
            .args = .{ .params = try alloc.dupe(ir.types.Type, &.{ wide.*, types[5] }) },
        } };
        const left = try typedExpr(&model, @intCast(12 + 2 * index), .{
            .path = .{ .def = caller_value[index], .generic_args = &.{} },
        });
        const right = try typedExpr(&model, 6, .{
            .path = .{ .def = caller_state[index], .generic_args = &.{} },
        });
        const site = try typedExpr(&model, @intCast(13 + 2 * index), .{ .call = .{
            .call_kind = .{ .free = callable },
            .args = try alloc.dupe(ir.exprs.NodeId, &.{ left, right }),
        } });
        caller_bodies[index] = try typedExpr(&model, 4, .{ .block = .{
            .statements = &.{},
            .tail = site,
            .labelled = null,
        } });
    }

    const unit_tail = try typedExpr(&model, 10, .{ .unit = {} });
    const zero_tail = try typedExpr(&model, 4, litInt(0));
    // `Bytes::hash<H: Hasher>` takes the SAME hasher parameter the trait names;
    // it cannot specialise it, and it returns nothing.
    var bytes_body: ir.exprs.NodeId = 0;
    if (scene != .no_source_hash) {
        const state_read = try typedExpr(&model, 3, .{ .path = .{
            .def = hash_state,
            .generic_args = &.{},
        } });
        // The value the source forwards is the receiver's OWN storage, read off
        // the `&Bytes` the trait hands it: the bytes for the `write` scene, the
        // tag for the exact-primitive one. Both `Hasher` methods take exactly ONE
        // value, so a call that passed nothing was never a call the trait's own
        // signature admits.
        const exact = scene == .source_hash_exact_write;
        const payload = try typedExpr(&model, if (exact) 4 else 9, .{ .field = .{
            .base = try typedExpr(&model, 8, .{ .path = .{
                .def = hash_self,
                .generic_args = &.{},
            } }),
            .field = if (exact) "tag" else "data",
            .resolved = if (exact) tag_field else data_field,
        } });
        bytes_body = try typedExpr(&model, 10, .{ .block = .{
            .statements = &.{},
            .tail = try typedExpr(&model, 10, .{ .method_call = .{
                .receiver = state_read,
                .receiver_mode = .mutable,
                .method = if (exact) write_u64_ref else write_ref,
                .args = try alloc.dupe(ir.exprs.NodeId, &.{payload}),
            } }),
            .labelled = null,
        } });
    }

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "value", .ty = types[1], .span = span },
            .{ .name = "state", .ty = types[3], .span = span },
        }),
        .ret = types[4],
        .generic_params = &.{ "T", "H" },
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{
            .{ .type_ = .{
                .name = "T",
                .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                    ir.types.PathSegment,
                    &.{
                        .{ .name = "core", .id = null },
                        .{ .name = "hash", .id = null },
                        .{ .name = "Hash", .id = null },
                    },
                ) } }}),
            } },
            .{ .type_ = .{
                .name = "H",
                .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                    ir.types.PathSegment,
                    &.{
                        .{ .name = "core", .id = null },
                        .{ .name = "hash", .id = null },
                        .{ .name = "Hasher", .id = null },
                    },
                ) } }}),
            } },
        }), .where_clauses = &.{} },
        .body = body,
    } };
    // `Bytes` declares the fields the source's own `Hash` implementation reads,
    // so the emitted type carries them whether or not a scene writes that
    // implementation. A named struct with fields is not a unit one, and saying
    // otherwise would describe a type the source never declared.
    body_rows[bytes] = .{ .struct_ = .{
        .fields = try alloc.dupe(ir.items.Field, &.{
            .{ .name = "data", .ty = types[9], .visibility = .public, .span = span },
            .{ .name = "tag", .ty = types[4], .visibility = .public, .span = span },
        }),
    } };
    body_rows[sea_write] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "self", .ty = types[6], .span = span },
            .{ .name = "bytes", .ty = types[9], .span = span },
        }),
        .ret = types[10],
        .body = try typedExpr(&model, 10, .{ .block = .{
            .statements = &.{},
            .tail = unit_tail,
            .labelled = null,
        } }),
    } };
    body_rows[sea_finish] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "self", .ty = types[11], .span = span },
        }),
        .ret = types[4],
        .body = try typedExpr(&model, 4, .{ .block = .{
            .statements = &.{},
            .tail = zero_tail,
            .labelled = null,
        } }),
    } };
    // `core::hash::Hasher::write_uN(&mut self, value: uN)` is a real method over
    // a real value, not a tag: it takes the integer the trait names.
    if (scene == .source_hash_exact_write) {
        body_rows[sea_write_u64] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "self", .ty = types[6], .span = span },
                .{ .name = "value", .ty = types[4], .span = span },
            }),
            .ret = types[10],
            .body = try typedExpr(&model, 10, .{ .block = .{
                .statements = &.{},
                .tail = unit_tail,
                .labelled = null,
            } }),
        } };
    }
    // The impl's own methods, recorded on the struct body the way
    // `finalizePendingImpls` records them: same name, same signature without the
    // receiver, same body node. That record is what makes the struct render them
    // itself instead of leaving a unit nominal beside hoisted free functions.
    var sea_method_ids: std.ArrayListUnmanaged(ir.spine.EntityId) = .empty;
    if (scene == .source_hash_exact_write) try sea_method_ids.append(alloc, sea_write_u64);
    try sea_method_ids.append(alloc, sea_write);
    try sea_method_ids.append(alloc, sea_finish);
    var sea_methods: std.ArrayListUnmanaged(ir.bodies.StructMethod) = .empty;
    for (sea_method_ids.items) |method_id| {
        const method = body_rows[method_id].fn_;
        try sea_methods.append(alloc, .{
            .name = graph.symbol_table.get(method_id).?.name,
            .visibility = .public,
            .params = method.params[1..],
            .ret = method.ret,
            .body = method.body,
            // `finish` is the one method `Hasher` declares over `&self`; both
            // writes are over `&mut self`.
            .receiver = if (method_id == sea_finish) .ref_ else .mut_ref,
        });
    }
    body_rows[sea] = .{ .struct_ = .{
        .layout = .unit,
        .methods = try sea_methods.toOwnedSlice(alloc),
    } };
    body_rows[sea_impl] = .{ .impl_ = .{
        .self_ty = types[5],
        .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
            .{ .name = "core", .id = null },
            .{ .name = "hash", .id = null },
            .{ .name = "Hasher", .id = null },
        }) },
        .assoc_items = try sea_method_ids.toOwnedSlice(alloc),
    } };
    if (scene != .no_source_hash) {
        // `impl core::hash::Hash for Bytes` names the trait it implements and the
        // type it answers for. That body is the only thing the source override is
        // found through — `blanketImplMethod` walks `assoc_items`, and the impl
        // loop in `lowerGenericSourceMethodCall` reads `trait_path` — so without
        // it the crate declares no `Hash` implementation at all and the scene
        // lowers to the primitive chain alone.
        body_rows[bytes_impl] = .{ .impl_ = .{
            .self_ty = types[7],
            .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
                .{ .name = "core", .id = null },
                .{ .name = "hash", .id = null },
                .{ .name = "Hash", .id = null },
            }) },
            .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{bytes_hash}),
        } };
        // `core::hash::Hash::hash<H: Hasher>(&self, state: &mut H)` returns
        // nothing, and the implementation names its own `H` because that is the
        // signature the trait declares.
        body_rows[bytes_hash] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "self", .ty = types[8], .span = span },
                .{ .name = "state", .ty = types[3], .span = span },
            }),
            .ret = types[10],
            .generic_params = &.{"H"},
            .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
                .name = "H",
                .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                    ir.types.PathSegment,
                    &.{
                        .{ .name = "core", .id = null },
                        .{ .name = "hash", .id = null },
                        .{ .name = "Hasher", .id = null },
                    },
                ) } }}),
            } }}), .where_clauses = &.{} },
            .body = bytes_body,
        } };
    }
    for (hash_primitive_cases, 0..) |_, index| {
        body_rows[caller_ids[index]] = .{ .fn_ = .{
            .params = try alloc.dupe(ir.items.Param, &.{
                .{ .name = "value", .ty = types[12 + 2 * index], .span = span },
                .{ .name = "state", .ty = types[6], .span = span },
            }),
            .ret = types[4],
            .body = caller_bodies[index],
        } };
    }

    // The crate's own items are the wrapper, the hasher and its `Hasher` impl,
    // the hashed type, one caller per primitive case, and — for every scene
    // but `no_source_hash` — the `Hash` impl the source wrote. The list is
    // built by appending because its length is the caller count PLUS that
    // impl, and sizing the storage from the callers alone left the last write
    // one past the end.
    var item_list: std.ArrayListUnmanaged(ir.spine.EntityId) = .empty;
    try item_list.appendSlice(alloc, &.{ callable, sea, sea_impl, bytes });
    try item_list.appendSlice(alloc, &caller_ids);
    if (scene != .no_source_hash) try item_list.append(alloc, bytes_impl);
    try addBareCrate(&graph, alloc, "generic_hash", root, item_list.items);

    const rust_ir = ir.RustIr{
        .crate_name = "generic_hash",
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

// A crate's own `Hash` implementation is the answer the source wrote down, so
// what a consumer of it is owed is the boundary it is reached through: the
// implementation keeps the trait's own hasher parameter, the storage it reads
// keeps the types the source declared, and a receiver nobody implemented fails
// to compile rather than being answered by an accident of the descriptor.
test "lower: a generic Hash receiver keeps the source's own Hash implementation reachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try genericHashPackage(alloc, .source_hash_forwards_write);

    // `impl Hash for Bytes` is published with the trait's OWN hasher parameter:
    // it cannot specialise `H`, because the answer it gives has to be the same
    // implementation for every instantiation the generic reaches. A hasher
    // pinned to one type here would leave every other `T` unhashable.
    const implementation = try findFnDecl(pkg.files[0], "hash");
    // A lowered free function declares its type parameters as `comptime`
    // parameters — the very `comptime H: type` a call site spells — so the
    // hasher parameter the trait names is read there.
    const implementation_generics = try comptimeTypeParams(alloc, implementation);
    try std.testing.expectEqual(@as(usize, 1), implementation_generics.len);
    try std.testing.expectEqualStrings("H", implementation_generics[0]);

    // The storage that implementation reads is the storage the source declared,
    // at the types it declared: what a consumer ends up hashing is a real
    // borrowed byte view and a real `u64`, not a descriptor the source never
    // wrote and not a by-value copy that aliased the owner's own allocation.
    const hashed = try findStructDecl(pkg.files[0], "Bytes");
    var bytes_view: ?ast.Type = null;
    var bytes_tag: ?ast.Type = null;
    for (hashed.fields) |field| {
        if (std.mem.eql(u8, field.name, "data")) bytes_view = field.ty;
        if (std.mem.eql(u8, field.name, "tag")) bytes_tag = field.ty;
    }
    const view = bytes_view orelse return error.MissingHashedStorage;
    if (view != .slice) return error.ExpectedHashedStorageAbi;
    try std.testing.expect(view.slice.is_const);
    if (view.slice.elem.* != .prim) return error.ExpectedHashedStorageAbi;
    try std.testing.expectEqual(ast.Prim.u8, view.slice.elem.prim);
    const tag = bytes_tag orelse return error.MissingHashedStorage;
    if (tag != .prim) return error.ExpectedHashedStorageAbi;
    try std.testing.expectEqual(ast.Prim.u64, tag.prim);

    // A receiver nobody implemented is REFUSED where the walk switches on the
    // layout, with a compile error and a message, rather than hashed by an
    // integer default no `Hash` implementation ever wrote.
    try expectUnknownReceiverRefusal(try derivedWalkOf((try hashPairIn(pkg.files[0])).value));
}

// An implementation the crate wrote does not have to stop at `write`: when it
// names an exact primitive write, the hasher is still reached through the ONE
// boundary `core::hash::Hasher` declares, and that boundary is what a consumer
// implements. Each method keeps the trait's own parameter type, so what the
// implementation hands over is exactly what the consumer's method receives.
test "lower: the hasher a source Hash implementation writes through keeps the trait's own ABI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try genericHashPackage(alloc, .source_hash_exact_write);

    // `write` takes the borrowed bytes and nothing else. `write_u64` takes the
    // integer ITSELF — not a pointer to it and not a `usize`, which is the one
    // value a Rust `Hash` implementation holding a `u64` field can forward.
    // `finish` takes no value at all and answers `u64`.
    const hasher = try findStructDecl(pkg.files[0], "SeaHasher");
    // A Zig member keeps the receiver, so what the trait declares is everything
    // AFTER it — and that receiver is a pointer to the hasher the source wrote.
    const byte_write = try findStructMethod(hasher, "write");
    try expectHasherReceiver(byte_write, "SeaHasher");
    const byte_write_params = traitParamsOf(byte_write);
    try std.testing.expectEqual(@as(usize, 1), byte_write_params.len);
    if (byte_write_params[0].ty != .slice) return error.ExpectedByteWriteAbi;
    try std.testing.expect(byte_write_params[0].ty.slice.is_const);
    if (byte_write_params[0].ty.slice.elem.* != .prim) return error.ExpectedByteWriteAbi;
    try std.testing.expectEqual(ast.Prim.u8, byte_write_params[0].ty.slice.elem.prim);
    const primitive_write = try findStructMethod(hasher, "write_u64");
    try expectHasherReceiver(primitive_write, "SeaHasher");
    const primitive_write_params = traitParamsOf(primitive_write);
    try std.testing.expectEqual(@as(usize, 1), primitive_write_params.len);
    if (primitive_write_params[0].ty != .prim) return error.ExpectedPrimitiveWriteAbi;
    try std.testing.expectEqual(ast.Prim.u64, primitive_write_params[0].ty.prim);
    const finished = try findStructMethod(hasher, "finish");
    try expectHasherReceiver(finished, "SeaHasher");
    try std.testing.expectEqual(@as(usize, 0), traitParamsOf(finished).len);
    if (finished.ret_type != .prim) return error.ExpectedFinishAbi;
    try std.testing.expectEqual(ast.Prim.u64, finished.ret_type.prim);

    // The exact primitive write is reachable from OUTSIDE the package only
    // because it is a method of the hasher the source declared. A scene whose
    // implementation stops at `write` publishes no such method at all, so the
    // one above is the source's own answer and not a method the lowering
    // invented for it.
    var forwarding_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer forwarding_arena.deinit();
    const forwarding = try genericHashPackage(
        forwarding_arena.allocator(),
        .source_hash_forwards_write,
    );
    try std.testing.expectError(
        error.MissingStructMethod,
        findStructMethod(try findStructDecl(forwarding.files[0], "SeaHasher"), "write_u64"),
    );
}

// The chain only means something once the primitives are really instantiated.
// The callee declares `T: core::hash::Hash`, so EVERY caller's `T` slot is the
// descriptor that callee bound asks for — a bare `u8` there would be the wrong
// type. Each slot therefore carries the runtime type and the layout that type
// has, and the `H` slot stays the plain declared struct it always was.
test "lower: the generic Hash chain is instantiated at every primitive the source can name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try genericHashPackage(alloc, .no_source_hash);
    const wrapper = try findFnDecl(pkg.files[0], "hash_of");
    // The signature keeps the PARAMETER: forwarding `T` forwards the
    // descriptor, and only the body is projected. Both names ride as comptime
    // type parameters, ahead of `value` and `state`.
    const wrapper_generics = try comptimeTypeParams(alloc, wrapper);
    try std.testing.expectEqual(@as(usize, 2), wrapper_generics.len);
    try std.testing.expectEqualStrings("T", wrapper_generics[0]);
    try std.testing.expectEqualStrings("H", wrapper_generics[1]);
    try std.testing.expect(wrapper.params[0].is_comptime);
    try std.testing.expect(wrapper.params[1].is_comptime);

    // Every primitive the source can name is instantiated at the descriptor
    // that names it. `usize` and `u64` are two different descriptors even where
    // the Zig runtime type erases the difference, because the two reach two
    // different `Hasher` writes — and `bool` and `char` reach neither the width
    // nor the signedness their name suggests.
    for (hash_primitive_cases) |case| {
        const decl = try findFnDecl(pkg.files[0], try std.fmt.allocPrint(
            alloc,
            "hash_{s}",
            .{@tagName(case.ir)},
        ));
        const body = try fnBodyExpr(decl);
        if (body != .call) return error.ExpectedInstantiationCall;
        try std.testing.expectEqual(@as(usize, 2), body.call.generic_args.len);
        try expectScalarHashDescriptor(body.call.generic_args[0], case.zig, @tagName(case.ir));
        // The hasher slot is a declared struct, not a Hash bound, so it is the
        // plain name and nothing else.
        try std.testing.expectEqualStrings("SeaHasher", try expectNamedType(body.call.generic_args[1]));
    }
}

/// The declaration a file emits for a source nominal, as the emitter spells a
/// container that has something to hold.
fn findStructDecl(file: ast.File, name: []const u8) !ast.StructDecl {
    for (file.decls) |decl| {
        if (decl != .struct_decl) continue;
        if (std.mem.eql(u8, decl.struct_decl.name, name)) return decl.struct_decl;
    }
    return error.MissingStructDeclaration;
}

/// One method a lowered nominal renders inside its own body.
fn findStructMethod(owner: ast.StructDecl, name: []const u8) !ast.FnDecl {
    for (owner.decls) |decl| {
        if (decl != .fn_decl) continue;
        if (std.mem.eql(u8, decl.fn_decl.name, name)) return decl.fn_decl;
    }
    return error.MissingStructMethod;
}

/// The names of the `comptime T: type` parameters a lowered declaration
/// declares.
///
/// A Rust type parameter reaches a lowered free function or a lowered method as
/// a comptime PARAMETER — the emitter fills `FnDecl.generic_params` only for the
/// two Hash helpers it generates itself — so this is where what a declaration is
/// generic over is read from.
fn comptimeTypeParams(alloc: std.mem.Allocator, decl: ast.FnDecl) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (decl.params) |param| {
        if (!param.is_comptime) continue;
        if (param.ty != .named or !std.mem.eql(u8, param.ty.named, "type")) continue;
        try names.append(alloc, param.name);
    }
    return names.toOwnedSlice(alloc);
}

/// The parameters a trait declares for a lowered member, the receiver removed.
///
/// A Zig member keeps its receiver: Rust spells `&self`/`&mut self` as the
/// method's own first parameter, so the trait's parameter list is everything
/// after it and never the receiver itself.
fn traitParamsOf(method: ast.FnDecl) []const ast.FnParam {
    if (method.params.len == 0) return &.{};
    return method.params[1..];
}

/// The receiver a `core::hash::Hasher` member is reached through: a thin
/// pointer to the hasher the source declared.
fn expectHasherReceiver(method: ast.FnDecl, owner: []const u8) !void {
    if (method.params.len == 0) return error.ExpectedHasherReceiver;
    if (method.params[0].ty != .ptr) return error.ExpectedHasherReceiver;
    try std.testing.expectEqualStrings(owner, try expectNamedType(method.params[0].ty.ptr.elem.*));
}

/// A scalar `RustHashType`: the runtime type the descriptor carries, and a
/// layout whose `scalar` field names WHICH primitive that runtime type is.
///
/// The layout cannot be a `void` tag, because `usize` and `u64` would then be
/// the same layout and a target that differs between them would hash as one.
/// The field therefore reads the enum's own member for the primitive — its
/// exact Rust identity — rather than carrying the value.
fn expectScalarHashDescriptor(ty: ast.Type, runtime: ast.Prim, tag: []const u8) !void {
    if (ty != .expr) return error.ExpectedHashDescriptor;
    const built = ty.expr.*;
    if (built != .call) return error.ExpectedHashDescriptor;
    const descriptor = built.call;
    if (descriptor.callee.* != .ident) return error.ExpectedHashDescriptor;
    try std.testing.expectEqual(@as(usize, 1), descriptor.generic_args.len);
    if (descriptor.generic_args[0] != .prim) return error.ExpectedHashDescriptor;
    try std.testing.expectEqual(runtime, descriptor.generic_args[0].prim);
    if (descriptor.args.len != 1) return error.ExpectedHashDescriptor;
    if (descriptor.args[0] != .struct_init) return error.ExpectedHashDescriptor;
    const layout = descriptor.args[0].struct_init;
    try std.testing.expectEqual(@as(usize, 1), layout.fields.len);
    // The layout field is named for the LAYOUT, and its value names the
    // primitive: `RustHashLayout{ .scalar = @FieldType(RustHashLayout, "scalar").<prim> }`.
    try std.testing.expectEqualStrings("scalar", layout.fields[0].name);
    // The layout names the RUST primitive, which is not always the Zig one it
    // lowers to: Rust's `char` is a `u21` in Zig and stays `char` here.
    try expectScalarLayoutTag(layout.fields[0].expr, tag);
}

/// `@FieldType(r2z.RustHashLayout, "scalar").<tag>` — the enum member the
/// scalar's own identity names, read back out of the AST.
fn expectScalarLayoutTag(expr: ast.Expr, tag: []const u8) !void {
    if (expr != .field_access) return error.ExpectedHashLayoutTag;
    if (!std.mem.eql(u8, expr.field_access.field_name, tag)) return error.ExpectedHashLayoutTag;
    if (expr.field_access.target.* != .builtin) return error.ExpectedHashLayoutTag;
    const query = expr.field_access.target.builtin;
    if (!std.mem.eql(u8, query.name, "FieldType")) return error.ExpectedHashLayoutTag;
    if (query.args.len != 2) return error.ExpectedHashLayoutTag;
    if (query.args[0] != .type_value or query.args[0].type_value != .named) return error.ExpectedHashLayoutTag;
    if (query.args[1] != .lit or query.args[1].lit != .str) return error.ExpectedHashLayoutTag;
    if (!std.mem.eql(u8, query.args[1].lit.str, "scalar")) return error.ExpectedHashLayoutTag;
}

// ── Releasing an owner: a container walks its elements ─────────────────────

/// Lower `fn release_it(..) -> ()` whose body is empty, over a by-value owner.
fn ownerReleasePackage(alloc: std.mem.Allocator, container: bool) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "release_it", root);
    const item_field = try addLowerEntity(&graph, .field, "item", callable);

    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    // 0: `String`, 1: `Vec<String>`, 2: unit.
    const types = [_]ir.types.Type{
        string_ty,
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = try alloc.dupe(ir.types.Type, &.{string_ty}),
        } },
        .{ .prim = .unit },
    };
    const item_ty = if (container) types[1] else types[0];
    const read = try typedExpr(&model, if (container) 1 else 0, .{
        .path = .{ .def = item_field, .generic_args = &.{} },
    });
    const body = try typedExpr(&model, 2, .{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{try model.stmt(.{ .expr = read })}),
        .tail = null,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = "item", .ty = item_ty, .span = span }}),
        .ret = types[2],
        .body = body,
    } };
    try addBareCrate(&graph, alloc, "owner_release", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{callable},
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "owner_release",
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

// A container holds owners of its own, and freeing the slab alone would leak
// every element in it. The release therefore goes through the runtime helper
// that knows how to walk them, rather than the container's own `deinit`.
test "lower: a container owner is released through the runtime helper that walks its elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try ownerReleasePackage(alloc, true);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "r2z.alloc.dropTemporary(allocator, &item)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "defer item.deinit(allocator);") == null);
}

// A scalar owner has no elements, so there is nothing to walk and the loop is
// resolved away at comptime. The plain release is both correct and cheaper.
test "lower: a scalar owner is released without a runtime element walk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try ownerReleasePackage(alloc, false);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "defer item.deinit(allocator);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "dropTemporary") == null);
}

// ── A closure created inside another closure's body ────────────────────────

/// Lower `fn run() -> String` whose body is
/// `let text = seed; let outer = move |_| { let inner = move |_| text; inner(()) }; outer(())`.
fn nestedCapturePackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const run = try addLowerEntity(&graph, .fn_, "run", root);
    const seed = try addLowerEntity(&graph, .const_, "seed", root);
    const text_entity = try addLowerEntity(&graph, .const_, "text", root);
    const outer_entity = try addLowerEntity(&graph, .const_, "outer", root);
    const inner_entity = try addLowerEntity(&graph, .const_, "inner", root);

    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    // 0: `String`, 1: unit.
    const types = [_]ir.types.Type{ string_ty, unit_ty };

    // Both closures take exactly one unit parameter and move `text` by value,
    // which is what the source `move |_| text` writes.
    const captures = try alloc.dupe(ir.exprs.Capture, &.{
        .{ .name = "text", .mode = .by_value, .ty = 0 },
    });
    // `ClosureExpr.params` is a slice; the closure takes exactly one unit, and a
    // Rust closure parameter may be the wildcard `_`.
    const unit_param = try alloc.dupe(ir.exprs.NodeId, &.{try model.pat(.{
        .binding = .{ .name = "_", .mode = .value, .mutable = false },
    })});
    const inner_closure = try typedExpr(&model, 0, .{
        .closure = .{
            .captures = captures,
            .params = unit_param,
            .return_ty = null,
            .body = .{ .statements = &.{}, .tail = try typedExpr(&model, 0, .{ .path = .{
                .def = text_entity,
                .generic_args = &.{},
            } }), .labelled = null },
            // `move |_| text` hands the capture back, so the closure is `FnOnce`.
            .trait = .fn_once,
        },
    });
    const inner_call = try typedExpr(&model, 0, .{ .call = .{
        .call_kind = .{ .free = inner_entity },
        .args = try alloc.dupe(ir.exprs.NodeId, &.{try typedExpr(&model, 1, .{ .unit = {} })}),
    } });
    const outer_closure = try typedExpr(&model, 0, .{
        .closure = .{
            .captures = captures,
            .params = unit_param,
            .return_ty = null,
            .body = .{
                .statements = try alloc.dupe(ir.exprs.NodeId, &.{try model.stmt(.{ .let = .{
                    .pattern = try model.pat(.{ .binding = .{
                        .name = "inner",
                        .mode = .value,
                        .mutable = false,
                    } }),
                    .init = inner_closure,
                    .ty = null,
                } })}),
                .tail = inner_call,
                .labelled = null,
            },
            // `move |_| { .. }` captures by value as well, so it is `FnOnce` too.
            .trait = .fn_once,
        },
    });
    const outer_call = try typedExpr(&model, 0, .{ .call = .{
        .call_kind = .{ .free = outer_entity },
        .args = try alloc.dupe(ir.exprs.NodeId, &.{try typedExpr(&model, 1, .{ .unit = {} })}),
    } });
    const body = try typedExpr(&model, 0, .{ .block = .{
        .statements = try alloc.dupe(ir.exprs.NodeId, &.{
            try model.stmt(.{ .let = .{
                .pattern = try model.pat(.{ .binding = .{
                    .name = "text",
                    .mode = .value,
                    .mutable = false,
                } }),
                .init = try typedExpr(&model, 0, .{ .path = .{ .def = seed, .generic_args = &.{} } }),
                .ty = null,
            } }),
            try model.stmt(.{ .let = .{
                .pattern = try model.pat(.{ .binding = .{
                    .name = "outer",
                    .mode = .value,
                    .mutable = false,
                } }),
                .init = outer_closure,
                .ty = null,
            } }),
        }),
        .tail = outer_call,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[run] = .{ .fn_ = .{
        .params = &.{},
        .ret = types[0],
        .body = body,
    } };
    try addBareCrate(&graph, alloc, "nested_capture", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{run},
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "nested_capture",
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

/// Every handle a `r2z.alloc.takeOwned(r2z.alloc.String, &x)` transfers, in the
/// order the emitted file performs them.
fn stringTransferTargets(
    source: []const u8,
    backing: std.mem.Allocator,
) ![][]const u8 {
    const needle = "r2z.alloc.takeOwned(r2z.alloc.String, &";
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |at| {
        const start = at + needle.len;
        const rest = source[start..];
        // The handle is the call's own argument, so the closing paren ends it.
        // Reading on to the statement's `;` instead reports the name and the
        // `)` that follows it as one token, and that is not a name anything can
        // be compared against.
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse
            std.mem.indexOfScalar(u8, rest, ';') orelse
            return error.MalformedOwnerTransfer;
        try targets.append(backing, rest[0..end]);
        cursor = start + end;
    }
    return targets.toOwnedSlice(backing);
}

// A closure created inside another closure's body captures the OUTER
// SNAPSHOT, not the original binding: the name `text` already resolves through
// the override the outer creation installed, and a capture that read the
// original instead would empty it a second time. The chain is therefore
// original -> outer alias -> inner alias, and each step is its own name.
test "lower: a nested closure captures the outer snapshot rather than the original binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try nestedCapturePackage(alloc);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    const targets = try stringTransferTargets(source, alloc);

    // The owner moves once into the outer snapshot, once into the inner one,
    // and once out through the inner body. Three transfers, three names.
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    // The first is the ORIGINAL place: the only take the source itself can see.
    try std.testing.expectEqualStrings("text", targets[0]);
    // The second is the outer snapshot, which is not the original name.
    try std.testing.expect(!std.mem.eql(u8, targets[1], targets[0]));
    // The third is the inner snapshot, distinct from both.
    try std.testing.expect(!std.mem.eql(u8, targets[2], targets[0]));
    try std.testing.expect(!std.mem.eql(u8, targets[2], targets[1]));

    // Each snapshot is released in the scope its own closure was created in.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, ".deinit(allocator);"));
}

// ── What the Hash bound is, decided by the bound and nothing else ──────────

/// Lower one of two `describe` functions beside the `run` that instantiates it.
///
/// They differ only in WHICH trait the source wrote, which is the whole
/// question: the descriptor answer belongs to the canonical trait alone.
///
/// - local homonym: `trait Hash { fn digest(&self) -> usize; }` declared by
///   THIS crate, `impl Hash for Tag`, `pub fn describe<T: Hash>(v: &T) -> usize
///   { v.digest() }`, and `pub fn run(value: &Tag) -> usize { describe(value) }`.
/// - ordinary: `pub fn describe<T: Copy>(v: &T) -> T { *v }`, and
///   `pub fn run(value: &u8) -> u8 { describe(value) }`.
///
/// Both callers really instantiate the generic, so the call carries the
/// instantiation record the callee's signature requires.
fn hashBoundClassifierPackage(alloc: std.mem.Allocator, local_homonym: bool) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "describe", root);
    const value_def = try addLowerEntity(&graph, .field, "value", callable);

    // The crate's own `Hash`, and the `Tag` that implements it. A different
    // trait that happens to share a name; it declares the method the source
    // actually calls.
    var local_trait: ir.spine.EntityId = 0;
    var method_parent = callable;
    if (local_homonym) {
        local_trait = try addLowerEntity(&graph, .trait_, "Hash", root);
        method_parent = local_trait;
    }
    const digest_ref = try addLowerEntity(&graph, .method_ref, "digest", method_parent);
    const tag = try addLowerEntity(&graph, .struct_, "Tag", root);
    const tag_impl = try addLowerEntity(&graph, .impl_, "Hash", root);
    const tag_digest = try addLowerEntity(&graph, .fn_, "digest", tag_impl);

    const caller = try addLowerEntity(&graph, .fn_, "run", root);
    const caller_value = try addLowerEntity(&graph, .field, "value", caller);

    const lexical: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "T", .id = null }},
    ) } };
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    const tag_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "Tag", .id = tag }},
    ) } };
    // 0: T, 1: `&T`, 2: usize, 3: unit, 4: the concrete caller type, 5: the
    // borrow of it, 6: the caller's own instantiation record.
    var types = [_]ir.types.Type{
        lexical,
        .{ .reference = &.{ .mut = false, .pointee = lexical } },
        usize_ty,
        unit_ty,
        undefined,
        undefined,
        undefined,
    };
    const concrete: ir.types.Type = if (local_homonym) tag_ty else u8_ty;
    types[4] = concrete;
    types[5] = .{ .reference = &.{ .mut = false, .pointee = concrete } };
    types[6] = .{ .generic_inst = .{
        .decl = callable,
        .args = .{ .params = try alloc.dupe(ir.types.Type, &.{concrete}) },
    } };

    // Each body is exactly what its own bound admits. The homonym reaches the
    // method its trait declares; the ordinary bound reads the parameter through
    // a dereference and hands the value back.
    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = value_def, .generic_args = &.{} } });
    const result_ty: ir.exprs.TypeId = if (local_homonym) 2 else 0;
    const result = if (local_homonym)
        try typedExpr(&model, result_ty, .{ .method_call = .{
            .receiver = receiver,
            .receiver_mode = .shared,
            .method = digest_ref,
            .args = &.{},
        } })
    else
        try typedExpr(&model, result_ty, .{ .unary = .{
            .op = .deref,
            .operand = receiver,
        } });
    const body = try typedExpr(&model, result_ty, .{ .block = .{
        .statements = &.{},
        .tail = result,
        .labelled = null,
    } });

    // `run` names the instantiation, so the callee's generic parameter is
    // filled exactly as a monomorphised signature requires.
    const caller_site = try typedExpr(&model, 6, .{ .call = .{
        .call_kind = .{ .free = callable },
        .args = try alloc.dupe(ir.exprs.NodeId, &.{try typedExpr(&model, 5, .{
            .path = .{ .def = caller_value, .generic_args = &.{} },
        })}),
    } });
    const caller_body = try typedExpr(&model, result_ty, .{ .block = .{
        .statements = &.{},
        .tail = caller_site,
        .labelled = null,
    } });

    const one_tail = try typedExpr(&model, 2, litInt(1));
    const tag_body = try typedExpr(&model, 2, .{ .block = .{
        .statements = &.{},
        .tail = one_tail,
        .labelled = null,
    } });

    const bound_segments: []const ir.types.PathSegment = if (local_homonym)
        &.{.{ .name = "Hash", .id = local_trait }}
    else
        &.{
            .{ .name = "core", .id = null },
            .{ .name = "marker", .id = null },
            .{ .name = "Copy", .id = null },
        };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = "value", .ty = types[1], .span = span }}),
        .ret = types[result_ty],
        .generic_params = &.{"T"},
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{.{ .type_ = .{
            .name = "T",
            .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                bound_segments,
            ) } }}),
        } }}), .where_clauses = &.{} },
        .body = body,
    } };
    body_rows[tag] = .{ .struct_ = .{} };
    // `impl Hash for Tag { fn digest(&self) -> usize }`, and `run` returning
    // exactly what `describe` returns.
    body_rows[tag_digest] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = "self", .ty = types[5], .span = span }}),
        .ret = types[2],
        .body = tag_body,
    } };
    body_rows[tag_impl] = .{ .impl_ = .{
        .self_ty = types[4],
        .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{.{ .name = "Hash", .id = local_trait }}) },
        .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{tag_digest}),
    } };
    if (local_homonym) {
        // The trait declares the method the source actually calls, with the
        // receiver it takes and the value it produces.
        body_rows[local_trait] = .{ .trait_ = .{
            .name = "Hash",
            .methods = &.{.{ .name = "digest", .ret = types[2], .receiver = .ref_ }},
        } };
    }
    body_rows[caller] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = "value", .ty = types[5], .span = span }}),
        .ret = types[result_ty],
        .body = caller_body,
    } };

    const items = try alloc.alloc(ir.spine.EntityId, if (local_homonym) 5 else 3);
    items[0] = callable;
    items[1] = tag;
    items[2] = caller;
    var item_count: usize = 3;
    if (local_homonym) {
        items[item_count] = local_trait;
        item_count += 1;
        items[item_count] = tag_impl;
        item_count += 1;
    }
    try addBareCrate(&graph, alloc, "hash_bound_classifier", root, items[0..item_count]);

    const rust_ir = ir.RustIr{
        .crate_name = "hash_bound_classifier",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// A crate's own `trait Hash` is a different trait that happens to share a name.
// Treating it as the canonical one would replace an ordinary type parameter
// with a descriptor, which changes every position the parameter appears in —
// the signature, the borrow, and the caller's argument — for a bound that never
// asked for it.
test "lower: a crate-local trait that shares the Hash name is not a descriptor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try hashBoundClassifierPackage(alloc, true);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    // Nothing about the parameter becomes descriptor-shaped.
    try std.testing.expect(std.mem.indexOf(u8, source, "RustHashType") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RustHashRef") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RustHashLayout") == null);
    // It stays an ordinary type parameter all the way through: the signature
    // keeps the parameter and the borrow keeps the pointer it always was.
    try std.testing.expect(std.mem.indexOf(u8, source, "comptime T: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "*const T") != null);
    // And the body is not projected onto a payload.
    try std.testing.expect(std.mem.indexOf(u8, source, "T.Type") == null);

    // The caller really instantiates the generic, so it carries the type
    // argument its signature requires — and that argument is the PLAIN type the
    // homonym bound asks for, read from the call AST rather than a spelling.
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "run"));
    if (body != .call) return error.ExpectedInstantiationCall;
    try std.testing.expectEqual(@as(usize, 1), body.call.generic_args.len);
    try std.testing.expectEqualStrings("Tag", try expectNamedType(body.call.generic_args[0]));
    try std.testing.expectEqual(@as(usize, 1), body.call.args.len);
    try std.testing.expectEqualStrings("value", operandIdent(body.call.args[0]) orelse
        return error.ExpectedInstantiationCall);
    // `describe` and `run` both answer `usize`, and so does the trait method.
    for ([_][]const u8{ "describe", "run" }) |name| {
        const ret_type = (try findFnDecl(pkg.files[0], name)).ret_type;
        if (ret_type != .prim) return error.ExpectedPrimitiveReturnType;
        try std.testing.expectEqual(ast.Prim.usize, ret_type.prim);
    }
}

// An ordinary bound leaves every ordinary position alone. `&I` for a
// `Copy` parameter is a pointer to the parameter's own type — not a borrowed
// descriptor — and the caller's slot for it is a plain type.
test "lower: an ordinary type parameter keeps its reference and its caller argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try hashBoundClassifierPackage(alloc, false);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "RustHashType") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RustHashRef") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "comptime T: type") != null);
    // `&T` is still `*const T`: the borrow is unchanged by any of this.
    try std.testing.expect(std.mem.indexOf(u8, source, "*const T") != null);

    // The caller instantiates the generic, and the slot is the plain type.
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "run"));
    if (body != .call) return error.ExpectedInstantiationCall;
    try std.testing.expectEqual(@as(usize, 1), body.call.generic_args.len);
    try std.testing.expectEqual(@as(usize, 1), body.call.args.len);
    try std.testing.expectEqualStrings("value", operandIdent(body.call.args[0]) orelse
        return error.ExpectedInstantiationCall);
    // `describe` returns its own parameter and `run` returns what `describe`
    // gave it, so both keep the type parameter itself. A concrete `u8` would
    // describe only the one instantiation this fixture makes, and a descriptor
    // is the shape an ordinary bound's parameter is not.
    for ([_][]const u8{ "describe", "run" }) |name| {
        try std.testing.expectEqualStrings("T", try expectNamedType(
            (try findFnDecl(pkg.files[0], name)).ret_type,
        ));
    }
}

// ── Moving an array owner whose length is a comptime expression ────────────

/// How a zero-length `String` array reaches the caller.
const ZeroArrayScene = enum {
    /// `fn take(a: [String; 0]) -> [String; 0] { a }` — a by-value owner the
    /// frame owns, so returning it transfers it out.
    borrowed_parameter,
    /// `fn make() -> [String; 0] { [] }` — an array literal with no elements,
    /// which owns nothing and has no handle to empty.
    literal_expression,
};

/// Lower one of the two, exactly as written.
fn zeroArrayOwnerPackage(alloc: std.mem.Allocator, scene: ZeroArrayScene) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, switch (scene) {
        .borrowed_parameter => "take",
        .literal_expression => "make",
    }, root);
    const param_def = try addLowerEntity(&graph, .field, "a", callable);

    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const usize_ty: ir.types.Type = .{ .prim = .usize };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    // The length is written as a comptime EXPRESSION that happens to evaluate to
    // zero. A Rust array always carries its length in its type; what the IR may
    // do is hand the length over as an expression, which is what forces the
    // emitted type to be an `array_expr` rather than a plain array.
    const count = try typedExpr(&model, 2, litInt(0));
    // 0: `String`, 1: `[String; <expression>]`, 2: usize, 3: unit,
    // 4: `[String; 0]` with the length written outright.
    const types = [_]ir.types.Type{
        string_ty,
        .{ .array = &.{ .elem = string_ty, .len = .{ .expression = count } } },
        usize_ty,
        unit_ty,
        .{ .array = &.{ .elem = string_ty, .len = .{ .literal = 0 } } },
    };

    const result_id: ir.exprs.TypeId = if (scene == .borrowed_parameter) 1 else 4;
    const body = try typedExpr(&model, result_id, switch (scene) {
        .borrowed_parameter => .{ .path = .{ .def = param_def, .generic_args = &.{} } },
        // Rust's `[]`, whose element type comes from the return position.
        .literal_expression => .{ .array = .{ .elements = &.{}, .repeat = null } },
    });
    const fn_body = try typedExpr(&model, result_id, .{ .block = .{
        .statements = &.{},
        .tail = body,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = switch (scene) {
            .borrowed_parameter => try alloc.dupe(ir.items.Param, &.{
                .{ .name = "a", .ty = types[1], .span = span },
            }),
            .literal_expression => &.{},
        },
        .ret = types[result_id],
        .body = fn_body,
    } };
    try addBareCrate(&graph, alloc, "zero_array_owner", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{callable},
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "zero_array_owner",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

// An array's length is not in its Zig type, so a plain copy could move no
// storage at all. The transfer therefore asks the runtime whether the concrete
// payload really owns something: if it does it takes the handle, and if it does
// not the handle itself is the answer. Either way the frame's release still
// runs, and finds the handle empty.
//
// The payload here is spelled from a comptime EXPRESSION length, so the emitted
// type is an `array_expr` whose length is an expression — and the payload the
// runtime is asked about is that expression-carrying type, not a plain array.
test "lower: moving an array owner is conditional on the runtime proving it owns storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try zeroArrayOwnerPackage(alloc, .borrowed_parameter);
    const decl = try findFnDecl(pkg.files[0], "take");
    const block = decl.body orelse return error.EmptyTranslatedBody;
    const body = (block.expr orelse return error.EmptyTranslatedBody).*;
    if (body != .if_expr) return error.ExpectedOwnedMoveGuard;
    const guard = body.if_expr;

    // The question is asked of the PAYLOAD type, with no argument: it is a
    // comptime question about that type alone.
    if (guard.cond.* != .call) return error.ExpectedOwnedMoveGuard;
    const question = guard.cond.call;
    try std.testing.expectEqualStrings("r2z.alloc.supportsOwnedMove", calleeName(question.callee.*) orelse
        return error.ExpectedOwnedMoveGuard);
    try std.testing.expectEqual(@as(usize, 1), question.generic_args.len);
    try std.testing.expectEqual(@as(usize, 0), question.args.len);
    // The payload is the array whose length is an EXPRESSION, so it lowers to
    // an `array_expr` and not to a plain array.
    const payload = question.generic_args[0];
    if (payload != .array_expr) return error.ExpectedOwnedMoveGuard;
    if (payload.array_expr.len.* != .lit or payload.array_expr.len.lit != .int)
        return error.ExpectedOwnedMoveGuard;
    try std.testing.expectEqual(@as(i128, 0), payload.array_expr.len.lit.int);

    // The `then` arm is the transfer itself, asked about the same type and
    // addressed at the handle the frame holds.
    if (guard.then_body.* != .call) return error.ExpectedOwnedMoveGuard;
    const transfer = guard.then_body.call;
    try std.testing.expectEqualStrings("r2z.alloc.takeOwned", calleeName(transfer.callee.*) orelse
        return error.ExpectedOwnedMoveGuard);
    try std.testing.expectEqual(@as(usize, 1), transfer.generic_args.len);
    try std.testing.expectEqual(@as(usize, 1), transfer.args.len);
    if (transfer.args[0] != .unary_op or transfer.args[0].unary_op.op != .addr_of)
        return error.ExpectedOwnedMoveGuard;
    const alias = operandIdent(transfer.args[0].unary_op.operand.*) orelse return error.ExpectedOwnedMoveGuard;

    // The `else` arm is that same handle, so the two answers are one type.
    if (guard.else_body == null) return error.ExpectedOwnedMoveGuard;
    if (guard.else_body.?.* != .ident) return error.ExpectedOwnedMoveGuard;
    try std.testing.expectEqualStrings(alias, guard.else_body.?.*.ident);

    // An array has no `deinit`: its elements own storage, so the release goes
    // through the runtime helper that knows how to walk them.
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "dropTemporary") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        try std.fmt.allocPrint(alloc, "defer r2z.alloc.dropTemporary(allocator, &{s});", .{alias}),
    ) != null);
}

// An array literal with no elements owns nothing and has no handle, so there is
// no alias to declare, nothing to take and nothing to release. A guard here
// would be a question about a type that cannot answer it.
test "lower: a zero-length array literal is never treated as an owner to move" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try zeroArrayOwnerPackage(alloc, .literal_expression);
    const source = try emit.emitFile(alloc, &pkg.files[0]);
    try std.testing.expect(std.mem.indexOf(u8, source, "supportsOwnedMove") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "takeOwned") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "dropTemporary") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "deinit(allocator)") == null);

    // The literal is still the array the source wrote, and it is still
    // returned: what it is not is an owner.
    const decl = try findFnDecl(pkg.files[0], "make");
    if (decl.ret_type != .array) return error.ExpectedZeroArrayReturn;
    try std.testing.expectEqual(@as(u64, 0), decl.ret_type.array.len);
    try std.testing.expectEqual(@as(usize, 0), decl.params.len);
}

// ── Refusing a move the ABI cannot make safe ───────────────────────────────

/// The payload shape a root tuple is refused for, or one it accepts.
const TaggedPayloadScene = enum {
    /// `(String, UserEnum(String))` — the tag's payload is itself an owner.
    tagged_owner_payload,
    /// `(String, UserEnum(u8))` — the tag's payload is a leaf, so the tag is
    /// only a tag and the whole tuple moves normally.
    tagged_leaf_payload,
    /// `[String; N]` with `N` a comptime parameter the lowering cannot resolve
    /// here, so the array's existing ABI is a borrowed slice.
    generic_length_array,
    /// `(String, UserEnum([String; 0]))` — the tag's payload is an array of
    /// OWNERS that is empty, so its length says it holds none of them.
    tagged_zero_array_payload,
};

/// Lower `fn take(payload: Root) -> Root { payload }` for one of the shapes.
fn taggedPayloadPackage(alloc: std.mem.Allocator, scene: TaggedPayloadScene) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "take", root);
    const param_def = try addLowerEntity(&graph, .field, "payload", callable);

    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const u8_ty: ir.types.Type = .{ .prim = .u8 };

    // The declared `N` of the generic-length array: a type parameter, so the
    // length is written as `.generic` rather than as a number.
    const n_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "N", .id = null }},
    ) } };

    // The user enum, declared once and instantiated with whichever payload the
    // scene needs.
    const user_enum = try addLowerEntity(&graph, .enum_, "UserEnum", root);
    // 0: `String`, 1: u8, 2: `N`, 3: the root tuple or array this scene moves,
    // 4: `UserEnum<String>`, 5: `UserEnum<u8>`, 6: `UserEnum<[u8; 0]>`.
    const enum_args = try alloc.dupe(ir.types.Type, &.{string_ty});
    const leaf_args = try alloc.dupe(ir.types.Type, &.{u8_ty});
    // The zero length is on an array of OWNERS, not of bytes: a byte element
    // would prove nothing, because a leaf was never at risk in the first place.
    const zero_args = try alloc.dupe(ir.types.Type, &.{.{ .array = &.{
        .elem = string_ty,
        .len = .{ .literal = 0 },
    } }});
    var types = [_]ir.types.Type{
        string_ty,
        u8_ty,
        n_ty,
        undefined,
        .{ .generic_inst = .{ .decl = user_enum, .args = .{ .params = enum_args } } },
        .{ .generic_inst = .{ .decl = user_enum, .args = .{ .params = leaf_args } } },
        .{ .generic_inst = .{ .decl = user_enum, .args = .{ .params = zero_args } } },
    };
    types[3] = switch (scene) {
        .tagged_owner_payload, .tagged_leaf_payload => .{ .tuple = try alloc.dupe(ir.types.Type, &.{
            types[0],
            if (scene == .tagged_owner_payload) types[4] else types[5],
        }) },
        .generic_length_array => .{ .array = &.{ .elem = types[0], .len = .{ .generic = 0 } } },
        .tagged_zero_array_payload => .{ .tuple = try alloc.dupe(ir.types.Type, &.{
            types[0],
            types[6],
        }) },
    };

    const body = try typedExpr(&model, 3, .{ .path = .{ .def = param_def, .generic_args = &.{} } });
    const fn_body = try typedExpr(&model, 3, .{ .block = .{
        .statements = &.{},
        .tail = body,
        .labelled = null,
    } });

    // The enum declares the payload the source's instantiation spells. Its own
    // body is `Payload`, so the argument is substituted per instantiation.

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    // `[String; N]`'s length indexes a REAL const slot the source declares, so
    // `N` is in scope where the array is spelled rather than free.
    const const_generics: ?ir.types.Generics = if (scene == .generic_length_array)
        .{ .params = try alloc.dupe(ir.types.GenericParam, &.{
            .{ .const_ = .{ .name = "N", .ty = types[2] } },
        }), .where_clauses = &.{} }
    else
        null;
    body_rows[callable] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = "payload", .ty = types[3], .span = span }}),
        .ret = types[3],
        .generic_params = if (scene == .generic_length_array) &.{"N"} else &.{},
        .generics = const_generics,
        .body = fn_body,
    } };
    body_rows[user_enum] = .{ .enum_ = .{
        .kind = .data,
        .generic_params = &.{"Payload"},
        .variants = try alloc.dupe(ir.items.Variant, &.{
            .{ .name = "Leaf", .fields = .{ .tuple = try alloc.dupe(ir.types.Type, &.{try lexParam(alloc, "Payload")}) }, .discriminant = 0 },
            .{ .name = "Nothing", .fields = .{ .none = {} }, .discriminant = 1 },
        }),
    } };
    try addBareCrate(&graph, alloc, "tagged_payload", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{ callable, user_enum },
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "tagged_payload",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// A bare type-parameter path, for a generic declaration's own body.
fn lexParam(alloc: std.mem.Allocator, name: []const u8) !ir.types.Type {
    return .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = name, .id = null }},
    ) } };
}

// A tag whose payload is itself an owner has no safe move. The tag is erased at
// runtime, so moving the payload would take storage the tag cannot describe —
// and a `String` inside it is exactly that. The refusal happens BEFORE any
// emission, so there is no half-built program to reason about.
test "lower: a user tag carrying an owner is refused before any move is emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedOwnedTaggedPayload,
        taggedPayloadPackage(arena.allocator(), .tagged_owner_payload),
    );
}

// An array whose length the lowering cannot resolve here has a borrowed-slice
// ABI: its storage is not the value. Copying it as though it were would alias
// two handles onto one buffer, so the shape is refused by name.
test "lower: an owned array of unresolved length is refused before any move is emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedOwnedGenericArrayRepresentation,
        taggedPayloadPackage(arena.allocator(), .generic_length_array),
    );
}

// A tag whose payload is a leaf is only a tag. The tuple around it is still an
// owner, and it moves directly: a tuple states its own length, so there is no
// runtime question to ask before the transfer is safe.
test "lower: a user tag carrying a leaf moves through a direct transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try taggedPayloadPackage(alloc, .tagged_leaf_payload);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "take"));
    // Asked about the TUPLE, which is the whole owner being moved — and asked
    // DIRECTLY, with no `supportsOwnedMove` guard in front of it.
    try expectDirectOwnerTransfer(body);
}

// A zero-length array of owners holds none of them, so neither gate applies to
// it — even inside a tag, and even though the source really did write one. The
// element is a `String` on purpose: a byte element was never at risk, so it
// would prove nothing about the length doing the work.
test "lower: a zero-length array of owners inside a user tag skips both refusal gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try taggedPayloadPackage(alloc, .tagged_zero_array_payload);
    const body = try fnBodyExpr(try findFnDecl(pkg.files[0], "take"));
    // Both gates declined, so the move is reached at all — and asked directly.
    try expectDirectOwnerTransfer(body);
}

/// `r2z.alloc.takeOwned(<the owner>, &<handle>)` with no guard in front of it.
///
/// Only an owner whose length the lowering cannot state needs to ask the
/// runtime first; anything that states its own length moves directly.
fn expectDirectOwnerTransfer(body: ast.Expr) !void {
    if (body != .call) return error.ExpectedDirectOwnerTransfer;
    const transfer = body.call;
    try std.testing.expectEqualStrings("r2z.alloc.takeOwned", calleeName(transfer.callee.*) orelse
        return error.ExpectedDirectOwnerTransfer);
    try std.testing.expectEqual(@as(usize, 1), transfer.generic_args.len);
    // The payload is the whole owner, not one field of it.
    if (transfer.generic_args[0] != .tuple) return error.ExpectedDirectOwnerTransfer;
    try std.testing.expectEqual(@as(usize, 1), transfer.args.len);
    if (transfer.args[0] != .unary_op or transfer.args[0].unary_op.op != .addr_of)
        return error.ExpectedDirectOwnerTransfer;
    // Addressed at the handle the frame holds, never at a copy of the value.
    if (operandIdent(transfer.args[0].unary_op.operand.*) == null)
        return error.ExpectedDirectOwnerTransfer;
}

// ── The recursive Hash pair ────────────────────────────────────────────────

/// Lower `pub fn digest_root<T: core::hash::Hash, H: core::hash::Hasher>(state:
/// &mut SeaHasher, value: &T)` whose only statement is `value.hash(state)`,
/// plus TWO callers that both instantiate it at the same tuple.
///
/// Two callers sharing one module is the case that makes "one pair per owning
/// module" observable: a per-call pair would emit two.
fn hashPairPackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);
    const callable = try addLowerEntity(&graph, .fn_, "digest_root", root);
    const state_def = try addLowerEntity(&graph, .field, "state", callable);
    const value_def = try addLowerEntity(&graph, .field, "value", callable);
    const hash_ref = try addLowerEntity(&graph, .method_ref, "hash", callable);

    const sea = try addLowerEntity(&graph, .struct_, "SeaHasher", root);
    // `impl Hasher for SeaHasher` over a type THIS crate declares: the
    // frontend parents the impl to the self type and names it `Trait for Self`,
    // and `resolvePendingImpls` records the impl's methods on that struct's own
    // body. Parented to the module instead, the methods hoist beside the
    // module and `SeaHasher` is left a nominal with nothing in it.
    const sea_impl = try addLowerEntity(&graph, .impl_, "Hasher for SeaHasher", sea);
    const sea_write = try addLowerEntity(&graph, .fn_, "write", sea_impl);
    const sea_finish = try addLowerEntity(&graph, .fn_, "finish", sea_impl);

    var caller_ids: [2]ir.spine.EntityId = undefined;
    var caller_state: [2]ir.exprs.NodeId = undefined;
    var caller_value: [2]ir.exprs.NodeId = undefined;
    for (0..2) |index| {
        caller_ids[index] = try addLowerEntity(&graph, .fn_, try std.fmt.allocPrint(
            alloc,
            "digest_pair{d}",
            .{index},
        ), root);
        caller_state[index] = try addLowerEntity(&graph, .field, "state", caller_ids[index]);
        caller_value[index] = try addLowerEntity(&graph, .field, "value", caller_ids[index]);
    }

    const lexical_t: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "T", .id = null }},
    ) } };
    const lexical_h: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "H", .id = null }},
    ) } };
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const unit_ty: ir.types.Type = .{ .prim = .unit };
    const bytes: ir.types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const sea_ty: ir.types.Type = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = "SeaHasher", .id = sea }},
    ) } };
    // The concrete receiver is a TUPLE, which is what makes the walk recurse:
    // a scalar receiver needs no pair.
    const tuple_ty: ir.types.Type = .{ .tuple = try alloc.dupe(ir.types.Type, &.{
        string_ty,
        u8_ty,
    }) };
    // 0: T, 1: `&T`, 2: H, 3: `&mut H`, 4: u64, 5: `SeaHasher`, 6: `&mut
    // SeaHasher`, 7: the tuple, 8: `&tuple`, 9: `&[u8]`, 10: unit,
    // 11/12: one instantiation record per caller.
    const types = [_]ir.types.Type{
        lexical_t,
        .{ .reference = &.{ .mut = false, .pointee = lexical_t } },
        lexical_h,
        .{ .reference = &.{ .mut = true, .pointee = lexical_h } },
        .{ .prim = .u64 },
        sea_ty,
        .{ .reference = &.{ .mut = true, .pointee = sea_ty } },
        tuple_ty,
        .{ .reference = &.{ .mut = false, .pointee = tuple_ty } },
        bytes,
        unit_ty,
        .{ .generic_inst = .{
            .decl = callable,
            .args = .{ .params = try alloc.dupe(ir.types.Type, &.{ tuple_ty, sea_ty }) },
        } },
        .{ .generic_inst = .{
            .decl = callable,
            .args = .{ .params = try alloc.dupe(ir.types.Type, &.{ tuple_ty, sea_ty }) },
        } },
    };

    const receiver = try typedExpr(&model, 1, .{ .path = .{ .def = value_def, .generic_args = &.{} } });
    const state = try typedExpr(&model, 3, .{ .path = .{ .def = state_def, .generic_args = &.{} } });
    const call = try typedExpr(&model, 4, .{ .method_call = .{
        .receiver = receiver,
        .receiver_mode = .shared,
        .method = hash_ref,
        .args = try alloc.dupe(ir.exprs.NodeId, &.{state}),
        .generic_args = try alloc.dupe(ir.types.Type, &.{lexical_h}),
    } });
    const body = try typedExpr(&model, 10, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });

    const unit_tail = try typedExpr(&model, 10, .{ .unit = {} });
    const zero_tail = try typedExpr(&model, 4, litInt(0));
    var caller_bodies: [2]ir.exprs.NodeId = undefined;
    for (0..2) |index| {
        const left = try typedExpr(&model, 6, .{
            .path = .{ .def = caller_state[index], .generic_args = &.{} },
        });
        const right = try typedExpr(&model, 8, .{
            .path = .{ .def = caller_value[index], .generic_args = &.{} },
        });
        const site = try typedExpr(&model, @intCast(11 + index), .{ .call = .{
            .call_kind = .{ .free = callable },
            .args = try alloc.dupe(ir.exprs.NodeId, &.{ left, right }),
        } });
        // The caller's block carries the type its tail produces, which is the
        // `u64` `digest_root` declares. A caller that declared `()` instead
        // would hand the block's own annotation to the tail-return inference,
        // and that annotation is the call's INSTANTIATION RECORD: a
        // `generic_inst` naming the generic FUNCTION `digest_root`, which is
        // exactly what the frontend records on a call to a generic
        // (`ts_ext.appendGenericCall`). `lowerType` answers a type DEFINITION
        // there and refuses a function, so the two declarations have to agree
        // or the call site is asked to be a type it never was.
        caller_bodies[index] = try typedExpr(&model, 4, .{ .block = .{
            .statements = &.{},
            .tail = site,
            .labelled = null,
        } });
    }

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "state", .ty = types[3], .span = span },
            .{ .name = "value", .ty = types[1], .span = span },
        }),
        .ret = types[4],
        .generic_params = &.{ "T", "H" },
        .generics = .{ .params = try alloc.dupe(ir.types.GenericParam, &.{
            .{ .type_ = .{ .name = "T", .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                &.{
                    .{ .name = "core", .id = null },
                    .{ .name = "hash", .id = null },
                    .{ .name = "Hash", .id = null },
                },
            ) } }}) } },
            .{ .type_ = .{ .name = "H", .bounds = try alloc.dupe(ir.types.Bound, &.{.{ .path = .{ .segments = try alloc.dupe(
                ir.types.PathSegment,
                &.{
                    .{ .name = "core", .id = null },
                    .{ .name = "hash", .id = null },
                    .{ .name = "Hasher", .id = null },
                },
            ) } }}) } },
        }), .where_clauses = &.{} },
        .body = body,
    } };
    body_rows[sea_write] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "self", .ty = types[6], .span = span },
            .{ .name = "bytes", .ty = types[9], .span = span },
        }),
        .ret = types[10],
        .body = try typedExpr(&model, 10, .{ .block = .{
            .statements = &.{},
            .tail = unit_tail,
            .labelled = null,
        } }),
    } };
    body_rows[sea_finish] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{ .name = "self", .ty = types[6], .span = span }}),
        .ret = types[4],
        .body = try typedExpr(&model, 4, .{ .block = .{
            .statements = &.{},
            .tail = zero_tail,
            .labelled = null,
        } }),
    } };
    // The impl's own methods, recorded on the struct body the way
    // `resolvePendingImpls` records them: same name, same signature without the
    // receiver, same body node. That record is what makes the struct render
    // them itself, rather than leaving the nominal an empty container.
    const sea_methods = try alloc.alloc(ir.bodies.StructMethod, 2);
    sea_methods[0] = .{
        .name = "write",
        .visibility = .public,
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "bytes", .ty = types[9], .span = span },
        }),
        .ret = types[10],
        .body = body_rows[sea_write].fn_.body,
        .receiver = .mut_ref,
    };
    sea_methods[1] = .{
        .name = "finish",
        .visibility = .public,
        .params = &.{},
        .ret = types[4],
        .body = body_rows[sea_finish].fn_.body,
        .receiver = .ref_,
    };
    body_rows[sea] = .{ .struct_ = .{ .layout = .unit, .methods = sea_methods } };
    body_rows[sea_impl] = .{ .impl_ = .{
        .self_ty = types[5],
        .trait_path = .{ .segments = try alloc.dupe(ir.types.PathSegment, &.{
            .{ .name = "core", .id = null },
            .{ .name = "hash", .id = null },
            .{ .name = "Hasher", .id = null },
        }) },
        .assoc_items = try alloc.dupe(ir.spine.EntityId, &.{ sea_write, sea_finish }),
    } };
    for (0..2) |index| {
        body_rows[caller_ids[index]] = .{
            .fn_ = .{
                .params = try alloc.dupe(ir.items.Param, &.{
                    .{ .name = "state", .ty = types[6], .span = span },
                    .{ .name = "value", .ty = types[8], .span = span },
                }),
                // What `digest_root` returns. A `()` here would send the tail's
                // instantiation record to the tail-return inference instead.
                .ret = types[4],
                .body = caller_bodies[index],
            },
        };
    }

    // Exactly the items the module declares. A module row carrying an id the
    // symbol table never minted is refused on sight, so the list is sized from
    // what it holds rather than left one slot past its own last write. `write`
    // and `finish` are not module items: they belong to the impl, and the impl
    // belongs to `SeaHasher`.
    try addBareCrate(&graph, alloc, "hash_pair", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{ callable, sea, sea_impl, caller_ids[0], caller_ids[1] },
    ));

    const rust_ir = ir.RustIr{
        .crate_name = "hash_pair",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The private value/slice pair a module emits, found by the prefix each of
/// them is minted under rather than by a whole name — a collision in the source
/// may suffix either one, and the tests below read the names back out of the
/// declarations instead of assuming them.
const HashPair = struct { value: ast.FnDecl, slice: ast.FnDecl };

fn hashPairIn(file: ast.File) !HashPair {
    var value_decls: usize = 0;
    var slice_decls: usize = 0;
    var found: HashPair = undefined;
    for (file.decls) |decl| {
        const function = switch (decl) {
            .fn_decl => |value| value,
            else => continue,
        };
        if (std.mem.startsWith(u8, function.name, "__r2z_hash_value")) {
            value_decls += 1;
            found.value = function;
        }
        if (std.mem.startsWith(u8, function.name, "__r2z_hash_slice")) {
            slice_decls += 1;
            found.slice = function;
        }
    }
    // ONE pair per owning module, not one per call site. Two callers reaching
    // the same module must still see one.
    try std.testing.expectEqual(@as(usize, 1), value_decls);
    try std.testing.expectEqual(@as(usize, 1), slice_decls);
    return found;
}

/// The arm of a `switch` that names `tag`, or its wildcard arm.
fn matchArm(expr: ast.Expr, tag: ?[]const u8) !ast.MatchArm {
    if (expr != .match_expr) return error.ExpectedLayoutSwitch;
    for (expr.match_expr.arms) |arm| {
        if (arm.patterns.len != 1) continue;
        switch (arm.patterns[0]) {
            .wildcard => if (tag == null) return arm,
            .enum_literal => |name| {
                if (tag) |wanted| {
                    if (std.mem.eql(u8, name, wanted)) return arm;
                }
                continue;
            },
            else => continue,
        }
    }
    return error.ExpectedLayoutArm;
}

// The pair is PRIVATE and lives in the module, not in the type it walks. Two
// callers that share a module share the pair, because one pair of functions is
// what keeps the borrowed value and its slice view the same storage.
test "lower: one private value and slice pair backs every Hash walk in a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pkg = try hashPairPackage(alloc);
    const pair = try hashPairIn(pkg.files[0]);
    try std.testing.expect(!pair.value.is_pub);
    try std.testing.expect(!pair.slice.is_pub);
    // Both are generic in the hasher, and the value side is generic in the
    // descriptor it walks.
    try std.testing.expectEqual(@as(usize, 2), pair.value.generic_params.len);
    try std.testing.expectEqual(@as(usize, 2), pair.slice.generic_params.len);
    try std.testing.expectEqualStrings("D", pair.value.generic_params[0].name);
    try std.testing.expectEqualStrings("H", pair.value.generic_params[1].name);
    try std.testing.expectEqualStrings("C", pair.slice.generic_params[0].name);
    try std.testing.expectEqualStrings("H", pair.slice.generic_params[1].name);
}

// The value is BORROWED, never taken: the walk reads the caller's own storage
// and must not consume it, so the borrow is the runtime's own descriptor
// reference and not a plain pointer.
test "lower: the Hash walk borrows the value through the runtime reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pair = try hashPairIn((try hashPairPackage(alloc)).files[0]);
    var value_param: ?ast.FnParam = null;
    for (pair.value.params) |param| {
        if (std.mem.eql(u8, param.name, "value")) value_param = param;
    }
    const borrowed = value_param orelse return error.ExpectedBorrowedValue;
    // The parameter's type is built by a CALL, not spelled: no plain pointer can
    // carry the descriptor.
    if (borrowed.ty != .expr) return error.ExpectedBorrowedValue;
    const built = borrowed.ty.expr.*;
    if (built != .call) return error.ExpectedBorrowedValue;
    const reference = built.call;
    try std.testing.expectEqualStrings("r2z.RustHashRef", calleeName(reference.callee.*) orelse
        return error.ExpectedBorrowedValue);
    try std.testing.expectEqual(@as(usize, 1), reference.generic_args.len);
    // Asked about the descriptor this pair is generic in.
    try std.testing.expectEqualStrings("D", try expectNamedType(reference.generic_args[0]));
    // And it is not mutable: a walk that could write would not be a walk.
    try std.testing.expectEqual(@as(usize, 1), reference.args.len);
    if (reference.args[0] != .lit or reference.args[0].lit != .bool_lit)
        return error.ExpectedBorrowedValue;
    try std.testing.expect(!reference.args[0].lit.bool_lit);
}

// The slice side receives a view of the SAME element type, not a copy of it and
// not a `[]const u8`: its element is the element descriptor's own type, which is
// what lets each element keep its own layout.
test "lower: the Hash slice view carries the element descriptor's own type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pair = try hashPairIn((try hashPairPackage(alloc)).files[0]);
    var items_param: ?ast.FnParam = null;
    for (pair.slice.params) |param| {
        if (std.mem.eql(u8, param.name, "items")) items_param = param;
    }
    const items = items_param orelse return error.ExpectedItemsView;
    if (items.ty != .slice) return error.ExpectedItemsView;
    try std.testing.expect(items.ty.slice.is_const);
    // The element is an EXPRESSION — `C.Type` — not a named type the emitter
    // had to invent.
    if (items.ty.slice.elem.* != .expr) return error.ExpectedItemsView;
    const element = items.ty.slice.elem.*.expr.*;
    if (element != .field_access) return error.ExpectedItemsView;
    try std.testing.expectEqualStrings("Type", element.field_access.field_name);
    try std.testing.expectEqualStrings("C", operandIdent(element.field_access.target.*) orelse
        return error.ExpectedItemsView);
}

// The two ends of the recursion borrow the ORIGINAL value, never a copy of it:
// a tuple field is `&@field(value.*, Slot.name)` and each element is forwarded
// as the bare `item` the loop captured. The loop over the fields is inlined, so
// no runtime iterator is created for a walk the compiler can finish itself.
test "lower: the Hash walk borrows the original field and each element in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pair = try hashPairIn((try hashPairPackage(alloc)).files[0]);

    // The tuple arm: a `std.meta.fields` binding, then an inline loop over the
    // fields and slots, whose body forwards the address of the field itself.
    const walk = try tupleWalkArm(pair.value);
    // The arm is a BLOCK: the inline loop's second input is the binding the
    // first statement makes, so the loop is its second statement and not the
    // whole arm. Inlining is a property of the `ForExpr` itself — there is no
    // arm-level flag to read.
    if (walk.body != .block) return error.ExpectedInlineFieldLoop;
    if (walk.body.block.stmts.len != 2) return error.ExpectedInlineFieldLoop;
    if (walk.body.block.stmts[0] != .let_stmt) return error.ExpectedInlineFieldLoop;
    const slots = walk.body.block.stmts[0].let_stmt;
    try std.testing.expectEqualStrings("Slots", slots.name);
    try std.testing.expect(!slots.is_mut);
    // The binding asks for the fields of the ORIGINAL value's own type: the
    // walk never copies the tuple out to learn what is in it.
    if (slots.init != .call) return error.ExpectedInlineFieldLoop;
    if (slots.init.call.callee.* != .field_access) return error.ExpectedInlineFieldLoop;
    const meta_fields = slots.init.call.callee.field_access;
    try std.testing.expectEqualStrings("fields", meta_fields.field_name);
    if (meta_fields.target.* != .field_access) return error.ExpectedInlineFieldLoop;
    try std.testing.expectEqualStrings("meta", meta_fields.target.field_access.field_name);
    try std.testing.expectEqualStrings("std", operandIdent(meta_fields.target.field_access.target.*) orelse
        return error.ExpectedInlineFieldLoop);
    try std.testing.expectEqual(@as(usize, 1), slots.init.call.args.len);
    if (slots.init.call.args[0] != .builtin or
        !std.mem.eql(u8, slots.init.call.args[0].builtin.name, "TypeOf"))
    {
        return error.ExpectedInlineFieldLoop;
    }
    try std.testing.expectEqual(@as(usize, 1), slots.init.call.args[0].builtin.args.len);
    if (slots.init.call.args[0].builtin.args[0] != .unary_op or
        slots.init.call.args[0].builtin.args[0].unary_op.op != .deref)
    {
        return error.ExpectedInlineFieldLoop;
    }
    try std.testing.expectEqualStrings("value", operandIdent(
        slots.init.call.args[0].builtin.args[0].unary_op.operand.*,
    ) orelse return error.ExpectedInlineFieldLoop);
    if (walk.body.block.stmts[1] != .expr_stmt or
        walk.body.block.stmts[1].expr_stmt.* != .for_expr)
    {
        return error.ExpectedInlineFieldLoop;
    }
    const fields = walk.body.block.stmts[1].expr_stmt.for_expr;
    try std.testing.expect(fields.is_inline);
    try std.testing.expectEqual(@as(usize, 2), fields.captures.len);
    try std.testing.expectEqualStrings("Field", fields.captures[0].name);
    try std.testing.expectEqualStrings("Slot", fields.captures[1].name);
    try std.testing.expectEqual(@as(usize, 2), fields.inputs.len);
    try std.testing.expectEqualStrings("Fields", operandIdent(fields.inputs[0]) orelse
        return error.ExpectedInlineFieldLoop);
    try std.testing.expectEqualStrings("Slots", operandIdent(fields.inputs[1]) orelse
        return error.ExpectedInlineFieldLoop);
    if (fields.body.stmts.len != 1) return error.ExpectedInlineFieldLoop;
    if (fields.body.stmts[0] != .expr_stmt or fields.body.stmts[0].expr_stmt.* != .call)
        return error.ExpectedInlineFieldLoop;
    const forwarded = fields.body.stmts[0].expr_stmt.call;
    // Each FIELD is forwarded to the VALUE pair, not to the slice pair: a
    // tuple field is not necessarily a slice, and routing an array field
    // through the bulk helper would hand it a `[]const C.Type` it does not have.
    try std.testing.expectEqualStrings(pair.value.name, calleeName(forwarded.callee.*) orelse
        return error.ExpectedInlineFieldLoop);
    const argument = forwarded.args[forwarded.args.len - 1];
    if (argument != .unary_op or argument.unary_op.op != .addr_of)
        return error.ExpectedInlineFieldLoop;
    if (argument.unary_op.operand.* != .builtin) return error.ExpectedInlineFieldLoop;
    const field_query = argument.unary_op.operand.builtin;
    try std.testing.expectEqualStrings("field", field_query.name);
    try std.testing.expectEqual(@as(usize, 2), field_query.args.len);
    // Off the ORIGINAL value, read through the descriptor — not through a
    // binding that already copied it out.
    if (field_query.args[0] != .unary_op or field_query.args[0].unary_op.op != .deref)
        return error.ExpectedInlineFieldLoop;
    try std.testing.expectEqualStrings("value", operandIdent(field_query.args[0].unary_op.operand.*) orelse
        return error.ExpectedInlineFieldLoop);
    if (field_query.args[1] != .field_access) return error.ExpectedInlineFieldLoop;
    try std.testing.expectEqualStrings("name", field_query.args[1].field_access.field_name);
    try std.testing.expectEqualStrings("Slot", operandIdent(field_query.args[1].field_access.target.*) orelse
        return error.ExpectedInlineFieldLoop);

    // The element side: the loop captures each item BY REFERENCE and forwards
    // that same item, so the walk reads the slice's storage rather than a copy
    // of each element.
    const elements = try matchArm(try sliceProng(pair.slice), null);
    if (elements.body != .for_expr) return error.ExpectedElementLoop;
    const loop = elements.body.for_expr;
    try std.testing.expectEqual(@as(usize, 1), loop.captures.len);
    try std.testing.expectEqualStrings("item", loop.captures[0].name);
    try std.testing.expect(loop.captures[0].by_ref);
    try std.testing.expectEqual(@as(usize, 1), loop.inputs.len);
    try std.testing.expectEqualStrings("items", operandIdent(loop.inputs[0]) orelse
        return error.ExpectedElementLoop);
    if (loop.body.stmts.len != 1) return error.ExpectedElementLoop;
    if (loop.body.stmts[0] != .expr_stmt or loop.body.stmts[0].expr_stmt.* != .call)
        return error.ExpectedElementLoop;
    const element_forward = loop.body.stmts[0].expr_stmt.call;
    try std.testing.expectEqualStrings(pair.value.name, calleeName(element_forward.callee.*) orelse
        return error.ExpectedElementLoop);
    try std.testing.expectEqualStrings("item", operandIdent(element_forward.args[element_forward.args.len - 1]) orelse
        return error.ExpectedElementLoop);
}

/// The tuple arm of the value declaration, whose body holds the field loop.
fn tupleWalkArm(value_fn: ast.FnDecl) !ast.MatchArm {
    const derived = try derivedWalkOf(value_fn);
    return matchArm(derived, "tuple");
}

/// The scalar/bulk arm of the slice declaration, whose wildcard holds the
/// element loop.
fn sliceProng(slice_fn: ast.FnDecl) !ast.Expr {
    const derived = try derivedWalkOf(slice_fn);
    const arm = try matchArm(derived, "scalar");
    return arm.body;
}

/// The `switch` a pair declaration reaches.
///
/// The declaration's one expression is whatever answered the receiver. With no
/// source implementation to claim it, that IS the walk. With one, the
/// declaration selects it first and the walk is the arm that did not match.
fn derivedWalkOf(decl: ast.FnDecl) !ast.Expr {
    const block = decl.body orelse return error.EmptyTranslatedBody;
    if (block.stmts.len != 1) return error.ExpectedSingleDerivedWalk;
    const statement = block.stmts[0];
    if (statement != .expr_stmt) return error.ExpectedSingleDerivedWalk;
    const answered = statement.expr_stmt.*;
    if (answered == .match_expr) return answered;
    if (answered != .if_expr) return error.ExpectedSingleDerivedWalk;
    const otherwise = answered.if_expr.else_body orelse return error.ExpectedSingleDerivedWalk;
    return otherwise.*;
}

// Every integer whose bytes ARE its payload is handed over in one call: no
// length prefix, no loop, no guard — an empty view has no bytes to describe and
// `sliceAsBytes` of it is empty, which is the same answer.
//
// The kinds that are NOT whole bytes get no bulk arm of their own; the wildcard
// sends them through the element loop, which forwards each item on its own
// terms.
test "lower: an integer element is hashed as one bulk byte write and any other one at a time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pair = try hashPairIn((try hashPairPackage(alloc)).files[0]);
    const bulk = try sliceProng(pair.slice);
    if (bulk != .match_expr) return error.ExpectedBulkSwitch;
    const switch_expr = bulk.match_expr;
    if (switch_expr.target.* != .ident) return error.ExpectedBulkSwitch;
    try std.testing.expectEqualStrings("Primitive", switch_expr.target.ident);

    // Twelve kinds have bytes of their own, and the wildcard is the thirteenth
    // arm. There is no explicit `bool`, `char` or `unit` arm.
    const bulk_kinds = [_][]const u8{
        "u8", "u16", "u32", "u64", "u128", "usize",
        "i8", "i16", "i32", "i64", "i128", "isize",
    };
    try std.testing.expectEqual(bulk_kinds.len + 1, switch_expr.arms.len);

    // Every bulk arm names one of them — the twelve BY NAME, not a count of
    // twelve arms that could be anything.
    for (bulk_kinds) |kind| {
        var present = false;
        for (switch_expr.arms[0..bulk_kinds.len]) |arm| {
            if (arm.patterns.len != 1) continue;
            switch (arm.patterns[0]) {
                .enum_literal => |name| present = present or std.mem.eql(u8, name, kind),
                else => {},
            }
        }
        try std.testing.expect(present);
    }

    // The bulk body is ONE canonical `write` of the view's own bytes, with no
    // length prefix and no comptime guard in front of it.
    try expectBulkByteWrite(switch_expr.arms[0].body);

    // And the wildcard is the element loop, which is what the kinds without a
    // byte layout are answered by.
    const fallback = switch_expr.arms[bulk_kinds.len];
    if (fallback.patterns.len != 1 or fallback.patterns[0] != .wildcard)
        return error.ExpectedBulkSwitch;
    if (fallback.body != .for_expr) return error.ExpectedElementLoop;
    const loop = fallback.body.for_expr;
    try std.testing.expectEqual(@as(usize, 1), loop.captures.len);
    try std.testing.expectEqualStrings("item", loop.captures[0].name);
    try std.testing.expect(loop.captures[0].by_ref);
}

/// The bulk body: the canonical `Hasher::write` reached with
/// `std.mem.sliceAsBytes(items)` and nothing else.
///
/// The source-first dispatcher wraps the call in a type selection when the
/// crate implements `Hasher` for the state type, so the write is reached
/// through the arm that matched rather than at the top.
fn expectBulkByteWrite(body: ast.Expr) !void {
    var write = body;
    if (write == .if_expr) write = write.if_expr.then_body.*;
    if (write != .call) return error.ExpectedBulkByteWrite;
    const call = write.call;
    try std.testing.expectEqualStrings("write", calleeName(call.callee.*) orelse
        return error.ExpectedBulkByteWrite);
    // The bytes are the VIEW's own: `sliceAsBytes(items)`, over the whole view
    // rather than over an element of it.
    var payload: ast.Expr = undefined;
    for (call.args) |argument| {
        switch (argument) {
            .call => |candidate| {
                if (candidate.callee.* == .field_access and
                    std.mem.eql(u8, candidate.callee.field_access.field_name, "sliceAsBytes"))
                {
                    payload = argument;
                }
            },
            else => {},
        }
    }
    if (payload != .call) return error.ExpectedBulkByteWrite;
    const view = payload.call;
    if (view.args.len != 1) return error.ExpectedBulkByteWrite;
    try std.testing.expectEqualStrings("items", operandIdent(view.args[0]) orelse
        return error.ExpectedBulkByteWrite);
}

// ── One allocator rule, asked from both ends of a call ─────────────────────
// `lowerFnEntity` declares the `allocator` parameter and every call site hands
// one over, so both ends read `callPassesAllocator` and nothing else. The two
// fixtures below differ in exactly ONE declaration line — the callee's
// declared return — and pin both answers to it.

/// Which value a declaration's return names.
const AllocatorRuleReturn = enum {
    /// `fn encode(data: &[u8]) -> String`: the returned value is one the
    /// callee BUILT, so the allocator that released it has to reach it.
    /// hex/src/lib.rs:259 is this shape, and its body reaches a blanket
    /// trait's method through `data: T` — a dispatch that resolves outside
    /// the call graph the effect table walks, so the table never records the
    /// allocation and the declaration learned it only while its own body
    /// lowered.
    owned,
    /// `fn encode(data: &[u8]) -> &[u8]`: a borrow of storage the caller
    /// still owns, which builds nothing and obliges nobody.
    borrowed,
};

fn lowerAllocatorRulePackage(
    alloc: std.mem.Allocator,
    returned: AllocatorRuleReturn,
) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root = try addLowerEntity(&graph, .module, "", null);
    const encode_id = try addLowerEntity(&graph, .fn_, "encode", root);
    const use_id = try addLowerEntity(&graph, .fn_, "use_hex", root);
    const data_field = try addLowerEntity(&graph, .field, "data", use_id);
    try addBareCrate(&graph, alloc, "allocator_rule", root, &.{ encode_id, use_id });

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice: ir.types.Type = .{ .slice = slice_info };
    const bytes_ref: ir.types.Type = .{ .reference = &.{ .mut = false, .pointee = byte_slice } };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    // 0: `&[u8]`, 1: whatever `encode` returns, 2: `String`, 3: unit.
    const types = [_]ir.types.Type{
        bytes_ref,
        switch (returned) {
            .owned => string_ty,
            .borrowed => bytes_ref,
        },
        string_ty,
        .{ .prim = .unit },
    };

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;

    // The callee's body is a stand-in for the one the effect table cannot
    // read: it records no effect and reaches nothing, which is the state a
    // blanket-trait dispatch leaves the precomputed table in. What it does NOT
    // do is stand in for a body that allocates — hex's own `encode` is the
    // case where the declaration discovers that late, and a fixture that
    // seeded the table itself would pin nothing.
    const unit_expr = try typedExpr(&model, 3, .{ .unit = {} });
    const callee_body = try typedExpr(&model, 3, .{ .block = .{
        .statements = &.{},
        .tail = unit_expr,
        .labelled = null,
    } });
    body_rows[encode_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "data", .ty = bytes_ref, .span = span },
        }),
        .ret = types[1],
        .body = callee_body,
        .is_allocating = false,
    } };

    const argument = try typedExpr(&model, 0, .{ .path = .{
        .def = data_field,
        .generic_args = &.{},
    } });
    const call = try typedExpr(&model, 1, .{ .call = .{
        .call_kind = .{ .free = encode_id },
        .args = try alloc.dupe(ir.exprs.NodeId, &.{argument}),
    } });
    const caller_body = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = call,
        .labelled = null,
    } });
    body_rows[use_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "data", .ty = bytes_ref, .span = span },
        }),
        .ret = types[1],
        .body = caller_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "allocator_rule",
        .edition = "2021",
        .graph = graph,
        .types = &types,
        .bodies = .{
            .exprs = try model.exprs.toOwnedSlice(alloc),
            .stmts = try model.stmts.toOwnedSlice(alloc),
            .pats = &.{},
            .types = &types,
            .bodies = body_rows,
        },
    };
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The call a declaration's tail expression is, read back through whatever
/// block or `try` the lowering wrapped it in on the way out.
fn unwrapTailCall(function: ast.FnDecl) !ast.Call {
    const body = function.body orelse return error.MissingCallTail;
    var current = (body.expr orelse return error.MissingCallTail).*;
    for (0..4) |_| {
        switch (current) {
            .block => |block| current = (block.expr orelse return error.MissingCallTail).*,
            .unary_op => |unary| if (unary.op == .try_op) {
                current = unary.operand.*;
            } else return error.MissingCallTail,
            .call => |call| return call,
            else => return error.MissingCallTail,
        }
    }
    return error.MissingCallTail;
}

// The declaration carries the parameter and the call site names one, in the
// position the declaration reads it. A call site that asked only what the body
// provably allocated emitted `encode([]const u8, "foobar")` against
// `encode(comptime T: type, allocator: std.mem.Allocator, data: T)` and Zig
// rejected the package with "expected 3 argument(s), found 2".
test "lower: a call to an owned-returning declaration passes the allocator that declaration carries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerAllocatorRulePackage(alloc, .owned);

    const encode = try findFnDecl(package.files[0], "encode");
    try std.testing.expectEqual(@as(usize, 2), encode.params.len);
    try std.testing.expectEqualStrings("allocator", encode.params[0].name);
    try std.testing.expectEqualStrings(
        "std.mem.Allocator",
        try expectNamedType(encode.params[0].ty),
    );
    try std.testing.expectEqualStrings("data", encode.params[1].name);
    // The owned return is what the declaration was asked about, and it is
    // spelled as the runtime owner it is.
    try std.testing.expectEqualStrings("r2z.alloc.String", try expectNamedType(encode.ret_type));

    const caller = try findFnDecl(package.files[0], "use_hex");
    try std.testing.expectEqual(@as(usize, 2), caller.params.len);
    try std.testing.expectEqualStrings("allocator", caller.params[0].name);
    try std.testing.expectEqualStrings("data", caller.params[1].name);

    const call = try unwrapTailCall(caller);
    try std.testing.expectEqualStrings("encode", calleeName(call.callee.*) orelse
        return error.UnexpectedCallee);
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqualStrings("allocator", operandIdent(call.args[0]) orelse
        return error.UnexpectedArgument);
    try std.testing.expectEqualStrings("data", operandIdent(call.args[1]) orelse
        return error.UnexpectedArgument);
}

// The same fixture with a borrowed return, which changes nothing but one line.
// An allocator added here would be a parameter the body never uses and an
// argument the declaration never reads, and the enclosing callable would
// declare a local allocator for it.
test "lower: a call to a borrowed-returning declaration passes no allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerAllocatorRulePackage(alloc, .borrowed);

    const encode = try findFnDecl(package.files[0], "encode");
    try std.testing.expectEqual(@as(usize, 1), encode.params.len);
    try std.testing.expectEqualStrings("data", encode.params[0].name);
    // A borrow is the caller's own storage: nothing is built, so the
    // declaration invents no allocator and no error union either.
    switch (encode.ret_type) {
        .err_union => return error.UnexpectedErrorUnion,
        else => {},
    }

    const caller = try findFnDecl(package.files[0], "use_hex");
    try std.testing.expectEqual(@as(usize, 1), caller.params.len);
    try std.testing.expectEqualStrings("data", caller.params[0].name);

    const call = try unwrapTailCall(caller);
    try std.testing.expectEqualStrings("encode", calleeName(call.callee.*) orelse
        return error.UnexpectedCallee);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualStrings("data", operandIdent(call.args[0]) orelse
        return error.UnexpectedArgument);
}

// ── A guarded chain whose block is the value the caller hands back ──────────

/// A function whose value is a guarded `match` reached through a conditional.
///
/// This is the shape `test/crates/compat`'s `or_payload` has, and it is where
/// the chain's result has to survive: the chain is the branch of an `if` whose
/// value the function returns, so the block that declares the label the arms
/// leave through is a block an enclosing `return` reads.
fn lowerGuardedBranchPackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root = try addRootModule(&graph, .{
        .crate_name = "guard_branch",
        .edition = 2021,
        .items = &.{},
    });
    const fn_id = try addLowerEntity(&graph, .fn_, "classify", root);
    const flag_id = try addLowerEntity(&graph, .field, "flag", fn_id);
    const x_id = try addLowerEntity(&graph, .field, "x", fn_id);
    graph.modules.items[0].items = try alloc.dupe(ir.spine.EntityId, &.{fn_id});

    // 0: u8, 1: bool.
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const bool_ty: ir.types.Type = .{ .prim = .bool };
    const types = [_]ir.types.Type{ u8_ty, bool_ty };

    const flag = try typedExpr(&model, 1, .{ .path = .{ .def = flag_id, .generic_args = &.{} } });
    const x = try typedExpr(&model, 0, .{ .path = .{ .def = x_id, .generic_args = &.{} } });
    const guard_rhs = try typedInt(&model, 1, 0);
    const guard = try typedEq(&model, try typedExpr(&model, 0, .{
        .path = .{ .def = x_id, .generic_args = &.{} },
    }), guard_rhs);

    // `match x { 0 if x == 1 => 1, _ => 2 }`: a guarded arm whose body
    // produces a value, followed by the catch-all that yields the chain's
    // other exit.
    const guarded_arms = try alloc.alloc(ir.exprs.MatchArm, 2);
    guarded_arms[0] = .{
        .patterns = try literalSelectors(alloc, &model, 0),
        .guard = guard,
        .body = try typedInt(&model, 1, 0),
    };
    guarded_arms[1] = .{
        .patterns = try oneSelector(alloc, try model.pat(.wildcard)),
        .guard = null,
        .body = try typedInt(&model, 2, 0),
    };
    const guarded_match = try typedExpr(&model, 0, .{ .match = .{
        .scrutinee = x,
        .arms = guarded_arms,
        .option_scrutinee = false,
    } });

    // The other branch is an ordinary unguarded match, so the conditional is
    // `u8` on both sides and the function returns it.
    const plain_arms = try alloc.alloc(ir.exprs.MatchArm, 2);
    plain_arms[0] = .{
        .patterns = try literalSelectors(alloc, &model, 0),
        .guard = null,
        .body = try typedInt(&model, 3, 0),
    };
    plain_arms[1] = .{
        .patterns = try oneSelector(alloc, try model.pat(.wildcard)),
        .guard = null,
        .body = try typedInt(&model, 4, 0),
    };
    const plain_match = try typedExpr(&model, 0, .{ .match = .{
        .scrutinee = x,
        .arms = plain_arms,
        .option_scrutinee = false,
    } });

    const conditional = try typedExpr(&model, 0, .{ .if_else = .{
        .cond = flag,
        .then_ = .{ .statements = &.{}, .tail = guarded_match, .labelled = null },
        .@"else" = .{ .block = .{
            .statements = &.{},
            .tail = plain_match,
            .labelled = null,
        } },
    } });
    const body = try typedExpr(&model, 0, .{ .block = .{
        .statements = &.{},
        .tail = conditional,
        .labelled = null,
    } });

    const params = try alloc.alloc(ir.items.Param, 2);
    params[0] = .{ .name = "flag", .ty = bool_ty, .span = span };
    params[1] = .{ .name = "x", .ty = u8_ty, .span = span };
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = u8_ty,
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "guard_branch",
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

/// The emitted Zig for the guarded-branch fixture.
fn guardedBranchSource() ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inner = arena.allocator();
    const package = try lowerGuardedBranchPackage(inner);
    return std.testing.allocator.dupe(u8, try emit.emitFile(inner, &package.files[0]));
}

// The chain is a labelled block, and every arm leaves it by naming that block.
// Before, the block the arms' `break`s named was the conditional's branch, and
// the flattening `lowerBlock` does for a statements-only tail dropped the
// label on the way: `test/crates/compat` emitted `break n_1 +% 1;` inside a
// bare switch prong, and Zig rejected it as a break outside any loop.
test "lower: a guarded arm's value leaves a block that is declared around it" {
    const source = try guardedBranchSource();
    defer std.testing.allocator.free(source);

    // The label the exits name is a block label, so `guardChainLabel` — which
    // reads the `<label>: {` that opens it — resolves. A `break :<label>` with
    // no such block is the defect this pins.
    const label = try guardChainLabel(source);
    var value_buf: [128]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&value_buf, label, "1")) != null,
    );
    value_buf = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&value_buf, label, "2")) != null,
    );
    // Both arms leave the chain and neither leaves it twice, so there are
    // exactly two exits and they all name it.
    var prefix_buf: [128]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, try guardExitPrefix(&prefix_buf, label)),
    );
    // Nothing in the function breaks out of anything but that block. An
    // unlabeled `break` reads as one out of the innermost enclosing loop, and
    // there is no loop here, which is exactly what Zig rejected.
    try std.testing.expectEqual(
        countOccurrences(source, "break "),
        countOccurrences(source, "break :"),
    );
    // The chain is the branch the function returns, not a body that falls off
    // the end: the fall-through past the last dispatch is spelled, and the
    // enclosing `return` is what hands the block's value back.
    try std.testing.expect(std.mem.indexOf(u8, source, "unreachable;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return ") != null);
}

// ── A guarded chain that is the whole value a function returns ──────────────

/// A function whose value is a guarded `match` with nothing around it.
///
/// This is the shape `test/crates/guarded-owned-fallthrough`'s
/// `guarded_fallthrough` has, and it is where the label the chain's arms leave
/// through has nowhere to go. The chain is a labelled value block whose arms
/// end on `break :<label> <value>`, and a Zig FUNCTION BODY is written
/// `{ … }` with no label in front of it: moving the chain's statements into the
/// body left the label behind, so every arm's exit resolved to no block at all
/// and the package emitted a bare `break r2z.alloc.takeOwned(…);` that Zig
/// rejected as a break outside any loop.
fn lowerGuardedTailPackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root = try addRootModule(&graph, .{
        .crate_name = "guard_tail",
        .edition = 2021,
        .items = &.{},
    });
    const fn_id = try addLowerEntity(&graph, .fn_, "classify", root);
    const x_id = try addLowerEntity(&graph, .field, "x", fn_id);
    graph.modules.items[0].items = try alloc.dupe(ir.spine.EntityId, &.{fn_id});

    // 0: u8.
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const types = [_]ir.types.Type{u8_ty};

    const x = try typedExpr(&model, 0, .{ .path = .{ .def = x_id, .generic_args = &.{} } });

    // `match x { 0 if x == 1 => 1, _ => 2 }`: the guarded arm and the
    // catch-all behind it are the chain's two exits.
    const guarded_arms = try alloc.alloc(ir.exprs.MatchArm, 2);
    guarded_arms[0] = .{
        .patterns = try literalSelectors(alloc, &model, 0),
        .guard = try typedEq(&model, try typedExpr(&model, 0, .{
            .path = .{ .def = x_id, .generic_args = &.{} },
        }), try typedInt(&model, 1, 0)),
        .body = try typedInt(&model, 1, 0),
    };
    guarded_arms[1] = .{
        .patterns = try oneSelector(alloc, try model.pat(.wildcard)),
        .guard = null,
        .body = try typedInt(&model, 2, 0),
    };
    const guarded_match = try typedExpr(&model, 0, .{ .match = .{
        .scrutinee = x,
        .arms = guarded_arms,
        .option_scrutinee = false,
    } });

    // The chain IS the body's tail. Nothing else in the body precedes it, so a
    // fix that only worked for a chain reached through a conditional would not
    // be exercised here.
    const body = try typedExpr(&model, 0, .{ .block = .{
        .statements = &.{},
        .tail = guarded_match,
        .labelled = null,
    } });

    const params = try alloc.alloc(ir.items.Param, 1);
    params[0] = .{ .name = "x", .ty = u8_ty, .span = span };
    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[fn_id] = .{ .fn_ = .{
        .params = params,
        .ret = u8_ty,
        .body = body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "guard_tail",
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

/// The emitted Zig for the guarded-tail fixture.
fn guardedTailSource() ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inner = arena.allocator();
    const package = try lowerGuardedTailPackage(inner);
    return std.testing.allocator.dupe(u8, try emit.emitFile(inner, &package.files[0]));
}

test "lower: a guarded chain used as a function-body tail is bound to a local, not promoted into return position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const package = try lowerGuardedTailPackage(arena.allocator());

    // The typed AST is the claim: the body keeps the chain WHOLE, bound to a
    // local in STATEMENT position, and hands the value back by name. Promoting
    // it into the tail wrote `return <label>: { … };`, which is not a grammar
    // production — a labelled block is legal only as an `if`/`else` branch or
    // under a carrier — and the tail is emitted through an empty `EmitContext`,
    // so every `break :<label>` inside it resolved against no exit scope.
    const classify = try findFnDecl(package.files[0], "classify");
    const frame = classify.body orelse return error.ExpectedFunctionBody;
    const chain_name = try expectIdent((frame.expr orelse
        return error.ExpectedFunctionTail).*);
    if (frame.stmts.len == 0) return error.ExpectedGuardChainBinding;
    const binding = switch (frame.stmts[frame.stmts.len - 1]) {
        .let_stmt => |let_stmt| let_stmt,
        else => return error.ExpectedGuardChainBinding,
    };
    // The tail reads the local back, so the binding and the tail name one thing.
    try std.testing.expectEqualStrings(chain_name, binding.name);
    const chain = switch (binding.init) {
        .block => |block| block,
        else => return error.ExpectedGuardChainTail,
    };
    if (chain.label == null) return error.MissingGuardChainLabel;
    try std.testing.expect(chain.expr == null);

    const source = try guardedTailSource();
    defer std.testing.allocator.free(source);
    const label = try guardChainLabel(source);

    // Both arms leave the chain by naming it, so the exits resolve to the block
    // the local was bound to.
    var value_buf: [128]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&value_buf, label, "1")) != null,
    );
    value_buf = undefined;
    try std.testing.expect(
        std.mem.indexOf(u8, source, try guardExit(&value_buf, label, "2")) != null,
    );
    var prefix_buf: [128]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, try guardExitPrefix(&prefix_buf, label)),
    );
    // Nothing breaks out of anything but that block. An unlabeled `break` reads
    // as one out of the innermost enclosing loop, and there is no loop here —
    // which is exactly what Zig rejected.
    try std.testing.expectEqual(
        countOccurrences(source, "break "),
        countOccurrences(source, "break :"),
    );
    // The label rides on a block sitting in a statement's initializer, which is
    // one of the positions Zig spells, and the value leaves by name.
    var bind_buf: [256]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            source,
            try std.fmt.bufPrint(&bind_buf, "const {s} = {s}: {{", .{ chain_name, label }),
        ) != null,
    );
    var return_buf: [128]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            source,
            try std.fmt.bufPrint(&return_buf, "return {s};", .{chain_name}),
        ) != null,
    );
    // NEGATIVE: the chain is not in return position at all. `return <label>: {`
    // is the shape the promotion emitted, and its absence is the property — a
    // body whose chain was flattened into its own statements emitted neither
    // the `const` binding nor the `return`, and a promoted one emitted this.
    var promoted_buf: [128]u8 = undefined;
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            source,
            try std.fmt.bufPrint(&promoted_buf, "return {s}: {{", .{label}),
        ) == null,
    );
    // The fall-through past the last dispatch is spelled rather than falling
    // off the end of the block.
    try std.testing.expect(std.mem.indexOf(u8, source, "unreachable;") != null);
}

// ── The declared return, once the body has answered ─────────────────────────

/// The two declarations `test/crates/compat` emits an unused `allocator`
/// parameter for, plus a caller that reads the same rule.
///
///     pub fn borrowed_bytes(input: &[u8]) -> Cow<'_, [u8]> { Cow::Borrowed(input) }
///     pub fn user_error() -> Result<String, UserError> { Err(UserError { code: 7 }) }
///
/// Both declare storage they own and both bodies build none: a `Cow::Borrowed`
/// is the caller's own slice under another name, and an `Err` arm never reaches
/// the `String` the `Result` declares. Neither may carry an allocator, and
/// because both ends of a call read one rule, the caller passes none either.
fn lowerAllocatorObligationPackage(alloc: std.mem.Allocator) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);

    const root = try addRootModule(&graph, .{
        .crate_name = "allocator_obligation",
        .edition = 2021,
        .items = &.{},
    });
    // `Err(..)` is a variant of the prelude's own `Result`, so the fixture
    // needs the module chain `syntheticExternalType` walks to recognise it.
    const core_id = try addLowerEntity(&graph, .module, "core", root);
    const result_module_id = try addLowerEntity(&graph, .module, "result", core_id);
    const result_enum_id = try addLowerEntity(&graph, .enum_, "Result", result_module_id);
    const error_id = try addLowerEntity(&graph, .struct_, "UserError", root);
    const borrowed_id = try addLowerEntity(&graph, .fn_, "borrowed_bytes", root);
    const user_error_id = try addLowerEntity(&graph, .fn_, "user_error", root);
    const caller_id = try addLowerEntity(&graph, .fn_, "use_bytes", root);
    const borrowed_input_id = try addLowerEntity(&graph, .field, "input", borrowed_id);
    const caller_data_id = try addLowerEntity(&graph, .field, "data", caller_id);
    graph.modules.items[0].items = try alloc.dupe(ir.spine.EntityId, &.{
        error_id, borrowed_id, user_error_id, caller_id,
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = "core",
        .parent = root,
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

    const slice_info = try alloc.create(ir.types.Slice);
    slice_info.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const byte_slice: ir.types.Type = .{ .slice = slice_info };
    const bytes_ref: ir.types.Type = .{ .reference = &.{ .mut = false, .pointee = byte_slice } };
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const cow_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = try alloc.dupe(ir.types.Type, &.{byte_slice}),
    } };
    const err_segments = try alloc.alloc(ir.types.PathSegment, 1);
    err_segments[0] = .{ .name = "UserError", .id = error_id };
    const error_ty: ir.types.Type = .{ .path = .{ .segments = err_segments } };
    const result_ty: ir.types.Type = .{ .result = try alloc.create(ir.types.Result) };
    @constCast(result_ty.result).* = .{
        .ok = string_ty,
        .err = error_ty,
        .is_error_unionable = false,
    };
    // 0: `&[u8]`, 1: `Cow<[u8]>`, 2: `Result<String, UserError>`, 3: `UserError`,
    // 4: u8.
    const types = [_]ir.types.Type{ bytes_ref, cow_ty, result_ty, error_ty, u8_ty };

    // `Cow::Borrowed(input)`
    const borrowed_input = try typedExpr(&model, 0, .{
        .path = .{ .def = borrowed_input_id, .generic_args = &.{} },
    });
    const borrowed_arm = try typedExpr(&model, 1, .{ .external_variant = .{
        .owner = cow_ty.external_nominal,
        .variant = "Borrowed",
        .tuple_fields = try alloc.dupe(ir.exprs.NodeId, &.{borrowed_input}),
    } });
    const borrowed_body = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = borrowed_arm,
        .labelled = null,
    } });

    // `Err(UserError { code: 7 })`
    const code_value = try typedExpr(&model, 4, litInt(7));
    const code_fields = try alloc.alloc(ir.exprs.FieldInit, 1);
    code_fields[0] = .{ .field = "code", .value = code_value, .shorthand = false };
    const error_literal = try typedExpr(&model, 3, .{ .struct_lit = .{
        .def = error_id,
        .fields = code_fields,
        .base = null,
    } });
    const err_arm = try typedExpr(&model, 2, .{ .enum_variant = .{
        .def = result_enum_id,
        .variant = "Err",
        .tuple_fields = try alloc.dupe(ir.exprs.NodeId, &.{error_literal}),
        .named_fields = &.{},
    } });
    const user_error_body = try typedExpr(&model, 2, .{ .block = .{
        .statements = &.{},
        .tail = err_arm,
        .labelled = null,
    } });

    // `use_bytes(data) { borrowed_bytes(data) }`
    const caller_data = try typedExpr(&model, 0, .{
        .path = .{ .def = caller_data_id, .generic_args = &.{} },
    });
    const borrow_call = try typedExpr(&model, 1, .{ .call = .{
        .call_kind = .{ .free = borrowed_id },
        .args = try alloc.dupe(ir.exprs.NodeId, &.{caller_data}),
    } });
    const caller_body = try typedExpr(&model, 1, .{ .block = .{
        .statements = &.{},
        .tail = borrow_call,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[error_id] = .{ .struct_ = .{
        .fields = try alloc.dupe(ir.items.Field, &.{
            .{ .name = "code", .ty = u8_ty, .visibility = .public, .span = span },
        }),
        .methods = &.{},
    } };
    body_rows[borrowed_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "input", .ty = bytes_ref, .span = span },
        }),
        .ret = cow_ty,
        .body = borrowed_body,
        .is_allocating = false,
    } };
    body_rows[user_error_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = result_ty,
        .body = user_error_body,
        .is_allocating = false,
    } };
    body_rows[caller_id] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{
            .{ .name = "data", .ty = bytes_ref, .span = span },
        }),
        .ret = cow_ty,
        .body = caller_body,
        .is_allocating = false,
    } };

    const rust_ir = ir.RustIr{
        .crate_name = "allocator_obligation",
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

// The signature the source declared, and nothing more: no `allocator` a body
// that builds no storage would leave unused, which Zig rejects as an unused
// function parameter.
test "lower: a declared owned return a body that builds nothing obliges no allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try lowerAllocatorObligationPackage(alloc);
    try std.testing.expectEqual(@as(usize, 1), package.files.len);

    // `Cow::Borrowed(input)` is the caller's own slice under another name.
    const borrowed = try findFnDecl(package.files[0], "borrowed_bytes");
    try std.testing.expectEqual(@as(usize, 1), borrowed.params.len);
    try std.testing.expectEqualStrings("input", borrowed.params[0].name);
    // The declared return still reaches the declaration spelled as the runtime
    // owner it is — a `Cow` of a byte slice instantiates the runtime's generic.
    const borrowed_return = switch (borrowed.ret_type) {
        .generic => |generic| generic,
        else => return error.ExpectedNamedType,
    };
    try std.testing.expectEqualStrings("r2z.alloc.CowSlice", borrowed_return.name);
    try std.testing.expectEqual(@as(usize, 1), borrowed_return.params.len);

    // `Err(UserError { .. })` never reaches the `String` the `Result` declares.
    const user_error = try findFnDecl(package.files[0], "user_error");
    try std.testing.expectEqual(@as(usize, 0), user_error.params.len);

    // The call site reads the same rule, so it hands over nothing either.
    const caller = try findFnDecl(package.files[0], "use_bytes");
    try std.testing.expectEqual(@as(usize, 1), caller.params.len);
    try std.testing.expectEqualStrings("data", caller.params[0].name);
    const call = try unwrapTailCall(caller);
    try std.testing.expectEqualStrings("borrowed_bytes", calleeName(call.callee.*) orelse
        return error.UnexpectedCallee);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualStrings("data", operandIdent(call.args[0]) orelse
        return error.UnexpectedArgument);
}

// ── A named struct pattern in `let` position ──────────────────────────────

/// Which `let S { .. } = ..` the fixture carries.
const StructPatternScene = enum {
    /// `let State { written, mut a, b } = state;` over three `u64` fields,
    /// followed by the one write that makes `mut a` observable.
    leaf_fields,
    /// `let Holder { tag, text } = holder;` where `text` is a `String`, so the
    /// binding is a transfer out of `holder` rather than a copy of it.
    owned_field,
};

/// One field the pattern names, with the type the struct declares for it and
/// the `mut` the source wrote beside it.
const StructPatternFieldPlan = struct {
    name: []const u8,
    ty: ir.types.Type,
    mutable: bool,
};

/// Lower `let S { .. } = <param>;` plus whatever the scene needs to make its
/// bindings observable.
///
/// `.leaf_fields` is test/crates/seahash/src/buffer.rs:211 in miniature: the
/// source marked one field `mut` and the body writes exactly that one. The
/// write is what survives `lowerBlock`'s downgrade of an untouched `var`, so a
/// fixture that only bound `a` and read it would prove nothing about `mut`.
/// The other two fields are read, which is what keeps them `const`.
///
/// `.owned_field` hands the moved binding straight back, so the tail is the
/// move site that empties the handle the scope release was armed on.
fn structPatternPackage(alloc: std.mem.Allocator, scene: StructPatternScene) !ast.Package {
    var graph = ir.graph.CrateGraph.init(alloc);
    var model = Model.init(alloc);
    const root = try addLowerEntity(&graph, .module, "", null);

    const u64_ty: ir.types.Type = .{ .prim = .u64 };
    const u8_ty: ir.types.Type = .{ .prim = .u8 };
    const string_ty: ir.types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
        .args = &.{},
    } };
    const struct_name: []const u8 = switch (scene) {
        .leaf_fields => "State",
        .owned_field => "Holder",
    };
    const callable_name: []const u8 = switch (scene) {
        .leaf_fields => "finalize",
        .owned_field => "take",
    };
    const param_name: []const u8 = if (scene == .leaf_fields) "state" else "holder";
    const plan: []const StructPatternFieldPlan = switch (scene) {
        .leaf_fields => &.{
            .{ .name = "written", .ty = u64_ty, .mutable = false },
            .{ .name = "a", .ty = u64_ty, .mutable = true },
            .{ .name = "b", .ty = u64_ty, .mutable = false },
        },
        .owned_field => &.{
            .{ .name = "tag", .ty = u8_ty, .mutable = false },
            .{ .name = "text", .ty = string_ty, .mutable = false },
        },
    };

    const struct_id = try addLowerEntity(&graph, .struct_, struct_name, root);
    const callable = try addLowerEntity(&graph, .fn_, callable_name, root);

    // The struct declares the same fields, so every slot's type comes from the
    // declaration the source wrote rather than from the pattern.
    const declared = try alloc.alloc(ir.items.Field, plan.len);
    const types = try alloc.alloc(ir.types.Type, plan.len + 1);
    types[0] = .{ .path = .{ .segments = try alloc.dupe(
        ir.types.PathSegment,
        &.{.{ .name = struct_name, .id = struct_id }},
    ) } };
    for (plan, 0..) |field, index| {
        declared[index] = .{
            .name = field.name,
            .ty = field.ty,
            .visibility = .private,
            .span = span,
        };
        types[index + 1] = field.ty;
    }

    const param_def = try addLowerEntity(&graph, .field, param_name, callable);
    const initializer = try typedExpr(&model, 0, .{
        .path = .{ .def = param_def, .generic_args = &.{} },
    });

    // One binding entity per field, in the order the pattern names them: a
    // binding's emitted name is claimed against the entity that declares it,
    // so a field the pattern introduces needs one of its own.
    const binding_defs = try alloc.alloc(ir.spine.EntityId, plan.len);
    const pattern_fields = try alloc.alloc(ir.exprs.FieldPat, plan.len);
    for (plan, 0..) |field, index| {
        binding_defs[index] = try addLowerEntity(&graph, .field, field.name, callable);
        pattern_fields[index] = .{
            .field = field.name,
            .pat = try model.pat(.{ .binding = .{
                .name = field.name,
                .mode = .{ .value = {} },
                .mutable = field.mutable,
            } }),
            .shorthand = true,
        };
    }
    const destructure = try model.stmt(.{ .let = .{
        .pattern = try model.pat(.{ .struct_pat = .{
            .def = struct_id,
            .fields = pattern_fields,
            .rest = false,
        } }),
        .init = initializer,
        .ty = null,
    } });

    var statements = try alloc.dupe(ir.exprs.NodeId, &.{destructure});
    const tail: ir.exprs.NodeId = switch (scene) {
        .leaf_fields => blk: {
            const write = try model.e(.{ .assign = .{
                .target = try model.e(.{ .path = .{ .def = binding_defs[1], .generic_args = &.{} } }),
                .op = .plain,
                .value = try model.e(.{ .path = .{ .def = binding_defs[2], .generic_args = &.{} } }),
                .overflow = .wrapping,
            } });
            statements = try alloc.dupe(ir.exprs.NodeId, &.{ destructure, try model.stmt(.{ .expr = write }) });
            break :blk try model.e(.{ .path = .{ .def = binding_defs[0], .generic_args = &.{} } });
        },
        .owned_field => try model.e(.{ .path = .{ .def = binding_defs[1], .generic_args = &.{} } }),
    };
    const block = try model.e(.{ .block = .{
        .statements = statements,
        .tail = tail,
        .labelled = null,
    } });

    const body_rows = try alloc.alloc(ir.bodies.BodyKind, graph.symbol_table.count());
    for (body_rows) |*row| row.* = .none;
    body_rows[callable] = .{ .fn_ = .{
        .params = try alloc.dupe(ir.items.Param, &.{.{
            .name = param_name,
            .ty = types[0],
            .span = span,
        }}),
        .ret = if (scene == .leaf_fields) u64_ty else string_ty,
        .body = block,
    } };
    body_rows[struct_id] = .{ .struct_ = .{ .layout = .named, .fields = declared } };
    try addBareCrate(&graph, alloc, "struct_pattern", root, try alloc.dupe(
        ir.spine.EntityId,
        &.{ callable, struct_id },
    ));
    const rust_ir = ir.RustIr{
        .crate_name = "struct_pattern",
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
    return lower.lowerRustIr(alloc, &rust_ir, null);
}

/// The `r2z.alloc.takeOwned(T, &<owner>.<field>)` a body performed, with the
/// handle it installed the payload into and the PLACE it emptied to do it.
///
/// Owner and field are kept apart because the whole question is whether the
/// transfer reads the storage the source handed in or a copy of it: a copy
/// would name a temporary this pass never declared, and would leave the
/// original field still holding the allocation.
const StructFieldTransfer = struct {
    handle: []const u8,
    owner: []const u8,
    field: []const u8,
};

fn structFieldTransfer(stmts: []const ast.Stmt) ?StructFieldTransfer {
    for (stmts) |stmt| {
        if (stmt != .let_stmt) continue;
        const transfer = stmt.let_stmt.init;
        if (transfer != .call) continue;
        const callee = calleeName(transfer.call.callee.*) orelse continue;
        if (!std.mem.eql(u8, callee, "r2z.alloc.takeOwned")) continue;
        if (transfer.call.args.len != 1) continue;
        const place = transfer.call.args[0];
        if (place != .unary_op or place.unary_op.op != .addr_of) continue;
        const target = place.unary_op.operand.*;
        if (target != .field_access) continue;
        const owner = operandIdent(target.field_access.target.*) orelse continue;
        return .{
            .handle = stmt.let_stmt.name,
            .owner = owner,
            .field = target.field_access.field_name,
        };
    }
    return null;
}

/// Every handle a scope release is armed on, in the order the body arms them.
///
/// A body that released the place a transfer emptied as well as the handle the
/// payload moved into would name two slots here, and the second one to run
/// would free bytes the caller now owns.
fn armedReleaseHandles(stmts: []const ast.Stmt, backing: std.mem.Allocator) ![][]const u8 {
    var handles: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer handles.deinit(backing);
    for (stmts) |stmt| {
        if (stmt != .defer_stmt) continue;
        const release = stmt.defer_stmt.expr;
        if (release != .call) continue;
        const callee = release.call.callee.*;
        if (callee != .field_access) continue;
        if (!std.mem.eql(u8, callee.field_access.field_name, "deinit")) continue;
        const name = operandIdent(callee.field_access.target.*) orelse continue;
        try handles.append(backing, name);
    }
    return handles.toOwnedSlice(backing);
}

// A named struct pattern binds ONE NAME PER FIELD, in the order the source
// named them, over the initializer's OWN place. `mut` is the source's own and
// not a rule this pass invented: the binding it marked stays a `var` and the
// rest stay `const`. The initializer here is the parameter itself, so no
// carrier stands between the bindings and the storage they read.
test "lower: a named multi-field struct pattern binds one name per field and honours mut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const package = try structPatternPackage(alloc, .leaf_fields);
    const block = (try findFnDecl(package.files[0], "finalize")).body orelse
        return error.EmptyTranslatedBody;

    // Three bindings and then the one write that keeps `mut` observable.
    try std.testing.expectEqual(@as(usize, 4), block.stmts.len);
    const expected = [_]struct { name: []const u8, mutable: bool }{
        .{ .name = "written", .mutable = false },
        .{ .name = "a", .mutable = true },
        .{ .name = "b", .mutable = false },
    };
    for (expected, block.stmts[0..expected.len]) |want, stmt| {
        if (stmt != .let_stmt) return error.ExpectedFieldBinding;
        try std.testing.expectEqualStrings(want.name, stmt.let_stmt.name);
        try std.testing.expectEqual(want.mutable, stmt.let_stmt.is_mut);
        // Its OWN field of the parameter, so the source's initializer is read
        // where it wrote it and each binding is independent of the others.
        if (stmt.let_stmt.init != .field_access) return error.ExpectedFieldAccess;
        const place = stmt.let_stmt.init.field_access;
        try std.testing.expectEqualStrings("state", operandIdent(place.target.*) orelse
            return error.ExpectedParameterPlace);
        try std.testing.expectEqualStrings(want.name, place.field_name);
    }

    // The body really does write the binding the source marked `mut`, which is
    // what keeps it a `var` rather than a `const` nothing reaches.
    if (block.stmts[expected.len] != .assign) return error.ExpectedFieldWrite;
    try std.testing.expectEqualStrings("a", operandIdent(block.stmts[expected.len].assign.target) orelse
        return error.ExpectedFieldWrite);
}

// ── The move a named struct pattern performs, executed ────────────────────

/// Every allocation the frames under test make, counted by ADDRESS.
///
/// The claim is about how many times ONE payload's bytes are released, and a
/// leak-checking allocator cannot answer that on its own: a payload that MOVED
/// is released by whoever holds it now, so a frame that released it as well
/// would still leave the testing allocator balanced — one free too many,
/// against an allocation the caller also freed, and reported as no leak at
/// all. And a release that reached an already-emptied handle frees nothing, so
/// the second release a wrong lowering performs is a silent no-op rather than
/// a crash. `Ledger` exists for that gap: it counts every allocation by
/// address and every release of that address, so "exactly once" is a number a
/// test reads rather than an absence it infers.
///
/// The ledger allocates nothing itself; a genuine double free still panics in
/// the allocator underneath and a genuine leak is still reported when the
/// test ends.
const Ledger = struct {
    /// One payload is live at a time in every test here, so an eighth is
    /// headroom for a frame that legitimately builds more than one owned
    /// value; running past it is counted rather than ignored, so an
    /// under-count cannot pass silently.
    const capacity = 8;

    const Record = struct {
        address: usize,
        releases: u16,
    };

    child: std.mem.Allocator,
    records: [capacity]Record,
    count: usize,
    /// Allocations made with no room left to record them.
    overflows: usize,
    /// Frees of an address this ledger never handed out.
    unowned_releases: usize,

    fn init(child: std.mem.Allocator) Ledger {
        return .{
            .child = child,
            .records = undefined,
            .count = 0,
            .overflows = 0,
            .unowned_releases = 0,
        };
    }

    fn allocator(self: *Ledger) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocSlot,
        .resize = resizeSlot,
        .remap = remapSlot,
        .free = freeSlot,
    };

    /// The index of the record for `address`, released or not. A record
    /// outlives its release on purpose: a second free of the same address has
    /// to find it again and count twice, which is the whole point.
    fn find(self: *const Ledger, address: usize) ?usize {
        for (self.records[0..self.count], 0..) |record, index| {
            if (record.address == address) return index;
        }
        return null;
    }

    /// How many of the recorded allocations have not been released.
    fn liveCount(self: *const Ledger) usize {
        var count: usize = 0;
        for (self.records[0..self.count]) |record| {
            if (record.releases == 0) count += 1;
        }
        return count;
    }

    /// The only address still held, or null when the count is not exactly one.
    fn onlyLiveAddress(self: *const Ledger) ?usize {
        if (self.liveCount() != 1) return null;
        for (self.records[0..self.count]) |record| {
            if (record.releases == 0) return record.address;
        }
        return null;
    }

    /// How many times `address` has been freed.
    fn releasesOf(self: *const Ledger, address: usize) u16 {
        const index = self.find(address) orelse return 0;
        return self.records[index].releases;
    }

    /// Every release the ledger saw, recorded or not.
    fn totalReleases(self: *const Ledger) usize {
        var total = self.unowned_releases;
        for (self.records[0..self.count]) |record| total += record.releases;
        return total;
    }

    fn allocSlot(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (self.count == capacity) {
            self.overflows += 1;
            return result;
        }
        self.records[self.count] = .{ .address = @intFromPtr(result), .releases = 0 };
        self.count += 1;
        return result;
    }

    fn resizeSlot(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Ledger = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapSlot(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        // A remap that moved the allocation releases the old address and hands
        // back this one, so the record follows it. One that did not move keeps
        // the address it already has.
        const relocated = @intFromPtr(result);
        if (@intFromPtr(memory.ptr) != relocated) {
            if (self.find(@intFromPtr(memory.ptr))) |index| {
                self.records[index].address = relocated;
            }
        }
        return result;
    }

    fn freeSlot(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Ledger = @ptrCast(@alignCast(context));
        // A zero-length free releases nothing, so it is not a release of any
        // address and must not be counted as one.
        if (memory.len != 0) {
            if (self.find(@intFromPtr(memory.ptr))) |index| {
                self.records[index].releases += 1;
            } else {
                self.unowned_releases += 1;
            }
        }
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// One owned field as the emitted code holds it: a handle over bytes that a
/// transfer empties in place.
const OwnedSlot = struct {
    bytes: []u8 = &.{},

    fn isEmpty(self: OwnedSlot) bool {
        return self.bytes.len == 0;
    }
};

/// What `r2z.alloc.takeOwned(T, &place)` does: the bytes move into the handle
/// the pattern bound, and the place they came from is left empty.
fn transferInPlace(place: *OwnedSlot) OwnedSlot {
    const taken = OwnedSlot{ .bytes = place.bytes };
    place.bytes = &.{};
    return taken;
}

/// What `handle.deinit(allocator)` does: the bytes go back to the allocator
/// that produced them, and a handle already emptied frees nothing — which is
/// what lets the scope release run unconditionally on both exits.
fn releaseInPlace(gpa: std.mem.Allocator, handle: *OwnedSlot) void {
    if (handle.bytes.len == 0) return;
    gpa.free(handle.bytes);
    handle.bytes = &.{};
}

// What the emitted statements DO is the only thing the ownership claim is
// worth, so this runs them. The payload is allocated once through a
// per-address ledger, the transfer the lowering emitted empties the field it
// was read from and installs the bytes in the handle the pattern bound, and
// every release the lowering armed runs in the order it armed it. A copy
// instead of a transfer is what this rules out: the original field would
// still name the allocation, and the release armed on the moved handle would
// free bytes the source's own field still holds.
test "lower: a struct pattern's owned field moves out of its place exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The shape, read off the typed AST: what was transferred, out of WHICH
    // place, and which handle the scope release was armed on.
    const package = try structPatternPackage(alloc, .owned_field);
    const block = (try findFnDecl(package.files[0], "take")).body orelse
        return error.EmptyTranslatedBody;
    const transfer = structFieldTransfer(block.stmts) orelse
        return error.NoStructFieldTransfer;
    try std.testing.expectEqualStrings("text", transfer.handle);
    // The ORIGINAL field of the parameter, not a copy of it.
    try std.testing.expectEqualStrings("holder", transfer.owner);
    try std.testing.expectEqualStrings("text", transfer.field);
    // `tag` owns nothing, so the body arms exactly ONE release, and it is
    // armed on the handle that holds the bytes.
    const armed = try armedReleaseHandles(block.stmts, alloc);
    try std.testing.expectEqual(@as(usize, 1), armed.len);
    try std.testing.expectEqualStrings("text", armed[0]);

    var ledger = Ledger.init(std.testing.allocator);
    const gpa = ledger.allocator();

    // The frame under test: the owned field the source destructured out of
    // its parameter. It stays the owner until the transfer runs.
    var original = OwnedSlot{ .bytes = try gpa.dupe(u8, "nested") };
    const address = ledger.onlyLiveAddress() orelse
        return error.PayloadBytesNotHeldOnce;

    // Nothing may be released before the transfer: the payload is live and
    // the frame still owns it.
    try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());

    // The transfer. The source field is left EMPTY, so a release that reached
    // it afterwards would free nothing at all.
    var moved = transferInPlace(&original);
    try std.testing.expect(original.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), ledger.totalReleases());

    // The one release the body armed, on the handle that holds the bytes.
    releaseInPlace(gpa, &moved);
    // Then the two defects this shape is built to survive: a frame that also
    // released the place it had moved out of, and a second release of the
    // handle that now holds the payload. Both reach storage that is already
    // gone, and neither may show up as a release.
    releaseInPlace(gpa, &original);
    releaseInPlace(gpa, &moved);

    try std.testing.expectEqual(@as(usize, 0), ledger.liveCount());
    try std.testing.expectEqual(@as(u16, 1), ledger.releasesOf(address));
    try std.testing.expectEqual(@as(usize, 1), ledger.totalReleases());
    try std.testing.expectEqual(@as(usize, 0), ledger.unowned_releases);
    try std.testing.expectEqual(@as(usize, 0), ledger.overflows);
}
