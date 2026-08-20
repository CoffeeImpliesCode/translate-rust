//! translate_rust.backend.zig.lower_test — Lowering engine tests.
//!
//! Builds a sample RustIR (struct with inherent methods + hoisted impl method,
//! top-level fn with a match expression, and a #[test] fn), lowers it to an
//! ast.Package, and verifies struct decls, method hoisting, expression shape,
//! and module-to-file mapping.

const std = @import("std");
const ir = @import("translate_rust.ir");
const ast = @import("ast.zig");
const lower = @import("lower.zig");
const strategy = @import("../strategy.zig");
const default_strat = @import("strategies/default.zig");

const span: ir.spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

// Build the full sample RustIR in-memory. All allocations go to the caller's
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

fn litInt(v: i128) ir.exprs.ExprKind {
    return .{ .literal = .{ .int = .{ .text = "", .value = v, .base = .dec, .ty_suffix = null } } };
}

fn buildSampleModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
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

    // var x = 1; x = 2; x += 2; x -= 2; x *= 2; x &= 2; x |= 2; x ^= 2;
    const e_one = try model.e(litInt(1));
    const e_two = try model.e(litInt(2));
    const e_x = try model.e(.{ .path = .{ .def = local_x_id, .generic_args = &.{} } });
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
            .body = e_match,
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

    // ── Wire bodies into the RustIR ───────────────────────────────────────
    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    // ── Module graph ──────────────────────────────────────────────────────
    const root_id = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        // scale_id (id1) is an inherent method — not a module-level item.
        .items = &.{ point_id, eval_id, test_dbg_id },
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "sample",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
}

test "lowerRustIR: struct methods, hoisting, and expressions" {
    const backing = std.testing.allocator;
    // One long-lived arena backs both the model and the lowering output.
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

    try buildSampleModel(alloc, &graph, &ir_bodies);

    const rust_ir = ir.RustIR{
        .crate_name = "sample",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };

    // Use the default strategy through the standard vtable.
    var def_strat = default_strat.DefaultStrategy{};
    const strat = strategy.LoweringStrategy{
        .ptr = &def_strat,
        .vtable = &.{
            .lowerType = default_strat.DefaultStrategy.lowerType,
            .lowerStdGeneric = default_strat.DefaultStrategy.lowerStdGeneric,
        },
    };

    const pkg = try lower.lowerRustIR(alloc, &rust_ir, &strat);

    // ── Package and file mapping ──────────────────────────────────────────
    try std.testing.expectEqualStrings("sample", pkg.name);
    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    try std.testing.expectEqualStrings("src/root.zig", pkg.files[0].path);

    const file = pkg.files[0];

    // Root decls: Point (struct), eval (fn). The hoisted scale and the test fn
    // are not top-level decls.
    try std.testing.expectEqual(@as(usize, 2), file.decls.len);

    // ── Struct declaration with fields and hoisted methods ────────────────
    const point_decl = file.decls[0];
    try std.testing.expect(point_decl == .struct_decl);
    const sd = point_decl.struct_decl;
    try std.testing.expectEqualStrings("Point", sd.name);
    try std.testing.expectEqual(@as(usize, 2), sd.fields.len);
    try std.testing.expectEqualStrings("x", sd.fields[0].name);
    try std.testing.expectEqual(ast.Prim.i32, sd.fields[0].ty.prim);
    try std.testing.expectEqualStrings("y", sd.fields[1].name);

    // Method hoisting: StructBody method "dist" + impl-hoisted "scale".
    try std.testing.expectEqual(@as(usize, 2), sd.decls.len);
    var saw_dist = false;
    var saw_scale = false;
    for (sd.decls) |d| {
        try std.testing.expect(d == .fn_decl);
        const fd = d.fn_decl;
        if (std.mem.eql(u8, fd.name, "dist")) {
            saw_dist = true;
            // .ref_ receiver → *const Point as the leading self parameter
            try std.testing.expectEqual(@as(usize, 1), fd.params.len);
            try std.testing.expectEqualStrings("self", fd.params[0].name);
            try std.testing.expect(fd.params[0].ty == .ptr);
            try std.testing.expect(fd.params[0].ty.ptr.is_const);
            // body tail = literal 10
            try std.testing.expect(fd.body != null);
            try std.testing.expect(fd.body.?.expr != null);
            try std.testing.expectEqual(@as(i128, 10), fd.body.?.expr.?.lit.int);
        } else if (std.mem.eql(u8, fd.name, "scale")) {
            saw_scale = true;
            try std.testing.expectEqual(ast.Prim.u32, fd.ret_type.prim);
        }
    }
    try std.testing.expect(saw_dist);
    try std.testing.expect(saw_scale);

    // ── Top-level fn with a match expression ──────────────────────────────
    const eval_decl = file.decls[1];
    try std.testing.expect(eval_decl == .fn_decl);
    const ef = eval_decl.fn_decl;
    try std.testing.expectEqualStrings("eval", ef.name);
    try std.testing.expectEqual(@as(usize, 1), ef.params.len);
    try std.testing.expectEqualStrings("v", ef.params[0].name);
    try std.testing.expectEqual(ast.Prim.i32, ef.ret_type.prim);

    try std.testing.expect(ef.body != null);
    try std.testing.expect(ef.body.?.expr != null);
    const eval_tail = ef.body.?.expr.?;
    try std.testing.expect(eval_tail.* == .match_expr);
    try std.testing.expectEqual(@as(usize, 1), eval_tail.*.match_expr.arms.len);
    try std.testing.expectEqual(@as(usize, 1), eval_tail.*.match_expr.arms[0].patterns.len);
    try std.testing.expect(eval_tail.*.match_expr.arms[0].patterns[0] == .wildcard);

    // ── Test declaration ──────────────────────────────────────────────────
    try std.testing.expectEqual(@as(usize, 1), file.tests.len);
    try std.testing.expectEqualStrings("test_dbg", file.tests[0].name);
    const test_stmts = file.tests[0].body.stmts;
    try std.testing.expectEqual(@as(usize, 8), test_stmts.len);
    try std.testing.expect(test_stmts[0] == .let_stmt);
    try std.testing.expectEqualStrings("x", test_stmts[0].let_stmt.name);
    const expected_ops = [_]ast.AssignOp{
        .assign,
        .add_assign,
        .sub_assign,
        .mul_assign,
        .bit_and_assign,
        .bit_or_assign,
        .bit_xor_assign,
    };
    for (expected_ops, test_stmts[1..]) |expected_op, stmt| {
        try std.testing.expect(stmt == .assign);
        try std.testing.expectEqual(expected_op, stmt.assign.op);
        try std.testing.expect(stmt.assign.target == .ident);
        try std.testing.expectEqualStrings("x", stmt.assign.target.ident);
        try std.testing.expectEqual(@as(i128, 2), stmt.assign.val.lit.int);
    }
}

