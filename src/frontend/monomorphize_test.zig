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

test "collectInstantiations clones a generic call named only by a vec! repeat count" {
    const a = std.testing.allocator;

    // `vec![7u8; count_of::<u32>()]`. `Vec` is a runtime container, so the count
    // is an ordinary Rust expression the target evaluates once, and a generic
    // function reached only through it must still be monomorphized. The second
    // literal, `vec![7u8; 7]`, is the control: a count the translator already
    // holds names no node and must add nothing.
    const count_of_id: exprs.DefId = 3;
    const generic_args = [_]types.Type{.{ .prim = .u32 }};

    // A turbofish'd call reaches the IR as a `.call` whose `ty` is the
    // `generic_inst` carrying the substituted type arguments.
    const types_store = [_]types.Type{
        .{ .generic_inst = .{ .decl = count_of_id, .args = .{ .params = &generic_args } } },
    };

    const exprs_store = [_]exprs.Expr{
        // 0: the repeated element `7u8`.
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "7",
                .value = 7,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        // 1: `count_of::<u32>()`, the count — the only generic use in the body.
        .{
            .id = 1,
            .span = span,
            .ty = 0,
            .kind = .{ .call = .{ .call_kind = .{ .free = count_of_id }, .args = &.{} } },
        },
        // 2: `vec![7u8; count_of::<u32>()]`.
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = &.{0},
                .repeat = .{ .expression = 1 },
            } },
        },
        // 3: `vec![7u8; 7]`, whose count is held outright.
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .vec_lit = .{
                .elements = &.{0},
                .repeat = .{ .literal = 7 },
            } },
        },
        // 4: the fn body block, holding both vec literals.
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = 2,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 3 } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 4,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    var table = try monomorphize.collectInstantiations(a, &g, &b);
    defer table.deinit(a);

    // Exactly one clone: the count's, deduplicated. The element and the
    // literal-count vec contribute none, and the element is shared by both
    // literals without being walked twice.
    try std.testing.expectEqual(@as(usize, 1), table.count());
    const inst = table.get(0).?;
    try std.testing.expectEqual(@as(spine.EntityId, count_of_id), inst.generic_id);
    try std.testing.expectEqualStrings("_u32", inst.zig_suffix);
}

/// A struct declaration with the given OWN type parameters and no fields. A
/// row naming it is legitimate exactly when it declares as many type
/// parameters as the row carries arguments.
fn genericStruct(
    generic_params: []const []const u8,
    fields: []const items.Field,
) bodies.BodyKind {
    return .{ .struct_ = .{ .generic_params = generic_params, .fields = fields } };
}

/// `Pair<A, B>`: the two-parameter declaration the "one row per distinct
/// argument list" and "no row without its own parameters" tests both use.
const pair_generic_params: []const []const u8 = &.{ "A", "B" };

