//! monomorphize_test — tests for P5 generic instantiation records and suffix mangling.
//!
//! C-free: this file links under pure `zig build test` without tree-sitter C.
//!
//! Asserts the 3 contract requirements:
//! 1. `mangleSuffix` produces unique readable Zig identifiers for generic args (`_u32`, `_f64`, `_u8_slice`, `_u64_u32`).
//! 2. `InstantiationTable` deduplicates identical generic instantiations.
//! 3. `collectInstantiations` records generic `Foo<T>` instantiated with `u32` and `&[u8]`.

const std = @import("std");
const monomorphize = @import("monomorphize.zig");
const ir = @import("translate_rust.ir");
const types = ir.types;
const spine = ir.spine;
const graph = ir.graph;
const bodies = ir.bodies;
const exprs = ir.exprs;
const items = ir.items;

const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

test "mangleSuffix produces unique readable Zig identifiers for generic args" {
    const alloc = std.testing.allocator;

    // 1. Primitive u32 -> "_u32"
    const s_u32 = try monomorphize.mangleSuffix(alloc, .{
        .params = &.{.{ .prim = .u32 }},
    });
    defer alloc.free(s_u32);
    try std.testing.expectEqualStrings("_u32", s_u32);

    // 2. Primitive f64 -> "_f64"
    const s_f64 = try monomorphize.mangleSuffix(alloc, .{
        .params = &.{.{ .prim = .f64 }},
    });
    defer alloc.free(s_f64);
    try std.testing.expectEqualStrings("_f64", s_f64);

    // 3. Slice &[u8] -> "_u8_slice"
    const u8_slice: types.Slice = .{
        .const_ = true,
        .elem = .{ .prim = .u8 },
    };
    const s_slice = try monomorphize.mangleSuffix(alloc, .{
        .params = &.{.{ .slice = &u8_slice }},
    });
    defer alloc.free(s_slice);
    try std.testing.expectEqualStrings("_u8_slice", s_slice);

    // 4. Multiple generic args [u64, u32] -> "_u64_u32"
    const s_u64_u32 = try monomorphize.mangleSuffix(alloc, .{
        .params = &.{
            .{ .prim = .u64 },
            .{ .prim = .u32 },
        },
    });
    defer alloc.free(s_u64_u32);
    try std.testing.expectEqualStrings("_u64_u32", s_u64_u32);
}

test "InstantiationTable deduplicates identical generic instantiations" {
    const alloc = std.testing.allocator;

    var table = monomorphize.InstantiationTable{};
    defer table.deinit(alloc);

    const generic_foo_id: spine.EntityId = 42;
    const args_u32: types.GenericArgs = .{
        .params = &.{.{ .prim = .u32 }},
    };

    // First insertion of Foo<u32>
    const idx1 = try table.addOrGet(alloc, generic_foo_id, args_u32);
    try std.testing.expectEqual(@as(usize, 0), idx1);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // Second insertion of identical Foo<u32> must deduplicate
    const idx2 = try table.addOrGet(alloc, generic_foo_id, args_u32);
    try std.testing.expectEqual(@as(usize, 0), idx2);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // Verify record contents
    const inst = table.get(0).?;
    try std.testing.expectEqual(generic_foo_id, inst.generic_id);
    try std.testing.expectEqualStrings("_u32", inst.zig_suffix);
}

