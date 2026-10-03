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

/// A source method lookup has to agree on the outcome AND on the method it
/// names. A trait answer is not an inherent one even when both point at the
/// same `fn`, and `ambiguous` must never degrade to `missing`: both are the
/// difference between resolving a call and picking a definition the source
/// never wrote.
fn expectSourceLookup(
    found: resolve_methods.SourceMethodLookup,
    expected: resolve_methods.SourceMethodLookup,
) !void {
    switch (expected) {
        .inherent => |method| switch (found) {
            .inherent => |actual| try std.testing.expectEqual(method, actual),
            else => try std.testing.expect(false),
        },
        .trait_ => |method| switch (found) {
            .trait_ => |actual| try std.testing.expectEqual(method, actual),
            else => try std.testing.expect(false),
        },
        .ambiguous => try std.testing.expect(found == .ambiguous),
        .missing => try std.testing.expect(found == .missing),
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

test "lookupSourceMethod gives an inherent method priority over a same-named trait method" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    _ = try addEntity(&g, a, .trait_, "Display", root);

    // impl Foo { fn render; }
    const inherent_impl = try addEntity(&g, a, .impl_, "Foo", root);
    const fn_inherent = try addEntity(&g, a, .fn_, "render", inherent_impl);
    // impl Display for Foo { fn render; } — the same call on the same receiver.
    const display_impl = try addEntity(&g, a, .impl_, "Display for Foo", root);
    const fn_trait = try addEntity(&g, a, .fn_, "render", display_impl);

    // The trait definition is there and findable on its own, so what the
    // assertion below reports is the inherent one winning, not a trait lookup
    // that failed to find anything.
    try std.testing.expectEqual(@as(?spine.EntityId, fn_trait), resolve_methods.lookupTraitMethod(&g, "Display", "Foo", "render"));
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", "render"), .{ .inherent = fn_inherent });
}

test "lookupSourceMethod resolves the one local trait impl that declares the method" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    _ = try addEntity(&g, a, .trait_, "Default", root);

    // impl Default for Foo { fn default; }
    const default_impl = try addEntity(&g, a, .impl_, "Default for Foo", root);
    const fn_default = try addEntity(&g, a, .fn_, "default", default_impl);
    // impl Clone for Bar { fn clone; } — a trait method of the same name for
    // another receiver must not answer for Foo.
    const clone_impl = try addEntity(&g, a, .impl_, "Clone for Bar", root);
    _ = try addEntity(&g, a, .fn_, "clone", clone_impl);

    // No inherent impl declares it, so the trait candidate is the answer.
    try std.testing.expectEqual(@as(?spine.EntityId, null), resolve_methods.lookupInherentMethod(&g, "Foo", "default"));
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", "default"), .{ .trait_ = fn_default });
}

test "lookupSourceMethod leaves competing trait candidates ambiguous instead of picking one" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    _ = try addEntity(&g, a, .trait_, "Display", root);
    _ = try addEntity(&g, a, .trait_, "Debug", root);

    // impl Display for Foo { fn render; } and impl Debug for Foo { fn render; }
    const display_impl = try addEntity(&g, a, .impl_, "Display for Foo", root);
    const display_render = try addEntity(&g, a, .fn_, "render", display_impl);
    const debug_impl = try addEntity(&g, a, .impl_, "Debug for Foo", root);
    const debug_render = try addEntity(&g, a, .fn_, "render", debug_impl);

    // Two traits declare it for one receiver. Neither wins, so the call stays
    // undecidable — it must not fall through to the standard methods either.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", "render"), .ambiguous);

    // The ambiguity belongs to the CALL SITE, not to either impl: naming the
    // trait is how Rust disambiguates, and each qualified lookup still answers
    // with its own method. Were either to answer null the ambiguity above
    // would be one missing impl rather than two competing ones.
    try std.testing.expectEqual(@as(?spine.EntityId, display_render), resolve_methods.lookupTraitMethod(&g, "Display", "Foo", "render"));
    try std.testing.expectEqual(@as(?spine.EntityId, debug_render), resolve_methods.lookupTraitMethod(&g, "Debug", "Foo", "render"));

    // One trait declared twice for one receiver is ambiguous the same way.
    _ = try addEntity(&g, a, .struct_, "Baz", root);
    const first_impl = try addEntity(&g, a, .impl_, "Display for Baz", root);
    _ = try addEntity(&g, a, .fn_, "fmt", first_impl);
    const second_impl = try addEntity(&g, a, .impl_, "Display for Baz", root);
    _ = try addEntity(&g, a, .fn_, "fmt", second_impl);
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Baz", "fmt"), .ambiguous);

    // An inherent definition decides the call the traits left open: it is
    // looked for before the trait candidates are counted, so the ambiguity
    // never gets a chance to refuse it.
    const inherent_impl = try addEntity(&g, a, .impl_, "Foo", root);
    const fn_inherent = try addEntity(&g, a, .fn_, "render", inherent_impl);
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", "render"), .{ .inherent = fn_inherent });
}

test "lookupSourceMethod reports a method or a receiver the crate does not declare" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Foo", root);
    // impl Foo { fn value; }
    const inherent_impl = try addEntity(&g, a, .impl_, "Foo", root);
    const fn_value = try addEntity(&g, a, .fn_, "value", inherent_impl);
    // impl Default for Bar { fn default; }
    const default_impl = try addEntity(&g, a, .impl_, "Default for Bar", root);
    const fn_default = try addEntity(&g, a, .fn_, "default", default_impl);

    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", "value"), .{ .inherent = fn_value });

    // A method Foo never declares stays missing whatever the crate declares.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", "default"), .missing);
    // A trait impl answers for its own receiver and no other. The impl really
    // is registered and really does declare `default` — nothing is missing
    // from the graph — so what is missing is the RECEIVER: nothing in this
    // crate declares a `Bar` for that impl to be an impl of. Naming the trait
    // is still enough to find it, which is what separates this from a typo.
    try std.testing.expectEqual(@as(?spine.EntityId, fn_default), resolve_methods.lookupTraitMethod(&g, "Default", "Bar", "default"));
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Bar", "default"), .missing);
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Bar", "value"), .missing);
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Baz", "value"), .missing);
    // Nothing was asked for.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "", "value"), .missing);
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "Foo", ""), .missing);
}

// ── a trait impl over a primitive receiver ─────────────────────────────────
//
//     pub trait Label { fn label_text(&self) -> &'static str; }
//     impl Label for u64 { fn label_text(&self) -> &'static str { "kib" } }
//     pub fn label_width() -> isize { let value: u64 = 4096; value.label_text().len() as isize }
//
// A primitive is the receiver this crate never declares and still writes an
// impl over: `impl Label for u64` names its self type outright, and a receiver
// typed `u64` reads as exactly that name. Requiring a declaration here would
// refuse the call with nothing left to recover it from, and every node
// downstream — the `&'static str`, its `len`, the cast — loses its type with it.
//
// The gate this test also pins is the OTHER half: a name that EXISTS and is
// the wrong kind of thing is still not a type to stand an impl on. Relaxing
// the primitive case must not turn `impl Render for BAZ` — where `BAZ` is a
// constant — into a dispatch, and it must not reach the undeclared-receiver
// case `lookupSourceMethod reports a method or a receiver the crate does not
// declare` already pins.

test "a trait impl over a primitive receiver resolves, and a non-type receiver still does not" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    // impl Label for u64 { fn label_text; }
    const label_impl = try addEntity(&g, a, .impl_, "Label for u64", root);
    const fn_label_text = try addEntity(&g, a, .fn_, "label_text", label_impl);
    // impl Default for u64 { fn default; }
    const default_impl = try addEntity(&g, a, .impl_, "Default for u64", root);
    const fn_default = try addEntity(&g, a, .fn_, "default", default_impl);
    // impl Render for BAZ { fn render; } — `BAZ` is a CONSTANT, not a type.
    _ = try addEntity(&g, a, .const_, "BAZ", root);
    const render_impl = try addEntity(&g, a, .impl_, "Render for BAZ", root);
    _ = try addEntity(&g, a, .fn_, "render", render_impl);

    // The primitive is a type the language names, so the impl's own self type
    // is enough to stand on — for whichever method it declares.
    try expectSourceLookup(
        resolve_methods.lookupSourceMethod(&g, "u64", "label_text"),
        .{ .trait_ = fn_label_text },
    );
    try expectSourceLookup(
        resolve_methods.lookupSourceMethod(&g, "u64", "default"),
        .{ .trait_ = fn_default },
    );
    // Naming the trait still finds it, so a primitive receiver and a
    // qualified lookup agree on one impl rather than two stories.
    try std.testing.expectEqual(
        @as(?spine.EntityId, fn_label_text),
        resolve_methods.lookupTraitMethod(&g, "Label", "u64", "label_text"),
    );
    // The primitive is not a wildcard: a method neither impl declares is still
    // missing, however well the receiver type is known.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "u64", "render"), .missing);

    // The receiver that exists and is the wrong KIND is still refused. This is
    // the case the declaration gate exists for, and exempting primitives must
    // not have relaxed it.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "BAZ", "render"), .missing);
}

// The exemption above admits a primitive so an impl over one resolves. It is
// an exemption from the DECLARATION scan only, and these are the two ways it
// could quietly become more than that: by letting the candidate count through
// without counting, or by letting one primitive's impl answer for another.
// Both would be silent — a call would dispatch, to the wrong impl — so each is
// pinned here rather than left to the nominal-receiver tests, whose receivers
// never reach the exemption at all.
test "a primitive receiver still counts its candidates and answers for itself alone" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    // impl Label for u64 { fn tag; } and impl Marker for u64 { fn tag; }
    const label_impl = try addEntity(&g, a, .impl_, "Label for u64", root);
    _ = try addEntity(&g, a, .fn_, "tag", label_impl);
    const marker_impl = try addEntity(&g, a, .impl_, "Marker for u64", root);
    _ = try addEntity(&g, a, .fn_, "tag", marker_impl);
    // impl Only32 for u32 { fn tag; }
    const only32_impl = try addEntity(&g, a, .impl_, "Only32 for u32", root);
    const fn_tag_32 = try addEntity(&g, a, .fn_, "tag", only32_impl);

    // Two traits over one primitive are the same competition a struct has, and
    // the exemption does not let either one win.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "u64", "tag"), .ambiguous);

    // A second primitive answers with its own impl and only its own: admitting
    // `u64` did not make the two `u64` impls candidates here, and admitting
    // `u32` did not make its single impl ambiguous.
    try expectSourceLookup(
        resolve_methods.lookupSourceMethod(&g, "u32", "tag"),
        .{ .trait_ = fn_tag_32 },
    );
    // A primitive this crate writes no impl over is missing, not ambiguous:
    // the exemption admits the NAME, it does not invent impls.
    try expectSourceLookup(resolve_methods.lookupSourceMethod(&g, "i64", "tag"), .missing);
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
    // The graph borrows an arena: answering a call grows the body tables
    // through the graph allocator and hands back no handle to free them with,
    // which is the contract the pipeline's arena-backed graph already meets.
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

test "a slice len result is a primitive operand of an operator" {
    // `hex/src/lib.rs:315, 318` and `:368, 375` are exactly this shape:
    //     if data.len() % 2 != 0 { .. }
    // The resolver admits `len` on a slice, so the call is left in the tree
    // with nothing marked on it, and the operator is the only place left that
    // can say what it reads. A `usize` result type is what it says, and that is
    // also what makes the operand primitive, so the two halves agree instead
    // of one admitting the operator and the other refusing its operand.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const len_method = try addEntity(&g, a, .fn_, "len", root);

    var types_store = [_]types.Type{
        .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
    };

    // 0 is the slice, 1 its `len()`, 2 the literal `*` multiplies, 3 the
    // operator over the two.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = len_method,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "2",
            .value = 2,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
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

    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[3].kind == .binary);

    // Admitting the `len` publishes the result it was dispatched on, so the
    // `usize` that admitted this operator is a type the tree now carries
    // rather than one only the operator gate could see. It is the canonical
    // entry: `b.types` held only the slice receiver before the pass, so the
    // published id is a newly appended `usize` and not the receiver's.
    try std.testing.expect(b.exprs[1].ty != null);
    const published = b.exprs[1].ty.?;
    try std.testing.expect(published < b.types.len);
    try std.testing.expect(published != 0);
    try std.testing.expect(types.deepEqual(.{ .prim = .usize }, b.types[published]));
}

test "a len this pass cannot type still refuses its operator" {
    // The same `len` name on the other side of the boundary. `impl
    // ExactSizeIterator for Bytes { fn len(&self) -> usize }` resolves as an
    // ordinary trait method, so the call is dispatched and nothing on it is
    // marked, but no runtime `len` backs it and this pass names no result
    // type for it. The operator is then refused with the reason that says
    // which half is missing, and the call itself stays dispatchable.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const bytes = try addEntity(&g, a, .struct_, "Bytes", root);
    const exact_size = try addEntity(&g, a, .impl_, "iter::ExactSizeIterator for Bytes", root);
    const len_method = try addEntity(&g, a, .fn_, "len", exact_size);

    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Bytes", .id = bytes }} } },
    };

    // Same four nodes as the slice case, one owner type apart.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = len_method,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "2",
            .value = 2,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
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

    try std.testing.expectEqual(@as(usize, 1), stats.trait_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    try expectUnsupportedReason(
        &b.exprs[3],
        "operator operand is a dispatched method call whose result type this pass does not name",
    );
    // The call is untouched: only the operator reads an unnameable value.
    try std.testing.expect(b.exprs[1].kind == .method_call);
}

test "a source call that declares a scalar return is a primitive operand of an operator" {
    // The question the slice `len` case above asks, asked of a FREE call this
    // crate declared:
    //     fn mask(seed: u64) -> u64 { .. }
    //     let key = mask(seed) ^ 0xFF;
    // Inference need not have pinned the call: the callee's own signature
    // names its result, and that name is what makes the operand a real value
    // an operator can read. Both halves have to answer that way — the
    // resolved-type gate already reads the declaration, so a primitive gate
    // that did not would refuse an operator over `u64` and emit nothing for
    // source Rust wrote.
    //
    // The arena is production's shape: publishing the resolved result type
    // appends to the caller's table, and that table belongs to whoever owns
    // the allocator.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const mask = try addEntity(&g, a, .fn_, "mask", root);

    // The declaration is the only thing in this crate that types the call.
    var body_store = [_]bodies.BodyKind{.none} ** 2;
    body_store[mask] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u64 },
        .body = 0,
    } };

    // 0 is the call's argument, 1 the first call, 2 the literal on its other
    // side, 3 the operator over those two.
    //
    // Node 4 is the SAME operator written AHEAD of the call it reads (6, over
    // 5) and that order is the point of it: the resolver reaches node 4
    // before the call's own turn has pinned a type for it, so the only thing
    // that can admit that operand is the declaration the callee carries. Node
    // 3 is the ordinary order, where the call's published type answers for it.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = mask }, .args = &.{0} } },
        },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "255",
            .value = 255,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .wrapping,
            .lhs = 6,
            .rhs = 5,
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "255",
            .value = 255,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = mask }, .args = &.{0} } },
        },
    };
    var type_store = [_]types.Type{};
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &type_store,
        .bodies = &body_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    // Both operators are the ones source wrote: same op, same overflow, same
    // two operands, in the same order. Neither was rewritten or refused.
    for ([_]struct { node: exprs.NodeId, lhs: exprs.NodeId, rhs: exprs.NodeId }{
        .{ .node = 3, .lhs = 1, .rhs = 2 },
        .{ .node = 4, .lhs = 6, .rhs = 5 },
    }) |expected| {
        try std.testing.expect(b.exprs[expected.node].kind == .binary);
        const binary = b.exprs[expected.node].kind.binary;
        try std.testing.expectEqual(exprs.BinaryOp.bit_xor, binary.op);
        try std.testing.expectEqual(exprs.Overflow.wrapping, binary.overflow);
        try std.testing.expectEqual(expected.lhs, binary.lhs);
        try std.testing.expectEqual(expected.rhs, binary.rhs);
    }
    // Only the operators read the calls' values; the calls are untouched.
    for ([_]exprs.NodeId{ 1, 6 }) |node| {
        try std.testing.expect(b.exprs[node].kind == .call);
    }

    // A resolved call publishes the type its declaration named: one canonical
    // `u64` entry that both calls share, not a copy apiece.
    try std.testing.expect(b.exprs[1].ty != null and b.exprs[6].ty != null);
    const published = b.exprs[1].ty.?;
    try std.testing.expectEqual(published, b.exprs[6].ty.?);
    try std.testing.expect(published < b.types.len);
    try std.testing.expect(types.deepEqual(.{ .prim = .u64 }, b.types[published]));
}

