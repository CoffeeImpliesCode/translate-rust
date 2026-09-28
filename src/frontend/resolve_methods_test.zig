//! resolve_methods_test — unit tests for Method, Trait, Operator, and Constructor resolution (P4).
//!
//! Pure Zig (C-free): tests run without tree-sitter C dependencies.
//! Imports only resolve_methods, graph, spine, types, bodies, items, exprs.

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const graph = ir.graph;
const types = ir.types;
const bodies = ir.bodies;
const items = ir.items;
const exprs = ir.exprs;
const resolve_methods = @import("resolve_methods.zig");

const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

fn addEntity(
    g: *graph.CrateGraph,
    a: std.mem.Allocator,
    kind: spine.EntityKind,
    name: []const u8,
    parent: ?spine.EntityId,
) !spine.EntityId {
    return try g.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = try a.dupe(u8, name),
        .span = span,
        .visibility = .public,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
}
fn expectUnsupported(expr: *const exprs.Expr) !void {
    switch (expr.kind) {
        .unsupported => |u| {
            try std.testing.expect(u.reason.len > 0);
            try std.testing.expect(u.reason.len <= 4096);
        },
        else => try std.testing.expect(false),
    }
}

fn expectUnsupportedReason(expr: *const exprs.Expr, reason: []const u8) !void {
    try expectUnsupported(expr);
    try std.testing.expectEqualStrings(reason, expr.kind.unsupported.reason);
}

test "trait method dispatch rewrites a unique concrete receiver candidate" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    _ = try addEntity(&g, a, .trait_, "Display", root);
    const display_impl = try addEntity(&g, a, .impl_, "Display for Foo", root);
    const fn_render = try addEntity(&g, a, .fn_, "render", display_impl);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);

    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Foo", .id = null }} } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = render_ident,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.trait_resolved);
    try std.testing.expectEqual(@as(spine.EntityId, fn_render), b.exprs[1].kind.method_call.method);
}

test "trait method dispatch marks distinct candidates as unsupported" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    _ = try addEntity(&g, a, .trait_, "Display", root);
    _ = try addEntity(&g, a, .trait_, "Debug", root);
    const display_impl = try addEntity(&g, a, .impl_, "Display for Foo", root);
    _ = try addEntity(&g, a, .fn_, "render", display_impl);
    const debug_impl = try addEntity(&g, a, .impl_, "Debug for Foo", root);
    _ = try addEntity(&g, a, .fn_, "render", debug_impl);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);

    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Foo", .id = null }} } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = render_ident,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    _ = try resolve_methods.resolveMethods(&g, &b);
    try expectUnsupported(&b.exprs[1]);
}

test "unknown method dispatch marks only the call as unsupported" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    const missing_ident = try addEntity(&g, a, .fn_, "missing", root);

    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Foo", .id = null }} } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = missing_ident,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    _ = try resolve_methods.resolveMethods(&g, &b);
    try expectUnsupported(&b.exprs[1]);
}

test "inherent dispatch normalizes generic impl receiver spelling" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Fletcher", root);
    const fletcher_impl = try addEntity(&g, a, .impl_, "Fletcher<T>", root);
    const fn_update = try addEntity(&g, a, .fn_, "update", fletcher_impl);
    const update_ident = try addEntity(&g, a, .fn_, "update", root);

    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Fletcher", .id = null }} } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .mutable,
                .method = update_ident,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    try std.testing.expectEqual(@as(spine.EntityId, fn_update), b.exprs[1].kind.method_call.method);
}

test "inherent method resolution for Fletcher16 new, update, and value" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Fletcher16", root);

    // Inherent impl Fletcher16 { fn new; fn update; fn value; }
    const fletcher_impl = try addEntity(&g, a, .impl_, "Fletcher16", root);
    const fn_new = try addEntity(&g, a, .fn_, "new", fletcher_impl);
    const fn_update = try addEntity(&g, a, .fn_, "update", fletcher_impl);
    const fn_value = try addEntity(&g, a, .fn_, "value", fletcher_impl);

    // Inherent method lookup
    try std.testing.expectEqual(@as(?spine.EntityId, fn_new), resolve_methods.lookupInherentMethod(&g, "Fletcher16", "new"));
    try std.testing.expectEqual(@as(?spine.EntityId, fn_update), resolve_methods.lookupInherentMethod(&g, "Fletcher16", "update"));
    try std.testing.expectEqual(@as(?spine.EntityId, fn_value), resolve_methods.lookupInherentMethod(&g, "Fletcher16", "value"));

    // Unknown method or unknown type returns null
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupInherentMethod(&g, "Fletcher16", "nonexistent"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupInherentMethod(&g, "UnknownType", "new"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupInherentMethod(&g, "", "new"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupInherentMethod(&g, "Fletcher16", ""));

    // Constructor lookup delegates to inherent method
    try std.testing.expectEqual(@as(?spine.EntityId, fn_new), resolve_methods.lookupConstructor(&g, "Fletcher16", "new"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupConstructor(&g, "Fletcher16", "create"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupConstructor(&g, "UnknownType", "new"));
}

test "trait method resolution and ambiguity handling" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);

    // impl Default for Foo { fn default; }
    const default_impl = try addEntity(&g, a, .impl_, "Default for Foo", root);
    const fn_default = try addEntity(&g, a, .fn_, "default", default_impl);

    // Valid trait method resolution
    try std.testing.expectEqual(@as(?spine.EntityId, fn_default), resolve_methods.lookupTraitMethod(&g, "Default", "Foo", "default"));

    // Mismatched trait / type / method
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "Clone", "Foo", "clone"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "Default", "Bar", "default"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "Default", "Foo", "nonexistent"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "", "Foo", "default"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "Default", "", "default"));
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "Default", "Foo", ""));

    // Ambiguity handling: multiple candidates for Default for Foo return null
    const default_impl2 = try addEntity(&g, a, .impl_, "Default for Foo", root);
    _ = try addEntity(&g, a, .fn_, "default", default_impl2);

    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupTraitMethod(&g, "Default", "Foo", "default"));
}

test "std prelude methods lookup on Option, Result, slice, numerics" {
    // Option methods
    const opt_inner: types.Type = .{ .prim = .u32 };
    const opt_ty: types.Type = .{ .option = &opt_inner };

    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_is_some), resolve_methods.lookupStdMethod(opt_ty, "is_some"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_is_none), resolve_methods.lookupStdMethod(opt_ty, "is_none"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_unwrap), resolve_methods.lookupStdMethod(opt_ty, "unwrap"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_unwrap_or), resolve_methods.lookupStdMethod(opt_ty, "unwrap_or"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_map), resolve_methods.lookupStdMethod(opt_ty, "map"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_as_ref), resolve_methods.lookupStdMethod(opt_ty, "as_ref"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .option_take), resolve_methods.lookupStdMethod(opt_ty, "take"));

    // Result methods
    const res_payload: types.Result = .{
        .ok = .{ .prim = .u32 },
        .err = .{ .prim = .u8 },
        .is_error_unionable = true,
    };
    const res_ty: types.Type = .{ .result = &res_payload };

    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_is_ok), resolve_methods.lookupStdMethod(res_ty, "is_ok"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_is_err), resolve_methods.lookupStdMethod(res_ty, "is_err"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_unwrap), resolve_methods.lookupStdMethod(res_ty, "unwrap"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_unwrap_or), resolve_methods.lookupStdMethod(res_ty, "unwrap_or"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_map), resolve_methods.lookupStdMethod(res_ty, "map"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_map_err), resolve_methods.lookupStdMethod(res_ty, "map_err"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .result_as_ref), resolve_methods.lookupStdMethod(res_ty, "as_ref"));

    // Slice and Array methods
    const slice_payload: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const slice_ty: types.Type = .{ .slice = &slice_payload };
    const array_payload: types.Array = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 16 } };
    const array_ty: types.Type = .{ .array = &array_payload };

    for ([_]types.Type{ slice_ty, array_ty }) |st| {
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .slice_len), resolve_methods.lookupStdMethod(st, "len"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .slice_is_empty), resolve_methods.lookupStdMethod(st, "is_empty"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .slice_as_bytes), resolve_methods.lookupStdMethod(st, "as_bytes"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .slice_as_slice), resolve_methods.lookupStdMethod(st, "as_slice"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .slice_iter), resolve_methods.lookupStdMethod(st, "iter"));
    }

    const usize_ty: types.Type = .{ .prim = .usize };

    // Numeric primitive methods (wrapping, saturating, bitwise)
    const u64_ty: types.Type = .{ .prim = .u64 };
    const i32_ty: types.Type = .{ .prim = .i32 };
    for ([_]types.Type{ u64_ty, i32_ty, usize_ty }) |num_ty| {
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_wrapping_add), resolve_methods.lookupStdMethod(num_ty, "wrapping_add"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_wrapping_sub), resolve_methods.lookupStdMethod(num_ty, "wrapping_sub"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_wrapping_mul), resolve_methods.lookupStdMethod(num_ty, "wrapping_mul"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_saturating_add), resolve_methods.lookupStdMethod(num_ty, "saturating_add"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_saturating_sub), resolve_methods.lookupStdMethod(num_ty, "saturating_sub"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_saturating_mul), resolve_methods.lookupStdMethod(num_ty, "saturating_mul"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_count_ones), resolve_methods.lookupStdMethod(num_ty, "count_ones"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_leading_zeros), resolve_methods.lookupStdMethod(num_ty, "leading_zeros"));
        try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_trailing_zeros), resolve_methods.lookupStdMethod(num_ty, "trailing_zeros"));
    }

    // Reference unwrapping
    const ref_payload: types.Ref = .{ .mut = false, .pointee = u64_ty };
    const ref_ty: types.Type = .{ .reference = &ref_payload };
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .num_wrapping_add), resolve_methods.lookupStdMethod(ref_ty, "wrapping_add"));

    // Universal traits (default, clone)
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .default), resolve_methods.lookupStdMethod(u64_ty, "default"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, .clone), resolve_methods.lookupStdMethod(u64_ty, "clone"));

    // Unknown method returns null
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, null), resolve_methods.lookupStdMethod(u64_ty, "custom_method"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, null), resolve_methods.lookupStdMethod(.{ .prim = .bool }, "wrapping_add"));
    try std.testing.expectEqual(@as(?resolve_methods.StdMethod, null), resolve_methods.lookupStdMethod(u64_ty, ""));
}