test "collectInstantiations records generic Foo<T> instantiated with u32 and &[u8]" {
    const alloc = std.testing.allocator;

    // ── Build CrateGraph with generic struct Foo<T> ─────────────────────────
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    // Module 0: crate root
    const root_id = try g.symbol_table.add(.{
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
    _ = try g.addModule(.{
        .id = root_id,
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

    // Struct 1: generic Foo<T>
    const foo_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Foo"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Fn 2: bar() caller containing expressions referencing Foo<u32> and Foo<&[u8]>
    const bar_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "bar"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // ── Build Bodies containing Foo<u32> and Foo<&[u8]> path expressions ─────
    // monomorphize.zig tracks visited nodes with a single bool array indexed
    // by NodeId across the expr/stmt/pat tables. To avoid an id-space collision
    // (an ExprStmt at stmt-id `i` pointing at expr-id `i` would be skipped),
    // the path exprs live at expr ids offset past the stmt-id range: stmts
    // occupy 0..2, paths live at exprs 2..4, and the fn-body block is expr 4.
    const u8_slice: types.Slice = .{
        .const_ = true,
        .elem = .{ .prim = .u8 },
    };

    const exprs_store = try alloc.alloc(exprs.Expr, 5);
    defer alloc.free(exprs_store);

    // Expr 0, 1: dummy padding so path exprs get ids past the stmt-id range.
    exprs_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } };
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .unit = {} } };

    // Expr 2: PathExpr Foo<u32>
    const args_u32 = try alloc.alloc(types.Type, 1);
    defer alloc.free(args_u32);
    args_u32[0] = .{ .prim = .u32 };

    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{
            .def = foo_id,
            .generic_args = args_u32,
        } },
    };

    // Expr 3: PathExpr Foo<&[u8]>
    const args_slice = try alloc.alloc(types.Type, 1);
    defer alloc.free(args_slice);
    args_slice[0] = .{ .slice = &u8_slice };

    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{
            .def = foo_id,
            .generic_args = args_slice,
        } },
    };

    // Expr 4: BlockExpr containing statements that reference Expr 2 and Expr 3
    const stmt_ids = try alloc.alloc(exprs.NodeId, 2);
    defer alloc.free(stmt_ids);
    stmt_ids[0] = 0;
    stmt_ids[1] = 1;

    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = stmt_ids,
            .tail = null,
            .labelled = null,
        } },
    };

    // Statements
    const stmts_store = try alloc.alloc(exprs.Statement, 2);
    defer alloc.free(stmts_store);

    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 2 },
    };
    stmts_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 3 },
    };

    // Bodies array indexed by EntityId
    const bodies_store = try alloc.alloc(bodies.BodyKind, 3);
    defer alloc.free(bodies_store);

    bodies_store[root_id] = .none;
    bodies_store[foo_id] = .none;
    bodies_store[bar_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 4,
    } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };

    // ── Run collectInstantiations ───────────────────────────────────────────
    var table = try monomorphize.collectInstantiations(alloc, &g, &b);
    defer table.deinit(alloc);

    // Exactly 2 instantiations produced
    try std.testing.expectEqual(@as(usize, 2), table.count());

    // Both instantiations target generic foo_id
    const inst0 = table.get(0).?;
    const inst1 = table.get(1).?;
    try std.testing.expectEqual(foo_id, inst0.generic_id);
    try std.testing.expectEqual(foo_id, inst1.generic_id);

    // One is _u32, one is _u8_slice
    try std.testing.expectEqualStrings("_u32", inst0.zig_suffix);
    try std.testing.expectEqualStrings("_u8_slice", inst1.zig_suffix);
}
test "collectInstantiations distinguishes Foo primitive and slice call-site qualifiers" {
    const a = std.testing.allocator;

    const const_slice: types.Slice = .{
        .const_ = true,
        .elem = .{ .prim = .u8 },
    };
    const mut_slice: types.Slice = .{
        .const_ = false,
        .elem = .{ .prim = .u8 },
    };
    const args_u32 = [_]types.Type{.{ .prim = .u32 }};
    const args_const_slice = [_]types.Type{.{ .slice = &const_slice }};
    const args_mut_slice = [_]types.Type{.{ .slice = &mut_slice }};

    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = 7, .generic_args = &args_u32 } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = 7, .generic_args = &args_const_slice } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = 7, .generic_args = &args_mut_slice } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{ 0, 1, 2 },
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 0 } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 1 } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .expr = 2 } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 3,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    var table = try monomorphize.collectInstantiations(a, &g, &b);
    defer table.deinit(a);

    try std.testing.expectEqual(@as(usize, 3), table.count());
    const primitive = table.get(0).?;
    const const_slice_inst = table.get(1).?;
    const mut_slice_inst = table.get(2).?;
    try std.testing.expectEqual(@as(spine.EntityId, 7), primitive.generic_id);
    try std.testing.expectEqual(@as(spine.EntityId, 7), const_slice_inst.generic_id);
    try std.testing.expectEqual(@as(spine.EntityId, 7), mut_slice_inst.generic_id);
    try std.testing.expectEqualStrings("_u32", primitive.zig_suffix);
    try std.testing.expectEqualStrings("_u8_slice", const_slice_inst.zig_suffix);
    try std.testing.expectEqualStrings("_u8_mut_slice", mut_slice_inst.zig_suffix);
    try std.testing.expect(!std.mem.eql(u8, const_slice_inst.zig_suffix, mut_slice_inst.zig_suffix));
}