test "a source call whose declared return is not a scalar still refuses its operator" {
    // The other side of the same question. A declared return types the call,
    // but it does not make the call an operand `^` can read: a nominal, an
    // aggregate, and a generic instantiation are all values with no scalar
    // operand, and a callee this pass cannot resolve types nothing at all —
    // which is refused a half earlier, by the resolved-type gate, with the
    // reason that says which half is missing.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const box = try addEntity(&g, a, .struct_, "Box", root);
    const wrapper = try addEntity(&g, a, .struct_, "Wrapper", root);
    const nominal_call = try addEntity(&g, a, .fn_, "nominal", root);
    const aggregate_call = try addEntity(&g, a, .fn_, "aggregate", root);
    const generic_call = try addEntity(&g, a, .fn_, "generic", root);
    const unknown_call = try addEntity(&g, a, .fn_, "unknown", root);

    // Three callees declare a result; the fourth declares nothing this pass
    // can read, so its body slot stays `.none`.
    var body_store = [_]bodies.BodyKind{.none} ** 7;
    body_store[nominal_call] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .path = .{ .segments = &.{.{ .name = "Box", .id = box }} } },
        .body = 0,
    } };
    body_store[aggregate_call] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .array = &.{
            .elem = .{ .prim = .u8 },
            .len = .{ .literal = 4 },
        } },
        .body = 0,
    } };
    body_store[generic_call] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .generic_inst = .{
            .decl = wrapper,
            .args = .{ .params = &.{.{ .prim = .u32 }} },
        } },
        .body = 0,
    } };

    // 1/4/6/8 are the four calls and 3/5/7/9 the operator each one is the left
    // operand of; 0 is their shared argument and 2 the shared literal.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = nominal_call }, .args = &.{0} } },
        },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "255",
            .value = 255,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = aggregate_call }, .args = &.{0} } },
        },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .wrapping,
            .lhs = 4,
            .rhs = 2,
        } } },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = generic_call }, .args = &.{0} } },
        },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .wrapping,
            .lhs = 6,
            .rhs = 2,
        } } },
        .{
            .id = 8,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = unknown_call }, .args = &.{0} } },
        },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .wrapping,
            .lhs = 8,
            .rhs = 2,
        } } },
    };
    var type_store = [_]types.Type{};
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &type_store,
        .bodies = &body_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    try std.testing.expectEqual(@as(usize, 4), stats.unsupported_operators);
    try expectUnsupportedReason(&b.exprs[3], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[5], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[7], "operator requires primitive operands");
    try expectUnsupportedReason(&b.exprs[9], "operator operands unresolved");
    // Every one of them is still the call source wrote: only the operator
    // reads a value the resolver could not admit as a scalar.
    for ([_]exprs.NodeId{ 1, 4, 6, 8 }) |node| {
        try std.testing.expect(b.exprs[node].kind == .call);
    }
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

test "an owned String reads its own bytes, and a chain off them reads a slice" {
    // `text.as_bytes()` is not a slice's own `as_bytes`: the receiver is the
    // runtime's `r2z.alloc.String`, and what the call hands back is a borrow of
    // the bytes that string owns. That borrow is what makes
    // `text.as_bytes().len()` a slice `len` over a typed `usize` operand rather
    // than an untyped one, and it is why the chain is worth a test of its own.
    //
    // A `&str` is the other runtime type that answers — `str::as_bytes` hands
    // back the very bytes the borrow already points at, no copy — so it is
    // checked here as a positive rather than as a refusal. The `Vec<u8>` this
    // test used to carry is gone: `Vec` has no `as_bytes` in Rust at all, so
    // the call was never a shape this resolver could be right about either way,
    // and pinning a refusal on it asserted a fact about Rust that is false.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const as_bytes = try addEntity(&g, a, .fn_, "as_bytes", root);
    const len = try addEntity(&g, a, .fn_, "len", root);

    var types_store = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        .{ .reference = &.{ .mut = false, .pointee = types.str_type } },
    };

    // 0/1: an owned `String` and its `len()`. 2: the literal `2`.
    // 3: `text.len() * 2`. 4/5: the same string and its `as_bytes()`.
    // 6: the `len()` over that borrow. 7: the operator over it.
    // 8/9: a `&str` and the `as_bytes()` it does answer.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = len,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "2",
            .value = 2,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{ .id = 4, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = as_bytes,
            .args = &.{},
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 5,
            .receiver_mode = .shared,
            .method = len,
            .args = &.{},
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .wrapping,
            .lhs = 6,
            .rhs = 2,
        } } },
        .{ .id = 8, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 8,
            .receiver_mode = .shared,
            .method = as_bytes,
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

    _ = try resolve_methods.resolveMethods(&g, &b);

    // Each surviving node is the observation. `resolveMethods` replaces a call
    // it refuses with an `.unsupported` marker, so a node that is still a
    // `.method_call` is a call that was admitted, and a counter would only
    // restate that — while changing for reasons unrelated to this test whenever
    // any other std path admits a call in the same graph.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expect(b.exprs[5].kind == .method_call);
    try std.testing.expect(b.exprs[6].kind == .method_call);
    // Both operators survive: the `len` over the borrowed bytes reads as a
    // `usize`, so the operand over it is primitive on both sides.
    try std.testing.expect(b.exprs[3].kind == .binary);
    try std.testing.expect(b.exprs[7].kind == .binary);
    // A `&str` answers too, and for a different reason than the owned string:
    // `str::as_bytes` hands back the bytes the borrow already points at, so
    // nothing is copied and the runtime value is a plain `[]const u8` rather
    // than the owned string's own view. The `String` case above is the one
    // that reads bytes OUT of an owner.
    try std.testing.expect(b.exprs[9].kind == .method_call);
}

test "a blanket AsRef<[u8]> impl binds an array receiver's call to the trait it implements" {
    // `[0x66, 0x6f, 0x6f, 0x62, 0x61, 0x72]` is `[T; 6]` for whatever `T` the
    // surrounding context fixes, so the literal itself proves no element type
    // and `arrayReceiverType` leaves it untyped. `impl<T: AsRef<[u8]>> ToHex
    // for T` does admit it — the declared bound is the only evidence that
    // says so, and an array `[E; N]` meets `AsRef<[u8]>` only for `E = u8`.
    //
    // The impl names no concrete self type, so no name lookup can pick the
    // call's method. What the resolver can do is name the TRAIT, and that is
    // what the backend selects the impl from. `blanketImplForMethod` reads the
    // trait off the call's `method_ref` — the shape this fixture produces by
    // parenting that reference to the trait — and `blanketImplFor` looks for
    // the impl declaring the method. The call's own `method_ref` is
    // synthesized per call site and carries only the enclosing module, so
    // parenting it to the trait is what puts that chain in reach.
    //
    // The element type is still never invented from the literals' magnitudes:
    // the bound names it, and a receiver that has a type of its own still
    // reaches the impl through the ordinary name lookup.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const to_hex = try addEntity(&g, a, .trait_, "ToHex", root);
    const to_hex_impl = try addEntity(&g, a, .impl_, "ToHex for T", root);
    _ = try addEntity(&g, a, .fn_, "encode_hex", to_hex_impl);
    _ = try addEntity(&g, a, .fn_, "encode_hex_upper", to_hex_impl);
    // Two more blanket impls, over bounds an array of integers does not meet.
    const display_impl = try addEntity(&g, a, .impl_, "fmt::Display for T", root);
    _ = try addEntity(&g, a, .fn_, "render", display_impl);
    const text_impl = try addEntity(&g, a, .impl_, "ToText for T", root);
    _ = try addEntity(&g, a, .fn_, "encode_text", text_impl);
    // The unresolved names a call reaches the resolver with, in the shape
    // body lowering synthesizes them: a `method_ref` owned by the enclosing
    // module.
    const encode_hex_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_hex_upper_ident = try addEntity(&g, a, .method_ref, "encode_hex_upper", root);
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
        .{ .impl_ = .{
            .self_ty = self_param,
            .trait_path = .{ .segments = &.{.{ .name = "ToHex", .id = to_hex }} },
            .generics = .{ .params = &hex_generics, .where_clauses = &.{} },
        } },
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
            .text = "0x66",
            .value = hex_values[0],
            .base = .hex,
            .ty_suffix = null,
        } } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x6f",
            .value = hex_values[1],
            .base = .hex,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x6f",
            .value = hex_values[2],
            .base = .hex,
            .ty_suffix = null,
        } } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x62",
            .value = hex_values[3],
            .base = .hex,
            .ty_suffix = null,
        } } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x61",
            .value = hex_values[4],
            .base = .hex,
            .ty_suffix = null,
        } } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0x72",
            .value = hex_values[5],
            .base = .hex,
            .ty_suffix = null,
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
            .text = "0_u8",
            .value = 0,
            .base = .hex,
            .ty_suffix = "u8",
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

    // All three calls the one `ToHex` impl provides are bound, whether the
    // literal's elements were typed or not: the rule reads the impl's bound to
    // find the trait, and each call's own `method_ref` is re-parented onto it.
    try std.testing.expectEqual(@as(usize, 3), stats.trait_resolved);
    for ([_]exprs.NodeId{ 7, 8, 14 }) |node| {
        const call = switch (b.exprs[node].kind) {
            .method_call => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const entity = g.symbol_table.get(call.method) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(spine.EntityKind.method_ref, entity.kind);
        try std.testing.expectEqual(@as(?spine.EntityId, to_hex), entity.parent);
    }

    // The bound is the whole of the evidence, in both directions. `Display` is
    // not `AsRef<[u8]>`, `AsRef<str>` is not `AsRef<[u8]>`, and no impl at all
    // provides `not_a_method`, so those three stay refused on the older
    // grounds, with their own reasons.
    try std.testing.expectEqual(@as(usize, 3), stats.unsupported_methods);
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
            .text = "0",
            .value = 0,
            .base = .dec,
            .ty_suffix = null,
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
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 2,
        } } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 2,
            .rhs = 0,
        } } },
        .{ .id = 4, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 4,
            .rhs = 6,
        } } },
        .{ .id = 6, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 6,
            .rhs = 4,
        } } },
        .{ .id = 8, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 8,
            .rhs = 10,
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

// ── Type aliases are the value they stand for ─────────────────────────────
//
// `type Chunk = u32;` reaches this pass as a `.path`, because that is what the
// CST layer records wherever the alias is spelled — and percent-encoding spells
// it in a field type (`mask: [Chunk; ASCII_RANGE_LEN / BITS_PER_CHUNK]`), so
// every element read out of that table arrives as the alias path. A predicate
// that only recognises `.prim` therefore refuses `&` on a `u32` because the
// source said `Chunk`, and `percent-encoding/src/lib.rs:85,94,100` all read
// that way.

test "a type alias to an integer is a primitive operand of an operator" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const chunk = try addEntity(&g, a, .type_alias, "Chunk", root);

    // Bodies are indexed by EntityId, so the alias body lands on the alias.
    var bodies_store = [_]bodies.BodyKind{ .none, .{ .type_alias = .{
        .target = .{ .prim = .u32 },
    } } };
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Chunk", .id = chunk }} } },
    };

    // `(chunk & mask)`: both operands reach this pass as the alias path.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .binary = .{
            .op = .bit_and,
            .overflow = .wrapping,
            .lhs = 0,
            .rhs = 1,
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

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
}

test "an indexed compound assign through a type alias is not refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const chunk = try addEntity(&g, a, .type_alias, "Chunk", root);

    var bodies_store = [_]bodies.BodyKind{ .none, .{ .type_alias = .{
        .target = .{ .prim = .u32 },
    } } };
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "Chunk", .id = chunk }} } },
        .{ .prim = .u8 },
        .{ .prim = .u32 },
    };

    // `mask[i] |= 1 << x` as percent-encoding writes it: the assign target is
    // an INDEX expression, and its type is the element type of the table, which
    // the alias path names.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .literal = .{ .int = .{
            .text = "0",
            .value = 0,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .index = .{
            .base = 0,
            .index = 1,
        } } },
        .{ .id = 3, .span = span, .ty = 2, .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .assign = .{
            .target = 2,
            .op = .bit_or,
            .value = 3,
            .overflow = .wrapping,
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

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[4].kind == .assign);
}

test "a path that names a nominal is still not a scalar operand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const ascii_set = try addEntity(&g, a, .struct_, "AsciiSet", root);

    // No alias body: `AsciiSet` is a nominal, and a nominal has no scalar
    // reading. Following a path must not become admitting every path.
    var bodies_store = [_]bodies.BodyKind{ .none, .none };
    var types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "AsciiSet", .id = ascii_set }} } },
    };

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .binary = .{
            .op = .bit_and,
            .overflow = .wrapping,
            .lhs = 0,
            .rhs = 1,
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

    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    try expectUnsupportedReason(
        &b.exprs[2],
        "operator requires primitive operands",
    );
}

test "a rev on a retained slice iterator dispatches and an unknown one does not" {
    // seahash/src/reference.rs:46 writes the loop `for &i in int.iter().rev()`,
    // which reaches the resolver as an ordinary `rev` call whose receiver is
    // the `slice.iter()` this pass keeps in the tree rather than as an
    // iterator chain. `rev` belongs to that receiver the way `cloned` does:
    // the runtime already carries it as `r2z.Rev`, so the call stays ordinary
    // and needs no carrier of its own. `render` is the other half of the
    // pair — a name the runtime drives over no carrier at all — and it stays
    // refused, which is what keeps the admission a list instead of the
    // receiver's whole method set.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const iter_ident = try addEntity(&g, a, .fn_, "iter", root);
    const rev_ident = try addEntity(&g, a, .fn_, "rev", root);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);

    var slice_payload: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var types_store = [_]types.Type{.{ .slice = &slice_payload }};

    // 0: the `&[u8]` `int` names, 1: `int.iter()`, 2: `int.iter().rev()`,
    // 3: `int.iter().render()`. Both calls read the SAME retained iterator,
    // so the only thing that separates them is the method name.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = iter_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = rev_ident,
            .args = &.{},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
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

    // `iter` is the std method the typed receiver earns on its own, and `rev`
    // now rides the arm `cloned` has always ridden. The admitted call stays
    // in the tree, bound to the method entity it was written with.
    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expectEqual(@as(spine.EntityId, rev_ident), b.exprs[2].kind.method_call.method);

    // The refusal is keyed on the METHOD over this receiver shape, and it
    // says which half of the rule the call could not meet.
    try expectUnsupportedReason(&b.exprs[3], "method dispatch unavailable");
}

test "a len and a clone on a bare slice iterator dispatch, and a mutating member does not" {
    // `xs.iter()` is a receiver the Zig backend lowers to the runtime's own
    // `r2z.SliceIter(T)`, and `len` and `clone` are members of that struct a
    // method call reaches on it, so the resolver no longer refuses them here.
    // `next` is refused for the opposite reason: it takes `self: *Self`, which
    // does not compile on the temporary the receiver lowers to, and `render`
    // names no member of it at all.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const iter_ident = try addEntity(&g, a, .fn_, "iter", root);
    const len_ident = try addEntity(&g, a, .fn_, "len", root);
    const clone_ident = try addEntity(&g, a, .fn_, "clone", root);
    const next_ident = try addEntity(&g, a, .fn_, "next", root);
    const render_ident = try addEntity(&g, a, .fn_, "render", root);

    var slice_payload: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var types_store = [_]types.Type{.{ .slice = &slice_payload }};

    // 0: the `&[u8]` receiver, 1: `xs.iter()`, 2: `xs.iter().len()`,
    // 3: `xs.iter().clone()`, 4: `xs.iter().next()`, 5: `xs.iter().render()`.
    // Every call reads the SAME retained iterator, so the method name is the
    // only thing that separates the two admitted calls from the two refused.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = iter_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = len_ident,
            .args = &.{},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = clone_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = next_ident,
            .args = &.{},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
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

    // `iter` is the std method the typed receiver earns on its own; `len` and
    // `clone` join it over the iterator it leaves in the tree.
    try std.testing.expectEqual(@as(usize, 3), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_methods);
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expectEqual(@as(spine.EntityId, len_ident), b.exprs[2].kind.method_call.method);
    try std.testing.expect(b.exprs[3].kind == .method_call);
    try std.testing.expectEqual(@as(spine.EntityId, clone_ident), b.exprs[3].kind.method_call.method);

    // The member that mutates through `self` and the one the runtime does not
    // declare both stay refused, each with the reason that says why.
    try expectUnsupportedReason(&b.exprs[4], "method dispatch unavailable");
    try expectUnsupportedReason(&b.exprs[5], "method dispatch unavailable");
}