test "resolveMethods on bodies with inferred types updates method entity id" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Fletcher16", root);

    // Inherent impl Fletcher16 { fn update; }
    const fletcher_impl = try addEntity(&g, a, .impl_, "Fletcher16", root);
    const fn_update = try addEntity(&g, a, .fn_, "update", fletcher_impl);

    // Placeholder entity for the unresolved method name "update"
    const update_ident = try addEntity(&g, a, .fn_, "update", root);
    // Placeholder entity for std method "wrapping_add"
    const wrapping_add_ident = try addEntity(&g, a, .fn_, "wrapping_add", root);
    // Placeholder entity for unsupported method "unknown_fn"
    const unknown_fn_ident = try addEntity(&g, a, .fn_, "unknown_fn", root);

    // Setup types table:
    // 0 = Path(Fletcher16)
    // 1 = Prim(u64)
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Fletcher16", .id = null }} } },
        .{ .prim = .u64 },
    };

    // Setup exprs:
    // 0: receiver of type Fletcher16 (ty = 0)
    // 1: method_call receiver.update()
    // 2: receiver of type u64 (ty = 1)
    // 3: method_call receiver.wrapping_add()
    // 4: method_call receiver.unknown_fn()
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 0, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{
                .method_call = .{
                    .receiver = 0,
                    .receiver_mode = .mutable,
                    .method = update_ident,
                    .args = &.{},
                },
            },
        },
        .{
            .id = 2,
            .span = span,
            .ty = 1,
            .kind = .{ .path = .{ .def = 0, .generic_args = &.{} } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{
                .method_call = .{
                    .receiver = 2,
                    .receiver_mode = .shared,
                    .method = wrapping_add_ident,
                    .args = &.{},
                },
            },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{
                .method_call = .{
                    .receiver = 0,
                    .receiver_mode = .shared,
                    .method = unknown_fn_ident,
                    .args = &.{},
                },
            },
        },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Inherent method "update" resolved and entity ID updated
    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    try std.testing.expectEqual(@as(spine.EntityId, fn_update), b.exprs[1].kind.method_call.method);

    // Std method "wrapping_add" resolved
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);

    // Unsupported method "unknown_fn" counted
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
}

test "equality through a reference compares the pointed-to array" {
    // Resolving an operator borrows storage for the type it synthesizes, so
    // the graph is built on an arena exactly as the production pipeline does.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const test_fn = try addEntity(&g, a, .fn_, "test_encode_to_slice", root);
    // The local is parented to its function, exactly as `let mut output_1`
    // is in hex's test module.
    const output = try addEntity(&g, a, .field, "output", test_fn);

    // 0 = [u8; 4]
    const array_ty: types.Type = .{ .array = &.{
        .elem = .{ .prim = .u8 },
        .len = .{ .literal = 4 },
    } };
    var types_store = [_]types.Type{array_ty};

    // 0: `0`, 1: `[0; 4]`, 2: `output`, 3: `&output`, 4: b"kiwi",
    // 5: `&output == b"kiwi"`, 6: the test body block
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{ .text = "0", .value = 0, .base = .dec, .ty_suffix = null } } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .array = .{ .elements = &.{0}, .repeat = 4 } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = output, .generic_args = &.{} } },
        },
        .{
            .id = 3,
            .span = span,
            // The borrow node itself carries no type, exactly as the frontend
            // leaves it for `&output_1` in hex's test module.
            .ty = null,
            .kind = .{ .unary = .{ .op = .{ .ref = .shared }, .operand = 2 } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .byte_array = .{ .items = &.{ 107, 105, 119, 105 } } } },
        },
        .{
            .id = 5,
            .span = span,
            .ty = null,
            .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 3, .rhs = 4 } },
        },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{0}, .tail = null, .labelled = null } },
        },
    };

    var pats_store = [_]exprs.Pattern{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .binding = .{ .name = "output", .mode = .value, .mutable = true } },
        },
    };

    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .let = .{ .pattern = 0, .init = 1, .ty = null } } },
    };

    // Indexed by entity id: 0 = module, 1 = test fn, 2 = the local binding.
    var bodies_store = [_]bodies.BodyKind{
        bodies.BodyKind.none,
        .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 6 } },
        bodies.BodyKind.none,
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[5].kind == .binary);
}

test "equality admits a Result whose payloads are comparable" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const decode = try addEntity(&g, a, .fn_, "decode", root);
    const error_enum = try addEntity(&g, a, .enum_, "FromHexError", root);
    const odd_length = try addEntity(&g, a, .enum_, "OddLength", error_enum);

    // 0 = Result<(), FromHexError>
    const result_ty: types.Type = .{ .result = &.{
        .ok = .{ .prim = .unit },
        .err = .{ .path = .{ .segments = &.{.{ .name = "FromHexError", .id = null }} } },
        .is_error_unionable = false,
    } };
    var types_store = [_]types.Type{result_ty};

    // 0: call decode(..), 1: FromHexError::OddLength, 2: `decode(..) == OddLength`
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .call = .{
                .call_kind = .{ .free = decode },
                .args = &.{},
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = 0,
            .kind = .{ .enum_variant = .{
                .def = odd_length,
                .variant = "OddLength",
                .tuple_fields = &.{},
                .named_fields = &.{},
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 0, .rhs = 1 } },
        },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
}

test "a method call on an untyped enum variant recovers the owning enum" {
    // Recovering the receiver's type borrows storage for the synthesized
    // path, so the graph is built on an arena exactly as production does.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const error_enum = try addEntity(&g, a, .enum_, "FromHexError", root);
    // The two shapes an `enum_variant` node can carry: the enum itself, and
    // the variant entity one level below it.
    const odd_length = try addEntity(&g, a, .variant, "OddLength", error_enum);
    const display_impl = try addEntity(&g, a, .impl_, "fmt::Display for FromHexError", root);
    const fn_render = try addEntity(&g, a, .fn_, "render", display_impl);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);
    const missing_ident = try addEntity(&g, a, .fn_, "not_a_method", root);

    // 0: `FromHexError::OddLength` (names the enum), 1: its `.render()` call,
    // 2: `FromHexError::InvalidStringLength` (names the variant entity),
    // 3: its `.render()` call, 4: its `.not_a_method()` call.
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            // The frontend leaves a bare unit variant untyped in value
            // position, exactly as `error.rs:53` reaches the resolver.
            .ty = null,
            .kind = .{ .enum_variant = .{
                .def = error_enum,
                .variant = "OddLength",
                .tuple_fields = &.{},
                .named_fields = &.{},
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = render_ident,
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .enum_variant = .{
                .def = odd_length,
                .variant = "OddLength",
                .tuple_fields = &.{},
                .named_fields = &.{},
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .shared,
                .method = render_ident,
                .args = &.{},
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .shared,
                .method = missing_ident,
                .args = &.{},
            } },
        },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Both spellings of the receiver reach the same owning enum, so both
    // trait calls resolve to the one `Display::render` in the crate.
    try std.testing.expectEqual(@as(usize, 2), stats.trait_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(@as(spine.EntityId, fn_render), b.exprs[1].kind.method_call.method);
    try std.testing.expectEqual(@as(spine.EntityId, fn_render), b.exprs[3].kind.method_call.method);

    // Recovering the receiver type is not a blanket pass: a method the
    // owning enum does not have is still refused.
    try expectUnsupported(&b.exprs[4]);
}