test "collectInstantiations mints one row per distinct argument list of one declaration" {
    const a = std.testing.allocator;

    // 0 = `Pair<A, B>`, the declaration under test.
    const pair_id: spine.EntityId = 0;
    // 1 = a plain `fn use_three(p: Pair<u32,u8>, q: Pair<u8,u32>, r: Pair<u32,u8>)`
    // holder. Three uses of ONE declaration, two of them identical.
    const params = [_]items.Param{
        .{
            .name = "p",
            .ty = .{ .generic_inst = .{ .decl = pair_id, .args = .{
                .params = &.{ .{ .prim = .u32 }, .{ .prim = .u8 } },
            } } },
            .span = span,
        },
        .{
            .name = "q",
            .ty = .{ .generic_inst = .{ .decl = pair_id, .args = .{
                .params = &.{ .{ .prim = .u8 }, .{ .prim = .u32 } },
            } } },
            .span = span,
        },
        .{
            .name = "r",
            .ty = .{ .generic_inst = .{ .decl = pair_id, .args = .{
                .params = &.{ .{ .prim = .u32 }, .{ .prim = .u8 } },
            } } },
            .span = span,
        },
    };
    const bodies_store = [_]bodies.BodyKind{
        genericStruct(pair_generic_params, &.{}),
        .{ .fn_ = .{
            .params = &params,
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &.{.{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } }},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    var table = try monomorphize.collectInstantiations(a, &g, &b);
    defer table.deinit(a);

    // Two distinct lists, not three uses and not one merged row.
    try std.testing.expectEqual(@as(usize, 2), table.count());
    const first = table.get(0).?;
    const second = table.get(1).?;
    try std.testing.expectEqual(pair_id, first.generic_id);
    try std.testing.expectEqual(pair_id, second.generic_id);
    try std.testing.expectEqualStrings("_u32_u8", first.zig_suffix);
    try std.testing.expectEqualStrings("_u8_u32", second.zig_suffix);

    // The two rows carry different arguments, not one row re-mangled. Order in
    // the list is what distinguishes `Pair<u32,u8>` from `Pair<u8,u32>`, and a
    // row set that disagreed about that would be indistinguishable.
    try std.testing.expectEqual(@as(usize, 2), first.args.params.len);
    try std.testing.expectEqual(@as(usize, 2), second.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, first.args.params[0]);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, second.args.params[0]);
}

test "the arity gate never merges two declarations that share a parameter count" {
    const a = std.testing.allocator;

    // 0 = `Wrap<T>`, 1 = `Box<T>`. Two different declarations that declare the
    // SAME number of parameters, so arity alone cannot tell them apart, and
    // 2 = `Pair<A, B>` reached with a one-argument list — right arity for
    // neither of them, which is what proves the gate refuses rather than
    // filters out nothing.
    const wrap_id: spine.EntityId = 0;
    const box_id: spine.EntityId = 1;
    const pair_id: spine.EntityId = 2;

    const params = [_]items.Param{
        .{
            .name = "w",
            .ty = .{ .generic_inst = .{ .decl = wrap_id, .args = .{
                .params = &.{.{ .prim = .u32 }},
            } } },
            .span = span,
        },
        .{
            .name = "b",
            .ty = .{ .generic_inst = .{ .decl = box_id, .args = .{
                .params = &.{.{ .prim = .u32 }},
            } } },
            .span = span,
        },
        .{
            .name = "mismatched",
            .ty = .{ .generic_inst = .{ .decl = pair_id, .args = .{
                .params = &.{.{ .prim = .u32 }},
            } } },
            .span = span,
        },
    };
    const bodies_store = [_]bodies.BodyKind{
        genericStruct(&.{"T"}, &.{}),
        genericStruct(&.{"T"}, &.{}),
        genericStruct(pair_generic_params, &.{}),
        .{ .fn_ = .{
            .params = &params,
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &.{.{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } }},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    var table = try monomorphize.collectInstantiations(a, &g, &b);
    defer table.deinit(a);

    // `Wrap<u32>` and `Box<u32>` are two rows even though they mangle alike and
    // declare alike; `Pair` with one argument against two declared is none.
    try std.testing.expectEqual(@as(usize, 2), table.count());
    const wrap = table.get(0).?;
    const box_row = table.get(1).?;
    try std.testing.expectEqual(wrap_id, wrap.generic_id);
    try std.testing.expectEqual(box_id, box_row.generic_id);
    try std.testing.expect(wrap.generic_id != box_row.generic_id);
    try std.testing.expectEqualStrings("_u32", wrap.zig_suffix);
    try std.testing.expectEqualStrings("_u32", box_row.zig_suffix);
}

test "a declaration that binds no parameters of its own mints no row" {
    const a = std.testing.allocator;

    // 0 = `impl<S: Sip> Hasher<S>`, which declares `S`. 1 = `struct Hasher<S>`,
    // whose OWN list is one entry long. 2 = `fn new_with_keys(k0, k1) ->
    // Hasher<S>`, nested in that impl and declaring nothing itself. 3 = the
    // caller, whose return type is `Hasher<u32>`.
    //
    // `getGenericParamNames` answers "S" for entity 2 by walking out to the
    // enclosing impl; the count a row is checked against must not, because
    // `(new_with_keys, [u32])` is not an instantiation of any declaration.
    const hasher_id: spine.EntityId = 1;
    const new_with_keys_id: spine.EntityId = 2;

    const bound_s = [_]types.Type{.{ .path = .{ .segments = &.{
        .{ .name = "S", .id = null },
    } } }};
    const impl_generics = [_]types.GenericParam{
        .{ .type_ = .{ .name = "S", .bounds = &.{} } },
    };
    const phantom_args = [_]types.Type{.{ .prim = .u32 }};
    const caller_params = [_]items.Param{.{
        .name = "via_type",
        .ty = .{ .generic_inst = .{ .decl = new_with_keys_id, .args = .{
            .params = &phantom_args,
        } } },
        .span = span,
    }};
    const no_statements: [0]exprs.NodeId = .{};
    const exprs_store: []const exprs.Expr = &[_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .unit = {} } },
        // `Hasher::new_with_keys::<u32>` as `ts_ext` lowers a receiver witness.
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .path = .{
            .def = new_with_keys_id,
            .generic_args = &phantom_args,
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .block = .{
            .statements = &no_statements,
            .tail = 1,
            .labelled = null,
        } } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .impl_ = .{
            .self_ty = .{ .generic_inst = .{ .decl = hasher_id, .args = .{
                .params = &bound_s,
            } } },
            .generics = .{ .params = &impl_generics, .where_clauses = &.{} },
        } },
        genericStruct(&.{"S"}, &.{}),
        .{
            .fn_ = .{
                .params = &.{},
                // The inherited `S`, which is exactly what must not be counted.
                .ret = .{ .generic_inst = .{ .decl = hasher_id, .args = .{
                    .params = &bound_s,
                } } },
                .generic_params = &.{},
                .body = 0,
            },
        },
        .{ .fn_ = .{
            .params = &caller_params,
            .ret = .{ .generic_inst = .{ .decl = hasher_id, .args = .{
                .params = &phantom_args,
            } } },
            .body = 2,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    var g = graph.CrateGraph.init(a);
    defer g.deinit();
    var table = try monomorphize.collectInstantiations(a, &g, &b);
    defer table.deinit(a);

    // Exactly the STRUCT's row, and it comes from the caller's return type —
    // the one place in this fixture that states a concrete `Hasher`. The
    // parameter type and the path expression both name `new_with_keys` with a
    // one-argument list and contribute nothing, because that declaration binds
    // no parameters of its own however deeply it is nested.
    try std.testing.expectEqual(@as(usize, 1), table.count());
    const row = table.get(0).?;
    try std.testing.expectEqual(hasher_id, row.generic_id);
    try std.testing.expectEqual(@as(usize, 1), row.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, row.args.params[0]);
    try std.testing.expectEqualStrings("_u32", row.zig_suffix);
}