test "a len over a cloned projection stays refused while cloned itself dispatches" {
    // The bare iterator is a runtime value the backend can call into; the
    // `cloned` projection is not, so the names the bare iterator admits must
    // NOT leak onto it. Admitting them there would emit a method call on the
    // `r2z.SliceIter` that has no `cloned` member, which is the trap this arm
    // exists to keep shut.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const iter_ident = try addEntity(&g, a, .fn_, "iter", root);
    const cloned_ident = try addEntity(&g, a, .fn_, "cloned", root);
    const len_ident = try addEntity(&g, a, .fn_, "len", root);
    const clone_ident = try addEntity(&g, a, .fn_, "clone", root);

    var slice_payload: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var types_store = [_]types.Type{.{ .slice = &slice_payload }};

    // 0: the `&[u8]` receiver, 1: `xs.iter()`, 2: `xs.iter().cloned()`,
    // 3: `xs.iter().cloned().len()`, 4: `xs.iter().cloned().clone()`. The
    // last two are the names the bare iterator admits, over the projection.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = iter_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = cloned_ident,
            .args = &.{},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .value,
            .method = len_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .value,
            .method = clone_ident,
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

    // `iter` and `cloned` resolve; the two member names do not, because the
    // receiver they would land on is the projection and not the iterator.
    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_methods);
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expectEqual(@as(spine.EntityId, cloned_ident), b.exprs[2].kind.method_call.method);

    try expectUnsupportedReason(&b.exprs[3], "method dispatch unavailable");
    try expectUnsupportedReason(&b.exprs[4], "method dispatch unavailable");
}

test "a blanket AsRef<[u8]> impl binds a bounded type parameter receiver's call to the trait it implements" {
    // `fn encode<T: AsRef<[u8]>>(data: T) -> String { data.encode_hex() }` is
    // the shape hex/src/lib.rs:259-261 is written in, and the call is the
    // blanket impl's method whether or not the two spell their parameter the
    // same way. It is spelled `U` here on purpose: `lookupTraitMethodCandidates`
    // can only match a receiver NAME against an impl's own self-type spelling,
    // so with `impl<U: AsRef<[u8]>> ToHex for U` no name lookup can bind this
    // call and the trait linkage is the only route to the impl. What the
    // resolver can prove is the receiver's own declaration: `T` is bounded by
    // a byte-sequence `AsRef`, which is what the impl's bound requires of its
    // self type.
    //
    // The trait is the linkage, because it is what the backend selects the
    // impl from: `blanketImplForMethod` reads the trait off the call's
    // `method_ref` — the shape this fixture produces — and `blanketImplFor`
    // looks for the impl declaring the method. Each call's own `method_ref`
    // is synthesized per call site and carries only the enclosing module, so
    // parenting it to the trait is what puts that chain in reach.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const to_hex = try addEntity(&g, a, .trait_, "ToHex", root);
    const to_hex_impl = try addEntity(&g, a, .impl_, "ToHex for U", root);
    _ = try addEntity(&g, a, .fn_, "encode_hex", to_hex_impl);
    const encode = try addEntity(&g, a, .fn_, "encode", root);
    _ = try addEntity(&g, a, .field, "data", encode);
    const encode_hex_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_where = try addEntity(&g, a, .fn_, "encode_where", root);
    _ = try addEntity(&g, a, .field, "data", encode_where);
    const encode_where_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_plain = try addEntity(&g, a, .fn_, "encode_plain", root);
    _ = try addEntity(&g, a, .field, "data", encode_plain);
    const encode_plain_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_text = try addEntity(&g, a, .fn_, "encode_text", root);
    _ = try addEntity(&g, a, .field, "data", encode_text);
    const encode_text_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_other = try addEntity(&g, a, .fn_, "encode_other", root);
    _ = try addEntity(&g, a, .field, "data", encode_other);
    const encode_other_ident = try addEntity(&g, a, .method_ref, "encode_hex_upper", root);

    const byte_seq: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const as_ref_bytes: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "AsRef", .id = null }} },
        .args = &.{byte_seq},
    };
    const self_param: types.Type = .{ .path = .{ .segments = &.{.{ .name = "U", .id = null }} } };
    const impl_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "U", .bounds = &.{as_ref_bytes} },
    }};
    // `encode` bounds the parameter in its own signature; `encode_where` puts
    // the same bound in a `where` clause. Both are the declaration the
    // receiver is read from, and both are scopes the generic walk reads.
    const bounded_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{as_ref_bytes} },
    }};
    const where_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{} },
    }};
    const where_clauses = [_]types.WhereClause{.{
        .self_ty = .{ .segments = &.{.{ .name = "T", .id = null }} },
        .bounds = &.{as_ref_bytes},
    }};
    const plain_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{} },
    }};
    const text_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{
            .{ .path = .{ .segments = &.{.{ .name = "AsRef", .id = null }} }, .args = &.{types.str_type} },
        } },
    }};

    // `bodies` is sparse and indexed by entity id, so each scope is written
    // at its own entity's slot rather than at a counted offset.
    var bodies_store = [_]bodies.BodyKind{bodies.BodyKind.none} ** 19;
    bodies_store[to_hex_impl] = .{ .impl_ = .{
        .self_ty = self_param,
        .trait_path = .{ .segments = &.{.{ .name = "ToHex", .id = to_hex }} },
        .generics = .{ .params = &impl_generics, .where_clauses = &.{} },
    } };
    bodies_store[encode] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &bounded_generics, .where_clauses = &.{} } },
    };
    bodies_store[encode_where] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &where_generics, .where_clauses = &where_clauses } },
    };
    bodies_store[encode_plain] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &plain_generics, .where_clauses = &.{} } },
    };
    bodies_store[encode_text] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &text_generics, .where_clauses = &.{} } },
    };
    bodies_store[encode_other] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &bounded_generics, .where_clauses = &.{} } },
    };

    const types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    };

    // 0/2/4/6/8: a `data: T` receiver, each parented to the callable that
    // declares the bound it is read from. 1/3/5/7/9: that receiver's call.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 5, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = encode_hex_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 8, .generic_args = &.{} } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .shared,
            .method = encode_where_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 11, .generic_args = &.{} } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = encode_plain_ident,
            .args = &.{},
        } } },
        .{ .id = 6, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 14, .generic_args = &.{} } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 6,
            .receiver_mode = .shared,
            .method = encode_text_ident,
            .args = &.{},
        } } },
        .{ .id = 8, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 17, .generic_args = &.{} } } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 8,
            .receiver_mode = .shared,
            .method = encode_other_ident,
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

    // Both calls the bound admits are bound to the trait the impl
    // implements, whether the bound is written on the parameter or in a
    // `where` clause beside it.
    try std.testing.expectEqual(@as(usize, 2), stats.trait_resolved);
    for ([_]exprs.NodeId{ 1, 3 }) |node| {
        const call = switch (b.exprs[node].kind) {
            .method_call => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const entity = g.symbol_table.get(call.method) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(spine.EntityKind.method_ref, entity.kind);
        try std.testing.expectEqual(@as(?spine.EntityId, to_hex), entity.parent);
    }

    // The bound is the whole of the evidence, in both directions. A bare `T`
    // promises nothing, `AsRef<str>` is not `AsRef<[u8]>`, and no impl
    // provides `encode_hex_upper`, so those three keep whatever reason their
    // own dispatch earns rather than resolving on the method's name.
    try std.testing.expectEqual(@as(usize, 3), stats.unsupported_methods);
    for ([_]exprs.NodeId{ 5, 7, 9 }) |node| {
        try expectUnsupported(&b.exprs[node]);
    }
}

test "two blanket AsRef<[u8]> impls leave a bounded type parameter receiver's call refused" {
    // Two impls providing `encode_hex` for a self type the bound admits name
    // the method ambiguously, and a bounded type parameter does not make the
    // pair less ambiguous: nothing about the receiver's declaration says which
    // impl its method comes from.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const to_hex = try addEntity(&g, a, .trait_, "ToHex", root);
    const to_hex_impl = try addEntity(&g, a, .impl_, "ToHex for U", root);
    _ = try addEntity(&g, a, .fn_, "encode_hex", to_hex_impl);
    const to_text = try addEntity(&g, a, .trait_, "ToText", root);
    const to_text_impl = try addEntity(&g, a, .impl_, "ToText for U", root);
    _ = try addEntity(&g, a, .fn_, "encode_hex", to_text_impl);
    const encode = try addEntity(&g, a, .fn_, "encode", root);
    const data = try addEntity(&g, a, .field, "data", encode);
    const encode_hex_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);

    const byte_seq: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const as_ref_bytes: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "AsRef", .id = null }} },
        .args = &.{byte_seq},
    };
    const self_param: types.Type = .{ .path = .{ .segments = &.{.{ .name = "U", .id = null }} } };
    const impl_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "U", .bounds = &.{as_ref_bytes} },
    }};
    const bounded_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{as_ref_bytes} },
    }};

    var bodies_store = [_]bodies.BodyKind{bodies.BodyKind.none} ** 10;
    bodies_store[to_hex_impl] = .{ .impl_ = .{
        .self_ty = self_param,
        .trait_path = .{ .segments = &.{.{ .name = "ToHex", .id = to_hex }} },
        .generics = .{ .params = &impl_generics, .where_clauses = &.{} },
    } };
    bodies_store[to_text_impl] = .{ .impl_ = .{
        .self_ty = self_param,
        .trait_path = .{ .segments = &.{.{ .name = "ToText", .id = to_text }} },
        .generics = .{ .params = &impl_generics, .where_clauses = &.{} },
    } };
    bodies_store[encode] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &bounded_generics, .where_clauses = &.{} } },
    };

    const types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    };

    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = data, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
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

    try std.testing.expectEqual(@as(usize, 0), stats.trait_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try expectUnsupported(&b.exprs[1]);
}

test "a core supertrait carries an operator over a generic parameter" {
    // `fn test_hash<T: Eq + core::fmt::Debug>(..)` asserting `hashed ==
    // expected` is const-fnv1a-hash/src/lib.rs:79-83. core declares
    // `Eq: PartialEq<Self>`, so `T: Eq` IS `T: PartialEq` and the `==` Rust
    // writes there is valid source over a typed binary operator: it stays a
    // `binary` node whose two operands keep the parameter they were declared
    // with, which is what the backend emits for any other typed operator.
    //
    // The edges are the ones core's own declarations spell out — `Ord` buys
    // both, `PartialOrd` buys `PartialEq`, `Eq` buys neither ordering — and
    // nothing else, so a bare parameter, an `Eq` compared with `<`, and a
    // crate trait that happens to be named `Eq` all stay refused.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const tests = try addEntity(&g, a, .module, "tests", root);
    const eq_hash = try addEntity(&g, a, .fn_, "test_hash", tests);
    const eq_hashed = try addEntity(&g, a, .field, "hashed", eq_hash);
    _ = try addEntity(&g, a, .field, "expected", eq_hash);
    const plain_hash = try addEntity(&g, a, .fn_, "plain_hash", tests);
    const plain_hashed = try addEntity(&g, a, .field, "hashed", plain_hash);
    _ = try addEntity(&g, a, .field, "expected", plain_hash);
    const ord_hash = try addEntity(&g, a, .fn_, "ord_hash", tests);
    const ord_hashed = try addEntity(&g, a, .field, "hashed", ord_hash);
    _ = try addEntity(&g, a, .field, "expected", ord_hash);
    const partial_ord_hash = try addEntity(&g, a, .fn_, "partial_ord_hash", tests);
    const partial_ord_hashed = try addEntity(&g, a, .field, "hashed", partial_ord_hash);
    _ = try addEntity(&g, a, .field, "expected", partial_ord_hash);
    const eq_order = try addEntity(&g, a, .fn_, "eq_order", tests);
    const eq_order_hashed = try addEntity(&g, a, .field, "hashed", eq_order);
    _ = try addEntity(&g, a, .field, "expected", eq_order);
    const crate_eq = try addEntity(&g, a, .trait_, "Eq", root);
    const local_hash = try addEntity(&g, a, .fn_, "local_hash", tests);
    const local_hashed = try addEntity(&g, a, .field, "hashed", local_hash);
    _ = try addEntity(&g, a, .field, "expected", local_hash);

    // The bounds are core's own paths, spelled the way the CST layer spells a
    // prelude name: `bodies.genericBound` resolves them against
    // `core::cmp::PartialEq` and `core::cmp::PartialOrd` with no crate entity
    // involved, which is what keeps a crate trait named `Eq` out.
    const eq_bound: types.Bound = .{ .path = .{ .segments = &.{
        .{ .name = "core", .id = null },
        .{ .name = "cmp", .id = null },
        .{ .name = "Eq", .id = null },
    } } };
    const ord_bound: types.Bound = .{ .path = .{ .segments = &.{
        .{ .name = "core", .id = null },
        .{ .name = "cmp", .id = null },
        .{ .name = "Ord", .id = null },
    } } };
    const partial_ord_bound: types.Bound = .{ .path = .{ .segments = &.{
        .{ .name = "core", .id = null },
        .{ .name = "cmp", .id = null },
        .{ .name = "PartialOrd", .id = null },
    } } };
    const debug_bound: types.Bound = .{ .path = .{ .segments = &.{
        .{ .name = "core", .id = null },
        .{ .name = "fmt", .id = null },
        .{ .name = "Debug", .id = null },
    } } };

    const eq_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{ eq_bound, debug_bound } },
    }};
    const plain_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{} },
    }};
    const ord_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{ord_bound} },
    }};
    const partial_ord_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{partial_ord_bound} },
    }};
    const eq_only_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{eq_bound} },
    }};
    // A crate trait named `Eq` resolves to the crate's own declaration, and
    // that is not core's `Eq`: the id the bound carries is the evidence, and
    // no supertrait of the local trait gives it PartialEq.
    const local_eq_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{
            .{ .path = .{ .segments = &.{.{ .name = "Eq", .id = crate_eq }} } },
        } },
    }};

    var bodies_store = [_]bodies.BodyKind{bodies.BodyKind.none} ** 21;
    bodies_store[eq_hash] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &eq_generics, .where_clauses = &.{} } },
    };
    bodies_store[plain_hash] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &plain_generics, .where_clauses = &.{} } },
    };
    bodies_store[ord_hash] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &ord_generics, .where_clauses = &.{} } },
    };
    bodies_store[partial_ord_hash] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &partial_ord_generics, .where_clauses = &.{} } },
    };
    bodies_store[eq_order] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &eq_only_generics, .where_clauses = &.{} } },
    };
    bodies_store[crate_eq] = .{ .trait_ = .{ .name = "Eq" } };
    bodies_store[local_hash] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &local_eq_generics, .where_clauses = &.{} } },
    };

    const types_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    };

    // 0/1 and 2: `T: Eq + Debug` compared for equality, in both directions.
    // 3/4 and 5: the same two operands over a parameter with no bound at all.
    // 6/7 and 8/9: `T: Ord` compared for equality and for ordering.
    // 10/11 and 12: `T: PartialOrd` compared for equality.
    // 13/14 and 15: `T: Eq` compared for ordering, which Eq does not give.
    // 16/17 and 18: a parameter bounded by the crate's own `Eq`.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = eq_hashed, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 4, .generic_args = &.{} } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 0, .rhs = 1 } } },
        .{ .id = 3, .span = span, .ty = 0, .kind = .{ .path = .{ .def = plain_hashed, .generic_args = &.{} } } },
        .{ .id = 4, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 3, .rhs = 4 } } },
        .{ .id = 6, .span = span, .ty = 0, .kind = .{ .path = .{ .def = ord_hashed, .generic_args = &.{} } } },
        .{ .id = 7, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 10, .generic_args = &.{} } } },
        .{ .id = 8, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 6, .rhs = 7 } } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .lt, .overflow = .checked, .lhs = 6, .rhs = 7 } } },
        .{ .id = 10, .span = span, .ty = 0, .kind = .{ .path = .{ .def = partial_ord_hashed, .generic_args = &.{} } } },
        .{ .id = 11, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 13, .generic_args = &.{} } } },
        .{ .id = 12, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 10, .rhs = 11 } } },
        .{ .id = 13, .span = span, .ty = 0, .kind = .{ .path = .{ .def = eq_order_hashed, .generic_args = &.{} } } },
        .{ .id = 14, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 16, .generic_args = &.{} } } },
        .{ .id = 15, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .lt, .overflow = .checked, .lhs = 13, .rhs = 14 } } },
        .{ .id = 16, .span = span, .ty = 0, .kind = .{ .path = .{ .def = local_hashed, .generic_args = &.{} } } },
        .{ .id = 17, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 20, .generic_args = &.{} } } },
        .{ .id = 18, .span = span, .ty = null, .kind = .{ .binary = .{ .op = .eq, .overflow = .checked, .lhs = 16, .rhs = 17 } } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    const stats = try resolve_methods.resolveMethods(&g, &b);

    // Every operator whose trait the declared bounds reach stays a binary node
    // over the two operands it was written over, and each operand keeps the
    // generic parameter it was declared with: nothing is rewritten, dropped,
    // or given a concrete type the source never named.
    for ([_]exprs.NodeId{ 2, 8, 9, 12 }) |node| {
        try std.testing.expect(b.exprs[node].kind == .binary);
        const binary = b.exprs[node].kind.binary;
        for ([_]exprs.NodeId{ binary.lhs, binary.rhs }) |operand| {
            const operand_ty = b.exprs[operand].ty orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("T", b.types[operand_ty].path.segments[0].name);
        }
    }

    // And a bound that reaches no edge of core's supertrait graph still
    // refuses its operator rather than borrowing another trait's capability.
    try std.testing.expectEqual(@as(usize, 3), stats.unsupported_operators);
    for ([_]exprs.NodeId{ 5, 15, 18 }) |node| {
        try expectUnsupported(&b.exprs[node]);
    }
}