test "literal and array receivers recover their own type, untyped elements do not" {
    // Recovering a receiver type borrows storage for the type it synthesizes,
    // so the graph is built on an arena exactly as production does.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const len_ident = try addEntity(&g, a, .fn_, "len", root);
    const clone_ident = try addEntity(&g, a, .fn_, "clone", root);

    // 0 = u8, the inferred element type of a suffixed integer literal.
    var types_store = [_]types.Type{.{ .prim = .u8 }};

    // 0: `b"kiwi"`, 1: `b"kiwi".len()`
    // 2: `0_u8`, 3: `[0_u8; 4]`, 4: `[0_u8; 4].len()`
    // 5: `"666f6f626172"`, 6: `"666f6f626172".clone()`
    // 7: an unsuffixed `4`, 8: `4.clone()`
    // 9: an element with no inferred type, 10: `[that; 2]`, 11: `.len()`
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .byte_array = .{ .items = "kiwi" } } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = len_ident,
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = span,
            // A suffixed literal is the shape inference itself produces for
            // `[0; 4]`: the element already carries u8.
            .ty = 0,
            .kind = .{ .literal = .{ .int = .{
                .text = "0_u8",
                .value = 0,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .array = .{ .elements = &.{2}, .repeat = 4 } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 3,
                .receiver_mode = .shared,
                .method = len_ident,
                .args = &.{},
            } },
        },
        .{
            .id = 5,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .string = .{ .bytes = "666f6f626172" } } },
        },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 5,
                .receiver_mode = .shared,
                .method = clone_ident,
                .args = &.{},
            } },
        },
        .{
            .id = 7,
            .span = span,
            // No suffix, so no type: Rust fixes it from context, not the text.
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "4",
                .value = 4,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 8,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 7,
                .receiver_mode = .shared,
                .method = clone_ident,
                .args = &.{},
            } },
        },
        .{
            .id = 9,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "1",
                .value = 1,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 10,
            .span = span,
            .ty = null,
            .kind = .{ .array = .{ .elements = &.{9}, .repeat = 2 } },
        },
        .{
            .id = 11,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 10,
                .receiver_mode = .shared,
                .method = len_ident,
                .args = &.{},
            } },
        },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // `b"kiwi"` is `&[u8; 4]` and `[0_u8; 4]` is `[u8; 4]`, so both reach the
    // array/slice standard methods; `"..."` is `&str` and reaches the
    // universal ones.
    try std.testing.expectEqual(@as(usize, 3), stats.std_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expect(b.exprs[4].kind == .method_call);
    try std.testing.expect(b.exprs[6].kind == .method_call);

    // The recovery is bounded by what the node actually proves. An unsuffixed
    // integer literal has no type until its context supplies one, and an array
    // over an untyped element is not `[T; N]` for any `T` — both stay refused
    // rather than acquiring a guessed primitive.
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_methods);
    try expectUnsupported(&b.exprs[8]);
    try expectUnsupported(&b.exprs[11]);
}

test "to_string resolves only for receivers whose Display is provable" {
    const str_ref: types.Ref = .{ .mut = false, .pointee = types.str_type };
    const string_ty: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "String" },
    } };
    const cow_str_ty: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{types.str_type},
    } };

    // Rust declares `impl<T: Display + ?Sized> ToString for T`, and each of
    // these receivers has a `Display` rendering the backend can emit without
    // consulting the crate graph.
    for ([_]types.Type{
        types.str_type,
        .{ .reference = &str_ref },
        string_ty,
        cow_str_ty,
        .{ .prim = .bool },
        .{ .prim = .char },
        .{ .prim = .u8 },
        .{ .prim = .i64 },
    }) |receiver| {
        try std.testing.expectEqual(
            @as(?resolve_methods.StdMethod, .to_string),
            resolve_methods.lookupStdMethod(receiver, "to_string"),
        );
    }

    // The table stays a whitelist. Rust renders these through `Debug`, not
    // `Display`; floats have a `Display` but no runtime rendering yet; and a
    // crate-local nominal is not provable from its type alone. All of them
    // must keep resolving as unsupported rather than being admitted.
    const opt_inner: types.Type = .{ .prim = .i32 };
    const res_payload: types.Result = .{
        .ok = .{ .prim = .i32 },
        .err = .{ .prim = .u8 },
        .is_error_unionable = true,
    };
    const slice_payload: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const array_payload: types.Array = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 4 } };
    const vec_ty: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const path_ty: types.Type = .{ .path = .{ .segments = &.{.{ .name = "Color", .id = null }} } };

    for ([_]types.Type{
        .{ .option = &opt_inner },
        .{ .result = &res_payload },
        .{ .slice = &slice_payload },
        .{ .array = &array_payload },
        vec_ty,
        .{ .prim = .unit },
        .{ .prim = .never },
        .{ .prim = .f64 },
        path_ty,
    }) |receiver| {
        try std.testing.expectEqual(
            @as(?resolve_methods.StdMethod, null),
            resolve_methods.lookupStdMethod(receiver, "to_string"),
        );
    }
}

test "to_string resolves on a Display impl and is refused on a Debug-only impl" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const shown = try addEntity(&g, a, .struct_, "Shown", root);
    const shown_display = try addEntity(&g, a, .impl_, "fmt::Display for Shown", root);
    _ = try addEntity(&g, a, .fn_, "fmt", shown_display);
    const hidden = try addEntity(&g, a, .struct_, "Hidden", root);
    const hidden_debug = try addEntity(&g, a, .impl_, "core::fmt::Debug for Hidden", root);
    _ = try addEntity(&g, a, .fn_, "fmt", hidden_debug);

    // `to_string` has no declaration in the crate. The frontend reaches it
    // through a synthesized method reference, exactly as it builds one for any
    // call it cannot yet resolve.
    const to_string_ref = try addEntity(&g, a, .method_ref, "to_string", null);

    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Shown", .id = shown }} } },
        .{ .path = .{ .segments = &.{.{ .name = "Hidden", .id = hidden }} } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 0,
                .receiver_mode = .shared,
                .method = to_string_ref,
                .args = &.{},
            } },
        },
        .{ .id = 2, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .shared,
                .method = to_string_ref,
                .args = &.{},
            } },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // `impl Display for Shown` carries a `fmt` member, so the call resolves.
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);

    // `Debug` is a formatting trait, not a `ToString` impl: a Debug-only type
    // cannot call `.to_string()` in Rust, so the resolver must keep refusing
    // it rather than turn a real rejection into a silent pass.
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try expectUnsupported(&b.exprs[3]);
}

// `String` and `Vec<T>` reach the runtime as list-backed Zig owners, so the
// emitter lowers a comparison of two of them to `r2z.ops.equal`, which
// compares the list's `items`. The pair is what decides the comparison, not
// either type alone, so every case below states both operand types.
test "an owned String compares against another owned String by content" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const encode = try addEntity(&g, a, .fn_, "encode", root);

    // 0 = alloc::string::String, 1 = core::primitive::str
    var types_store = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        types.str_type,
    };

    // Two owned strings and the two directions of their comparison, then the
    // same string against a literal the frontend typed as `str`, in both
    // directions. `str` is Rust's unsized byte sequence, so a literal carrying
    // it is a BORROW of a list — the cross-form branch meets it — and not an
    // owner.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = encode },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = encode },
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 1,
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .ne,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 0,
        } } },
        .{ .id = 4, .span = span, .ty = 1, .kind = .{ .literal = .{ .string = .{ .bytes = "abc" } } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 4,
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 4,
            .rhs = 1,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Two owners of the same shape: `r2z.ops.equal` reaches both `bytes`
    // fields and walks the items, so the comparison is by content and the
    // allocated capacity is never read.
    try std.testing.expect(b.exprs[2].kind == .binary);
    try std.testing.expect(b.exprs[3].kind == .binary);

    // The owner-vs-borrow pair is admitted in both directions: the runtime
    // descends into the owner's list and compares it against the literal.
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[5].kind == .binary);
    try std.testing.expect(b.exprs[6].kind == .binary);
}

test "a list owner is admitted only when its elements carry a comparable value" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const bytes = try addEntity(&g, a, .fn_, "bytes", root);
    const handlers = try addEntity(&g, a, .fn_, "handlers", root);

    // 0 = Vec<u8>, 1 = Vec<fn()>
    var types_store = [_]types.Type{
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .fn_ptr = &.{
                .params = &.{},
                .ret = .{ .prim = .unit },
            } }},
        } },
    };

    // 0/1: `bytes(..)`, 2: `Vec<u8> == Vec<u8>`, 3/4: `handlers(..)` compared
    // in both directions.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = bytes },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = bytes },
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 1,
        } } },
        .{ .id = 3, .span = span, .ty = 1, .kind = .{ .call = .{
            .call_kind = .{ .free = handlers },
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = 1, .kind = .{ .call = .{
            .call_kind = .{ .free = handlers },
            .args = &.{},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 3,
            .rhs = 4,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // `Vec<u8>` lowers to a list of bytes, which the runtime walks by content.
    try std.testing.expect(b.exprs[2].kind == .binary);

    // A function pointer is not a comparable payload: the runtime would
    // reduce the whole list to an address comparison, which is not the
    // element-wise comparison Rust asks for.
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    try expectUnsupported(&b.exprs[5]);
}

test "a to_string result compares as an owned String" {
    // `stdMethodResultType` reads its receiver's type from the graph, and
    // `to_string` hands back a freshly owned string, so the graph is built on
    // an arena exactly as the production pipeline does.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const shown = try addEntity(&g, a, .struct_, "Shown", root);
    const shown_display = try addEntity(&g, a, .impl_, "fmt::Display for Shown", root);
    _ = try addEntity(&g, a, .fn_, "fmt", shown_display);
    const hidden = try addEntity(&g, a, .struct_, "Hidden", root);
    const hidden_debug = try addEntity(&g, a, .impl_, "core::fmt::Debug for Hidden", root);
    _ = try addEntity(&g, a, .fn_, "fmt", hidden_debug);
    const to_string_ref = try addEntity(&g, a, .method_ref, "to_string", null);

    // 0 = Shown, 1 = Hidden
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Shown", .id = shown }} } },
        .{ .path = .{ .segments = &.{.{ .name = "Hidden", .id = hidden }} } },
    };

    // 0/2: two `Shown` values, 1/3: their `to_string()` results. 4 compares
    // the two conversions, 6 is the `Debug`-only receiver whose `to_string()`
    // stays unresolved.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = to_string_ref,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .shared,
            .method = to_string_ref,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 3,
        } } },
        .{ .id = 5, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 5,
            .receiver_mode = .shared,
            .method = to_string_ref,
            .args = &.{},
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 6,
            .rhs = 3,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Both conversions resolve, and the comparison between them is admitted:
    // each operand is the owned `String` `ToString` returns, so the emitted
    // call compares the two string bodies rather than their storage.
    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);
    try std.testing.expect(b.exprs[4].kind == .binary);

    // A `Debug`-only receiver cannot call `.to_string()` in Rust, and the
    // call above already says so. The comparison over it is NOT re-marked:
    // the operator is not what is untranslatable, the value it reads is, and a
    // second marker with a vaguer reason only buries the one that names the
    // cause. Refusing it again here would neither make the package build nor
    // tell anyone anything the refused operand has not already said.
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try expectUnsupported(&b.exprs[6]);
    try std.testing.expect(b.exprs[7].kind == .binary);
}

