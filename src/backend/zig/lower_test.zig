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
    const e_match = try model.e(.{
        .match = .{
            .scrutinee = e_scrut,
            .arms = &.{
                .{
                    .patterns = &.{p_wild},
                    .guard = null,
                    .body = e_arm_body,
                },
            },
            .option_scrutinee = false,
        },
    });

    // var x = 1  (let statement inside the test-fn block)
    const e_one = try model.e(litInt(1));
    const p_bind_x = try model.pat(.{ .binding = .{ .name = "x", .mode = .{ .value = {} }, .mutable = false } });
    const s_let_x = try model.stmt(.{
        .let = .{ .pattern = p_bind_x, .init = e_one, .ty = null },
    });
    const e_test_block = try model.e(.{
        .block = .{ .statements = &.{s_let_x}, .tail = null, .labelled = null },
    });

    // ── Bodies ────────────────────────────────────────────────────────────
    try model.bodies.append(model.a(), .{
        .struct_ = .{
            .fields = &.{
                .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
                .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
            },
            .methods = &.{
                .{
                    .name = "dist",
                    .visibility = .public,
                    .params = &.{},
                    .ret = .{ .prim = .u64 },
                    .body = e_dist_block,
                    .receiver = .ref_,
                },
            },
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
    try std.testing.expectEqual(@as(usize, 1), file.tests[0].body.stmts.len);
    try std.testing.expect(file.tests[0].body.stmts[0] == .let_stmt);
    try std.testing.expectEqualStrings("x", file.tests[0].body.stmts[0].let_stmt.name);
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
    const e_pt_lit = try model.e(.{
        .struct_lit = .{
            .def = point_id,
            .fields = &.{
                .{ .field = "x", .value = e_x, .shorthand = false },
                .{ .field = "y", .value = e_y, .shorthand = false },
            },
            .base = null,
        },
    });
    const e_pt_block = try model.e(.{ .block = .{ .statements = &.{}, .tail = e_pt_lit, .labelled = null } });

    // first_char body: block { tail = literal 'A' }
    const e_char = try model.e(.{ .literal = .{ .character = .{ .text = "'A'", .value = 'A' } } });
    const e_char_block = try model.e(.{ .block = .{ .statements = &.{}, .tail = e_char, .labelled = null } });

    // Bodies (indexed by entity id):
    //  id0: Point struct (no fields)
    try model.bodies.append(model.a(), .{ .struct_ = .{
        .fields = &.{},
        .methods = &.{},
    } });
    //  id1: make_point → path Point, body = pt block
    try model.bodies.append(model.a(), .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .path = .{ .segments = &.{ .{ .name = "Point", .id = point_id } } } },
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