test "a carrier around a bounded type parameter keeps the blanket call refused" {
    // `fn encode<T: AsRef<[u8]>>(data: &T) -> String { data.encode_hex() }` is
    // the declaration above with one word changed, and that word is the whole
    // question. The bound is on the parameter either way, all three callables
    // declare their parameter as `T`, and the impl is still spelled
    // `ToHex for U` against callers that name theirs `T` — so no name lookup
    // can bind any of the three calls and the receiver's own type is the only
    // thing that tells them apart.
    //
    // The bare parameter is the shape the backend builds a self type for:
    // `blanketReceiverType` hands the receiver's type to `isTypeParameterPath`,
    // and a one-segment path with no entity id IS the hoisted method's
    // `comptime T: type`. A reference or a box wrapped around the parameter
    // gets no self type at all, and the backend answers such a call by
    // returning null — which leaves `data.encode_hex()` in the output as a Zig
    // member call on a slice, naming a field no slice has. So each carrier is
    // refused in this pass, where the reason can say so, and the bare call
    // beside them still reaches the trait.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const to_hex = try addEntity(&g, a, .trait_, "ToHex", root);
    const to_hex_impl = try addEntity(&g, a, .impl_, "ToHex for U", root);
    _ = try addEntity(&g, a, .fn_, "encode_hex", to_hex_impl);
    const encode = try addEntity(&g, a, .fn_, "encode", root);
    _ = try addEntity(&g, a, .field, "data", encode);
    const encode_hex_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_ref = try addEntity(&g, a, .fn_, "encode_ref", root);
    _ = try addEntity(&g, a, .field, "data", encode_ref);
    const encode_ref_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);
    const encode_boxed = try addEntity(&g, a, .fn_, "encode_boxed", root);
    _ = try addEntity(&g, a, .field, "data", encode_boxed);
    const encode_boxed_ident = try addEntity(&g, a, .method_ref, "encode_hex", root);

    const byte_seq: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const as_ref_bytes: types.Bound = .{
        .path = .{ .segments = &.{.{ .name = "AsRef", .id = null }} },
        .args = &.{byte_seq},
    };
    const self_param: types.Type = .{ .path = .{ .segments = &.{.{ .name = "U", .id = null }} } };
    const impl_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "U", .bounds = &.{as_ref_bytes} },
    }};
    const bounded_generics = [_]types.GenericParam{.{
        .type_ = .{ .name = "T", .bounds = &.{as_ref_bytes} },
    }};

    // `bodies` is sparse and indexed by entity id, so each scope is written
    // at its own entity's slot rather than at a counted offset.
    var bodies_store = [_]bodies.BodyKind{bodies.BodyKind.none} ** 13;
    bodies_store[to_hex_impl] = .{ .impl_ = .{
        .self_ty = self_param,
        .trait_path = .{ .segments = &.{.{ .name = "ToHex", .id = to_hex }} },
        .generics = .{ .params = &impl_generics, .where_clauses = &.{} },
    } };
    bodies_store[encode] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &bounded_generics, .where_clauses = &.{} } },
    };
    bodies_store[encode_ref] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &bounded_generics, .where_clauses = &.{} } },
    };
    bodies_store[encode_boxed] = .{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0, .generics = .{ .params = &bounded_generics, .where_clauses = &.{} } },
    };

    const param_path: types.Type = .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } };
    const param_ref: types.Ref = .{ .mut = false, .pointee = param_path };
    const types_store = [_]types.Type{
        param_path,
        .{ .reference = &param_ref },
        .{ .boxed = &param_path },
    };

    // 0/2/4: a bare `T`, a `&T`, a `Box<T>`. 1/3/5: each receiver's call.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = 5, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = encode_hex_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 1, .kind = .{ .path = .{ .def = 8, .generic_args = &.{} } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .shared,
            .method = encode_ref_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = 2, .kind = .{ .path = .{ .def = 11, .generic_args = &.{} } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = encode_boxed_ident,
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

    // The bare parameter reaches the trait the impl implements, which is the
    // linkage the backend selects the impl from: one call, not three.
    try std.testing.expectEqual(@as(usize, 1), stats.trait_resolved);
    const call = switch (b.exprs[1].kind) {
        .method_call => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const entity = g.symbol_table.get(call.method) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(spine.EntityKind.method_ref, entity.kind);
    try std.testing.expectEqual(@as(?spine.EntityId, to_hex), entity.parent);

    // Each carrier keeps the reason its own dispatch earns. Nothing was
    // re-parented onto a trait for them, so the backend is never handed a
    // blanket route it has no self type to take.
    try std.testing.expectEqual(@as(usize, 2), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[3], "method dispatch unavailable");
    try expectUnsupportedReason(&b.exprs[5], "method dispatch unavailable");
}

// ── `Result::expect` / `Result::expect_err` ─────────────────────────────────
//
// This is the shape leb128/src/lib.rs is written in:
//     pub enum Fault { Bad }
//     pub fn make() -> Result<u8, Fault> { Ok(7) }
//     pub fn value() -> u8 { make().expect("valid payload") }
//
// The two names return opposite arms, so they are answered from opposite ends
// of the same receiver. `expect` returns the Ok payload, whatever the error
// lowers to. `expect_err` returns the Err arm, and the two `Result`s here
// differ in how that arm is held: a fieldless `Fault` lowers to the Zig error
// union `Fault!u8` and keeps the error as a typed tag, a data-carrying
// `FaultDetail` lowers to the runtime's tagged `r2z.Result` and keeps it as a
// payload beside the Ok value. Both hand an error value back, so both admit the
// method, and each has to hand back ITS OWN `E`.

test "expect returns the Ok payload and expect_err the error arm of its own Result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const make = try addEntity(&g, a, .fn_, "make", root);
    const make_detailed = try addEntity(&g, a, .fn_, "make_detailed", root);
    const fault = try addEntity(&g, a, .enum_, "Fault", root);
    const fault_detail = try addEntity(&g, a, .enum_, "FaultDetail", root);
    const bad = try addEntity(&g, a, .variant, "Bad", fault);
    const bad_detail = try addEntity(&g, a, .variant, "BadDetail", fault_detail);
    const expect_ident = try addEntity(&g, a, .fn_, "expect", root);
    const expect_err_ident = try addEntity(&g, a, .fn_, "expect_err", root);
    const checked_add_ident = try addEntity(&g, a, .fn_, "checked_add", root);

    // `Fault` carries nothing, so it is a Zig error set and the error is a tag
    // inside the union. `FaultDetail` carries `code`, so it is not one and the
    // error is a value beside the payload. Both report `is_error_unionable`,
    // which is why that flag alone cannot answer for either.
    const error_set_result: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "Fault", .id = fault }} } },
        .is_error_unionable = true,
    } };
    const value_result: types.Type = .{ .result = &.{
        .ok = .{ .prim = .u8 },
        .err = .{ .path = .{ .segments = &.{.{ .name = "FaultDetail", .id = fault_detail }} } },
        .is_error_unionable = true,
    } };
    var types_store = [_]types.Type{ error_set_result, value_result };

    // 0/3: the two `Result`-returning calls. 1/4: `.expect(..)` on each, with
    // the borrowed message. 2/5: `checked_add` on each `expect` result, which
    // is admitted only when that result is the `u8` payload. 6: `.expect_err`
    // on the error-union `Result`. 7: that error arm against `Fault::Bad`.
    // 8: `.expect_err` on the value-carrying `Result`. 9: `Fault::Bad`.
    // 10: that error arm against `FaultDetail::BadDetail`. 11: `FaultDetail`.
    // 12/13: the message and the `1`.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .call = .{
            .call_kind = .{ .free = make },
            .args = &.{},
        } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = expect_ident,
            .args = &.{12},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = checked_add_ident,
            .args = &.{13},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .call = .{
            .call_kind = .{ .free = make_detailed },
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 3,
            .receiver_mode = .value,
            .method = expect_ident,
            .args = &.{12},
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .value,
            .method = checked_add_ident,
            .args = &.{13},
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = expect_err_ident,
            .args = &.{12},
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 6,
            .rhs = 9,
        } } },
        .{ .id = 8, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 3,
            .receiver_mode = .value,
            .method = expect_err_ident,
            .args = &.{12},
        } } },
        .{ .id = 9, .span = span, .ty = null, .kind = .{ .enum_variant = .{
            .def = bad,
            .variant = "Bad",
            .tuple_fields = &.{},
            .named_fields = &.{},
        } } },
        .{ .id = 10, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 8,
            .rhs = 11,
        } } },
        .{ .id = 11, .span = span, .ty = null, .kind = .{ .enum_variant = .{
            .def = bad_detail,
            .variant = "BadDetail",
            .tuple_fields = &.{},
            .named_fields = &.{},
        } } },
        .{ .id = 12, .span = span, .ty = null, .kind = .{ .literal = .{
            .string = .{ .bytes = "valid payload" },
        } } },
        .{ .id = 13, .span = span, .ty = null, .kind = .{ .literal = .{
            .int = .{ .text = "1", .value = 1, .base = .dec, .ty_suffix = null },
        } } },
    };

    var bodies_store = [_]bodies.BodyKind{.none} ** 10;
    bodies_store[make] = .{ .fn_ = .{ .params = &.{}, .ret = error_set_result, .body = 0 } };
    bodies_store[make_detailed] = .{ .fn_ = .{ .params = &.{}, .ret = value_result, .body = 0 } };
    bodies_store[fault] = .{ .enum_ = .{
        .kind = .c_like,
        .variants = &.{
            .{ .name = "Bad", .fields = .none, .discriminant = null },
        },
    } };
    bodies_store[fault_detail] = .{ .enum_ = .{
        .kind = .data,
        .variants = &.{
            .{ .name = "BadDetail", .fields = .{ .named = &.{
                .{ .name = "code", .ty = .{ .prim = .u8 }, .visibility = .public, .span = span },
            } }, .discriminant = null },
        },
    } };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    _ = try resolve_methods.resolveMethods(&g, &b);

    // `expect` returns the Ok payload, so each of its results is the `u8` the
    // call site goes on to do arithmetic with, and the integer method chained
    // off it is a real method. This holds for both lowerings alike: `expect`
    // reads no error value.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expect(b.exprs[4].kind == .method_call);
    try std.testing.expect(b.exprs[5].kind == .method_call);

    // `expect_err` reads the Err arm, and each receiver's arm is a value a
    // comparison is written against: the fieldless `Fault` as a tag inside
    // `Fault!u8`, the data-carrying `FaultDetail` as a payload beside the Ok
    // value. Both enums carry the value comparison Rust's derived `PartialEq`
    // gives them, which is what the pair rule walks.
    try std.testing.expect(b.exprs[6].kind == .method_call);
    try std.testing.expect(b.exprs[7].kind == .binary);
    try std.testing.expect(b.exprs[8].kind == .method_call);
    try std.testing.expect(b.exprs[10].kind == .binary);
}

// ── A constant as a method receiver ─────────────────────────────────────────
//
// percent-encoding/src/lib.rs builds its bit table once and reads it from
// everywhere:
//     pub struct Set { mask: u32 }
//     impl Set { pub const fn contains(&self, bit: u8) -> bool { .. } }
//     pub const CONTROL: &Set = &Set { mask: 1 };
//     pub fn contains(bit: u8) -> bool { CONTROL.contains(bit) }
//
// A constant IS its own declaration: the type beside its name is the only
// account of what every later mention of it is, and inference reaches the
// initializer rather than the declaration when it types a mention. Reading the
// declaration is what makes the dispatch a name lookup instead of a refusal.

test "a constant's own declared type is what types its method receiver" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const set = try addEntity(&g, a, .struct_, "Set", root);
    const set_impl = try addEntity(&g, a, .impl_, "Set", root);
    const contains_fn = try addEntity(&g, a, .fn_, "contains", set_impl);
    const control = try addEntity(&g, a, .const_, "CONTROL", root);
    const table = try addEntity(&g, a, .const_, "TABLE", root);
    const len_ident = try addEntity(&g, a, .fn_, "len", root);
    const contains_ident = try addEntity(&g, a, .method_ref, "contains", root);

    const set_type: types.Type = .{ .path = .{ .segments = &.{.{ .name = "Set", .id = set }} } };
    const set_ref: types.Ref = .{ .mut = false, .pointee = set_type };
    // `TABLE` is a `[u8; N]` whose length is a const-generic PARAMETER rather
    // than a literal. Nothing here needs N's value: the declaration already
    // names the receiver's type, and a length this pass cannot evaluate is not
    // a reason to leave the receiver untyped.
    const table_type: types.Type = .{ .array = &.{
        .elem = .{ .prim = .u8 },
        .len = .{ .generic = 0 },
    } };

    // 0/2: the two constants as bare paths, the way every later mention of one
    // arrives. 1: `CONTROL.contains(0)`. 3/4/5: `TABLE.len() % 2`. 6: the `0`
    // argument. 7/8: the two initializers.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .path = .{ .def = control, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = contains_ident,
            .args = &.{6},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .path = .{ .def = table, .generic_args = &.{} } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .shared,
            .method = len_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{
            .int = .{ .text = "2", .value = 2, .base = .dec, .ty_suffix = null },
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .rem,
            .overflow = .checked,
            .lhs = 3,
            .rhs = 4,
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .literal = .{
            .int = .{ .text = "0", .value = 0, .base = .dec, .ty_suffix = null },
        } } },
        .{ .id = 7, .span = span, .ty = null, .kind = .{ .struct_lit = .{
            .def = set,
            .fields = &.{},
            .base = null,
        } } },
        .{ .id = 8, .span = span, .ty = null, .kind = .{ .array = .{
            .elements = &.{},
            .repeat = null,
        } } },
    };

    var bodies_store = [_]bodies.BodyKind{.none} ** 8;
    bodies_store[control] = .{ .const_ = .{ .ty = .{ .reference = &set_ref }, .init = 7 } };
    bodies_store[table] = .{ .const_ = .{ .ty = table_type, .init = 8 } };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    _ = try resolve_methods.resolveMethods(&g, &b);

    // `CONTROL: &Set` is a borrow of a `Set`, and the borrow is peeled to the
    // `Set` whose inherent block declares `contains`. The call is bound to the
    // crate's own function, not left as a name nothing answers to.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expectEqual(contains_fn, b.exprs[1].kind.method_call.method);

    // `TABLE`'s array type comes from the declaration too, so `len` is admitted
    // on it and its `usize` result is the primitive the `%` reads.
    try std.testing.expect(b.exprs[3].kind == .method_call);
    try std.testing.expect(b.exprs[5].kind == .binary);
}

// ── `std::io::Error::kind` ──────────────────────────────────────────────────
//
// leb128 reads the end of its input through the io error rather than through
// its own:
//     Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => { .. }
//
// That comparison is the point. `kind()` is a method on `std::io::Error`, and
// what it hands back is `std::io::ErrorKind` — a payload-free std enum the
// backend lowers to `r2z.io.ErrorKind`, which Zig compares with `==`. So the
// resolver has to name that result, or the pair rule has nothing to admit the
// operator on.