// ── Equality pair rules: what is admitted, and what is refused on purpose ──
//
// `r2z.ops.equal` walks a list-backed owner by descending into the list it
// holds, so an owner and a BORROW of a list are the same value in two forms and
// compare in either order. An owner against a value that is neither an owner
// nor a borrow still has no list to meet, and stays refused on purpose.
// The two directions are pinned separately because the rule reads the pair,
// not either type alone: a regression that only checked one side would let the
// other direction stage a package that cannot compile.

test "an owned String compares against a string literal in both directions" {
    // This is the exact pair hex's `mod test` needs at
    // `src/lib.rs:516-522` and `src/error.rs:49-56`:
    //     assert_eq!(thing.to_string(), "666f6f626172");
    // The left side types as the owned `String` `ToString` returns and the
    // right side is a string literal, which the frontend leaves untyped. The
    // two are the same Rust value in two forms — `String == &str` compiles in
    // Rust — and `r2z.ops.equal` has the cross-form branch that makes them so
    // in Zig: the owner descends into the list it holds and the borrow meets
    // its items. So the pair is admitted, in both directions, and the emitted
    // call compares by content.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const shown = try addEntity(&g, a, .struct_, "Shown", root);
    const shown_display = try addEntity(&g, a, .impl_, "fmt::Display for Shown", root);
    _ = try addEntity(&g, a, .fn_, "fmt", shown_display);
    const to_string_ref = try addEntity(&g, a, .method_ref, "to_string", null);

    // 0 = Shown. The owned `String` is not in this table: `ToString` returns
    // it, and the resolver synthesizes that type from the call it admitted.
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Shown", .id = shown }} } },
    };

    // 0: a `Shown` value. 1/3: its `to_string()`. 2: the string literal hex
    // writes on the other side of `assert_eq!`. 4/5: both directions of the
    // owner-vs-borrow comparison. 6: the same two `to_string()` results,
    // which is owner against owner.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = to_string_ref,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{
            .string = .{ .bytes = "666f6f626172" },
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = to_string_ref,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .ne,
            .overflow = .checked,
            .lhs = 2,
            .rhs = 3,
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 3,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // The literal carries no declared type, so the pair rule reads it by
    // shape: a string literal IS a borrow of a list in Rust, and the runtime
    // compares an owner against one. Both directions are admitted.
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[4].kind == .binary);
    try std.testing.expect(b.exprs[5].kind == .binary);

    // The same two owned strings, with no borrow involved, stay admitted too:
    // each side is the owned `String` `ToString` returns, so the emitted call
    // reads a `bytes` field off both operands and compares them by content.
    try std.testing.expect(b.exprs[6].kind == .binary);
}

test "a list owner compares against a list borrow in either direction" {
    // `Vec<u8>` against `Vec<u8>` is owner against owner, `&[u8]` against
    // `&[u8]` is borrow against borrow, and the mixed pair is the one the
    // cross-form branch in `r2z.ops.equal` exists for: the owner descends into
    // the list it holds and the borrow meets its items, in either order.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const bytes = try addEntity(&g, a, .fn_, "bytes", root);
    const window = try addEntity(&g, a, .fn_, "window", root);

    // 0 = Vec<u8>, 1 = &[u8]
    const borrow_ty: types.Type = .{ .reference = &.{
        .mut = false,
        .pointee = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
    } };
    var types_store = [_]types.Type{
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
        borrow_ty,
    };

    // 0/1: `bytes(..)` in both directions. 2: `Vec<u8> == Vec<u8>`.
    // 3/4: `window(..)` in both directions. 5: `&[u8] == &[u8]`.
    // 6/7: `Vec<u8> == &[u8]`, the mixed pair, in both directions.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = bytes },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = bytes },
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 1,
        } } },
        .{ .id = 3, .span = span, .ty = 1, .kind = .{ .call = .{
            .call_kind = .{ .free = window },
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = 1, .kind = .{ .call = .{
            .call_kind = .{ .free = window },
            .args = &.{},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 3,
            .rhs = 4,
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 3,
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 3,
            .rhs = 0,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Nothing is refused: all four pairs reach `r2z.ops.equal`, which either
    // reads the list field off both owners or descends into the one owner and
    // meets the borrow's items.
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
    try std.testing.expect(b.exprs[5].kind == .binary);
    try std.testing.expect(b.exprs[6].kind == .binary);
    try std.testing.expect(b.exprs[7].kind == .binary);
}

test "a list owner is refused against a value that is neither an owner nor a borrow" {
    // The cross-form branch has exactly two shapes to descend into: a list
    // owner, and a list borrow to meet its items. An owner against anything
    // else has no list on the far side, so the walk is undefined and the
    // refusal is DELIBERATE — admitting it would stage a package whose
    // `r2z.ops.equal` call does not compile. `Option<u8>` is on the per-type
    // whitelist on its own, so these pairs are refused by the PAIR rule and
    // not by a type the runtime cannot compare.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const text = try addEntity(&g, a, .fn_, "text", root);
    const byte = try addEntity(&g, a, .fn_, "byte", root);
    const maybe = try addEntity(&g, a, .fn_, "maybe", root);

    const optional: types.Type = .{ .option = &types.Type{ .prim = .u8 } };

    // 0 = String, 1 = u8, 2 = Option<u8>
    var types_store = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        .{ .prim = .u8 },
        optional,
    };

    // 0: `text(..)`, 1: `byte(..)`, 2: `String == u8`.
    // 3: `maybe(..)`, 4/5: `String == Option<u8>` and its reverse.
    // 6: a second `text(..)`, 7: `u8 == String`.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = text },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .call = .{
            .call_kind = .{ .free = byte },
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 1,
        } } },
        .{ .id = 3, .span = span, .ty = 2, .kind = .{ .call = .{
            .call_kind = .{ .free = maybe },
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 3,
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .ne,
            .overflow = .checked,
            .lhs = 3,
            .rhs = 0,
        } } },
        .{ .id = 6, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = text },
            .args = &.{},
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 6,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 4), stats.unsupported_operators);
    try expectUnsupportedReason(&b.exprs[2], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[4], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[5], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[7], "operator requires primitive operands");
}

test "a literal the frontend typed as an owner is read as one" {
    // A string literal is a borrow in Rust, but inference sometimes types one
    // as the owned `String` it will be turned into. The declared type is the
    // operand's own account of itself, so the pair rule reads THAT and not the
    // literal's shape: two `String`s are owner against owner, and a literal the
    // frontend left untyped — the shape hex's `assert_eq!` produces — is the
    // borrow the cross-form branch meets.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const text = try addEntity(&g, a, .fn_, "text", root);

    // 0 = String
    var types_store = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
    };

    // 0: `text(..)`. 1: a literal inference typed as `String`. 2/3: it against
    // the owner, in both directions. 4: the same literal left untyped, 5: the
    // owner against it.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .free = text },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .literal = .{ .string = .{ .bytes = "abc" } } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 1,
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 0,
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{ .string = .{ .bytes = "abc" } } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 4,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
    try std.testing.expect(b.exprs[3].kind == .binary);
    try std.testing.expect(b.exprs[5].kind == .binary);
}

test "String::into_bytes dispatches on the owned string and nowhere else" {
    // Every receiver here carries a declared type, so nothing is recovered:
    // the only question is which of them the runtime backs `into_bytes` on.
    // `r2z.alloc.String.into_bytes` is the one, and it hands the backing
    // `Vec(u8)` over and leaves the string empty.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const into_bytes = try addEntity(&g, a, .fn_, "into_bytes", root);

    // 0: `String`, 1: `&[u8]`, 2: `Vec<u8>`, 3: `&str`.
    const slice_ref: types.Ref = .{
        .mut = false,
        .pointee = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
    };
    const str_ref: types.Ref = .{ .mut = false, .pointee = types.str_type };
    const types_store = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        .{ .reference = &slice_ref },
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
        .{ .reference = &str_ref },
    };

    // 0/1: an owned `String`, 2/3: a slice borrow, 4/5: a `Vec<u8>`, 6/7: a
    // string borrow. Each even node is a receiver, each odd node the
    // `.into_bytes()` call on it.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = into_bytes,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .shared,
            .method = into_bytes,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = into_bytes,
            .args = &.{},
        } } },
        .{ .id = 6, .span = span, .ty = 3, .kind = .{ .unit = {} } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 6,
            .receiver_mode = .shared,
            .method = into_bytes,
            .args = &.{},
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Only the owned string is a `String` in the runtime. A slice borrow, a
    // `Vec<u8>`, and a string borrow are three different types, and none of
    // them owns a `String` whose bytes it can hand over.
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expectEqual(@as(usize, 3), stats.unsupported_methods);
    try expectUnsupported(&b.exprs[3]);
    try expectUnsupported(&b.exprs[5]);
    try expectUnsupported(&b.exprs[7]);
}