/// Build a model whose fn returns a non-primitive path type via a
/// struct-literal body tail, plus a char-returning fn, to exercise:
///   - `lowerFnEntity`/`lowerStructMethod` return-type mapping (path → named,
///     NOT void / anyopaque);
///   - `lowerType` primitive mapping (char → u21) and `.unsupported` with a
///     message → named type;
///   - `lowerBlock` tail preservation (struct-init value tail kept in
///     `ast.Block.expr`).
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

    // Bodies (indexed by entity id):
    //  id0: Point struct (no fields)
    try model.bodies.append(model.a(), .{ .struct_ = .{
        .fields = &.{},
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

    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    const root_id = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ point_id, make_point_id, first_char_id },
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "types",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
}

test "lower: non-primitive fn return types and block tail preservation" {
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

    const rust_ir = ir.RustIR{
        .crate_name = "types",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);

    try std.testing.expectEqual(@as(usize, 1), pkg.files.len);
    const file = pkg.files[0];

    // Root decls: Point struct + make_point + first_char.
    try std.testing.expectEqual(@as(usize, 3), file.decls.len);

    // make_point returns path "Point" → named "Point", NOT void/anyopaque.
    const make_point = file.decls[1].fn_decl;
    try std.testing.expectEqualStrings("make_point", make_point.name);
    try std.testing.expect(make_point.ret_type == .named);
    try std.testing.expectEqualStrings("Point", make_point.ret_type.named);
    // Body tail (struct-init) is preserved as the block expr.
    try std.testing.expect(make_point.body != null);
    try std.testing.expect(make_point.body.?.expr != null);
    try std.testing.expect(make_point.body.?.expr.?.* == .struct_init);

    // first_char returns prim char → ast.Prim.u21.
    const first_char = file.decls[2].fn_decl;
    try std.testing.expectEqualStrings("first_char", first_char.name);
    try std.testing.expect(first_char.ret_type == .prim);
    try std.testing.expectEqual(ast.Prim.u21, first_char.ret_type.prim);
    try std.testing.expect(first_char.body.?.expr != null);
    try std.testing.expect(first_char.body.?.expr.?.* == .lit);
}

/// Build a graph exercising `pub use` re-export lowering:
/// - cross-module qualified re-export (`pub use util::helper;` → `util.helper`)
/// - same-module self-referential `pub use dup;` → skipped (no `pub const dup = dup;`)
/// - `_` wildcard re-export → skipped
fn buildUseModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
) !void {
    var model = Model.init(alloc);

    // Module ids come from graph.addModule dense counter (root=0, util=1).
    const root_id = try graph.addModule(.{
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
    const util_id = try graph.addModule(.{
        .id = 0,
        .kind = .@"inline",
        .name = try alloc.dupe(u8, "util"),
        .parent = 0,
        .source_path = null,
        .is_crate = false,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    // id0: helper — lives in the `util` module (parent = util_id).
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
    // id1: dup — lives in the root module (parent = root_id = 0).
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

    // id2: `pub use util::helper;` — cross-module qualified re-export.
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

    // id3: `pub use dup;` — same-module self-referential → must be skipped.
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

    // id4: `pub use other::x as _;` — wildcard local name → must be skipped.
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

    // id5: a glob must be skipped even if malformed input carries a name.
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

    // Pad the sparse bodies table to cover the use_ entity ids.
    var i: usize = 0;
    while (i <= use_glob_id) : (i += 1) {
        try model.bodies.append(model.a(), .{ .none = {} });
    }

    bodies.* = .{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = &.{},
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    // Root module's items list must reference all use entities.
    graph.modules.items[0].items = &.{
        use_helper_id,
        use_dup_id,
        use_wild_id,
        use_glob_id,
    };

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

    const rust_ir = ir.RustIR{
        .crate_name = "usecrate",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);

    // Root module maps to src/root.zig.
    var root_file: ?ast.File = null;
    for (pkg.files) |f| {
        if (std.mem.eql(u8, f.path, "src/root.zig")) {
            root_file = f;
            break;
        }
    }
    const rf = root_file orelse return error.RootFileMissing;

    // Only the cross-module `pub use util::helper;` should lower to a decl;
    // the self-ref `pub use dup;` and `_` wildcard are skipped.
    try std.testing.expectEqual(@as(usize, 1), rf.decls.len);

    const d = rf.decls[0];
    try std.testing.expect(d == .const_decl);
    try std.testing.expectEqualStrings("helper", d.const_decl.name);
    try std.testing.expect(d.const_decl.is_pub);
    // init must be a qualified field access: util.helper
    try std.testing.expect(d.const_decl.init == .field_access);
    const fa = d.const_decl.init.field_access;
    try std.testing.expect(fa.target.* == .ident);
    try std.testing.expectEqualStrings("util", fa.target.*.ident);
    try std.testing.expectEqualStrings("helper", fa.field_name);
}

fn buildGenericModel(
    alloc: std.mem.Allocator,
    graph: *ir.graph.CrateGraph,
    bodies: *ir.bodies.Bodies,
) !void {
    var model = Model.init(alloc);

    // id0: struct Fletcher<T>
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

    // Explicit `generic_params` list on the StructBody (the primary path).
    try model.bodies.append(model.a(), .{
        .struct_ = .{
            .generic_params = &.{"T"},
            .trait_bounds = &.{},
            .layout = .named,
            .fields = &.{
                .{ .name = "a", .ty = .{ .path = t_path }, .visibility = .public, .span = span },
                .{ .name = "b", .ty = .{ .path = t_path }, .visibility = .public, .span = span },
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

    const root_id = try graph.addModule(.{
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
        .edition = 2018,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });
}

test "lower: generic struct generic_params populate ast.StructDecl" {
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

    const rust_ir = ir.RustIR{
        .crate_name = "fletcher",
        .edition = "2018",
        .graph = graph,
        .types = &.{},
        .bodies = ir_bodies,
    };
    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);

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
    try std.testing.expect(sd.generic_params[0].ty == null);
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

    const root_id = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{ a_id, b_id },
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "consts",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIR{
        .crate_name = "consts",
        .edition = "2021",
        .graph = graph,
        .types = &types_store,
        .bodies = ir_bodies,
    };

    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);

    const emit = @import("emit.zig");
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

test "lower: prelude trait methods lower to native Zig expressions" {
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
    _ = clone_id;
    _ = len_id;
    _ = bitxor_id;
    _ = to_vec_id;

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
    const body_id: ir.spine.EntityId = @intCast(model.bodies.items.len);
    try model.bodies.append(model.a(), .{
        .fn_ = .{
            .params = &.{.{ .name = "data", .ty = types_store[0], .span = span }},
            .ret = types_store[0],
            .body = e_blk,
        },
    });

    const final_bodies = ir.bodies.Bodies{
        .exprs = try model.exprs.toOwnedSlice(model.a()),
        .stmts = try model.stmts.toOwnedSlice(model.a()),
        .pats = try model.pats.toOwnedSlice(model.a()),
        .types = types_store,
        .bodies = try model.bodies.toOwnedSlice(model.a()),
    };

    const root_id = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{body_id},
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = "sample",
        .edition = 2021,
        .kind = .lib,
        .root = root_id,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIR{
        .crate_name = "sample",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = final_bodies,
    };
    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);

    // data.as_ref() must lower to a plain ident, not an unresolvable method call.
    var found_ident = false;
    var found_call = false;
    const file0 = pkg.files[0];
    for (file0.decls) |d| {
        if (d != .fn_decl) continue;
        if (d.fn_decl.body) |b| {
            if (b.expr) |tail| {
                if (tail.* == .ident) found_ident = true;
                if (tail.* == .call) found_call = true;
            }
        }
    }
    // The prelude `.as_ref()` lowers to the receiver ident (slice-compatible).
    try std.testing.expect(found_ident);
    try std.testing.expect(!found_call);
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

    const generic_segments = try alloc.alloc(ir.types.PathSegment, 1);
    generic_segments[0] = .{ .name = "T", .id = null };
    const generic_ty: ir.types.Type = .{ .path = .{
        .segments = generic_segments,
    } };
    const input_segments = try alloc.alloc(ir.types.PathSegment, 3);
    input_segments[0] = .{ .name = "T", .id = null };
    input_segments[1] = .{ .name = "FletcherAccumulator", .id = null };
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

    const method_bodies = [_]ir.bodies.StructMethod{
        .{
            .name = "with_initial_values",
            .params = &.{
                .{ .name = "a", .ty = input_ty, .span = span },
                .{ .name = "b", .ty = input_ty, .span = span },
            },
            .ret = self_ty,
            .body = 0,
        },
        .{
            .name = "update",
            .params = &.{
                .{ .name = "data", .ty = .{ .slice = input_slice }, .span = span },
            },
            .ret = .{ .prim = .unit },
            .body = 0,
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
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    const rust_ir = ir.RustIR{
        .crate_name = "fletcher",
        .edition = "2021",
        .graph = graph,
        .types = &.{},
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &.{},
            .types = &.{},
            .bodies = &.{ .none, struct_body },
        },
    };
    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);
    const struct_decl = pkg.files[0].decls[0].struct_decl;

    var saw_constructor = false;
    var saw_update = false;
    for (struct_decl.decls) |decl| {
        const method = decl.fn_decl;
        if (std.mem.eql(u8, method.name, "with_initial_values")) {
            saw_constructor = true;
            try std.testing.expectEqualStrings("T", method.params[0].ty.named);
            try std.testing.expectEqualStrings("T", method.params[1].ty.named);
            try std.testing.expect(method.ret_type == .generic);
            try std.testing.expectEqualStrings("Fletcher", method.ret_type.generic.name);
        } else if (std.mem.eql(u8, method.name, "update")) {
            saw_update = true;
            try std.testing.expect(method.params[0].ty == .ptr);
            try std.testing.expect(!method.params[0].ty.ptr.is_const);
            try std.testing.expect(method.params[0].ty.ptr.elem.* == .generic);
            try std.testing.expectEqualStrings("Fletcher", method.params[0].ty.ptr.elem.generic.name);
            try std.testing.expectEqualStrings("T", method.params[1].ty.slice.elem.*.named);
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

    const rust_ir = ir.RustIR{
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
    const pkg = try lower.lowerRustIR(alloc, &rust_ir, null);
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

    const rust_ir = ir.RustIR{
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
    return lower.lowerRustIR(alloc, &rust_ir, null);
}

fn sourceFidelityRootFile(pkg: ast.Package) !ast.File {
    for (pkg.files) |file| {
        if (std.mem.eql(u8, file.path, "src/root.zig")) return file;
    }
    return error.RootFileMissing;
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