test "io::Error::kind names the ErrorKind a std comparison is written against" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const kind_ident = try addEntity(&g, a, .method_ref, "kind", null);
    const unexpected_eof = try addEntity(&g, a, .variant, "UnexpectedEof", root);

    const error_type: types.Type = .{ .external_nominal = .{
        .path = &.{ "std", "io", "Error" },
        .args = &.{},
    } };
    const error_kind_type: types.Type = .{ .external_nominal = .{
        .path = &.{ "std", "io", "ErrorKind" },
        .args = &.{},
    } };
    var types_store = [_]types.Type{ error_type, error_kind_type };

    // 0: the `std::io::Error` the failed read returned. 1:
    // `ErrorKind::UnexpectedEof`. 2: `e.kind()`. 3/4: the same comparison in
    // both operand orders, which is how the two sides of an `assert_eq!` read.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .path = .{ .def = unexpected_eof, .generic_args = &.{} } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = kind_ident,
            .args = &.{},
        } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 2,
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

    _ = try resolve_methods.resolveMethods(&g, &b);

    // The call survives, so neither comparison is skipped as a read of a
    // refused operand; both then survive as comparisons. An `ErrorKind` is a
    // payload-free enum the runtime compares by value, in either position.
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expect(b.exprs[3].kind == .binary);
    try std.testing.expect(b.exprs[4].kind == .binary);
}

// ── `std::io` methods on a receiver that carries its bound itself ───────────

/// Register `use <path>;` the way the ingest pass records an unresolved rooted
/// std path, so a bound spelled by its short name resolves through the import
/// the source actually wrote.
///
/// Every string is copied rather than borrowed. `CrateGraph.deinit` frees the
/// local name, the path array and every segment in it, so a literal handed
/// straight through is an `InvalidFree` at teardown — which surfaces as a
/// crash in whichever test drops the graph, not in the one that registered
/// the import.
fn addExternalUse(
    g: *graph.CrateGraph,
    a: std.mem.Allocator,
    parent: spine.EntityId,
    local_name: []const u8,
    path: []const []const u8,
) !spine.EntityId {
    const id = try addEntity(g, a, .use_, local_name, parent);
    const owned_path = try a.alloc([]const u8, path.len);
    var copied: usize = 0;
    errdefer {
        for (owned_path[0..copied]) |segment| a.free(segment);
        a.free(owned_path);
    }
    for (path) |segment| {
        owned_path[copied] = try a.dupe(u8, segment);
        copied += 1;
    }
    const owned_name = try a.dupe(u8, local_name);
    errdefer a.free(owned_name);
    try g.addUse(.{
        .id = id,
        .kind = .{ .external = .{ .path = owned_path } },
        .local_name = owned_name,
        .is_pub_export = false,
        .target = 0,
        .span = span,
    });
    return id;
}

/// Storage for one `&mut dyn Trait` receiver.
///
/// Every piece is a field written through a pointer, never a local of a
/// builder function, and that is the whole point. A `dyn_trait` is a slice of
/// bounds and each bound is a slice of path segments, so a helper that built
/// them as its own locals and returned the type would hand back a slice to a
/// stack frame that has already ended. The segment's `id` is exactly what
/// `boundPathMatches` reads to find the importing `use`, so a dangling id
/// reads back as null, the identity proof misses, and every dyn receiver
/// quietly falls back to being refused — which looks exactly like a broken
/// production rule rather than a broken fixture.
const DynReceiver = struct {
    segment: types.PathSegment,
    bounds: [1]types.Bound,
    ref: types.Ref,

    fn init(self: *DynReceiver, name: []const u8, use_id: ?spine.EntityId) void {
        self.segment = .{ .name = name, .id = use_id };
        self.bounds = .{.{ .path = .{ .segments = (&self.segment)[0..1] } }};
        self.ref = .{ .mut = true, .pointee = .{ .dyn_trait = self.bounds[0..] } };
    }

    fn ty(self: *const DynReceiver) types.Type {
        return .{ .reference = &self.ref };
    }
};

test "a dyn std io receiver resolves the io method its own bound names" {
    // `use std::io::{Read, Write}; fn read_byte(input: &mut dyn Read)` is the
    // shape dyn-io/src/lib.rs:1-9 is written in, and it is the one leb128's
    // `pub fn unsigned<R>(r: &mut R) where R: ?Sized + io::Read` reduces to
    // once its own `R` is substituted. The receiver names its trait itself, so
    // there is no method entity to read the bound from and no type parameter to
    // look it up under: the object type's own bounds ARE the declaration, and
    // `boundPathMatches` resolves the short `Read` through the very
    // `use std::io::Read` the source wrote.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const read_use = try addExternalUse(&g, a, root, "Read", &.{ "std", "io", "Read" });
    const write_use = try addExternalUse(&g, a, root, "Write", &.{ "std", "io", "Write" });

    const read_byte = try addEntity(&g, a, .fn_, "read_byte", root);
    const input = try addEntity(&g, a, .field, "input", read_byte);
    const read_exact_ident = try addEntity(&g, a, .fn_, "read_exact", root);
    const write_byte = try addEntity(&g, a, .fn_, "write_byte", root);
    const output = try addEntity(&g, a, .field, "output", write_byte);
    const write_all_ident = try addEntity(&g, a, .fn_, "write_all", root);

    var read_dyn: DynReceiver = undefined;
    read_dyn.init("Read", read_use);
    var write_dyn: DynReceiver = undefined;
    write_dyn.init("Write", write_use);
    var types_store = [_]types.Type{ read_dyn.ty(), write_dyn.ty() };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = input, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .mutable,
            .method = read_exact_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 1, .kind = .{ .path = .{ .def = output, .generic_args = &.{} } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .mutable,
            .method = write_all_ident,
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

    _ = try resolve_methods.resolveMethods(&g, &b);

    // Both calls survive as calls: `read_exact` on a `dyn Read` and `write_all`
    // on a `dyn Write` are the two the runtime owns end to end, and neither one
    // is the other's — a `Read` receiver has no `Write` bound, so the proof
    // that admits one is the same proof that keeps the other out. The node
    // itself is the observation, not a tally: `resolveMethods` replaces a call
    // it refuses with an `.unsupported` marker, so a surviving `.method_call`
    // already says the call was admitted.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expect(b.exprs[3].kind == .method_call);
}

test "a dyn receiver bound by a crate's own trait is not the std io reader" {
    // Same shape as above with `use std::io::Read;` removed. A crate that
    // declares its own `Read` writes `dyn Read` and means ITS trait, so nothing
    // about the receiver names `std::io::Read` and the call has to stay refused.
    // Without this the bound would be decided from the name alone, and every
    // crate could claim the runtime's io reader by declaring a homonym.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .trait_, "Read", root);
    const read_byte = try addEntity(&g, a, .fn_, "read_byte", root);
    const input = try addEntity(&g, a, .field, "input", read_byte);
    const read_exact_ident = try addEntity(&g, a, .fn_, "read_exact", root);

    // The crate's own `Read`: the same shape, but with no `use` to resolve the
    // name through, so `boundPathMatches` finds nothing and the call is refused.
    var crate_read_dyn: DynReceiver = undefined;
    crate_read_dyn.init("Read", null);
    var types_store = [_]types.Type{crate_read_dyn.ty()};
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = input, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .mutable,
            .method = read_exact_ident,
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

    _ = try resolve_methods.resolveMethods(&g, &b);
    try expectUnsupportedReason(&b.exprs[1], "method dispatch unavailable");
}

// ── Ownership: `ToOwned`, the growing methods, and UTF-8 errors ─────────────

test "each std owner answers only the methods its own runtime type has" {
    const str_ref: types.Type = .{ .reference = &.{ .mut = false, .pointee = types.str_type } };
    const u8_slice: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    const string: types.Type = .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } };
    const bytes_vec: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const str_cow: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{types.str_type},
    } };
    const from_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "FromUtf8Error" },
    } };

    // `&str` is the runtime's `[]const u8`, so `as_bytes` hands back the very
    // bytes it already borrows and `to_owned` is the copy that ends the borrow.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .str_as_bytes),
        resolve_methods.lookupStdMethod(str_ref, "as_bytes"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .str_to_owned),
        resolve_methods.lookupStdMethod(str_ref, "to_owned"),
    );
    // A borrowed slice's `Owned` is a `Vec<T>` — a different owner from the
    // `String` a `str` produces, which is why the two are separate answers.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .slice_to_owned),
        resolve_methods.lookupStdMethod(u8_slice, "to_owned"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .string_push_str),
        resolve_methods.lookupStdMethod(string, "push_str"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .string_extend),
        resolve_methods.lookupStdMethod(string, "extend"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .vec_push),
        resolve_methods.lookupStdMethod(bytes_vec, "push"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .vec_extend),
        resolve_methods.lookupStdMethod(bytes_vec, "extend"),
    );

    // A `Vec` counts the elements it owns, and the runtime holds those in the
    // very storage the slice length already reads — so it is that length, over
    // that storage, and not a second operation with a second answer.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .slice_len),
        resolve_methods.lookupStdMethod(bytes_vec, "len"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .cow_as_bytes),
        resolve_methods.lookupStdMethod(str_cow, "as_bytes"),
    );
    // `into_owned` is the CONSUMING half and yields the owned payload.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .cow_to_owned),
        resolve_methods.lookupStdMethod(str_cow, "into_owned"),
    );
    // `to_owned` is not that. A `Cow` is `Clone`, so the blanket
    // `impl<T: Clone> ToOwned for T { type Owned = T }` applies and the result is
    // a CLONE of the same `Cow`, taken through `&self` — the receiver is still
    // usable afterwards. Answering it like `into_owned` would consume a borrow.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .clone),
        resolve_methods.lookupStdMethod(str_cow, "to_owned"),
    );
    // The same blanket gives `[T; N]` back unchanged, where only the UNSIZED
    // slice is specialized to a `Vec<T>`. So an array's `to_owned` is a clone
    // and a slice's is an allocation — two receivers of the same shape and two
    // different Rust owners.
    const byte_array: types.Type = .{ .array = &.{
        .elem = .{ .prim = .u8 },
        .len = .{ .literal = 4 },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .clone),
        resolve_methods.lookupStdMethod(byte_array, "to_owned"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .from_utf8_error_utf8_error),
        resolve_methods.lookupStdMethod(from_utf8_error, "utf8_error"),
    );
}
test "the std methods the corpus calls resolve to the backend's own arms" {
    // `test/crates` calls these against exactly these receivers, so each one
    // is pinned here: the table is the vocabulary the corpus refusals are
    // reported in, and an unlisted corpus method is a gap to report, not a
    // name for speculative recognition.
    //
    // differential: `text.len()` over an owned `String`.
    const string: types.Type = .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .string_len),
        resolve_methods.lookupStdMethod(string, "len"),
    );
    // differential, allocator-failure-ownership, cow-handoff, compat:
    // `marked.push('!')` grows one code point.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .string_push),
        resolve_methods.lookupStdMethod(string, "push"),
    );
    // differential: `rounds.push_str(&round)` borrows into an owned string.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .string_push_str),
        resolve_methods.lookupStdMethod(string, "push_str"),
    );
    // differential: `String::from_utf8(..).map_err(|_| 1u8)` remaps the error
    // arm on the external-nominal Result `string_from_utf8` produces. The
    // backend's closure expansion then needs a `.result` descriptor off that
    // same node, so the dispatch this test pins is the table's half of that
    // contract — not the lowering half, which this file does not own.
    const utf8_result: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "result", "Result" },
        .args = &.{
            .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
            .{ .external_nominal = .{ .path = &.{ "alloc", "string", "FromUtf8Error" } } },
        },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .result_map_err),
        resolve_methods.lookupStdMethod(utf8_result, "map_err"),
    );
    // differential, cow-handoff: `error.utf8_error()` reads the validation
    // detail out of the conversion error.
    const from_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "FromUtf8Error" },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .from_utf8_error_utf8_error),
        resolve_methods.lookupStdMethod(from_utf8_error, "utf8_error"),
    );
    // differential: `.valid_up_to()` on the unwrapped detail.
    const detail: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "str", "Utf8Error" },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .utf8_error_valid_up_to),
        resolve_methods.lookupStdMethod(detail, "valid_up_to"),
    );
    // differential: `input.iter()` opens the slice cursor.
    const u32_slice: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u32 } } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .slice_iter),
        resolve_methods.lookupStdMethod(u32_slice, "iter"),
    );
    // differential: `input.len()` on the caller's borrowed bytes.
    const u8_slice: types.Type = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .slice_len),
        resolve_methods.lookupStdMethod(u8_slice, "len"),
    );
    // differential, cow-handoff: `values.len()` counts owned elements, and
    // `values.push(..)` grows the caller's vector.
    const string_vec: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{
            .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .slice_len),
        resolve_methods.lookupStdMethod(string_vec, "len"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .vec_push),
        resolve_methods.lookupStdMethod(string_vec, "push"),
    );
    // differential: `String::from_utf8(..).unwrap()` takes the Ok arm off the
    // same external-nominal Result `map_err` is answered on.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .result_unwrap),
        resolve_methods.lookupStdMethod(utf8_result, "unwrap"),
    );
    // compat, optional-entry fixtures: `Option::unwrap_or` and `as_ref` stay
    // on the borrowed/`None` arms the runtime models.
    const option_u32: types.Type = .{ .option = &.{ .prim = .u32 } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .option_unwrap_or),
        resolve_methods.lookupStdMethod(option_u32, "unwrap_or"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .option_as_ref),
        resolve_methods.lookupStdMethod(option_u32, "as_ref"),
    );
    // leb128 percent-encoding: fallible `Vec` growth.
    const byte_vec: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .prim = .u8 }},
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .vec_extend),
        resolve_methods.lookupStdMethod(byte_vec, "extend"),
    );
    // adler, seeded fixtures: `chunks_exact` off the caller's bytes.
    const bytes_ref: types.Type = .{ .reference = &.{ .mut = false, .pointee = u8_slice } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .slice_chunks_exact),
        resolve_methods.lookupStdMethod(bytes_ref, "chunks_exact"),
    );
}

// ── `Vec::len` ─────────────────────────────────────────────────────────────
//
//     pub fn owner_tuple_repeat(count: usize) -> usize {
//         let values: Vec<(String, u8)> = vec![(String::from("nested"), 7u8); count];
//         let mut total = values.len();
//         for entry in &values {
//             total += entry.0.len() + entry.1 as usize;
//         }
//         total
//     }
//
// `values` OWNS the wrappers rather than borrowing them, so `values.len()`
// counts the vector's own storage — which is the storage the slice length
// already reads. Naming `slice_len` is therefore what puts the call through
// the projection the backend already has, and it is what makes `total` a
// `usize` the `+=` can read rather than a value this pass cannot name.

test "a Vec len dispatches and publishes the usize an operator is written against" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const len_ident = try addEntity(&g, a, .fn_, "len", root);

    var types_store = [_]types.Type{
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
    };

    // 0 is the `Vec<u8>` receiver, 1 its `len()`, 2 the literal `2`, and 3 the
    // operator over the two.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = len_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "2",
            .value = 2,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
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

    // The call is admitted on the std dispatch rather than replaced with an
    // unsupported marker, so the node is still the call the source wrote.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);

    // `usize` is the result type, and admitting the operator over it is the
    // same claim seen from the other side: both halves read a primitive, so
    // neither is left admitting what the other refuses.
    try std.testing.expect(b.exprs[3].kind == .binary);
    try std.testing.expect(b.exprs[1].ty != null);
    // `b.types` held only the `Vec` receiver before the pass, so the published
    // id is a newly appended `usize` and not the receiver's own nominal.
    const published = b.exprs[1].ty.?;
    try std.testing.expect(published < b.types.len);
    try std.testing.expect(published != 0);
    try std.testing.expect(types.deepEqual(.{ .prim = .usize }, b.types[published]));
}

test "a crate's own Vec len wins over the std dispatch that shares its name" {
    // A receiver the graph reads as `Vec` reaches the source lookup FIRST, and
    // a crate that declares a `Vec` of its own has written a `len` for it.
    // Both answers are available here on purpose — the std table would match
    // this receiver on its own — so the fixture is the only shape in which
    // precedence can be observed at all. Binding it to the crate's `fn` is the
    // contract: naming `slice_len` here would dispatch a call the source never
    // wrote, over a type this crate defined.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Vec", root);
    const crate_vec_impl = try addEntity(&g, a, .impl_, "Vec", root);
    const crate_vec_len = try addEntity(&g, a, .fn_, "len", crate_vec_impl);
    // The name the call site spells, before any lookup has had its say.
    const len_ident = try addEntity(&g, a, .fn_, "len", root);

    var types_store = [_]types.Type{
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
    };

    // 0: the receiver, and 1: its `len()`.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = len_ident,
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

    try std.testing.expectEqual(@as(usize, 1), stats.inherent_resolved);
    // Nothing reached the std table, so the runtime length was never the answer
    // this call was given and no runtime `usize` was published for it.
    try std.testing.expectEqual(@as(usize, 0), stats.std_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expectEqual(crate_vec_len, b.exprs[1].kind.method_call.method);
    try std.testing.expect(b.exprs[1].ty == null);
}

test "a core str Utf8Error answers valid_up_to and a crate's own one does not" {
    // `String::from_utf8` reports failure as `FromUtf8Error`, and
    // `utf8_error` on it yields the very `core::str::Utf8Error` a direct
    // `str::from_utf8` produces. Reading `valid_up_to` off that detail is a
    // separate receiver, so it needs its own answer in the table.
    const std_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "str", "Utf8Error" },
    } };
    // `std::str` re-exports the same type, so the root the source spelled does
    // not change which one this is.
    const std_rooted_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "std", "str", "Utf8Error" },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .utf8_error_valid_up_to),
        resolve_methods.lookupStdMethod(std_utf8_error, "valid_up_to"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .utf8_error_valid_up_to),
        resolve_methods.lookupStdMethod(std_rooted_utf8_error, "valid_up_to"),
    );
    // `Utf8Error` is a name a crate may declare for something else, so the
    // leaf alone must not claim the method — the same rule every other std
    // owner in this table is matched under.
    const crate_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "my_text", "str", "Utf8Error" },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(crate_utf8_error, "valid_up_to"),
    );
    // A `Utf8Error<T>` names nothing std declares, so it is not this either.
    const payload_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "str", "Utf8Error" },
        .args = &.{.{ .prim = .u8 }},
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(payload_utf8_error, "valid_up_to"),
    );
    // `FromUtf8Error` holds the bytes and the detail together; `valid_up_to`
    // is the DETAIL's method, not the wrapper's.
    const from_utf8_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "string", "FromUtf8Error" },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(from_utf8_error, "valid_up_to"),
    );
}