test "a blanket AsRef<[u8]> impl names no receiver type, so an untyped array literal stops there" {
    // `[0x66, 0x6f, 0x6f, 0x62, 0x61, 0x72]` is `[T; 6]` for whatever `T` the
    // surrounding context fixes, so the literal itself proves no element type
    // and `arrayReceiverType` leaves it untyped. `impl<T: AsRef<[u8]>> ToHex
    // for T` does admit it — the declared bound is the only evidence that
    // says so, and an array `[E; N]` meets `AsRef<[u8]>` only for `E = u8`.
    // But the bound never says WHICH `T`, and a call needs exactly that:
    //
    //   * the result type. `encode_hex<U: FromIterator<char>>(&self) -> U`
    //     is fixed only at the call site, `exprs.MethodCall` carries no type
    //     arguments, and the frontend drops a turbofish, so
    //     `encode_hex::<String>()` binds nothing anywhere in the IR.
    //   * the method itself. The Zig backend hoists a method onto the type
    //     that implements it, and a blanket impl over a type parameter has no
    //     such type: `validateMethodTopology` refuses it with
    //     `error.GenericDefinitionMismatch`.
    //
    // Resolving the call would only move that failure downstream and hide it,
    // so it is refused here with a reason that names the cause. The refusal is
    // DELIBERATE: an element type is never invented from the literals'
    // magnitudes, and a receiver that has a type of its own still reaches the
    // impl through the ordinary name lookup.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .trait_, "ToHex", root);
    const to_hex_impl = try addEntity(&g, a, .impl_, "ToHex for T", root);
    _ = try addEntity(&g, a, .fn_, "encode_hex", to_hex_impl);
    _ = try addEntity(&g, a, .fn_, "encode_hex_upper", to_hex_impl);
    // Two more blanket impls, over bounds an array of integers does not meet.
    const display_impl = try addEntity(&g, a, .impl_, "fmt::Display for T", root);
    _ = try addEntity(&g, a, .fn_, "render", display_impl);
    const text_impl = try addEntity(&g, a, .impl_, "ToText for T", root);
    _ = try addEntity(&g, a, .fn_, "encode_text", text_impl);
    // The unresolved names a call reaches the resolver with.
    const encode_hex_ident = try addEntity(&g, a, .fn_, "encode_hex", root);
    const encode_hex_upper_ident = try addEntity(&g, a, .fn_, "encode_hex_upper", root);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);
    const encode_text_ident = try addEntity(&g, a, .fn_, "encode_text", root);
    const missing_ident = try addEntity(&g, a, .fn_, "not_a_method", root);

    const byte_seq: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const self_param: types.Type = .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } };
    const hex_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{
            .{ .path = .{ .segments = &.{.{ .name = "AsRef", .id = null }} }, .args = &.{byte_seq} },
        } },
    }};
    const display_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{
            .{ .path = .{ .segments = &.{.{ .name = "Display", .id = null }} } },
        } },
    }};
    const text_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{
            .{ .path = .{ .segments = &.{.{ .name = "AsRef", .id = null }} }, .args = &.{types.str_type} },
        } },
    }};
    // `bodies` is sparse and indexed by entity id, so the three impls sit at
    // the slots `addEntity` gave them.
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .none,
        .{ .impl_ = .{ .self_ty = self_param, .generics = .{ .params = &hex_generics, .where_clauses = &.{} } } },
        .none,
        .none,
        .{ .impl_ = .{ .self_ty = self_param, .generics = .{ .params = &display_generics, .where_clauses = &.{} } } },
        .none,
        .none,
        .{ .impl_ = .{ .self_ty = self_param, .generics = .{ .params = &text_generics, .where_clauses = &.{} } } },
    };

    const types_store = [_]types.Type{.{ .prim = .u8 }};
    const hex_values = [_]i128{ 0x66, 0x6f, 0x6f, 0x62, 0x61, 0x72 };

    // 0: the array literal, 1..6: its six unsuffixed hex elements, 7/8:
    // `.encode_hex()` and `.encode_hex_upper()`, 9: `.render()`, 10:
    // `.encode_text()`, 11: `.not_a_method()`, 12: a second literal whose
    // single element carries `u8`, 13: that element, 14: its `.encode_hex()`.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .array = .{
            .elements = &.{ 1, 2, 3, 4, 5, 6 },
            .repeat = null,
        } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x66", .value = hex_values[0], .base = .hex, .ty_suffix = null,
        } } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x6f", .value = hex_values[1], .base = .hex, .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x6f", .value = hex_values[2], .base = .hex, .ty_suffix = null,
        } } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x62", .value = hex_values[3], .base = .hex, .ty_suffix = null,
        } } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x61", .value = hex_values[4], .base = .hex, .ty_suffix = null,
        } } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x72", .value = hex_values[5], .base = .hex, .ty_suffix = null,
        } } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = encode_hex_ident,
            .args = &.{},
        } } },
        .{ .id = 8, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = encode_hex_upper_ident,
            .args = &.{},
        } } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = render_ident,
            .args = &.{},
        } } },
        .{ .id = 10, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = encode_text_ident,
            .args = &.{},
        } } },
        .{ .id = 11, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = missing_ident,
            .args = &.{},
        } } },
        .{ .id = 12, .span = span, .ty = null, .kind = .{ .array = .{
            .elements = &.{13},
            .repeat = 4,
        } } },
        .{ .id = 13, .span = span, .ty = 0, .kind = .{ .literal = .{ .int = .{
            .text = "0_u8", .value = 0, .base = .hex, .ty_suffix = "u8",
        } } } },
        .{ .id = 14, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 12,
            .receiver_mode = .shared,
            .method = encode_hex_ident,
            .args = &.{},
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // All three calls the one `ToHex` impl provides are refused, whether the
    // literal's elements were typed or not: the rule reads the impl's bound to
    // find the method, and then declines it because the bound names no `T`.
    try std.testing.expectEqual(@as(usize, 0), stats.trait_resolved);
    try expectUnsupportedReason(
        &b.exprs[7],
        "blanket impl names no receiver type: backend validateMethodTopology has no parent to hoist onto",
    );
    try expectUnsupportedReason(
        &b.exprs[8],
        "blanket impl names no receiver type: backend validateMethodTopology has no parent to hoist onto",
    );
    // A literal whose single element DOES carry `u8` gets no better: the
    // element type is not what was missing.
    try expectUnsupportedReason(
        &b.exprs[14],
        "blanket impl names no receiver type: backend validateMethodTopology has no parent to hoist onto",
    );

    // The bound is the whole of the evidence, in both directions. `Display` is
    // not `AsRef<[u8]>`, `AsRef<str>` is not `AsRef<[u8]>`, and no impl at all
    // provides `not_a_method`, so those three stay refused on the older
    // grounds, with their own reasons.
    try std.testing.expectEqual(@as(usize, 6), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[9], "method receiver unavailable");
    try expectUnsupportedReason(&b.exprs[10], "method receiver unavailable");
    try expectUnsupportedReason(&b.exprs[11], "method receiver unavailable");
}

