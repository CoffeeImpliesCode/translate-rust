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

    const stats = resolve_methods.resolveMethods(&g, &b);
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

    _ = resolve_methods.resolveMethods(&g, &b);
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

    _ = resolve_methods.resolveMethods(&g, &b);
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

    const stats = resolve_methods.resolveMethods(&g, &b);
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

    // Numeric primitive methods (wrapping, saturating, bitwise)
    const u64_ty: types.Type = .{ .prim = .u64 };
    const i32_ty: types.Type = .{ .prim = .i32 };
    const usize_ty: types.Type = .{ .prim = .usize };

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

    const stats = resolve_methods.resolveMethods(&g, &b);

    // Inherent method "update" resolved and entity ID updated
    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    try std.testing.expectEqual(@as(spine.EntityId, fn_update), b.exprs[1].kind.method_call.method);

    // Std method "wrapping_add" resolved
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);

    // Unsupported method "unknown_fn" counted
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
}