test "the ownership methods are decided by the full std path, never the leaf" {
    // Three homonyms, each of which a real crate can declare. `lookupStdMethod`
    // matches `alloc::string::String` in full — root, module, and leaf — so a
    // crate's own `String`, `Vec`, or `FromUtf8Error` reaches none of the arms
    // above and keeps whatever reason its own dispatch earns. This is the same
    // rule `isExactStdIoType` already states for `std::io`.
    const crate_string: types.Type = .{ .external_nominal = .{
        .path = &.{ "my_text", "string", "String" },
    } };
    const crate_vec: types.Type = .{ .external_nominal = .{
        .path = &.{ "my_text", "vec", "Vec" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const crate_error: types.Type = .{ .external_nominal = .{
        .path = &.{ "my_text", "string", "FromUtf8Error" },
    } };

    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(crate_string, "push_str"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(crate_string, "to_owned"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(crate_vec, "push"),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(crate_error, "utf8_error"),
    );
    // A `Cow` with no payload names nothing the runtime can build, so it is not
    // the `Cow<str>` the arms above answer for.
    const payloadless_cow: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdMethod(payloadless_cow, "as_bytes"),
    );
}

// ── `.into()` ──────────────────────────────────────────────────────────────

test "an into conversion is admitted only for a pair std actually declares" {
    const str_ref: types.Type = .{ .reference = &.{ .mut = false, .pointee = types.str_type } };
    const slice_ref: types.Type = .{ .reference = &.{
        .mut = false,
        .pointee = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
    } };
    const string: types.Type = .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } };
    const bytes_vec: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const str_cow: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{types.str_type},
    } };
    const bytes_cow: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } }},
    } };

    // The borrowed half is the identity tagged `Borrowed`, and the owned half
    // moves the receiver's own owner across tagged `Owned`. Both are one
    // answer per side: which of them applies is decided by the RECEIVER, never
    // by which one reads more naturally at the call site.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .into_cow_borrowed),
        resolve_methods.lookupStdIntoMethod(str_ref, str_cow),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .into_cow_borrowed),
        resolve_methods.lookupStdIntoMethod(slice_ref, bytes_cow),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .into_cow_owned),
        resolve_methods.lookupStdIntoMethod(string, str_cow),
    );
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .into_cow_owned),
        resolve_methods.lookupStdIntoMethod(bytes_vec, bytes_cow),
    );

    // A `&mut B` borrows exactly the bytes a `&B` does — mutability is not part
    // of what the `Cow` holds — so it is the same borrowed conversion.
    const mutable_str_ref: types.Type = .{ .reference = &.{ .mut = true, .pointee = types.str_type } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .into_cow_borrowed),
        resolve_methods.lookupStdIntoMethod(mutable_str_ref, str_cow),
    );

    // The element type is part of the payload, not decoration: a `Cow<[u16]>`
    // is owned by a `Vec<u16>`, so the owned half reads the source's element
    // and not merely that it is a vector.
    const u16_vec: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .prim = .u16 }},
    } };
    const u16_cow: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u16 } } }},
    } };
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, .into_cow_owned),
        resolve_methods.lookupStdIntoMethod(u16_vec, u16_cow),
    );

    // `&str` into a `String` is a real, valid conversion — and deliberately
    // not one this predicate claims. It answers for the `Cow` ownership
    // conversions and nothing else, because those are the pairs whose result
    // changes who owns the bytes; a `String` is reached by `ToOwned`, not by
    // an ownership tag. Claiming it here would answer a different question
    // with the same rule.
    try std.testing.expectEqual(
        @as(?resolve_methods.StdMethod, null),
        resolve_methods.lookupStdIntoMethod(str_ref, string),
    );
}

test "a crate From impl is what its own into call resolves to" {
    // `impl<'a> From<PercentDecode<'a>> for Cow<'a, [u8]>` is what makes
    // `percent_decode(..).into()` a `Cow<[u8]>` in percent-encoding, and the
    // receiver's nominal names no std trait at all — the conversion lives in
    // an impl block this crate wrote, so the callee is rebound to that impl's
    // own `from`.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    // `impl From<..> for Cow` names the trait by the short name the module
    // imports, so the fixture has to import it: `userFromImplMethod` proves the
    // trait by its full `core::convert::From` path resolved through the scope's
    // use declarations, which is the same proof every other trait identity in
    // the pipeline makes — and the reason a crate's OWN `trait From<T>` cannot
    // answer this call.
    const from_use = try addExternalUse(&g, a, root, "From", &.{ "core", "convert", "From" });
    _ = try addEntity(&g, a, .struct_, "PercentDecode", root);
    const decode = try addEntity(&g, a, .fn_, "decode", root);
    const from_impl = try addEntity(&g, a, .impl_, "From<PercentDecode> for Cow", root);
    const from_fn = try addEntity(&g, a, .fn_, "from", from_impl);
    const into_ident = try addEntity(&g, a, .fn_, "into", root);

    const decode_ty: types.Type = .{ .path = .{ .segments = &.{.{ .name = "PercentDecode", .id = null }} } };
    const cow_ty: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } }},
    } };

    var bodies_store = [_]bodies.BodyKind{.none} ** 7;
    var types_store = [_]types.Type{ decode_ty, cow_ty };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = decode, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = into_ident,
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
    bodies_store[from_impl] = .{ .impl_ = .{
        .self_ty = cow_ty,
        .trait_path = .{ .segments = &.{.{ .name = "From", .id = from_use }} },
        .trait_args = &.{decode_ty},
        .assoc_items = &.{from_fn},
    } };

    _ = try resolve_methods.resolveMethods(&g, &b);

    // The call survives AND is retargeted: `into` is the spelling, `from` is
    // the implementation Rust picks for it, and a callee left as `into` would
    // emit a call to a method no impl provides. The rebound callee is the whole
    // observation — a tally would only restate that one call was counted.
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expectEqual(@as(spine.EntityId, from_fn), b.exprs[1].kind.method_call.method);
}

test "an into with no target this pass recovered stays refused" {
    // The same call without the type inference that settled its target. Rust
    // would still resolve it, but only from a context this frontend cannot
    // see; guessing the nearest std conversion here would emit a `Cow` the
    // source never asked for, so the call keeps the reason it earned.
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const text = try addEntity(&g, a, .fn_, "text", root);
    const into_ident = try addEntity(&g, a, .fn_, "into", root);

    var types_store = [_]types.Type{
        .{ .reference = &.{ .mut = false, .pointee = types.str_type } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = text, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = into_ident,
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

    _ = try resolve_methods.resolveMethods(&g, &b);
    try expectUnsupportedReason(&b.exprs[1], "method dispatch unavailable");
}

// ── The allocator effect a `write_all` carries ─────────────────────────────

test "only a std Write write_all is an allocating call" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const read_use = try addExternalUse(&g, a, root, "Read", &.{ "std", "io", "Read" });
    const write_use = try addExternalUse(&g, a, root, "Write", &.{ "std", "io", "Write" });
    _ = try addEntity(&g, a, .struct_, "Sink", root);

    const read_byte = try addEntity(&g, a, .fn_, "read_byte", root);
    const input = try addEntity(&g, a, .field, "input", read_byte);
    const write_byte = try addEntity(&g, a, .fn_, "write_byte", root);
    const output = try addEntity(&g, a, .field, "output", write_byte);
    const drain = try addEntity(&g, a, .fn_, "drain", root);
    const sink = try addEntity(&g, a, .field, "sink", drain);

    const read_exact_ident = try addEntity(&g, a, .fn_, "read_exact", root);
    const write_all_ident = try addEntity(&g, a, .fn_, "write_all", root);

    // 0: a `&mut dyn Read`. 1: a `&mut dyn Write`. 2: a crate-local `Sink`
    // whose OWN `write_all` shadows the std name.
    var read_dyn: DynReceiver = undefined;
    read_dyn.init("Read", read_use);
    var write_dyn: DynReceiver = undefined;
    write_dyn.init("Write", write_use);
    var types_store = [_]types.Type{
        read_dyn.ty(),
        write_dyn.ty(),
        .{ .path = .{ .segments = &.{.{ .name = "Sink", .id = null }} } },
    };
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = input, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .mutable,
            .method = read_exact_ident,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 1, .kind = .{ .path = .{ .def = output, .generic_args = &.{} } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .mutable,
            .method = write_all_ident,
            .args = &.{},
        } } },
        .{ .id = 4, .span = span, .ty = 2, .kind = .{ .path = .{ .def = sink, .generic_args = &.{} } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .value,
            .method = write_all_ident,
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

    // Only the `std::io::Write` one. `read_exact` fills a buffer the caller
    // already owns, so marking its caller allocating would invent an effect
    // it does not have; and the crate's own `Sink::write_all` is not the std
    // intrinsic, so the runtime's `gpa`-taking lowering is not what runs.
    try std.testing.expect(!resolve_methods.stdIoWriteMethodAllocates(&g, &b, 1));
    try std.testing.expect(resolve_methods.stdIoWriteMethodAllocates(&g, &b, 3));
    try std.testing.expect(!resolve_methods.stdIoWriteMethodAllocates(&g, &b, 5));
    // A node that is not a method call at all cannot name the method.
    try std.testing.expect(!resolve_methods.stdIoWriteMethodAllocates(&g, &b, 0));
    try std.testing.expect(!resolve_methods.stdIoWriteMethodAllocates(&g, &b, 99));
}

// ── A raw pointer compares by ADDRESS, not by its pointee ──────────────────
//
// `seahash/src/buffer.rs:47` writes `while end_ptr > ptr` and
// `syn/src/buffer.rs:137` writes `if ptr == scope`. Both are core's
// `impl PartialOrd for *const T` / `impl PartialEq for *const T`, which
// compare the two POINTERS. Those impls live in core, so they are not in the
// translated crate's entity graph and no `lookupTraitMethod` below can find
// them: the operator has to be decided from the operands' own types. What it
// must NOT be decided from is the POINTEES — `*const Entry < *const Entry` is
// not `Entry < Entry`, and `*const Entry + 1` is not `Entry + Entry`.

test "a raw pointer pair comparison is a typed operator" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const less = try addEntity(&g, a, .fn_, "less", root);
    const left = try addEntity(&g, a, .field, "a", less);
    const right = try addEntity(&g, a, .field, "b", less);

    // `pub fn less(a: *const u8, b: *const u8) -> bool { a < b }`: both
    // operands are named by the signature they are declared in, so neither
    // carries a TypeId of its own. Bodies are indexed by EntityId, so the
    // signature lands on its own function.
    const byte_pointer: types.Type = .{ .raw_ptr = &.{
        .mut = false,
        .pointee = .{ .prim = .u8 },
    } };
    var bodies_store = [_]bodies.BodyKind{bodies.BodyKind.none} ** 4;
    bodies_store[less] = .{ .fn_ = .{
        .params = &.{
            .{ .name = "a", .ty = byte_pointer, .span = span },
            .{ .name = "b", .ty = byte_pointer, .span = span },
        },
        .ret = .{ .prim = .bool },
        .body = 0,
    } };

    const types_store = [_]types.Type{byte_pointer};

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .path = .{ .def = left, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .path = .{ .def = right, .generic_args = &.{} } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .lt,
            .overflow = .checked,
            .lhs = 0,
            .rhs = 1,
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

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
}

test "a raw pointer comparison is not the pointee's operator" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    _ = try addEntity(&g, a, .struct_, "Entry", root);
    _ = try addEntity(&g, a, .trait_, "PartialOrd", root);
    const ord_impl = try addEntity(&g, a, .impl_, "PartialOrd for Entry", root);
    _ = try addEntity(&g, a, .fn_, "lt", ord_impl);
    const entry_pointer: types.Type = .{ .raw_ptr = &.{
        .mut = false,
        .pointee = .{ .path = .{ .segments = &.{.{ .name = "Entry", .id = null }} } },
    } };
    const types_store = [_]types.Type{
        entry_pointer,
        entry_pointer,
    };

    // Comparing Entry pointers must not call Entry's PartialOrd implementation.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .lt,
            .overflow = .checked,
            .lhs = 0,
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

    // The comparison stays the binary node it was written as: no trait method
    // was bound for it, so `trait_resolved` is the proof that `Entry`'s own
    // `lt` was never picked up as the operator's implementation.
    try std.testing.expectEqual(@as(usize, 0), stats.trait_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
}

test "a raw pointer comparison reads through a borrow, an alias, and a qualifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    const root = try addEntity(&g, a, .module, "", null);
    const byte_ptr = try addEntity(&g, a, .type_alias, "BytePtr", root);

    // `type BytePtr = *const u8;` is how a crate spells the pointer a
    // signature or a field carries, and the CST layer records the ALIAS PATH
    // wherever it is spelled — so `b >= b` over two `BytePtr`s is the same
    // pointer comparison with one more layer in front of it.
    const byte_pointer: types.Type = .{ .raw_ptr = &.{
        .mut = false,
        .pointee = .{ .prim = .u8 },
    } };
    const mutable_byte_pointer: types.Type = .{ .raw_ptr = &.{
        .mut = true,
        .pointee = .{ .prim = .u8 },
    } };
    var bodies_store = [_]bodies.BodyKind{ .none, .{ .type_alias = .{
        .target = byte_pointer,
    } } };

    // Direct mixed-mutability pointers coerce to a common pointer type.
    // Borrowed pointer values retain their source qualifier.
    const types_store = [_]types.Type{
        mutable_byte_pointer,
        .{ .path = .{ .segments = &.{.{ .name = "BytePtr", .id = byte_ptr }} } },
        .{ .reference = &.{ .mut = false, .pointee = byte_pointer } },
        .{ .reference = &.{ .mut = false, .pointee = byte_pointer } },
    };

    // Alias ordering, direct mixed qualifiers, and borrowed pointer ordering.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = 2, .kind = .{ .unit = {} } },
        .{ .id = 3, .span = span, .ty = 3, .kind = .{ .unit = {} } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .ge,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 1,
        } } },
        .{ .id = 5, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .le,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 0,
        } } },
        .{ .id = 6, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .lt,
            .overflow = .checked,
            .lhs = 2,
            .rhs = 3,
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

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    for ([_]exprs.NodeId{ 4, 5, 6 }) |node| {
        try std.testing.expect(b.exprs[node].kind == .binary);
    }
}

test "a raw pointer to a slice stays refused for an ordering comparison" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    _ = try addEntity(&g, a, .module, "", null);

    // `*const [u8]` is a pointer to a SLICE, which the emitter writes as a Zig
    // slice rather than as a pointer — a two-word descriptor with no `<` in
    // Zig. Admitting the comparison would admit an operator the emitter
    // cannot spell, so the boundary is the POINTEE, and a fat pointer stays
    // a refusal rather than a comparison of the wrong thing.
    const slice_pointer: types.Type = .{ .raw_ptr = &.{
        .mut = false,
        .pointee = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
    } };
    const types_store = [_]types.Type{ slice_pointer, slice_pointer };

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .lt,
            .overflow = .checked,
            .lhs = 0,
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

    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    try expectUnsupportedReason(&b.exprs[2], "operator requires primitive operands");
}