test "a collect on a method-call receiver follows the recovered iterator chain" {
    // `hex.chunks(2).enumerate().map(..).collect()` reaches the resolver with
    // only its root typed: inference names `Chunks<u8>` and nothing after it.
    // Each adapter keeps the source iterator as its first type parameter, so
    // naming the carrier and the source is enough to know the chain is still
    // an iterator and `.collect()` still dispatches.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const chunks_ident = try addEntity(&g, a, .fn_, "chunks", root);
    const enumerate_ident = try addEntity(&g, a, .fn_, "enumerate", root);
    const map_ident = try addEntity(&g, a, .fn_, "map", root);
    const collect_ident = try addEntity(&g, a, .fn_, "collect", root);
    const into_bytes_ident = try addEntity(&g, a, .fn_, "into_bytes", root);
    const make_ident = try addEntity(&g, a, .fn_, "make", root);

    const byte_slice: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const source_ref: types.Ref = .{ .mut = false, .pointee = .{ .slice = &byte_slice } };
    // 0: `&[u8]`, 1: `Chunks<u8>`, 2: `usize`.
    const types_store = [_]types.Type{
        .{ .reference = &source_ref },
        .{ .external_nominal = .{
            .path = &.{ "core", "slice", "Chunks" },
            .args = &.{.{ .prim = .u8 }},
        } },
        .{ .prim = .usize },
    };
    // `make() -> String`, at the entity id `addEntity` gave it.
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .none,
        .none,
        .none,
        .none,
        .none,
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
            .body = 0,
        } },
    };

    // 0: the source slice, 1: `.chunks(2)`, 2: its argument, 3: `.enumerate()`,
    // 4: `.map(..)`, 5: its closure, 6: `.collect()` off the map, 7:
    // `.collect()` straight off the enumerate, 8: `.collect()` off the slice,
    // 9: `.map(..)` off the slice, 10: `.enumerate(5)` with an argument Rust
    // does not take, 11: `.collect()` off that call, 12: `make()`, 13:
    // `make().into_bytes()`.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = chunks_ident,
            .args = &.{2},
        } } },
        .{ .id = 2, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .shared,
            .method = enumerate_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 3,
            .receiver_mode = .shared,
            .method = map_ident,
            .args = &.{5},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 3,
            .receiver_mode = .shared,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 8, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = map_ident,
            .args = &.{5},
        } } },
        .{ .id = 10, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .shared,
            .method = enumerate_ident,
            .args = &.{5},
        } } },
        .{ .id = 11, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 10,
            .receiver_mode = .shared,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 12, .span = span, .ty = null, .kind = .{ .call = .{
            .call_kind = .{ .free = make_ident },
            .args = &.{},
        } } },
        .{ .id = 13, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 12,
            .receiver_mode = .shared,
            .method = into_bytes_ident,
            .args = &.{},
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // The chain carries through both adapters, and the call receiver carries
    // the return type its own signature declares.
    try std.testing.expect(b.exprs[6].kind == .method_call);
    try std.testing.expect(b.exprs[7].kind == .method_call);
    try std.testing.expect(b.exprs[13].kind == .method_call);

    // A chain is only an iterator while every step is one. A slice is not a
    // carrier, so neither `.collect()` nor `.map(..)` off it resolves, and a
    // call that does not match its adapter's arity produces no carrier for the
    // next call to lean on.
    try std.testing.expectEqual(@as(usize, 3), stats.unsupported_methods);
    try expectUnsupported(&b.exprs[8]);
    try expectUnsupported(&b.exprs[9]);
    try expectUnsupported(&b.exprs[11]);
}

test "a runtime iterator method needs a receiver the backend can name" {
    // `generate_iter(5)` returns `impl Iterator<Item = (usize, usize)>`, which
    // the frontend records as an OPAQUE. The Zig backend peels an opaque to
    // the concrete the frontend recovered beside it before it matches a
    // method, so an opaque WITH a carrier is exactly as nameable as the
    // carrier — and that is the one answer all three of the resolver's
    // receiver predicates have to give, because they ask it of the same type
    // about the same method.
    //
    // What the backend cannot peel is an opaque with NO carrier. Nothing
    // recovers a concrete type for it, nothing downstream can name it, and a
    // runtime iterator method on it would be emitted as a bare
    // `receiver.collect(..)` against a type no side can write. That is
    // refused here, where the reason can say what is missing, instead of
    // producing a package that cannot build.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const collect_ident = try addEntity(&g, a, .fn_, "collect", root);
    const next_ident = try addEntity(&g, a, .fn_, "next", root);
    _ = try addEntity(&g, a, .fn_, "generate_iter", root);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);

    const iterator_bound: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "Iterator", .id = null }} },
    };
    const chunks: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "Chunks" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const opaque_with_carrier: types.Type = .{ .@"opaque" = .{
        .bounds = &.{iterator_bound},
        .concrete = &chunks,
    } };
    const opaque_without_carrier: types.Type = .{ .@"opaque" = .{
        .bounds = &.{iterator_bound},
        .concrete = null,
    } };
    // 0 = the `impl Iterator` receiver that recovered its carrier, 1 = the
    // nominal `Chunks<u8>` receiver, 2 = the `impl Iterator` receiver that
    // did not.
    var types_store = [_]types.Type{ opaque_with_carrier, chunks, opaque_without_carrier };
    // 2/3: `.collect()` off each carrier, 4: `.next()` off the nominal, 5:
    // `.collect()` off the carrier-less opaque, 6: `.render(..)` off it.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = next_ident,
            .args = &.{},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .value,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .value,
            .method = render_ident,
            .args = &.{},
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // An opaque that recovered its carrier is the carrier. The backend peels
    // the same field this resolver walks, so `.collect()` off one dispatches
    // exactly as it does off the nominal it was recovered from.
    try std.testing.expect(b.exprs[3].kind == .method_call);
    try std.testing.expect(b.exprs[4].kind == .method_call);
    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);

    // An opaque that recovered nothing names nothing, and the reason says so.
    try expectUnsupportedReason(
        &b.exprs[5],
        "opaque receiver: backend lookupRecognizedStdMethod has no arm for this iterator method",
    );
    // The refusal is keyed on the METHOD too. `render` is not a runtime
    // iterator method, so this receiver has no iterator arm to be missing,
    // and the reason has to stay the one that actually applies.
    try expectUnsupportedReason(&b.exprs[6], "method dispatch unavailable");
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_methods);
}

test "a struct literal receiver recovers the type its own definition names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const buffer = try addEntity(&g, a, .struct_, "Buffer", root);
    const buffer_impl = try addEntity(&g, a, .impl_, "Buffer", root);
    const fn_copy_from_slice = try addEntity(&g, a, .fn_, "copy_from_slice", buffer_impl);
    const mode = try addEntity(&g, a, .enum_, "Mode", root);
    const copy_ident = try addEntity(&g, a, .fn_, "copy_from_slice", root);
    const missing_ident = try addEntity(&g, a, .fn_, "not_a_method", root);
    const is_ident = try addEntity(&g, a, .fn_, "is", root);

    // 0: `Buffer { v0: 0 }`, 1: its field value, 2: its `.copy_from_slice(..)`,
    // 3: the argument, 4: `Buffer { v0: 0 }` again, 5: its `.not_a_method()`,
    // 6: a literal whose `def` names an enum, 7: its `.is(..)`.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .struct_lit = .{
            .def = buffer,
            .fields = &.{.{ .field = "v0", .value = 1, .shorthand = false }},
            .base = null,
        } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0", .value = 0, .base = .dec, .ty_suffix = null,
        } } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = copy_ident,
            .args = &.{3},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .struct_lit = .{
            .def = buffer,
            .fields = &.{.{ .field = "v0", .value = 1, .shorthand = false }},
            .base = null,
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = missing_ident,
            .args = &.{},
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .struct_lit = .{
            .def = mode,
            .fields = &.{.{ .field = "v0", .value = 1, .shorthand = false }},
            .base = null,
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 6,
            .receiver_mode = .shared,
            .method = is_ident,
            .args = &.{},
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // `Buffer { .. }` is a `Buffer`, so the inherent method dispatches.
    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    try std.testing.expectEqual(@as(spine.EntityId, fn_copy_from_slice), b.exprs[2].kind.method_call.method);

    // Recovering the receiver is not a pass for everything. A method the
    // struct does not declare is a dispatch failure, not a receiver failure,
    // and a literal whose `def` names something that is not a struct leaves
    // the receiver untyped.
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[5], "method dispatch unavailable");
    try expectUnsupportedReason(&b.exprs[7], "method receiver unavailable");
}

test "unwrap_err is decided by how a Result receiver lowers, not by is_error_unionable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const plain_error = try addEntity(&g, a, .enum_, "PlainError", root);
    const from_hex_error = try addEntity(&g, a, .enum_, "FromHexError", root);

    // `PlainError` is fieldless, so it IS a Zig error set: `Result<u8,
    // PlainError>` lowers to `PlainError!u8` and the error lives in the union
    // rather than in a value, so there is nothing for `unwrap_err` to hand
    // back. `FromHexError` is a crate enum that CARRIES data
    // (`InvalidHexCharacter { c, index }`), so it is not an error set, and
    // `Result<u8, FromHexError>` lowers to the runtime's tagged
    // `r2z.Result(T, E)`, which has the error value the method returns.
    // `is_error_unionable` says the same thing for both, which is why the
    // flag alone cannot decide this.
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .{ .enum_ = .{
            .kind = .c_like,
            .variants = &.{
                .{ .name = "NotFound", .fields = .none, .discriminant = null },
                .{ .name = "Interrupted", .fields = .none, .discriminant = null },
            },
        } },
        .{ .enum_ = .{
            .kind = .data,
            .variants = &.{
                .{ .name = "InvalidHexCharacter", .fields = .{ .named = &.{
                    .{ .name = "c", .ty = .{ .prim = .char }, .visibility = .public, .span = span },
                    .{ .name = "index", .ty = .{ .prim = .usize }, .visibility = .public, .span = span },
                } }, .discriminant = null },
                .{ .name = "OddLength", .fields = .none, .discriminant = null },
            },
        } },
    };
    var b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    const error_union: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "PlainError", .id = plain_error }} } },
        .is_error_unionable = true,
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupResultRepresentationMethod(&b, error_union, "unwrap_err"),
    );

    const value_result: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "FromHexError", .id = from_hex_error }} } },
        .is_error_unionable = true,
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .result_unwrap_err),
        resolve_methods.lookupResultRepresentationMethod(&b, value_result, "unwrap_err"),
    );

    // A `Result` whose error is open keeps its own value whatever the error
    // type names, so it is admitted on the flag alone.
    const open_result: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "PlainError", .id = plain_error }} } },
        .is_error_unionable = false,
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .result_unwrap_err),
        resolve_methods.lookupResultRepresentationMethod(&b, open_result, "unwrap_err"),
    );

    // Neither the method nor the receiver is a `Result` question, so neither
    // is admitted: `u8.unwrap_err()` is a Rust type error, and a slice is a
    // list, not a result. The other `Result` methods are not in this
    // function's reach either — the pure type table still owns them.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupResultRepresentationMethod(&b, .{ .prim = .u8 }, "unwrap_err"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupResultRepresentationMethod(
            &b,
            .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
            "unwrap_err",
        ),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupResultRepresentationMethod(&b, value_result, "is_ok"),
    );
}

