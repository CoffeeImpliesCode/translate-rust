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

test "serialize: explicit Vec literal preserves wire payload and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 3,
        .start_col = 5,
        .end_line = 3,
        .end_col = 20,
    };
    const element_ids = [_]exprs.NodeId{ 2, 0, 1 };
    const expr_arr = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = &element_ids,
                .repeat = null,
            } },
        },
    };
    const body_kinds = [_]bodies.BodyKind{};
    const ir_types = [_]types.Type{};
    const sample_ir: serialize.RustIR = .{
        .crate_name = "vec_list",
        .edition = "2021",
        .graph = graph.CrateGraph.init(alloc),
        .types = &ir_types,
        .bodies = .{
            .exprs = &expr_arr,
            .stmts = &.{},
            .pats = &.{},
            .types = &ir_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(alloc, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"vec_lit\",\"value\":{\"elements\":[2,0,1],\"repeat\":null}",
    ) != null);

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();
    const decoded_vec = switch (decoded.bodies.exprs[3].kind) {
        .vec_lit => |vec| vec,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(exprs.NodeId, &element_ids, decoded_vec.elements);
    try std.testing.expectEqual(@as(?usize, null), decoded_vec.repeat);
}

test "serialize: repeat Vec literal preserves wire payload and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 7,
        .start_col = 9,
        .end_line = 7,
        .end_col = 18,
    };
    const element_ids = [_]exprs.NodeId{0};
    const expr_arr = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = &element_ids,
                .repeat = 13,
            } },
        },
    };
    const body_kinds = [_]bodies.BodyKind{};
    const ir_types = [_]types.Type{};
    const sample_ir: serialize.RustIR = .{
        .crate_name = "vec_repeat",
        .edition = "2021",
        .graph = graph.CrateGraph.init(alloc),
        .types = &ir_types,
        .bodies = .{
            .exprs = &expr_arr,
            .stmts = &.{},
            .pats = &.{},
            .types = &ir_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(alloc, &sample_ir);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "\"kind\":\"vec_lit\",\"value\":{\"elements\":[0],\"repeat\":13}",
    ) != null);

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();
    const decoded_vec = switch (decoded.bodies.exprs[1].kind) {
        .vec_lit => |vec| vec,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(exprs.NodeId, &element_ids, decoded_vec.elements);
    try std.testing.expectEqual(@as(?usize, 13), decoded_vec.repeat);
}

test "serialize: unsupported pattern preserves reason-only wire payload and roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span: spine.Span = .{
        .start_line = 11,
        .start_col = 9,
        .end_line = 11,
        .end_col = 28,
    };
    const patterns = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "slice pattern",
            .suggested_version = .v1,
        } },
    }};
    const body_kinds = [_]bodies.BodyKind{};
    const ir_types = [_]types.Type{};
    const sample_ir: serialize.RustIR = .{
        .crate_name = "unsupported_pattern",
        .edition = "2021",
        .graph = graph.CrateGraph.init(alloc),
        .types = &ir_types,
        .bodies = .{
            .exprs = &.{},
            .stmts = &.{},
            .pats = &patterns,
            .types = &ir_types,
            .bodies = &body_kinds,
        },
    };

    const encoded = try serialize.encode(alloc, &sample_ir);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();
    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const body_object = switch (root_object.get("bodies") orelse return error.TestUnexpectedResult) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    const pattern_values = switch (body_object.get("pats") orelse return error.TestUnexpectedResult) {
        .array => |array| array.items,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), pattern_values.len);
    const pattern_object = switch (pattern_values[0]) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(
        "unsupported",
        switch (pattern_object.get("kind") orelse return error.TestUnexpectedResult) {
            .string => |kind| kind,
            else => return error.TestUnexpectedResult,
        },
    );
    const unsupported_value = switch (pattern_object.get("value") orelse return error.TestUnexpectedResult) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), unsupported_value.count());
    try std.testing.expectEqualStrings(
        "slice pattern",
        switch (unsupported_value.get("reason") orelse return error.TestUnexpectedResult) {
            .string => |reason| reason,
            else => return error.TestUnexpectedResult,
        },
    );

    var decoded = try serialize.decode(alloc, encoded);
    defer decoded.graph.deinit();
    const decoded_unsupported = switch (decoded.bodies.pats[0].kind) {
        .unsupported => |unsupported| unsupported,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("slice pattern", decoded_unsupported.reason);
}