test "a tuple comparison is the runtime walk the emitter already spells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    _ = try addEntity(&g, a, .module, "", null);

    // `(Option<I>, usize)` is the tuple `atoi`'s own `#[cfg(test)]` module
    // compares: `assert_eq!((Some(255), 3), u8::from_radix_10_checked(b"255"))`.
    // The backend lowers a tuple to an anonymous `struct { ?u8, usize }` and
    // routes every non-primitive operand through `r2z.ops.equal`, which
    // compares a struct with `std.meta.eql`. Nothing about the operator has to
    // change, so it stays a plain binary node over two operands of the tuple's
    // own type.
    const digit: types.Type = .{ .prim = .u8 };
    const parsed: types.Type = .{ .tuple = &.{
        .{ .option = &digit },
        .{ .prim = .usize },
    } };
    const types_store = [_]types.Type{ parsed, parsed };

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
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

    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_operators);
    try std.testing.expect(b.exprs[2].kind == .binary);
}

test "a tuple carrying a value the runtime cannot compare stays refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    _ = try addEntity(&g, a, .module, "", null);

    // The tuple arm is an element-wise rule, and a trait object is the element
    // the walk cannot reach: it has no value to compare and no tag to read, so
    // a tuple that carries one stays a refusal rather than a comparison of
    // something the runtime never walks.
    const parsed: types.Type = .{ .tuple = &.{
        .{ .prim = .u8 },
        .{ .dyn_trait = &.{} },
    } };
    const types_store = [_]types.Type{ parsed, parsed };

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
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

    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    try expectUnsupportedReason(&b.exprs[2], "operator requires primitive operands");
}

test "a Cow equality stays refused because the runtime compares it by tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    _ = try addEntity(&g, a, .module, "", null);

    // `Cow<'a, str>` is one Rust type and TWO runtime shapes: it lowers to
    // `r2z.alloc.CowStr`, a tagged union of a borrowed slice and an owned
    // string. Rust compares it BY CONTENT — `Cow::Borrowed(x)` equals
    // `Cow::Owned(x.to_owned())` — while `r2z.ops.equal` reaches a union
    // through `equalUnion`, which compares the TAG first and only reads the
    // active payload when the two agree. Admitting the operator would emit a
    // comparison that answers `false` where Rust answers `true`, and unlike
    // the `String` against `&str` pair above there is no second TYPE here for
    // the cross-form branch to meet: both arms are the same nominal, so the
    // walk has nothing to descend into. Correcting it needs a runtime
    // comparison that reads `CowStr.as_ref()` on both sides, which is
    // r2z-core work this pass cannot stand in for.
    //
    // So the refusal stays, and it stays a refusal rather than a comparison
    // that is silently wrong on the arm this crate is built to exercise.
    const cow: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{types.str_type},
    } };
    const types_store = [_]types.Type{ cow, cow };

    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 0,
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

    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_operators);
    try expectUnsupportedReason(&b.exprs[2], "operator requires primitive operands");
}

test "itoa sealed Integer write resolves through the declared supertrait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const sealed = try addEntity(&g, a, .module, "private", root);
    const inner = try addEntity(&g, a, .trait_, "Sealed", sealed);
    const outer = try addEntity(&g, a, .trait_, "Integer", root);
    const format = try addEntity(&g, a, .fn_, "format", root);
    const value = try addEntity(&g, a, .field, "value", format);
    const write = try addEntity(&g, a, .method_ref, "write", format);
    const generic = [_]types.GenericParam{.{ .type_ = .{ .name = "I", .bounds = &.{
        .{ .path = .{ .segments = &.{.{ .name = "Integer", .id = outer }} } },
    } } }};
    const inherited = [_]types.WhereClause{.{
        .self_ty = .{ .segments = &.{.{ .name = "Self", .id = null }} },
        .bounds = &.{.{ .path = .{ .segments = &.{
            .{ .name = "private", .id = sealed }, .{ .name = "Sealed", .id = inner },
        } } }},
    }};
    var body_store = [_]bodies.BodyKind{.none} ** 8;
    const text: types.Ref = .{ .mut = false, .pointee = types.str_type };
    body_store[inner] = .{ .trait_ = .{ .name = "Sealed", .methods = &.{
        .{ .name = "write", .ret = .{ .reference = &text }, .receiver = .owned },
    } } };
    body_store[outer] = .{ .trait_ = .{
        .name = "Integer",
        .generics = .{ .params = &.{}, .where_clauses = &inherited },
    } };
    body_store[format] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .reference = &text },
        .body = 1,
        .generics = .{ .params = &generic, .where_clauses = &.{} },
    } };
    const type_store = [_]types.Type{.{ .path = .{ .segments = &.{.{ .name = "I", .id = null }} } }};
    // itoa/src/lib.rs:96-99, the actual Buffer::format call.
    const source_span: spine.Span = .{ .start_line = 96, .start_col = 9, .end_line = 99, .end_col = 11 };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = source_span, .ty = 0, .kind = .{ .path = .{ .def = value, .generic_args = &.{} } } },
        .{ .id = 1, .span = source_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = write,
            .args = &.{},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const proof = resolve_methods.boundTraitMethod(&g, &b, format, type_store[0], "write").?;
    try std.testing.expectEqual(inner, proof.trait_id);
    try std.testing.expect(types.deepEqual(.{ .reference = &text }, proof.signature.ret));
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.trait_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try std.testing.expectEqual(inner, g.symbol_table.get(write).?.parent.?);
    const repeated = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), repeated.trait_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);
}

test "atoi checked arithmetic requires its exact numeric trait bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const parse = try addEntity(&g, a, .fn_, "from_radix_10_checked", root);
    const number = try addEntity(&g, a, .field, "number", parse);
    const checked = try addEntity(&g, a, .method_ref, "checked_mul", parse);
    const unbounded = try addEntity(&g, a, .fn_, "unbounded", root);
    const other = try addEntity(&g, a, .field, "number", unbounded);
    const rejected = try addEntity(&g, a, .method_ref, "checked_mul", unbounded);
    const bounds = [_]types.GenericParam{.{ .type_ = .{ .name = "I", .bounds = &.{
        .{ .path = .{ .segments = &.{
            .{ .name = "num_traits", .id = null }, .{ .name = "ops", .id = null },
            .{ .name = "checked", .id = null },    .{ .name = "CheckedMul", .id = null },
        } } },
    } } }};
    var body_store = [_]bodies.BodyKind{.none} ** 8;
    body_store[parse] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 1,
        .generics = .{ .params = &bounds, .where_clauses = &.{} },
    } };
    const type_store = [_]types.Type{.{ .path = .{ .segments = &.{.{ .name = "I", .id = null }} } }};
    // atoi/src/lib.rs:515, inside number.and_then(|n| ...).
    const source_span: spine.Span = .{ .start_line = 515, .start_col = 46, .end_line = 515, .end_col = 68 };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = source_span, .ty = 0, .kind = .{ .path = .{ .def = number, .generic_args = &.{} } } },
        .{ .id = 1, .span = source_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = checked,
            .args = &.{0},
        } } },
        .{ .id = 2, .span = source_span, .ty = 0, .kind = .{ .path = .{ .def = other, .generic_args = &.{} } } },
        .{ .id = 3, .span = source_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 2,
            .receiver_mode = .shared,
            .method = rejected,
            .args = &.{2},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expect(b.exprs[1].kind == .method_call);
    try expectUnsupported(&b.exprs[3]);
}

test "atoi first borrows a slice element and does not claim a str method" {
    const bytes: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .slice = &bytes } };
    try std.testing.expectEqual(resolve_methods.StdMethod.slice_first, resolve_methods.lookupStdMethod(.{ .reference = &borrow }, "first").?);
    try std.testing.expect(resolve_methods.lookupStdMethod(types.str_type, "first") == null);
    try std.testing.expect(resolve_methods.lookupStdMethod(.{ .prim = .u8 }, "first") == null);
}

test "SeaHasher primitive writes retain source trait override dispatch" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const hasher = try addEntity(&g, a, .struct_, "SeaHasher", root);
    const implementation = try addEntity(&g, a, .impl_, "Hasher for SeaHasher", root);
    const override = try addEntity(&g, a, .fn_, "write_u16", implementation);
    const method = try addEntity(&g, a, .method_ref, "write_u16", root);
    const borrow: types.Ref = .{ .mut = true, .pointee = .{
        .path = .{ .segments = &.{.{ .name = "SeaHasher", .id = hasher }} },
    } };
    const type_store = [_]types.Type{ .{ .reference = &borrow }, .{ .prim = .u16 } };
    // stream.rs:190-191 explicitly encodes LE; replacing it with Hasher's
    // native-endian default changes hashes on a big-endian consumer target.
    const source_span: spine.Span = .{ .start_line = 190, .start_col = 5, .end_line = 192, .end_col = 6 };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = source_span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = source_span, .ty = 1, .kind = .{ .literal = .{ .int = .{ .text = "0x1234", .value = 0x1234, .base = .hex, .ty_suffix = "u16" } } } },
        .{ .id = 2, .span = source_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .mutable,
            .method = method,
            .args = &.{1},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &.{}, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.trait_resolved);
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expectEqual(override, b.exprs[2].kind.method_call.method);
    try std.testing.expectEqual(exprs.ReceiverMode.mutable, b.exprs[2].kind.method_call.receiver_mode);
}

test "generic Hasher primitive write remains deferred rather than taking a native default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const function = try addEntity(&g, a, .fn_, "write_number", root);
    const receiver = try addEntity(&g, a, .field, "hasher", function);
    const method = try addEntity(&g, a, .method_ref, "write_u16", function);
    const parameters = [_]types.GenericParam{.{ .type_ = .{ .name = "H", .bounds = &.{
        .{ .path = .{ .segments = &.{
            .{ .name = "core", .id = null },   .{ .name = "hash", .id = null },
            .{ .name = "Hasher", .id = null },
        } } },
    } } }};
    var body_store = [_]bodies.BodyKind{.none} ** 5;
    body_store[function] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 2,
        .generics = .{ .params = &parameters, .where_clauses = &.{} },
    } };
    const type_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "H", .id = null }} } },
        .{ .prim = .u16 },
    };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = receiver, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .literal = .{ .int = .{
            .text = "0x1234",
            .value = 0x1234,
            .base = .hex,
            .ty_suffix = "u16",
        } } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .mutable,
            .method = method,
            .args = &.{1},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expectEqual(exprs.ReceiverMode.mutable, b.exprs[2].kind.method_call.receiver_mode);
    // The backend selects H's translated override at instantiation; this
    // frontend must not turn the call into hash_write_primitive first.
    try std.testing.expectEqual(function, g.symbol_table.get(method).?.parent.?);
}

test "Adler BufRead calls retain mutable dispatch without allocating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const function = try addEntity(&g, a, .fn_, "adler32", root);
    const reader = try addEntity(&g, a, .field, "reader", function);
    const fill = try addEntity(&g, a, .method_ref, "fill_buf", function);
    const consume = try addEntity(&g, a, .method_ref, "consume", function);
    const parameters = [_]types.GenericParam{.{ .type_ = .{ .name = "R", .bounds = &.{
        .{ .path = .{ .segments = &.{
            .{ .name = "std", .id = null },     .{ .name = "io", .id = null },
            .{ .name = "BufRead", .id = null },
        } } },
    } } }};
    var body_store = [_]bodies.BodyKind{.none} ** 5;
    body_store[function] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 3,
        .generics = .{ .params = &parameters, .where_clauses = &.{} },
    } };
    const type_store = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "R", .id = null }} } },
        .{ .prim = .usize },
    };
    const fill_span: spine.Span = .{ .start_line = 210, .start_col = 23, .end_line = 210, .end_col = 40 };
    const consume_span: spine.Span = .{ .start_line = 218, .start_col = 9, .end_line = 218, .end_col = 28 };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = fill_span, .ty = 0, .kind = .{ .path = .{ .def = reader, .generic_args = &.{} } } },
        .{ .id = 1, .span = consume_span, .ty = 1, .kind = .{ .literal = .{ .int = .{
            .text = "4",
            .value = 4,
            .base = .dec,
            .ty_suffix = "usize",
        } } } },
        .{ .id = 2, .span = fill_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = fill,
            .args = &.{},
        } } },
        .{ .id = 3, .span = consume_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = consume,
            .args = &.{1},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 2), stats.std_resolved);
    for ([_]exprs.NodeId{ 2, 3 }) |node| {
        try std.testing.expect(b.exprs[node].kind == .method_call);
        try std.testing.expectEqual(exprs.ReceiverMode.mutable, b.exprs[node].kind.method_call.receiver_mode);
        try std.testing.expect(!resolve_methods.stdIoWriteMethodAllocates(&g, &b, node));
    }
}

test "late inferred slice and pointer receivers use the admitted ownership and copy cores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const copy = try addEntity(&g, a, .method_ref, "copy_to_nonoverlapping", root);
    const to_vec = try addEntity(&g, a, .method_ref, "to_vec", root);
    const pointer: types.RawPtr = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const pointer_borrow: types.Ref = .{ .mut = false, .pointee = .{ .raw_ptr = &pointer } };
    const destination: types.RawPtr = .{ .mut = true, .pointee = .{ .prim = .u8 } };
    const bytes: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const type_store = [_]types.Type{
        .{ .reference = &pointer_borrow }, .{ .raw_ptr = &destination },
        .{ .prim = .usize },               .{ .slice = &bytes },
    };
    const copy_span: spine.Span = .{ .start_line = 65, .start_col = 9, .end_line = 65, .end_col = 66 };
    const vector_span: spine.Span = .{ .start_line = 286, .start_col = 35, .end_line = 286, .end_col = 47 };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = copy_span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = copy_span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = copy_span, .ty = 2, .kind = .{ .literal = .{ .int = .{
            .text = "4",
            .value = 4,
            .base = .dec,
            .ty_suffix = "usize",
        } } } },
        .{ .id = 3, .span = copy_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = copy,
            .args = &.{ 1, 2 },
        } } },
        .{ .id = 4, .span = vector_span, .ty = 3, .kind = .{ .unit = {} } },
        .{ .id = 5, .span = vector_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 4,
            .receiver_mode = .shared,
            .method = to_vec,
            .args = &.{},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &.{}, .stmts = &.{}, .pats = &.{} };
    _ = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(exprs.CoreFunction.ptr_copy_nonoverlapping, b.exprs[3].kind.core_call.function);
    try std.testing.expectEqualSlices(exprs.NodeId, &.{ 6, 1, 2 }, b.exprs[3].kind.core_call.args);
    try std.testing.expect(b.exprs[6].kind == .unary);
    try std.testing.expect(b.exprs[6].kind.unary.op == .deref);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), b.exprs[6].kind.unary.operand);
    try std.testing.expect(types.deepEqual(.{ .prim = .u8 }, b.exprs[3].kind.core_call.generic_args[0]));
    try std.testing.expectEqual(exprs.CoreFunction.convert_from, b.exprs[5].kind.core_call.function);
    const target = b.exprs[5].kind.core_call.generic_args[0];
    try std.testing.expectEqual(@as(usize, 3), target.external_nominal.path.len);
    for ([_][]const u8{ "alloc", "vec", "Vec" }, target.external_nominal.path) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expect(types.deepEqual(.{ .prim = .u8 }, target.external_nominal.args[0]));
    try std.testing.expect(types.deepEqual(target, b.types[b.exprs[5].ty.?]));
}

test "source trait methods remain available through opaque receiver bounds" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const provider = try addEntity(&g, a, .trait_, "Render", root);
    const owner = try addEntity(&g, a, .fn_, "render", root);
    const bounds = [_]types.Bound{.{ .path = .{ .segments = &.{.{ .name = "Render", .id = provider }} } }};
    var body_store = [_]bodies.BodyKind{.none} ** 3;
    body_store[provider] = .{ .trait_ = .{ .name = "Render", .methods = &.{
        .{ .name = "render", .ret = .{ .prim = .usize } },
    } } };
    const b: bodies.Bodies = .{ .exprs = &.{}, .types = &.{}, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const opaque_type: types.Type = .{ .@"opaque" = .{ .bounds = &bounds } };
    const borrow: types.Ref = .{ .mut = false, .pointee = opaque_type };
    const proof = resolve_methods.boundTraitMethod(&g, &b, owner, .{ .reference = &borrow }, "render").?;
    try std.testing.expectEqual(provider, proof.trait_id);
    try std.testing.expect(types.deepEqual(.{ .prim = .usize }, proof.signature.ret));
}