test "a Result receiver keeps its unwrap_err call dispatchable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const unwrap_err_ident = try addEntity(&g, a, .fn_, "unwrap_err", root);
    const collect_ident = try addEntity(&g, a, .fn_, "collect", root);
    const from_hex_error = try addEntity(&g, a, .enum_, "FromHexError", root);
    const plain_error = try addEntity(&g, a, .enum_, "PlainError", root);

    const result_ty: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "FromHexError", .id = null }} } },
        .is_error_unionable = false,
    } };
    // `hex`'s own shape: a finite error set, but a crate enum that carries
    // data, so the backend lowers it to the runtime's tagged
    // `r2z.Result(T, E)` rather than to a Zig error union — and that form
    // has the error value `unwrap_err` returns.
    const crate_enum_result_ty: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "FromHexError", .id = from_hex_error }} } },
        .is_error_unionable = true,
    } };
    // The same flag on a fieldless error enum is the other answer: this one
    // really does lower to `PlainError!u8`, which has no error value.
    const error_union_ty: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "PlainError", .id = plain_error }} } },
        .is_error_unionable = true,
    } };
    const slice_ty: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    // 0: a `Result` with an open error, 1: a slice, 2: a `Result` with a
    // data-carrying crate enum, 3: a bare `u8`, 4: a `Result` that lowers to
    // a real error union.
    var types_store = [_]types.Type{
        result_ty,
        slice_ty,
        crate_enum_result_ty,
        .{ .prim = .u8 },
        error_union_ty,
    };
    // 5: `.unwrap_err()` off receiver 0, 6: `.collect()` off the slice, 7:
    // `.unwrap_err()` off receiver 2, 8: off the `u8`, 9: off receiver 4.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = 3, .kind = .{ .unit = {} } },
        .{ .id = 4, .span = span, .ty = 4, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = unwrap_err_ident,
            .args = &.{},
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .value,
            .method = unwrap_err_ident,
            .args = &.{},
        } } },
        .{ .id = 8, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 3,
            .receiver_mode = .value,
            .method = unwrap_err_ident,
            .args = &.{},
        } } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .value,
            .method = unwrap_err_ident,
            .args = &.{},
        } } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .none,
        .none,
        .{ .enum_ = .{
            .kind = .data,
            .variants = &.{
                .{ .name = "InvalidHexCharacter", .fields = .{ .named = &.{
                    .{ .name = "c", .ty = .{ .prim = .char }, .visibility = .public, .span = span },
                    .{ .name = "index", .ty = .{ .prim = .usize }, .visibility = .public, .span = span },
                } }, .discriminant = null },
                .{ .name = "OddLength", .fields = .none, .discriminant = null },
            },
        } },
        .{ .enum_ = .{
            .kind = .c_like,
            .variants = &.{
                .{ .name = "NotFound", .fields = .none, .discriminant = null },
            },
        } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // `Result<Vec<u8>, FromHexError>::unwrap_err` keeps its call however the
    // error type is spelled, and the slice receiver's `collect` is the
    // contrast: a slice is a list, not an iterator carrier, so the same
    // method on it is a dispatch failure.
    try std.testing.expect(b.exprs[5].kind == .method_call);
    try expectUnsupportedReason(&b.exprs[6], "method dispatch unavailable");
    // The `hex` shape: a finite error set whose type carries data, so the
    // backend lowers it to a tagged `r2z.Result` and the runtime method
    // exists.
    try std.testing.expect(b.exprs[7].kind == .method_call);
    // A receiver that is not a `Result` at all is a Rust type error, and it
    // stays one: the method is the runtime's, not the language's.
    try expectUnsupportedReason(&b.exprs[8], "method dispatch unavailable");
    // A receiver that really does lower to a Zig error union has no error
    // value to hand back, so admitting it would emit a call the backend's
    // switch answers with nothing.
    try expectUnsupportedReason(&b.exprs[9], "method dispatch unavailable");
    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 3), stats.unsupported_methods);
}

// ── `Result::unwrap_err` as an operator operand ──────────────────────────────
//
// `Result<T, E>::unwrap_err(&self) -> E` names its own result: the error arm
// of the receiver it was admitted on. The rule reads the receiver and asks the
// same question the CALL was admitted on, so a `Result` that lowers to a Zig
// error union — which has no error value to hand back — keeps its operand
// untyped, and an operator over it stays refused rather than being emitted
// against a type nobody recovered.

test "an unwrap_err result types the comparison hex's test module writes" {
    // hex/src/lib.rs:468, 470, 479 and 494:
    //     assert_eq!(Vec::from_hex("1").unwrap_err(), FromHexError::OddLength);
    //     assert_eq!(Vec::from_hex("66ag").unwrap_err(),
    //                FromHexError::InvalidHexCharacter { c: 'g', index: 3 });
    // The left side is `FromHexError` because `unwrap_err` returns the error
    // arm; the right side is a unit variant of the same enum. `r2z.ops.equal`
    // compares a tagged union by tag and then by payload, so the pair is a
    // value comparison and not a storage one.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const unwrap_err_ident = try addEntity(&g, a, .fn_, "unwrap_err", root);
    const from_hex_error = try addEntity(&g, a, .enum_, "FromHexError", root);
    const odd_length = try addEntity(&g, a, .variant, "OddLength", from_hex_error);
    const from_hex_ident = try addEntity(&g, a, .fn_, "from_hex", root);

    // `hex`'s own shape: `is_error_unionable` is true, and it decides nothing
    // on its own. The error enum CARRIES data
    // (`InvalidHexCharacter { c, index }`), so the backend lowers the `Result`
    // to the runtime's tagged `r2z.Result(T, E)`, which has the error value
    // `unwrap_err` hands back.
    const result_ty: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "FromHexError", .id = from_hex_error }} } },
        .is_error_unionable = true,
    } };
    var types_store = [_]types.Type{result_ty};
    // 0: `Vec::from_hex("1")`, 1: its `.unwrap_err()`, 2: the unit variant the
    // test names, 3: the `==` between them.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .associated = from_hex_ident },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = unwrap_err_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .enum_variant = .{
            .def = odd_length,
            .variant = "OddLength",
            .tuple_fields = &.{},
            .named_fields = &.{},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .none,
        .{ .enum_ = .{
            .kind = .data,
            .variants = &.{
                .{ .name = "InvalidHexCharacter", .fields = .{ .named = &.{
                    .{ .name = "c", .ty = .{ .prim = .char }, .visibility = .public, .span = span },
                    .{ .name = "index", .ty = .{ .prim = .usize }, .visibility = .public, .span = span },
                } }, .discriminant = null },
                .{ .name = "OddLength", .fields = .none, .discriminant = null },
            },
        } },
        .none,
        .{ .fn_ = .{
            .params = &.{},
            .ret = result_ty,
            .body = 0,
        } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // The call keeps its identity and the comparison over it is admitted: the
    // left operand is the error arm of the `Result`, so the pair is two
    // `FromHexError` values and the runtime knows how to walk that.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expect(b.exprs[3].kind == .binary);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
}

