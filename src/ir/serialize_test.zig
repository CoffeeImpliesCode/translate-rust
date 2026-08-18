//! serialize_test.zig — roundtrip encoding and decoding tests for RustIR.

const std = @import("std");
const root = @import("root.zig");
const spine = root.spine;
const graph = root.graph;
const types = root.types;
const exprs = root.exprs;
const bodies = root.bodies;
const serialize = root.serialize;

test "serialize: RustIR roundtrip with entities, types, and bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 10, .end_col = 1 };

    // Add root module entity (0)
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "test_crate"),
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
        .name = "test_crate",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    _ = try g.addCrate(.{
        .name = "test_crate",
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });
    _ = try g.symbol_table.add(.{
        .id = 1,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Point"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Add a function entity new_point (2)
    _ = try g.symbol_table.add(.{
        .id = 2,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "new_point"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const ir_types = try alloc.alloc(types.Type, 2);
    ir_types[0] = .{ .prim = .i32 };
    ir_types[1] = .{ .path = .{ .segments = &.{.{ .name = "Point", .id = 1 }} } };

    const expr_arr = try alloc.alloc(exprs.Expr, 2);
    expr_arr[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "42", .value = 42, .base = .dec, .ty_suffix = null } } },
    };
    expr_arr[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    };

    const bodies_arr = try alloc.alloc(bodies.BodyKind, 3);
    bodies_arr[0] = .none;
    bodies_arr[1] = .{ .struct_ = .{
        .generic_params = &.{},
        .layout = .named,
        .fields = &.{
            .{ .name = "x", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
            .{ .name = "y", .ty = .{ .prim = .i32 }, .visibility = .public, .span = span },
        },
    } };
    bodies_arr[2] = .{ .fn_ = .{
        .params = &.{},
        .ret = ir_types[1],
        .body = 1,
    } };

    const sample_ir: serialize.RustIR = .{
        .crate_name = "test_crate",
        .edition = "2021",
        .graph = g,
        .types = ir_types,
        .bodies = .{
            .exprs = expr_arr,
            .stmts = &.{},
            .pats = &.{},
            .types = ir_types,
            .bodies = bodies_arr,
        },
    };

    const encoded = try serialize.encode(alloc, &sample_ir);
    try std.testing.expect(encoded.len > 0);

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();

    try std.testing.expectEqualStrings("test_crate", decoded.crate_name);
    try std.testing.expectEqualStrings("2021", decoded.edition);
    try std.testing.expectEqual(@as(usize, 3), decoded.graph.symbol_table.entities.items.len);
    try std.testing.expectEqualStrings("Point", decoded.graph.symbol_table.entities.items[1].name);
    try std.testing.expectEqualStrings("new_point", decoded.graph.symbol_table.entities.items[2].name);
    try std.testing.expectEqual(@as(usize, 2), decoded.bodies.exprs.len);
    try std.testing.expectEqual(@as(usize, 3), decoded.bodies.bodies.len);
}