test "late borrowed integer LE encoding passes a value and retains the byte width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", root);
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .prim = .u16 } };
    const image: types.Array = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 2 } };
    const type_store = [_]types.Type{ .{ .reference = &borrow }, .{ .array = &image } };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = method,
            .args = &.{},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &.{}, .stmts = &.{}, .pats = &.{} };
    _ = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(exprs.CoreFunction.prim_to_le_bytes, b.exprs[1].kind.core_call.function);
    try std.testing.expectEqual(@as(exprs.NodeId, 2), b.exprs[1].kind.core_call.args[0]);
    try std.testing.expect(b.exprs[2].kind.unary.op == .deref);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), b.exprs[2].kind.unary.operand);
    try std.testing.expect(types.deepEqual(.{ .prim = .u16 }, b.exprs[1].kind.core_call.generic_args[0]));
    try std.testing.expect(types.deepEqual(.{ .array = &image }, b.types[b.exprs[1].ty.?]));
}

test "a little-endian image over a recovered field receiver dispatches and takes its width from the receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    // The exact shape `impl Hasher for SeaHasher { fn finish(&self) -> u64 {`
    // reaches this pass with: the receiver is a struct FIELD of the borrowed
    // receiver, not a parameter, so the lowering layer had no type to measure
    // and the call arrives with no result type of its own.
    const hasher_impl = try addEntity(&g, a, .impl_, "Hasher for SeaHasher", root);
    const finish = try addEntity(&g, a, .fn_, "finish", hasher_impl);
    const self_param = try addEntity(&g, a, .field, "self", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    const sea_hasher: types.Type = .{ .path = .{ .segments = &.{.{ .name = "SeaHasher", .id = null }} } };
    const borrow: types.Ref = .{ .mut = false, .pointee = sea_hasher };
    const type_store = [_]types.Type{ .{ .reference = &borrow }, .{ .prim = .u64 } };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = self_param, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .field = .{ .base = 0, .field = "tail", .resolved = 0 } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 5;
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(exprs.CoreFunction.prim_to_le_bytes, b.exprs[2].kind.core_call.function);
    // A `u64` receiver is passed through: it is the value, not a borrow of one.
    try std.testing.expectEqual(@as(exprs.NodeId, 1), b.exprs[2].kind.core_call.args[0]);
    try std.testing.expect(types.deepEqual(.{ .prim = .u64 }, b.exprs[2].kind.core_call.generic_args[0]));
    // The width comes from the receiver, because nothing else knows it.
    const recorded = b.types[b.exprs[2].ty.?];
    try std.testing.expect(recorded == .array);
    try std.testing.expect(types.deepEqual(.{ .prim = .u8 }, recorded.array.elem));
    try std.testing.expectEqual(@as(u64, 8), recorded.array.len.literal);
}

test "a pointer-sized byte image still needs the lowering layer's target width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const finish = try addEntity(&g, a, .fn_, "finish", root);
    const size_param = try addEntity(&g, a, .field, "size", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    const type_store = [_]types.Type{.{ .prim = .usize }};
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = size_param, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 4;
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[1], "method dispatch unavailable");
}

test "a recorded byte image whose width is not the receiver's stays refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const finish = try addEntity(&g, a, .fn_, "finish", root);
    const value = try addEntity(&g, a, .field, "n", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    // A `u32` receiver recorded as a four-byte image of something else.
    const image: types.Array = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = 8 } };
    const type_store = [_]types.Type{ .{ .prim = .u32 }, .{ .array = &image } };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = value, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 4;
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[1], "method dispatch unavailable");
}

test "a pointer-sized byte image whose width is an expression still dispatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const finish = try addEntity(&g, a, .fn_, "finish", root);
    const size_param = try addEntity(&g, a, .field, "size", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    // The record the lowering layer leaves for a pointer-sized width: the
    // target's own `mem_size_of` call, not a number.
    const image: types.Array = .{ .elem = .{ .prim = .u8 }, .len = .{ .expression = 1 } };
    const type_store = [_]types.Type{ .{ .prim = .usize }, .{ .array = &image } };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = size_param, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .core_call = .{
            .function = .mem_size_of,
            .generic_args = &.{.{ .prim = .usize }},
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = 1, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 4;
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    try std.testing.expectEqual(exprs.CoreFunction.prim_to_le_bytes, b.exprs[2].kind.core_call.function);
    try std.testing.expectEqual(b.exprs[2].ty, @as(exprs.TypeId, 1));
}

test "an untyped field receiver takes its type from the struct declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const sea_hasher = try addEntity(&g, a, .struct_, "SeaHasher", root);
    const hasher_impl = try addEntity(&g, a, .impl_, "Hasher for SeaHasher", root);
    const finish = try addEntity(&g, a, .fn_, "finish", hasher_impl);
    const self_param = try addEntity(&g, a, .field, "self", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    const fields = [_]items.Field{
        .{ .name = "tail", .ty = .{ .prim = .u64 }, .visibility = .private, .span = span },
        .{ .name = "ntail", .ty = .{ .prim = .usize }, .visibility = .private, .span = span },
    };
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .path = .{
        .segments = &.{.{ .name = "SeaHasher", .id = sea_hasher }},
    } } };
    const type_store = [_]types.Type{.{ .reference = &borrow }};
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = self_param, .generic_args = &.{} } } },
        // The FIELD carries no type: only its base does, and the field list
        // the struct declares is what the projection reads.
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .field = .{ .base = 0, .field = "tail", .resolved = 0 } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
        // A field the struct does not declare has no declared type to
        // project, so the call over it stays refused — named as the missing
        // receiver, because there is no receiver type to dispatch from.
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .field = .{ .base = 0, .field = "absent", .resolved = 0 } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 3,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 6;
    body_store[sea_hasher] = .{ .struct_ = .{ .layout = .named, .fields = &fields } };
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try std.testing.expectEqual(exprs.CoreFunction.prim_to_le_bytes, b.exprs[2].kind.core_call.function);
    try std.testing.expectEqual(@as(exprs.NodeId, 1), b.exprs[2].kind.core_call.args[0]);
    const projected = b.types[b.exprs[2].ty.?];
    try std.testing.expect(projected == .array);
    try std.testing.expectEqual(@as(u64, 8), projected.array.len.literal);
    try expectUnsupportedReason(&b.exprs[4], "method receiver unavailable");
}

test "a tuple struct field receiver projects the position the source wrote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    // `struct Lane(u64)` — a tuple struct, whose fields are addressed by
    // position, so the source writes `self.0` and not a name.
    const lane = try addEntity(&g, a, .struct_, "Lane", root);
    const finish = try addEntity(&g, a, .fn_, "finish", root);
    const self_param = try addEntity(&g, a, .field, "self", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    const fields = [_]items.Field{
        .{ .name = "0", .ty = .{ .prim = .u64 }, .visibility = .private, .span = span },
    };
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .path = .{
        .segments = &.{.{ .name = "Lane", .id = lane }},
    } } };
    const type_store = [_]types.Type{.{ .reference = &borrow }};
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = self_param, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .field = .{ .base = 0, .field = "0", .resolved = 0 } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 5;
    body_store[lane] = .{ .struct_ = .{ .layout = .tuple, .fields = &fields } };
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    try std.testing.expectEqual(exprs.CoreFunction.prim_to_le_bytes, b.exprs[2].kind.core_call.function);
    const projected = b.types[b.exprs[2].ty.?];
    try std.testing.expect(projected == .array);
    try std.testing.expectEqual(@as(u64, 8), projected.array.len.literal);
}

test "a tuple element receiver dispatches from the element's declared type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const scan = try addEntity(&g, a, .fn_, "owner_tuple_repeat", root);
    const entry_param = try addEntity(&g, a, .field, "entry", scan);
    const len_method = try addEntity(&g, a, .method_ref, "len", scan);
    // `for entry in &values` over `Vec<(String, u8)>`, then `entry.0.len()`.
    // The receiver of `len` is a TUPLE ELEMENT, and nothing on the node says
    // which one — the tuple the borrow peels to does.
    const wrapper = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        .{ .prim = .u8 },
    };
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .tuple = &wrapper } };
    const type_store = [_]types.Type{.{ .reference = &borrow }};
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = entry_param, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .field = .{ .base = 0, .field = "0", .resolved = 0 } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .shared,
            .method = len_method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 4;
    body_store[scan] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .usize }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 1), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 0), stats.unsupported_methods);
    // A standard method stays an ordinary call: the backend picks the runtime
    // arm from the name, and the RESULT is what this pass has to supply.
    try std.testing.expect(b.exprs[2].kind == .method_call);
    try std.testing.expect(types.deepEqual(.{ .prim = .usize }, b.types[b.exprs[2].ty.?]));
}

test "a tuple element position outside the tuple stays refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const scan = try addEntity(&g, a, .fn_, "owner_tuple_repeat", root);
    const entry_param = try addEntity(&g, a, .field, "entry", scan);
    const len_method = try addEntity(&g, a, .method_ref, "len", scan);
    const wrapper = [_]types.Type{ .{ .prim = .u8 }, .{ .prim = .u8 } };
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .tuple = &wrapper } };
    const type_store = [_]types.Type{.{ .reference = &borrow }};
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = entry_param, .generic_args = &.{} } } },
        // Position 7 is not a position this tuple has, so nothing is projected
        // and the call over it stays refused rather than answered with
        // whichever element happened to be nearest.
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .field = .{ .base = 0, .field = "7", .resolved = 0 } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .shared,
            .method = len_method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 4;
    body_store[scan] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .usize }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 0), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[2], "method receiver unavailable");
}

test "two declarations under one name leave a field projection untyped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const first = try addEntity(&g, a, .struct_, "Twin", root);
    const second = try addEntity(&g, a, .struct_, "Twin", root);
    const finish = try addEntity(&g, a, .fn_, "finish", root);
    const self_param = try addEntity(&g, a, .field, "self", finish);
    const method = try addEntity(&g, a, .method_ref, "to_le_bytes", finish);
    const wide = [_]items.Field{
        .{ .name = "value", .ty = .{ .prim = .u64 }, .visibility = .private, .span = span },
    };
    const narrow = [_]items.Field{
        .{ .name = "value", .ty = .{ .prim = .u16 }, .visibility = .private, .span = span },
    };
    // The base records NO declaration, which is what makes the name ambiguous
    // at all: a base that names one twin by entity reads that twin's own field
    // list, and "an untyped field receiver takes its type from the struct
    // declaration" above is that case. Here the spelling is all there is, and
    // two declarations answer to it.
    const borrow: types.Ref = .{ .mut = false, .pointee = .{ .path = .{
        .segments = &.{.{ .name = "Twin", .id = null }},
    } } };
    const type_store = [_]types.Type{.{ .reference = &borrow }};
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = self_param, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .field = .{ .base = 0, .field = "value", .resolved = 0 } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .value,
            .method = method,
            .args = &.{},
        } } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 6;
    body_store[first] = .{ .struct_ = .{ .layout = .named, .fields = &wide } };
    body_store[second] = .{ .struct_ = .{ .layout = .named, .fields = &narrow } };
    body_store[finish] = .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .u64 }, .body = 0 } };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    // Picking one of the two layouts would answer with a width the source
    // never wrote, so neither is read and the call stays refused.
    try std.testing.expectEqual(@as(usize, 0), stats.std_resolved);
    try std.testing.expectEqual(@as(usize, 1), stats.unsupported_methods);
    try expectUnsupportedReason(&b.exprs[2], "method receiver unavailable");
}

test "SipHasher generic Hash and Hasher methods keep source dispatch available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const function = try addEntity(&g, a, .fn_, "hash_with", root);
    const state = try addEntity(&g, a, .field, "st", function);
    const value = try addEntity(&g, a, .field, "x", function);
    const hash = try addEntity(&g, a, .method_ref, "hash", function);
    const finish = try addEntity(&g, a, .method_ref, "finish", function);
    const write = try addEntity(&g, a, .method_ref, "write", function);
    const parameters = [_]types.GenericParam{
        .{ .type_ = .{ .name = "H", .bounds = &.{.{ .path = .{ .segments = &.{
            .{ .name = "std", .id = null },    .{ .name = "hash", .id = null },
            .{ .name = "Hasher", .id = null },
        } } }} } },
        .{ .type_ = .{ .name = "T", .bounds = &.{.{ .path = .{ .segments = &.{
            .{ .name = "std", .id = null },  .{ .name = "hash", .id = null },
            .{ .name = "Hash", .id = null },
        } } }} } },
    };
    var body_store = [_]bodies.BodyKind{.none} ** 7;
    body_store[function] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u64 },
        .body = 4,
        .generics = .{ .params = &parameters, .where_clauses = &.{} },
    } };
    const hasher: types.Type = .{ .path = .{ .segments = &.{.{ .name = "H", .id = null }} } };
    const item: types.Type = .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } };
    const item_ref: types.Ref = .{ .mut = false, .pointee = item };
    const state_ref: types.Ref = .{ .mut = true, .pointee = hasher };
    const bytes: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const type_store = [_]types.Type{
        hasher, .{ .reference = &item_ref }, .{ .reference = &state_ref }, .{ .slice = &bytes },
    };
    const hash_span: spine.Span = .{ .start_line = 49, .start_col = 5, .end_line = 49, .end_col = 25 };
    const finish_span: spine.Span = .{ .start_line = 50, .start_col = 5, .end_line = 50, .end_col = 16 };
    const write_span: spine.Span = .{ .start_line = 22, .start_col = 9, .end_line = 22, .end_col = 23 };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = hash_span, .ty = 0, .kind = .{ .path = .{ .def = state, .generic_args = &.{} } } },
        .{ .id = 1, .span = hash_span, .ty = 1, .kind = .{ .path = .{ .def = value, .generic_args = &.{} } } },
        .{ .id = 2, .span = hash_span, .ty = 2, .kind = .{ .unary = .{ .op = .{ .ref = .mutable }, .operand = 0 } } },
        .{ .id = 3, .span = hash_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 1,
            .receiver_mode = .shared,
            .method = hash,
            .args = &.{2},
        } } },
        .{ .id = 4, .span = finish_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = finish,
            .args = &.{},
        } } },
        .{ .id = 5, .span = write_span, .ty = 3, .kind = .{ .unit = {} } },
        .{ .id = 6, .span = write_span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = write,
            .args = &.{5},
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &body_store, .stmts = &.{}, .pats = &.{} };
    const stats = try resolve_methods.resolveMethods(&g, &b);
    try std.testing.expectEqual(@as(usize, 3), stats.std_resolved);
    for ([_]exprs.NodeId{ 3, 4, 6 }) |node| try std.testing.expect(b.exprs[node].kind == .method_call);
    try std.testing.expectEqual(exprs.ReceiverMode.mutable, b.exprs[6].kind.method_call.receiver_mode);
    try std.testing.expect(types.deepEqual(.{ .prim = .u64 }, resolve_methods.boundHashMethodReturnType(&g, &b, function, hasher, "finish").?));
    try std.testing.expect(types.deepEqual(.{ .prim = .unit }, resolve_methods.boundHashMethodReturnType(&g, &b, function, item, "hash").?));
    try std.testing.expect(resolve_methods.boundHashMethodReturnType(&g, &b, function, item, "write") == null);
}

test "multiple borrowed pointer copies retain one owned output table without leaking growth buffers" {
    const a = std.testing.allocator;
    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    const root = try addEntity(&g, a, .module, "", null);
    const method = try addEntity(&g, a, .method_ref, "copy_to_nonoverlapping", root);
    const source_pointer: types.RawPtr = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const source_borrow: types.Ref = .{ .mut = false, .pointee = .{ .raw_ptr = &source_pointer } };
    const destination_pointer: types.RawPtr = .{ .mut = true, .pointee = .{ .prim = .u8 } };
    const type_store = [_]types.Type{
        .{ .reference = &source_borrow }, .{ .raw_ptr = &destination_pointer }, .{ .prim = .usize },
    };
    const expression_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 0, .kind = .{ .unit = {} } },
        .{ .id = 1, .span = span, .ty = 1, .kind = .{ .unit = {} } },
        .{ .id = 2, .span = span, .ty = 2, .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = "usize",
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = method,
            .args = &.{ 1, 2 },
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .value,
            .method = method,
            .args = &.{ 1, 2 },
        } } },
    };
    var b: bodies.Bodies = .{ .exprs = &expression_store, .types = &type_store, .bodies = &.{}, .stmts = &.{}, .pats = &.{} };
    _ = try resolve_methods.resolveMethods(&g, &b);
    defer a.free(b.exprs);
    defer a.free(b.types);
    for ([_]exprs.NodeId{ 3, 4 }) |node| {
        const core = b.exprs[node].kind.core_call;
        defer a.free(core.args);
        defer a.free(core.generic_args);
        try std.testing.expectEqual(exprs.CoreFunction.ptr_copy_nonoverlapping, core.function);
        try std.testing.expect(b.exprs[core.args[0]].kind.unary.op == .deref);
        try std.testing.expectEqual(@as(exprs.NodeId, 0), b.exprs[core.args[0]].kind.unary.operand);
    }
    try std.testing.expectEqual(@as(usize, 7), b.exprs.len);
}