test "a Result that lowers to a Zig error union names no error value for unwrap_err" {
    // Same `unwrap_err`, same `==`, and the only difference is the error enum:
    // `PlainError` is FIELDLESS, so it is a Zig error set, the `Result` lowers
    // to `PlainError!u8`, and the error lives in the union rather than in a
    // value. There is nothing for the method to hand back, so the operand
    // stays untyped and the operator stays refused. Reading `is_error_unionable`
    // alone would have typed it and emitted a call the backend's switch answers
    // with nothing.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const unwrap_err_ident = try addEntity(&g, a, .fn_, "unwrap_err", root);
    const plain_error = try addEntity(&g, a, .enum_, "PlainError", root);
    const not_found = try addEntity(&g, a, .variant, "NotFound", plain_error);
    const load_ident = try addEntity(&g, a, .fn_, "load", root);

    const result_ty: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "PlainError", .id = plain_error }} } },
        .is_error_unionable = true,
    } };
    var types_store = [_]types.Type{result_ty};
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .call = .{
            .call_kind = .{ .associated = load_ident },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = unwrap_err_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .enum_variant = .{
            .def = not_found,
            .variant = "NotFound",
            .tuple_fields = &.{},
            .named_fields = &.{},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .none,
        .{ .enum_ = .{
            .kind = .c_like,
            .variants = &.{
                .{ .name = "NotFound", .fields = .none, .discriminant = null },
            },
        } },
        .none,
        .{ .fn_ = .{ .params = &.{}, .ret = result_ty, .body = 0 } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    try expectUnsupportedReason(&b.exprs[1], "method dispatch unavailable");
    // The operator over it is NOT re-marked with a second, vaguer reason: the
    // refusal already in the tree is the one that names the cause.
    try std.testing.expect(b.exprs[3].kind == .binary);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
}

test "a crate enum compares when every variant carries a comparable value" {
    // `builtInEqualityType` answers "does `r2z.ops.equal` have value semantics
    // for this type", and for a crate enum the answer is the same question it
    // already asks of a `Result` payload: the runtime compares a tagged union
    // by tag and then walks the ACTIVE payload, so one variant that carries
    // something the walk cannot read is enough to refuse the whole type.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const readable = try addEntity(&g, a, .enum_, "Readable", root);
    const opaque_payload = try addEntity(&g, a, .enum_, "OpaquePayload", root);
    const first = try addEntity(&g, a, .variant, "First", readable);
    const second = try addEntity(&g, a, .variant, "Second", opaque_payload);
    const where_ = try addEntity(&g, a, .enum_, "Where", root);
    const here = try addEntity(&g, a, .variant, "Here", where_);

    const readable_ty: types.Type = .{ .path = .{ .segments = &.{.{ .name = "Readable", .id = readable }} } };
    const opaque_ty: types.Type = .{ .path = .{ .segments = &.{.{ .name = "OpaquePayload", .id = opaque_payload }} } };
    const where_ty: types.Type = .{ .path = .{ .segments = &.{.{ .name = "Where", .id = where_ }} } };
    var types_store = [_]types.Type{ readable_ty, opaque_ty, where_ty };
    // 0/2: two `Readable`; 4/6: two `OpaquePayload`; 8/10: two `Where`. Nodes
    // 1/3/5/7/9 are the `==` between a pair, and every pair is one TYPE
    // against itself, in both orders, because that is the only comparison Rust
    // admits here and the only one the rule below is about.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq, .overflow = .checked, .lhs = 0, .rhs = 2,
        } } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq, .overflow = .checked, .lhs = 2, .rhs = 0,
        } } },
        .{ .id = 4, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq, .overflow = .checked, .lhs = 4, .rhs = 6,
        } } },
        .{ .id = 6, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq, .overflow = .checked, .lhs = 6, .rhs = 4,
        } } },
        .{ .id = 8, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq, .overflow = .checked, .lhs = 8, .rhs = 10,
        } } },
        .{ .id = 10, .span = span, .ty = 2, .kind = .{ .unit = {} } },
    };
    // Indexed by entity id: 1 is `Readable`, 2 is `OpaquePayload`, 5 is
    // `Where`. The variants are the ones declared above.
    const bodies_store = [_]bodies.BodyKind{
        .none,
        .{ .enum_ = .{
            .kind = .data,
            .variants = &.{
                .{ .name = "First", .fields = .{ .named = &.{
                    .{ .name = "code", .ty = .{ .prim = .u16 }, .visibility = .public, .span = span },
                    .{ .name = "text", .ty = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } }, .visibility = .public, .span = span },
                } }, .discriminant = null },
                .{ .name = "Second", .fields = .none, .discriminant = null },
            },
        } },
        // A variant that carries a trait object: `r2z.ops.equal` has no walk
        // for it, so the whole enum stays out.
        .{ .enum_ = .{
            .kind = .data,
            .variants = &.{
                .{ .name = "Loaded", .fields = .none, .discriminant = null },
                .{ .name = "Vended", .fields = .{ .named = &.{
                    .{
                        .name = "vended",
                        .ty = .{ .dyn_trait = &.{.{ .path = .{ .segments = &.{
                            .{ .name = "Display", .id = null },
                        } } }} },
                        .visibility = .public,
                        .span = span,
                    },
                } }, .discriminant = null },
            },
        } },
        .none,
        .none,
        // The control: a fieldless enum, which lowers to a Zig `enum` the
        // runtime compares with `std.meta.eql`.
        .{ .enum_ = .{
            .kind = .c_like,
            .variants = &.{
                .{ .name = "Here", .fields = .none, .discriminant = null },
            },
        } },
        .none,
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // `Readable` carries a `u16` and a slice, and the runtime walks both, so
    // the pair is admitted in either order. The rule is a property of the
    // TYPE, not of the order the source happened to write it in, so both
    // directions are pinned separately.
    try std.testing.expect(b.exprs[1].kind == .binary);
    try std.testing.expect(b.exprs[3].kind == .binary);
    // `OpaquePayload` carries a trait object in one of its variants. The walk
    // never reads an INACTIVE payload, but it cannot be shown to read an
    // active one either, so the whole type stays out and the pair is refused
    // in either order.
    try expectUnsupportedReason(&b.exprs[5], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[7], "operator requires primitive operands");
    // A fieldless enum lowers to a Zig `enum`, which `std.meta.eql` compares.
    try std.testing.expect(b.exprs[9].kind == .binary);
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_operators);
    _ = first;
    _ = second;
    _ = here;
}

test "an operand the frontend cannot type still refuses its operator" {
    // `assert_eq!(match n { 0 => "zero", _ => "many" }, "one")`. A `match` has
    // a type in Rust, and this pass does not recover it, so the operator is
    // genuinely unresolvable and says so. The rule that would paper over this
    // — reading an untyped operand as a typed one — is exactly what turns a
    // precise refusal into a package that stages a call against a type nobody
    // named, so the refusal stays.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const scrutinee = try addEntity(&g, a, .field, "n", root);
    const zero = try addEntity(&g, a, .variant, "zero", root);
    const many = try addEntity(&g, a, .variant, "many", root);

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .path = .{
            .def = scrutinee,
            .generic_args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .match = .{
            .scrutinee = 0,
            .arms = &.{
                .{ .patterns = &.{}, .guard = null, .body = 4 },
                .{ .patterns = &.{}, .guard = null, .body = 5 },
            },
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .string = .{
            .bytes = "one",
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{ .string = .{
            .bytes = "zero",
        } } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .literal = .{ .string = .{
            .bytes = "many",
        } } } },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // The `match` carries no refusal of its own, so the operator is the thing
    // that is refused, and the reason names the operands rather than the
    // operator's own inability.
    try std.testing.expect(b.exprs[1].kind == .match);
    try expectUnsupportedReason(&b.exprs[3], "operator operands unresolved");
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    _ = zero;
    _ = many;
}

test "an operator over a refused iterator method keeps the operand's own reason" {
    // `generate_iter(5)` recovers no iterator carrier, so the resolver refuses
    // the `collect` on it with the reason that names the gap. The `==` around
    // it is not what is untranslatable — the value it reads is — so it is left
    // alone. Re-marking it would replace a reason that says which arm is
    // missing with one that says neither operand has a type, and the operator
    // check is downstream of the method check on purpose.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const collect_ident = try addEntity(&g, a, .fn_, "collect", root);

    const iterator_bound: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "Iterator", .id = null }} },
    };
    const opaque_ty: types.Type = .{ .@"opaque" = .{
        .bounds = &.{iterator_bound},
        .concrete = null,
    } };
    var types_store = [_]types.Type{opaque_ty};
    // 0: the opaque iterator, 1: its `.collect()`, 2: the `==` against a
    // local, 3: the local.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = collect_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 3,
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0",
            .value = 0,
            .base = .dec,
            .ty_suffix = null,
        } } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    try expectUnsupportedReason(
        &b.exprs[1],
        "opaque receiver: backend lookupRecognizedStdMethod has no arm for this iterator method",
    );
    try std.testing.expect(b.exprs[2].kind == .binary);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
}

test "an operator over a dispatched call names the call, not the operator" {
    // The same rule, on the OTHER side of the cascade. When the call the
    // resolver admitted is still a method call in the tree, nothing on it is
    // marked, so the operator is the only place left that can say what is
    // missing — and "a type is missing" is not it. The call's own result type
    // is. `iter.any(..)` is the shape pinned here: an iterator method this
    // pass dispatches, whose result it cannot name (Rust returns `bool` only
    // because it knows the closure's return, and no rule here does).
    //
    // A shape that cannot occur in a real crate is deliberate: the point is
    // which of the two reason strings the operator check picks, not that this
    // comparison is one anyone writes.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const any_ident = try addEntity(&g, a, .fn_, "any", root);
    const generate_iter = try addEntity(&g, a, .fn_, "generate_iter", root);
    const chunks: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "slice", "Chunks" },
        .args = &.{.{ .prim = .u8 }},
    } };
    // An opaque WITH a carrier: the resolver peels it to `Chunks<u8>` and
    // admits the method, so the call is dispatched and nothing on it is
    // marked.
    const iterator_bound: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "Iterator", .id = null }} },
    };
    const opaque_with_carrier: types.Type = .{ .@"opaque" = .{
        .bounds = &.{iterator_bound},
        .concrete = &chunks,
    } };
    var types_store = [_]types.Type{opaque_with_carrier};
    // 0: the opaque iterator, 1: its `.any(..)`, 2: the `==`, 3: a literal,
    // 4: a plain call whose return type nothing names, 5: the `==` over it.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = any_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 3,
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0",
            .value = 0,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .call = .{
            .call_kind = .{ .free = generate_iter },
            .args = &.{},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 4,
            .rhs = 3,
        } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // The call keeps its identity, and the operator over it says which half is
    // missing.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try expectUnsupportedReason(
        &b.exprs[2],
        "operator operand is a dispatched method call whose result type this pass does not name",
    );
    // A free call is not a dispatched method call: there is nothing in the
    // tree that claims it is fine, so the general reason is still the one that
    // fits.
    try expectUnsupportedReason(&b.exprs[5], "operator operands unresolved");
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_operators);
}
