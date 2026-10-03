//! infer_test — tests for P2 constraint generation (infer.zig).
//!
//! This file is part of the `translate_rust.frontend` test binary, which links
//! the tree-sitter grammar the frontend needs; the hand-built fixtures below
//! still do not use it.
//!
//! Asserts the 5 contract requirements:
//! (a) Suffixed literal 0x1u64 is pinned to u64.
//! (b) Type-annotated `let x: u32 = e` pins init expression `e` to u32.
//! (c) `.return_` inner expression produces an Edge.ret.
//! (d) Binary `a + b` produces Edge.eq(a, result) and Edge.eq(b, result).
//! (e) A body containing an `.unsupported` node completes without error and
//!     emits its supported pins/edges (unsupported node absent).
//!
//! Two shapes of regression live here. Most build the IR by hand, because the
//! question is what one constraint-generation decision does to a graph the
//! test owns. The source regressions at the end drive real Rust text through
//! `pipeline`, so what they assert is what a crate actually produced.

const std = @import("std");
const infer = @import("infer.zig");
const ir = @import("translate_rust.ir");
const exprs = ir.exprs;
const bodies = ir.bodies;
const types = ir.types;
const items = ir.items;
const spine = ir.spine;
const crate_graph = ir.graph;
const pipeline = @import("pipeline.zig");

const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

/// Helper fixture holding allocated tables so tests can deinit cleanly.
const Fixture = struct {
    b: bodies.Bodies,
    exprs_store: []exprs.Expr,
    stmts_store: []exprs.Statement,
    pats_store: []exprs.Pattern,
    types_store: []types.Type,
    bodies_store: []bodies.BodyKind,

    pub fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        for (self.bodies_store) |bk| {
            switch (bk) {
                .fn_ => |fb| alloc.free(fb.params),
                else => {},
            }
        }
        alloc.free(self.bodies_store);
        alloc.free(self.types_store);
        alloc.free(self.pats_store);
        alloc.free(self.stmts_store);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

/// Build a fixture with fn `f`:
/// ```rust
/// fn f() -> u64 {
///     let x: u32 = 5;
///     var acc: u64 = 0u64;
///     acc = acc + 0x1u64;
///     return acc;
/// }
/// ```
///
/// Table layout:
/// Types:
///   0 = u64
///   1 = u32
///   2 = bool
///
/// Pats:
///   0 = Binding { name: "x", mode: value, mutable: false }
///   1 = Binding { name: "acc", mode: value, mutable: true }
///
/// Exprs:
///   0 = literal int "5" (no suffix)
///   1 = literal int "0u64" (suffix "u64")
///   2 = literal int "0x1u64" (suffix "u64", base hex)
///   3 = PathExpr(def=acc)
///   4 = BinaryExpr(op=add, lhs=3, rhs=2)
///   5 = AssignExpr(target=3, op=plain, value=4)
///   6 = ReturnExpr(value=3)
///   7 = BlockExpr(stmts=[0, 1, 2, 3], tail=null) — fn body
///
/// Stmts:
///   0 = LetStmt(pat=0, init=0, ty=1)  — let x: u32 = 5
///   1 = LetStmt(pat=1, init=1, ty=0)  — var acc: u64 = 0u64
///   2 = ExprStmt(expr=5)              — acc = acc + 0x1u64
///   3 = ExprStmt(expr=6)              — return acc
fn buildFixtureF(alloc: std.mem.Allocator) !Fixture {
    // ── Types ───────────────────────────────────────────────────────────
    const types_store = try alloc.alloc(types.Type, 4);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .u32 };
    types_store[2] = .{ .prim = .bool };
    types_store[3] = .{ .prim = .unit };

    // ── Pats ────────────────────────────────────────────────────────────
    const pats_store = try alloc.alloc(exprs.Pattern, 2);
    pats_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "x",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    };
    pats_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "acc",
            .mode = .{ .value = {} },
            .mutable = true,
        } },
    };

    // ── Exprs ───────────────────────────────────────────────────────────
    const exprs_store = try alloc.alloc(exprs.Expr, 8);

    // 0: lit 5 (no suffix)
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "5",
            .value = 5,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };

    // 1: lit 0u64
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "0u64",
            .value = 0,
            .base = .dec,
            .ty_suffix = "u64",
        } } },
    };

    // 2: lit 0x1u64
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "0x1u64",
            .value = 1,
            .base = .hex,
            .ty_suffix = "u64",
        } } },
    };

    // 3: path acc
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{
            .def = 100,
            .generic_args = &.{},
        } },
    };

    // 4: binary add (lhs=3 path, rhs=2 lit 0x1u64)
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .binary = .{
            .op = .add,
            .overflow = .checked,
            .lhs = 3,
            .rhs = 2,
        } },
    };

    // 5: assign (target=3, op=plain, value=4)
    exprs_store[5] = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .assign = .{
            .target = 3,
            .op = .plain,
            .value = 4,
            .overflow = .checked,
        } },
    };

    // 6: return_ (value=3)
    exprs_store[6] = .{
        .id = 6,
        .span = span,
        .ty = null,
        .kind = .{ .return_ = .{
            .value = 3,
        } },
    };

    // 7: fn body block
    const stmt_ids = try alloc.alloc(exprs.NodeId, 4);
    stmt_ids[0] = 0;
    stmt_ids[1] = 1;
    stmt_ids[2] = 2;
    stmt_ids[3] = 3;
    exprs_store[7] = .{
        .id = 7,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = stmt_ids,
            .tail = null,
            .labelled = null,
        } },
    };

    // ── Stmts ───────────────────────────────────────────────────────────
    const stmts_store = try alloc.alloc(exprs.Statement, 4);

    // 0: let x: u32 = 5
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 1,
        .kind = .{ .let = .{
            .pattern = 0,
            .init = 0,
            .ty = 1,
        } },
    };

    // 1: var acc: u64 = 0u64
    stmts_store[1] = .{
        .id = 1,
        .span = span,
        .ty = 0,
        .kind = .{ .let = .{
            .pattern = 1,
            .init = 1,
            .ty = 0,
        } },
    };

    // 2: acc = acc + 0x1u64
    stmts_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 5 },
    };

    // 3: return acc
    stmts_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 6 },
    };

    // ── Bodies ──────────────────────────────────────────────────────────
    const bodies_store = try alloc.alloc(bodies.BodyKind, 1);
    const params = try alloc.dupe(items.Param, &.{});
    bodies_store[0] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .u64 },
        .body = 7,
    } };

    return .{
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = pats_store,
            .types = types_store,
            .bodies = bodies_store,
        },
        .exprs_store = exprs_store,
        .stmts_store = stmts_store,
        .pats_store = pats_store,
        .types_store = types_store,
        .bodies_store = bodies_store,
    };
}

/// Free the statement slice embedded inside the fixture's block exprs.
fn deinitFixtureFStatements(alloc: std.mem.Allocator, fx: *Fixture) void {
    alloc.free(fx.exprs_store[7].kind.block.statements);
}

/// Build a fixture with fn `g` containing an `.unsupported` node:
/// ```rust
/// fn g() -> u32 {
///     let y: u32 = 7;
///     <unsupported>;
/// }
/// ```
fn buildFixtureG(alloc: std.mem.Allocator) !Fixture {
    const types_store = try alloc.alloc(types.Type, 2);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .u32 };

    const pats_store = try alloc.alloc(exprs.Pattern, 1);
    pats_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "y",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    };

    const exprs_store = try alloc.alloc(exprs.Expr, 3);
    // 0: lit 7
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "7",
            .value = 7,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };
    // 1: unsupported
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .unsupported = .{
            .reason = "inline asm",
            .suggested_version = .v3,
        } },
    };
    // 2: block
    const stmt_ids = try alloc.alloc(exprs.NodeId, 2);
    stmt_ids[0] = 0;
    stmt_ids[1] = 1;
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = stmt_ids,
            .tail = null,
            .labelled = null,
        } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 2);
    // 0: let y: u32 = 7
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 1,
        .kind = .{ .let = .{
            .pattern = 0,
            .init = 0,
            .ty = 1,
        } },
    };
    // 1: expr stmt(1) — unsupported
    stmts_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 1 },
    };

    const bodies_store = try alloc.alloc(bodies.BodyKind, 1);
    const params = try alloc.dupe(items.Param, &.{});
    bodies_store[0] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .u32 },
        .body = 2,
    } };

    return .{
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = pats_store,
            .types = types_store,
            .bodies = bodies_store,
        },
        .exprs_store = exprs_store,
        .stmts_store = stmts_store,
        .pats_store = pats_store,
        .types_store = types_store,
        .bodies_store = bodies_store,
    };
}

fn deinitFixtureGStatements(alloc: std.mem.Allocator, fx: *Fixture) void {
    alloc.free(fx.exprs_store[2].kind.block.statements);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "(a) suffixed literal 0x1u64 is pinned to u64" {
    const a = std.testing.allocator;
    var fx = try buildFixtureF(a);
    defer {
        deinitFixtureFStatements(a, &fx);
        fx.deinit(a);
    }

    var g = try infer.gen(a, &fx.b);
    defer g.deinit(a);

    // Node 2 is `0x1u64`; Type 0 is `u64`.
    var found = false;
    for (g.pins.items) |p| {
        if (p.node == 2 and p.ty == 0) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "(b) let x: u32 = e pins e to u32" {
    const a = std.testing.allocator;
    var fx = try buildFixtureF(a);
    defer {
        deinitFixtureFStatements(a, &fx);
        fx.deinit(a);
    }

    var g = try infer.gen(a, &fx.b);
    defer g.deinit(a);

    // Node 0 is init `5`; Type 1 is `u32`.
    var found = false;
    for (g.pins.items) |p| {
        if (p.node == 0 and p.ty == 1) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "(c) return_ inner expression produces Edge.ret" {
    const a = std.testing.allocator;
    var fx = try buildFixtureF(a);
    defer {
        deinitFixtureFStatements(a, &fx);
        fx.deinit(a);
    }

    var g = try infer.gen(a, &fx.b);
    defer g.deinit(a);

    // Return value is expr 3 (`acc`); fn body block is node 7.
    var found = false;
    for (g.edges.items) |e| {
        if (e == .ret and e.ret.expr == 3 and e.ret.fn_body == 7) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "(d) binary a + b produces Edge.eq(a, result) and Edge.eq(b, result)" {
    const a = std.testing.allocator;
    var fx = try buildFixtureF(a);
    defer {
        deinitFixtureFStatements(a, &fx);
        fx.deinit(a);
    }

    var g = try infer.gen(a, &fx.b);
    defer g.deinit(a);

    // Binary add is node 4; LHS is node 3 (`acc`); RHS is node 2 (`0x1u64`).
    var found_lhs = false;
    var found_rhs = false;
    for (g.edges.items) |e| {
        if (e == .eq) {
            if (e.eq.a == 3 and e.eq.b == 4) found_lhs = true;
            if (e.eq.a == 2 and e.eq.b == 4) found_rhs = true;
        }
    }
    try std.testing.expect(found_lhs);
    try std.testing.expect(found_rhs);
}

test "(e) body containing .unsupported completes without error and emits supported pins" {
    const a = std.testing.allocator;
    var fx = try buildFixtureG(a);
    defer {
        deinitFixtureGStatements(a, &fx);
        fx.deinit(a);
    }

    var g = try infer.gen(a, &fx.b);
    defer g.deinit(a);

    // Must succeed; must have pinned node 0 (let y: u32 = 7) to Type 1 (u32).
    try std.testing.expectEqual(@as(usize, 1), g.pins.items.len);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), g.pins.items[0].node);
    try std.testing.expectEqual(@as(exprs.TypeId, 1), g.pins.items[0].ty);

    // Node 1 is unsupported — must NOT appear in pins or edges.
    for (g.pins.items) |p| {
        try std.testing.expect(p.node != 1);
    }
    for (g.edges.items) |e| {
        switch (e) {
            .eq => |eq| {
                try std.testing.expect(eq.a != 1);
                try std.testing.expect(eq.b != 1);
            },
            .ret => |r| {
                try std.testing.expect(r.expr != 1);
                try std.testing.expect(r.fn_body != 1);
            },
        }
    }
}

test "solve on fixture f infers u32 and u64 on expressions" {
    const a = std.testing.allocator;
    var fx = try buildFixtureF(a);
    defer {
        deinitFixtureFStatements(a, &fx);
        fx.deinit(a);
    }

    var inferred = try infer.solve(a, &fx.b);
    defer inferred.deinit(a);

    // Node 0 (lit 5 in `let x: u32 = 5`) -> u32 (1)
    try std.testing.expectEqual(@as(?exprs.TypeId, 1), inferred.getType(0));
    // Node 1 (lit 0u64) -> u64 (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(1));
    // Node 2 (lit 0x1u64) -> u64 (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(2));
    // Node 3 (path acc) -> u64 (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(3));
    // Node 4 (binary add `acc + 0x1u64`) -> u64 (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(4));
    // Node 5 (assignment `acc = acc + 0x1u64`) -> unit (3)
    try std.testing.expectEqual(@as(?exprs.TypeId, 3), inferred.getType(5));
    // Node 6 (return acc) -> u64 (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(6));
}

test "fnv1a_hash and checksum style function infers u64 on every node with wrapping_mul" {
    const a = std.testing.allocator;

    // ── Types: 0=u64, 1=u32, 2=bool, 3=i32, 4=unit ──
    const types_store = try a.alloc(types.Type, 5);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .u32 };
    types_store[2] = .{ .prim = .bool };
    types_store[3] = .{ .prim = .i32 };
    types_store[4] = .{ .prim = .unit };

    // ── Pats: 0=hash binding ──
    const pats_store = try a.alloc(exprs.Pattern, 1);
    pats_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "hash",
            .mode = .{ .value = {} },
            .mutable = true,
        } },
    };

    // ── Exprs:
    // 0: lit 0xcbf29ce484222325u64 (suffix u64)
    // 1: path hash (def 10)
    // 2: lit 0x100000001b3 (unannotated literal int)
    // 3: binary wrapping_mul: hash *% 0x100000001b3 (lhs=1, rhs=2)
    // 4: assign: hash = hash *% 0x100000001b3 (target=1, val=3)
    // 5: return hash (value=1)
    // 6: block body
    const exprs_store = try a.alloc(exprs.Expr, 7);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "0xcbf29ce484222325u64",
            .value = 14695981039346656037,
            .base = .hex,
            .ty_suffix = "u64",
        } } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .path = .{ .def = 10, .generic_args = &.{} } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{
            .literal = .{
                .int = .{
                    .text = "0x100000001b3",
                    .value = 1099511628211,
                    .base = .hex,
                    .ty_suffix = null, // unannotated!
                },
            },
        },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .wrapping,
            .lhs = 1,
            .rhs = 2,
        } },
    };
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .assign = .{
            .target = 1,
            .op = .plain,
            .value = 3,
            .overflow = .wrapping,
        } },
    };
    exprs_store[5] = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .return_ = .{ .value = 1 } },
    };
    const stmt_ids = try a.alloc(exprs.NodeId, 3);
    stmt_ids[0] = 0;
    stmt_ids[1] = 1;
    stmt_ids[2] = 2;
    exprs_store[6] = .{
        .id = 6,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = stmt_ids,
            .tail = null,
            .labelled = null,
        } },
    };

    // ── Stmts:
    // 0: let mut hash: u64 = 0xcbf29ce484222325u64
    // 1: expr stmt (assign: hash = hash *% 0x100000001b3)
    // 2: return hash
    const stmts_store = try a.alloc(exprs.Statement, 3);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .let = .{ .pattern = 0, .init = 0, .ty = 0 } },
    };
    stmts_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 4 },
    };
    stmts_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 5 },
    };

    const bodies_store = try a.alloc(bodies.BodyKind, 1);
    const params = try a.dupe(items.Param, &.{});
    bodies_store[0] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .u64 },
        .body = 6,
    } };
    defer {
        a.free(stmt_ids);
        a.free(params);
        a.free(bodies_store);
        a.free(stmts_store);
        a.free(exprs_store);
        a.free(pats_store);
        a.free(types_store);
    }

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = pats_store,
        .types = types_store,
        .bodies = bodies_store,
    };

    var inferred = try infer.solve(a, &b);
    defer inferred.deinit(a);

    // Every value-producing expression node in fnv1a_hash infers u64 (TypeId 0).
    // 0: initial hash literal
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(0));
    // 1: hash path
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(1));
    // 2: unannotated multiplier literal 0x100000001b3 unifies to u64
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(2));
    // 3: wrapping_mul binary expression
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(3));
    // 4: assignment expression has Rust unit type (TypeId 4)
    try std.testing.expectEqual(@as(?exprs.TypeId, 4), inferred.getType(4));
    // 5: return expression
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(5));

    // Verify apply mutates exprs.ty
    inferred.apply(exprs_store);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), exprs_store[0].ty);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), exprs_store[2].ty);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), exprs_store[3].ty);
    try std.testing.expectEqual(@as(?exprs.TypeId, 4), exprs_store[4].ty);
}

test "unannotated integer defaults to i32 and unannotated float defaults to f64" {
    const a = std.testing.allocator;

    const types_store = try a.alloc(types.Type, 2);
    types_store[0] = .{ .prim = .i32 };
    types_store[1] = .{ .prim = .f64 };

    const exprs_store = try a.alloc(exprs.Expr, 3);
    // 0: unannotated integer literal 42
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "42",
            .value = 42,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };
    // 1: unannotated float literal 3.14
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .float = .{
            .text = "3.14",
            .value = 3.14,
        } } },
    };
    // 2: block body
    const stmt_ids = try a.alloc(exprs.NodeId, 2);
    stmt_ids[0] = 0;
    stmt_ids[1] = 1;
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = stmt_ids,
            .tail = null,
            .labelled = null,
        } },
    };

    const stmts_store = try a.alloc(exprs.Statement, 2);
    stmts_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 0 } };
    stmts_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 1 } };

    const bodies_store = try a.alloc(bodies.BodyKind, 1);
    const params = try a.dupe(items.Param, &.{});
    bodies_store[0] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .unit },
        .body = 2,
    } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var inferred = try infer.solve(a, &b);
    defer inferred.deinit(a);

    // Unannotated integer 42 defaults to i32 (TypeId 0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(0));
    // Unannotated float 3.14 defaults to f64 (TypeId 1)
    try std.testing.expectEqual(@as(?exprs.TypeId, 1), inferred.getType(1));

    a.free(stmt_ids);
    a.free(params);
    a.free(bodies_store);
    a.free(stmts_store);
    a.free(exprs_store);
    a.free(types_store);
}

test "control flow if_else and comparison type inference" {
    const a = std.testing.allocator;

    // Types: 0=u64, 1=bool, 2=i32
    const types_store = try a.alloc(types.Type, 3);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .bool };
    types_store[2] = .{ .prim = .i32 };

    const exprs_store = try a.alloc(exprs.Expr, 6);
    // 0: lit 10u64 (pinned u64)
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "10u64", .value = 10, .base = .dec, .ty_suffix = "u64" } } },
    };
    // 1: lit 20 (unannotated)
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "20", .value = 20, .base = .dec, .ty_suffix = null } } },
    };
    // 2: binary lt: 0 < 1
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .binary = .{ .op = .lt, .overflow = .checked, .lhs = 0, .rhs = 1 } },
    };
    // 3: then block (tail=0)
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    };
    // 4: else block (tail=1)
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 1, .labelled = null } },
    };
    // 5: if_else (cond=2, then=3, else=4)
    exprs_store[5] = .{
        .id = 5,
        .span = span,
        .ty = null,
        .kind = .{ .if_else = .{
            .cond = 2,
            .then_ = exprs_store[3].kind.block,
            .@"else" = .{ .block = exprs_store[4].kind.block },
        } },
    };

    const bodies_store = try a.alloc(bodies.BodyKind, 1);
    const params = try a.dupe(items.Param, &.{});
    bodies_store[0] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .u64 },
        .body = 5,
    } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var inferred = try infer.solve(a, &b);
    defer inferred.deinit(a);

    // Comparison result is bool (TypeId 1)
    try std.testing.expectEqual(@as(?exprs.TypeId, 1), inferred.getType(2));
    // Unannotated literal 20 in else branch unifies with 10u64 -> u64 (TypeId 0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(1));
    // The if_else expr itself unifies with branches -> u64 (TypeId 0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(5));

    a.free(params);
    a.free(bodies_store);
    a.free(exprs_store);
    a.free(types_store);
}

test "non-fn bodies are skipped without error" {
    const a = std.testing.allocator;
    const types_store = try a.alloc(types.Type, 1);
    types_store[0] = .{ .prim = .u64 };

    const bodies_store = try a.alloc(bodies.BodyKind, 2);
    bodies_store[0] = .none;
    bodies_store[1] = .{ .const_ = .{ .ty = .{ .prim = .u64 }, .init = 0 } };

    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var g = try infer.gen(a, &b);
    defer g.deinit(a);

    try std.testing.expectEqual(@as(usize, 0), g.pins.items.len);
    try std.testing.expectEqual(@as(usize, 0), g.edges.items.len);

    a.free(bodies_store);
    a.free(types_store);
}

test "prelude trait methods infer return types (len=usize, clone=self, bitxor=self)" {
    const a = std.testing.allocator;

    var graph = ir.graph.CrateGraph.init(a);
    defer graph.deinit();

    const len_ent = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try a.dupe(u8, "len"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const clone_ent = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try a.dupe(u8, "clone"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bitxor_ent = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try a.dupe(u8, "bitxor"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Types: 0 = []const u8 (slice), 1 = u8, 2 = usize, 3 = bool.
    const slice_t = try a.create(types.Slice);
    defer a.destroy(slice_t);
    slice_t.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const types_store = try a.alloc(types.Type, 4);
    defer a.free(types_store);
    types_store[0] = .{ .slice = slice_t };
    types_store[1] = .{ .prim = .u8 };
    types_store[2] = .{ .prim = .usize };
    types_store[3] = .{ .prim = .bool };

    // Exprs:
    //   0: receiver `data` (path → slice, ty=0)
    //   1: data.len()       → usize (2)
    //   2: data.clone()     → slice (0, eq to receiver)
    //   3: data.bitxor(o)   → slice (0, eq to receiver)
    //   4: rhs literal (path def, untyped)
    //   5: block tail = bitxor result
    const exprs_store = try a.alloc(exprs.Expr, 6);
    defer a.free(exprs_store);
    const recv_def: exprs.DefId = @intCast(graph.symbol_table.count());
    exprs_store[0] = .{ .id = 0, .span = span, .ty = 0, .kind = .{ .path = .{ .def = recv_def, .generic_args = &.{} } } };
    exprs_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 0, .receiver_mode = .shared, .method = len_ent, .args = &.{} } } };
    exprs_store[2] = .{ .id = 2, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 0, .receiver_mode = .value, .method = clone_ent, .args = &.{} } } };
    exprs_store[3] = .{ .id = 3, .span = span, .ty = null, .kind = .{ .method_call = .{ .receiver = 0, .receiver_mode = .value, .method = bitxor_ent, .args = &.{4} } } };
    exprs_store[4] = .{ .id = 4, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{ .text = "1", .value = 1, .base = .dec, .ty_suffix = null } } } };
    const stmt_ids = try a.alloc(exprs.NodeId, 2);
    defer a.free(stmt_ids);
    stmt_ids[0] = 0;
    stmt_ids[1] = 1;
    exprs_store[5] = .{ .id = 5, .span = span, .ty = null, .kind = .{ .block = .{ .statements = stmt_ids, .tail = 3, .labelled = null } } };

    const stmts_store = try a.alloc(exprs.Statement, 2);
    defer a.free(stmts_store);
    stmts_store[0] = .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 1 } };
    stmts_store[1] = .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 2 } };

    const bodies_store = try a.alloc(bodies.BodyKind, 1);
    defer a.free(bodies_store);
    bodies_store[0] = .{ .fn_ = .{
        .params = try a.dupe(items.Param, &.{}),
        .ret = types_store[0],
        .body = 5,
    } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var inferred = try infer.solveWithGraph(a, &b, &graph);
    defer inferred.deinit(a);

    // data.len() -> usize (2)
    try std.testing.expectEqual(@as(?exprs.TypeId, 2), inferred.getType(1));
    // data.clone() -> slice (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(2));
    // data.bitxor(o) -> slice (0)
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(3));
}
test "solveWithGraph retains explicit generic function path instantiation" {
    const a = std.testing.allocator;

    const generic_param: types.Type = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    const explicit_args = [_]types.Type{.{ .prim = .u32 }};
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{
                .def = 1,
                .generic_args = &explicit_args,
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 0,
                .labelled = null,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .unit = {} },
        },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 1,
        } },
        .{ .fn_ = .{
            .params = &.{},
            .ret = generic_param,
            .generic_params = &.{"T"},
            .body = 2,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    var cg = ir.graph.CrateGraph.init(a);
    defer cg.deinit();
    var inferred = try infer.solveWithGraph(a, &b, &cg);
    defer inferred.deinit(a);

    const inst = inferred.getInstantiation(0);
    try std.testing.expect(inst != null);
    try std.testing.expectEqual(@as(exprs.DefId, 1), inst.?.generic_id);
    try std.testing.expectEqual(@as(usize, 1), inst.?.args.params.len);
    switch (inst.?.args.params[0]) {
        .prim => |p| try std.testing.expectEqual(types.Prim.u32, p),
        else => try std.testing.expect(false),
    }
}

test "solveWithGraph does not default missing generic call arguments to i32" {
    const a = std.testing.allocator;

    const generic_param: types.Type = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{
                .call_kind = .{ .free = 1 },
                .args = &.{},
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 0,
                .labelled = null,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .unit = {} },
        },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 1,
        } },
        .{ .fn_ = .{
            .params = &.{},
            .ret = generic_param,
            .generic_params = &.{"T"},
            .body = 2,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };

    var cg = ir.graph.CrateGraph.init(a);
    defer cg.deinit();
    var inferred = try infer.solveWithGraph(a, &b, &cg);
    defer inferred.deinit(a);

    try std.testing.expect(inferred.getInstantiation(0) == null);
}
test "scalar casts propagate their primitive target type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const types_store = try alloc.alloc(types.Type, 3);
    types_store[0] = .{ .prim = .u8 };
    types_store[1] = .{ .prim = .u64 };
    types_store[2] = .{ .reference = reference };

    const exprs_store = try alloc.alloc(exprs.Expr, 4);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 2,
        .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .unary = .{ .op = .deref, .operand = 0 } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = 1,
        .kind = .{ .cast = .{
            .operand = 1,
            .source_type = .{ .prim = .u8 },
            .target = 1,
        } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 2,
            .labelled = null,
        } },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u64 },
            .body = 3,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(@as(exprs.TypeId, 1), inferred.getType(2).?);
}

test "scalar casts reject reference sources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const types_store = try alloc.alloc(types.Type, 2);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .reference = reference };

    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 1,
            .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = 0,
            .kind = .{ .cast = .{
                .operand = 0,
                .source_type = .{ .reference = reference },
                .target = 0,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 1,
                .labelled = null,
            } },
        },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u64 },
            .body = 2,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = &bodies_store,
    };

    try std.testing.expectError(error.InvalidCast, infer.solve(alloc, &b));
}

test "scalar casts reject non-scalar targets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const types_store = try alloc.alloc(types.Type, 2);
    types_store[0] = .{ .reference = reference };
    types_store[1] = .{ .prim = .u8 };

    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 1,
            .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = 0,
            .kind = .{ .cast = .{
                .operand = 0,
                .source_type = .{ .prim = .u8 },
                .target = 0,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 1,
                .labelled = null,
            } },
        },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .u8 },
            .body = 2,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = &bodies_store,
    };

    try std.testing.expectError(error.InvalidCast, infer.solve(alloc, &b));
}

test "reference loop pattern binds the dereferenced slice element" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var graph_store = ir.graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const function_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "sum"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bytes_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "bytes"),
        .span = span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const byte_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "byte"),
        .span = span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const bytes_reference = try alloc.create(types.Ref);
    bytes_reference.* = .{ .mut = false, .pointee = .{ .slice = slice } };
    const types_store = [_]types.Type{
        .{ .prim = .u8 },
        .{ .prim = .u64 },
        .{ .reference = bytes_reference },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 2,
            .kind = .{ .path = .{ .def = bytes_def, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = byte_def, .generic_args = &.{} } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = 1,
            .kind = .{ .cast = .{
                .operand = 1,
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = 1,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .for_ = .{
                .pattern = 1,
                .iterable = 0,
                .body = .{ .statements = &.{0}, .tail = null, .labelled = null },
                .iter_kind = .{ .slice = {} },
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{1},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 2 } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 3 } },
    };
    const pats_store = [_]exprs.Pattern{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .binding = .{
                .name = "byte",
                .mode = .{ .value = {} },
                .mutable = false,
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .reference = .{
                .mode = .{ .value = {} },
                .inner = 0,
            } },
        },
    };
    const params = [_]items.Param{
        .{ .name = "bytes", .ty = types_store[2], .span = span },
    };
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &params,
            .ret = .{ .prim = .unit },
            .body = 4,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solveWithGraph(alloc, &b, &graph_store);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, exprs_store[2].kind.cast.source_type);
}

test "explicit u64 annotation constrains an unsuffixed integer expression" {
    const alloc = std.testing.allocator;
    const types_store = [_]types.Type{
        .{ .prim = .u64 },
        .{ .prim = .i32 },
    };
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
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
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "2",
                .value = 2,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .binary = .{
                .op = .add,
                .overflow = .checked,
                .lhs = 0,
                .rhs = 1,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "x",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    }};
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{
            .pattern = 0,
            .init = 2,
            .ty = 0,
        } },
    }};
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 3,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(2));
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(0));
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(1));
}

test "by-value array iteration binds the element value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var graph_store = ir.graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const function_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "sum"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const data_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "data"),
        .span = span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const byte_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "byte"),
        .span = span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const array = try alloc.create(types.Array);
    array.* = .{
        .elem = .{ .prim = .u8 },
        .len = .{ .literal = 2 },
    };
    const types_store = [_]types.Type{
        .{ .prim = .u8 },
        .{ .prim = .u64 },
        .{ .array = array },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 2,
            .kind = .{ .path = .{ .def = data_def, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = byte_def, .generic_args = &.{} } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = 1,
            .kind = .{ .cast = .{
                .operand = 1,
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = 1,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .for_ = .{
                .pattern = 0,
                .iterable = 0,
                .body = .{ .statements = &.{0}, .tail = null, .labelled = null },
                .iter_kind = .{ .slice = {} },
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{1},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 2 } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 3 } },
    };
    const pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "byte",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    }};
    const params = [_]items.Param{
        .{ .name = "data", .ty = types_store[2], .span = span },
    };
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &params,
            .ret = .{ .prim = .unit },
            .body = 4,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solveWithGraph(alloc, &b, &graph_store);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, exprs_store[2].kind.cast.source_type);
}
test "range carrier stays distinct from concrete bound type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const range_u8: types.Type = .{ .external_nominal = .{
        .path = &.{ "core", "ops", "Range" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const types_store = [_]types.Type{
        .{ .prim = .u8 },
        .{ .prim = .usize },
        range_u8,
    };
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "0u8",
                .value = 0,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "255u8",
                .value = 255,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .range = .{
                .start = 0,
                .end = 1,
                .inclusive = false,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = 2,
                .labelled = null,
            } },
        },
    };
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = range_u8,
            .body = 3,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    for (generated.edges.items) |edge| {
        switch (edge) {
            .eq => |equal| {
                try std.testing.expect(!((equal.a == 2 and (equal.b == 0 or equal.b == 1)) or
                    (equal.b == 2 and (equal.a == 0 or equal.a == 1))));
            },
            .ret => {},
        }
    }

    var inferred = try infer.solveWithGen(alloc, &b, &generated);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(0));
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(1));
    try std.testing.expectEqual(@as(?exprs.TypeId, 2), inferred.getType(2));
}

test "explicit generic call uses the instantiated return type" {
    const explicit_args = [_]types.Type{.{ .prim = .u32 }};
    const generic_t: types.Type = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    const types_store = [_]types.Type{
        .{ .prim = .u32 },
        .{ .generic_inst = .{
            .decl = 1,
            .args = .{ .params = &explicit_args },
        } },
        .{ .prim = .unit },
    };
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 1,
            .kind = .{ .call = .{
                .call_kind = .{ .free = 1 },
                .args = &.{},
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = 2,
            .kind = .{ .unit = {} },
        },
    };
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 0 },
    }};
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = types_store[2],
            .body = 1,
        } },
        .{ .fn_ = .{
            .params = &.{},
            .ret = generic_t,
            .generic_params = &.{"T"},
            .body = 2,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(std.testing.allocator, &b);
    defer inferred.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(0));
}

test "tuple constructor call has its declared nominal type" {
    const array_type = types.Array{
        .elem = .{ .prim = .u32 },
        .len = .{ .literal = 4 },
    };
    const nominal_type: types.Type = .{ .path = .{
        .segments = &.{.{ .name = "U32X4", .id = 1 }},
    } };
    const types_store = [_]types.Type{
        nominal_type,
        .{ .array = &array_type },
        .{ .prim = .unit },
    };
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 1,
            .kind = .{ .array = .{
                .elements = &.{},
                .repeat = 4,
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{
                .call_kind = .{ .constructor = 1 },
                .args = &.{0},
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 1 },
    }};
    const fields = [_]items.Field{.{
        .name = "0",
        .ty = types_store[1],
        .visibility = .private,
        .span = span,
    }};
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = types_store[2],
            .body = 2,
        } },
        .{ .struct_ = .{
            .layout = .tuple,
            .fields = &fields,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(std.testing.allocator, &b);
    defer inferred.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(1));
}

test "chained raw pointer cast resolves a wildcard pointee" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const wildcard: types.Type = .{ .external_nominal = .{
        .path = &.{"_"},
    } };
    const wildcard_pointer = types.RawPtr{
        .mut = false,
        .pointee = wildcard,
    };
    const byte_pointer = types.RawPtr{
        .mut = false,
        .pointee = .{ .prim = .u8 },
    };
    // Inference resolves wildcard cast targets in this table in place.
    var types_store = [_]types.Type{
        .{ .prim = .u64 },
        .{ .raw_ptr = &wildcard_pointer },
        .{ .raw_ptr = &byte_pointer },
        .{ .prim = .unit },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .path = .{
                .def = 10,
                .generic_args = &.{},
            } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .unary = .{
                .op = .{ .ref = .shared },
                .operand = 0,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = 1,
            .kind = .{ .cast = .{
                .kind = .as_,
                .operand = 1,
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = 1,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = 2,
            .kind = .{ .cast = .{
                .kind = .as_,
                .operand = 2,
                .source_type = .{ .raw_ptr = &wildcard_pointer },
                .target = 2,
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 3 },
    }};
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = types_store[3],
            .body = 4,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);
    // `&value as *const _` is the pointer `value` already had, so the wildcard
    // resolves to the operand's own pointee — the `u64` the chain walks over
    // before it narrows to bytes. Reading the destination instead would state
    // `*const u8` as the source of a `*const u64` value, and the two would
    // contradict each other the moment anything types the operand.
    const resolved = exprs_store[3].kind.cast.source_type;
    try std.testing.expect(resolved == .raw_ptr);
    try std.testing.expect(!resolved.raw_ptr.mut);
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, resolved.raw_ptr.pointee);
    try std.testing.expectEqual(@as(?exprs.TypeId, 2), inferred.getType(3));
}

/// `&mut bytes as *mut [MaybeUninit<u8>; N]` — the operand's reference already
/// carries a number and the destination spells the same length as the
/// constant's own expression, the shape `Buffer::format` writes in itoa.
const ConstLengthCastFixture = struct {
    types: [5]types.Type,
    exprs: [5]exprs.Expr,
    stmts: [1]exprs.Statement,
    bodies: [4]bodies.BodyKind,

    /// `operand_length` is the number the operand's array carries and
    /// `declared_length` the number `const N: usize = declared_length;` holds.
    /// Every table is arena-owned and lives as long as the caller's arena.
    fn build(
        alloc: std.mem.Allocator,
        operand_length: u64,
        declared_length: i128,
    ) !ConstLengthCastFixture {
        const usize_type: types.Type = .{ .prim = .usize };
        const unit_type: types.Type = .{ .prim = .unit };
        const maybe_uninit: types.Type = .{ .external_nominal = .{
            .path = &.{ "core", "mem", "MaybeUninit" },
            .args = &.{.{ .prim = .u8 }},
        } };
        const operand_array = try alloc.create(types.Array);
        operand_array.* = .{ .elem = maybe_uninit, .len = .{ .literal = operand_length } };
        // The destination's spelling: the length is the constant's expression.
        const spelled_array = try alloc.create(types.Array);
        spelled_array.* = .{ .elem = maybe_uninit, .len = .{ .expression = 0 } };
        const destination = try alloc.create(types.RawPtr);
        destination.* = .{ .mut = true, .pointee = .{ .array = spelled_array } };
        const borrow = try alloc.create(types.Ref);
        borrow.* = .{ .mut = true, .pointee = .{ .array = operand_array } };
        const borrow_type: types.Type = .{ .reference = borrow };

        return .{
            .types = .{
                usize_type,
                unit_type,
                .{ .raw_ptr = destination },
                .{ .array = operand_array },
                borrow_type,
            },
            .exprs = .{
                // 0 `N` — the length's own expression node.
                .{ .id = 0, .span = span, .ty = null, .kind = .{ .path = .{
                    .def = 1,
                    .generic_args = &.{},
                } } },
                // 1 the initializer the constant declares.
                .{
                    .id = 1,
                    .span = span,
                    .ty = 0,
                    .kind = .{ .literal = .{ .int = .{
                        .text = "40",
                        .value = declared_length,
                        .base = .dec,
                        .ty_suffix = null,
                    } } },
                },
                // 2 `self.bytes`, a field whose own type holds the number.
                .{ .id = 2, .span = span, .ty = 4, .kind = .{ .path = .{
                    .def = 2,
                    .generic_args = &.{},
                } } },
                // 3 the cast itself.
                .{
                    .id = 3,
                    .span = span,
                    .ty = 2,
                    .kind = .{ .cast = .{
                        .kind = .as_,
                        .operand = 2,
                        .source_type = borrow_type,
                        .target = 2,
                    } },
                },
                .{ .id = 4, .span = span, .ty = null, .kind = .{ .block = .{
                    .statements = &.{0},
                    .tail = null,
                    .labelled = null,
                } } },
            },
            .stmts = .{.{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 3 } }},
            .bodies = .{
                .none,
                .{ .const_ = .{ .ty = usize_type, .init = 1 } },
                .none,
                .{ .fn_ = .{ .params = &.{}, .ret = unit_type, .body = 4 } },
            },
        };
    }
};

test "a destination whose array length names a constant carries that constant's value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try ConstLengthCastFixture.build(alloc, 40, 40);
    const b: bodies.Bodies = .{
        .exprs = &fixture.exprs,
        .stmts = &fixture.stmts,
        .pats = &.{},
        .types = &fixture.types,
        .bodies = &fixture.bodies,
    };

    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);
    inferred.apply(&fixture.exprs);

    // Both spellings are one type, so the destination the crate publishes names
    // the one length `const I128_MAX_LEN: usize = 40;` states and the cast is
    // pinned to that row.
    const published = fixture.types[2];
    try std.testing.expect(published == .raw_ptr);
    try std.testing.expect(published.raw_ptr.mut);
    try std.testing.expect(published.raw_ptr.pointee == .array);
    try std.testing.expectEqual(
        types.ArrayLen{ .literal = 40 },
        published.raw_ptr.pointee.array.len,
    );
    try std.testing.expectEqual(@as(?exprs.TypeId, 2), inferred.getType(3));
}

test "a destination whose constant declares a different length is still refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Restoring the number the declaration carries is not a licence to agree
    // with the operand: this constant says 41 while the operand is a
    // `[MaybeUninit<u8>; 40]`, and no rule makes those the same array.
    var fixture = try ConstLengthCastFixture.build(alloc, 40, 41);
    const b: bodies.Bodies = .{
        .exprs = &fixture.exprs,
        .stmts = &fixture.stmts,
        .pats = &.{},
        .types = &fixture.types,
        .bodies = &fixture.bodies,
    };

    if (infer.solve(alloc, &b)) |inferred| {
        var accepted = inferred;
        defer accepted.deinit(alloc);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.InvalidCast, err);
    }
}

test "a wildcard scalar cast target resolves from the destination annotation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Types:
    //   0 = u32      — the `n` operand
    //   1 = `_`      — the wildcard `as _` destination placeholder
    //   2 = usize    — the `let` annotation that pins the destination
    const types_store = try alloc.alloc(types.Type, 3);
    types_store[0] = .{ .prim = .u32 };
    types_store[1] = .{ .external_nominal = .{ .path = &.{"_"} } };
    types_store[2] = .{ .prim = .usize };

    // Exprs:
    //   0 = path(def=7)      — `n`
    //   1 = `n as _`         — cast whose target is the placeholder
    //   2 = path(def=8)      — `x`
    //   3 = fn body block
    const exprs_store = try alloc.alloc(exprs.Expr, 4);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = 1,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 0,
            .source_type = .{ .prim = .u32 },
            .target = 1,
        } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = 2,
        .kind = .{ .path = .{ .def = 8, .generic_args = &.{} } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{0},
            .tail = 2,
            .labelled = null,
        } },
    };

    // Stmts:
    //   0 = `let x: usize = n as _;`
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = 2,
        .kind = .{ .let = .{ .pattern = 0, .init = 1, .ty = 2 } },
    }};
    const pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "x",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    }};
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .usize },
            .body = 3,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);

    // The cast itself takes the annotated destination type.
    try std.testing.expectEqual(@as(exprs.TypeId, 2), inferred.getType(1).?);

    // The driver writes the solved types back onto the exprs, so a cast must
    // end up pointing at the same entry as its own `ty`. Repointing the target
    // keeps that invariant; leaving it on the placeholder slot breaks it.
    inferred.apply(exprs_store);
    try std.testing.expectEqual(exprs_store[1].ty.?, exprs_store[1].kind.cast.target);
    // The destination is the annotated type, so no `_` survives into the
    // backend through the cast.
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        b.types[exprs_store[1].kind.cast.target],
    );
}

test "a wildcard scalar cast target with no constraining destination still rejects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Types:
    //   0 = u32      — the `n` operand
    //   1 = `_`      — the wildcard `as _` destination placeholder
    //   2 = unit     — the fn return
    const types_store = try alloc.alloc(types.Type, 3);
    types_store[0] = .{ .prim = .u32 };
    types_store[1] = .{ .external_nominal = .{ .path = &.{"_"} } };
    types_store[2] = .{ .prim = .unit };

    // `n as _;` as a bare expression statement: nothing constrains the
    // destination, so the placeholder must not silently become the source.
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = 1,
            .kind = .{ .cast = .{
                .kind = .as_,
                .operand = 0,
                .source_type = .{ .prim = .u32 },
                .target = 1,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = 1 },
    }};
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 2,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_store,
        .bodies = &bodies_store,
    };

    try std.testing.expectError(error.InvalidCast, infer.solve(alloc, &b));
}

// ── Borrow of a local array literal ────────────────────────────────────────

/// Expr-table layout shared by the borrow-constraining fixtures:
///   0 = `[0; 4]`
///   1 = its repeated `0` element
///   2 = the `out` path
///   3 = `&mut out` (or `&mut [0; 4]`)
///   4 = the `callee(...)` call
///   5 = the tested function's body block
///   6 = the callee's empty body block
const borrow_array_node: exprs.NodeId = 0;
const borrow_element_node: exprs.NodeId = 1;
const borrow_path_node: exprs.NodeId = 2;
const borrow_call_node: exprs.NodeId = 4;
const borrow_body_node: exprs.NodeId = 5;

/// Whether the call borrows the `out` binding or the array literal itself.
const ArrayArgument = enum { borrow_of_local, direct_literal };

/// How the callee's `&mut [T]` parameter is modelled. The frontend lowers
/// `&mut [T]` to a mutable slice; the reference form is what a `&[T; N]`
/// parameter carries instead.
const BorrowParameter = enum { mutable_slice, reference_to_slice };

const BorrowFixture = struct {
    types: std.ArrayListUnmanaged(types.Type),
    inferred: infer.Inferred,

    fn deinit(self: *BorrowFixture, alloc: std.mem.Allocator) void {
        self.inferred.deinit(alloc);
        self.types.deinit(alloc);
        self.* = undefined;
    }

    /// The type the solver settled on for `node`, read back out of the
    /// interned type table the frontend materializes derived types into.
    fn typeOf(self: *const BorrowFixture, node: exprs.NodeId) !types.Type {
        const type_id = self.inferred.getType(node) orelse return error.MissingInferredType;
        return self.types.items[type_id];
    }
};

/// Build a one-statement function whose only call passes an array to a callee
/// declared `out: &mut [T]`. `let mut out = [0; 4];` names no element type, so
/// the parameter is the only source for it — which is the Rust rule that an
/// integer literal's `i32` fallback is filtered by the expected type.
fn buildBorrowFixture(
    alloc: std.mem.Allocator,
    argument: ArrayArgument,
    parameter: BorrowParameter,
    element: types.Prim,
) !BorrowFixture {
    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = false, .elem = .{ .prim = element } };
    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = true, .pointee = .{ .slice = slice } };
    const parameter_type: types.Type = switch (parameter) {
        .mutable_slice => .{ .slice = slice },
        .reference_to_slice => .{ .reference = reference },
    };

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer types_list.deinit(alloc);
    try types_list.appendSlice(alloc, &.{
        .{ .prim = .u8 },
        .{ .prim = .u16 },
        .{ .prim = .unit },
        .{ .slice = slice },
        .{ .reference = reference },
    });

    var exprs_store = [_]exprs.Expr{
        .{
            .id = borrow_array_node,
            .span = span,
            .ty = null,
            .kind = .{ .array = .{ .elements = &.{borrow_element_node}, .repeat = 4 } },
        },
        .{
            .id = borrow_element_node,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "0",
                .value = 0,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        // Without a crate graph `bindPattern` keys locals by pattern index,
        // so `out` is def 0 and its initializer is the `[0; 4]` node.
        .{
            .id = borrow_path_node,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = 0, .generic_args = &.{} } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .unary = .{
                .op = .{ .ref = .mutable },
                .operand = if (argument == .direct_literal) borrow_array_node else borrow_path_node,
            } },
        },
        .{
            .id = borrow_call_node,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = 0 }, .args = &.{3} } },
        },
        .{
            .id = borrow_body_node,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = if (argument == .direct_literal)
                    all_statements[1..]
                else
                    all_statements[0..],
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    // `let mut out = [0; 4];` precedes the call only when the call borrows it.
    var pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "out",
            .mode = .{ .value = {} },
            .mutable = true,
        } },
    }};
    const stmts_store = [_]exprs.Statement{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .let = .{
                .pattern = 0,
                .init = borrow_array_node,
                .ty = null,
            } },
        },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = borrow_call_node } },
    };
    const callee_params = [_]items.Param{.{
        .name = "out",
        .ty = parameter_type,
        .span = span,
    }};
    const bodies_store = [_]bodies.BodyKind{
        .{
            .fn_ = .{
                .params = &callee_params,
                .ret = .{ .prim = .unit },
                .body = 6,
            },
        },
        .{
            .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = .unit },
                .body = borrow_body_node,
            },
        },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &pats_store, &generated);
    b.types = types_list.items;
    return .{
        .types = types_list,
        .inferred = try infer.solveWithGen(alloc, &b, &generated),
    };
}

/// Statement ids for the tested body; the `let` is dropped when the call takes
/// the array literal directly and has no binding to borrow.
const all_statements = [_]exprs.NodeId{ 0, 1 };

fn expectArrayType(ty: types.Type, element: types.Prim, len: u64) !void {
    const array = switch (ty) {
        .array => |array| array,
        else => return error.NotAnArrayType,
    };
    try std.testing.expectEqual(types.Type{ .prim = element }, array.elem);
    const actual_len = switch (array.len) {
        .literal => |literal| literal,
        else => return error.NotALiteralArrayLen,
    };
    try std.testing.expectEqual(len, actual_len);
}

test "borrowing a local array into a &mut [u8] parameter types the literal's element as u8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try buildBorrowFixture(alloc, .borrow_of_local, .mutable_slice, .u8);
    defer fixture.deinit(alloc);

    try expectArrayType(try fixture.typeOf(borrow_array_node), .u8, 4);
    try expectArrayType(try fixture.typeOf(borrow_path_node), .u8, 4);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, try fixture.typeOf(borrow_element_node));
}

test "a &mut [u8] parameter bound directly to an array literal keeps its u8 element" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try buildBorrowFixture(alloc, .direct_literal, .mutable_slice, .u8);
    defer fixture.deinit(alloc);

    try expectArrayType(try fixture.typeOf(borrow_array_node), .u8, 4);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, try fixture.typeOf(borrow_element_node));
}

test "a &mut [u16] parameter types the borrowed local's element as u16" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try buildBorrowFixture(alloc, .borrow_of_local, .mutable_slice, .u16);
    defer fixture.deinit(alloc);

    try expectArrayType(try fixture.typeOf(borrow_array_node), .u16, 4);
    try expectArrayType(try fixture.typeOf(borrow_path_node), .u16, 4);
    try std.testing.expectEqual(types.Type{ .prim = .u16 }, try fixture.typeOf(borrow_element_node));
}

test "a &mut [u8] reference parameter types the borrowed local's element as u8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try buildBorrowFixture(alloc, .borrow_of_local, .reference_to_slice, .u8);
    defer fixture.deinit(alloc);

    try expectArrayType(try fixture.typeOf(borrow_array_node), .u8, 4);
    try expectArrayType(try fixture.typeOf(borrow_path_node), .u8, 4);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, try fixture.typeOf(borrow_element_node));
}

test "a generic callee's concrete &mut [u8] parameter types the borrowed local's element as u8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `fn callee<T>(input: T, out: &mut [u8])` borrows exactly like the
    // non-generic fixtures, but `T` must be bound before the second argument
    // can be matched. A generic callee that gives up on an argument inference
    // has not typed would leave the array literal untyped, which is how
    // `hex::encode_to_slice` reached the backend without an element type.
    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = false, .elem = .{ .prim = .u8 } };
    const type_param: types.Type = .{ .path = .{
        .segments = &.{.{ .name = "T", .id = null }},
    } };
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer types_list.deinit(alloc);
    try types_list.appendSlice(alloc, &.{
        .{ .prim = .u8 },
        .{ .prim = .unit },
        .{ .slice = slice },
        type_param,
    });
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .array = .{ .elements = &.{1}, .repeat = 4 } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "0",
                .value = 0,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = 0, .generic_args = &.{} } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .unary = .{ .op = .{ .ref = .mutable }, .operand = 2 } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "1u8",
                .value = 1,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 5,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = 0 }, .args = &.{ 4, 3 } } },
        },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{ 0, 1 },
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 7,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
        },
    };
    var pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "out",
            .mode = .{ .value = {} },
            .mutable = true,
        } },
    }};
    var stmts_store = [_]exprs.Statement{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .let = .{ .pattern = 0, .init = 0, .ty = null } },
        },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 5 } },
    };
    const callee_params = [_]items.Param{
        .{ .name = "input", .ty = type_param, .span = span },
        .{ .name = "out", .ty = .{ .slice = slice }, .span = span },
    };
    const callee_generic_params = [_][]const u8{"T"};
    const bodies_store = [_]bodies.BodyKind{
        .{
            .fn_ = .{
                .params = &callee_params,
                .ret = .{ .prim = .unit },
                .generic_params = &callee_generic_params,
                .body = 7,
            },
        },
        .{
            .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = .unit },
                .body = 6,
            },
        },
    };
    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &pats_store, &generated);
    b.types = types_list.items;
    var inferred = try infer.solveWithGen(alloc, &b, &generated);
    defer inferred.deinit(alloc);

    const array_id = inferred.getType(0) orelse return error.MissingInferredType;
    const array = switch (types_list.items[array_id]) {
        .array => |array| array,
        else => return error.NotAnArrayType,
    };
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, array.elem);
    const element_id = inferred.getType(1) orelse return error.MissingInferredType;
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, types_list.items[element_id]);
}

// ── Typing across a comparison ──────────────────────────────────────────────

/// Expr-table layout shared by the nested-call fixtures:
///   0 = `1u8`, the first argument of `f`
///   1 = `0u8`, the argument of `g`
///   2 = `g(0u8)`, nested in `f`'s argument list
///   3 = `f(1u8, g(0u8))`
///   4 = the tested function's body block
///   5 = `g`'s empty body block
///   6 = `f`'s empty body block
const nested_call_node: exprs.NodeId = 2;

const NestedCallFixture = struct {
    types: std.ArrayListUnmanaged(types.Type),
    inferred: infer.Inferred,

    fn deinit(self: *NestedCallFixture, alloc: std.mem.Allocator) void {
        self.inferred.deinit(alloc);
        self.types.deinit(alloc);
        self.* = undefined;
    }

    fn typeOf(self: *const NestedCallFixture, node: exprs.NodeId) !types.Type {
        const type_id = self.inferred.getType(node) orelse return error.MissingInferredType;
        return self.types.items[type_id];
    }
};

/// Build a body whose only statement nests `g(0u8)` inside `f(..)`, with `g`
/// declared `-> ret` over `callee_generics`. A call in argument position
/// receives no expected type from the caller's signature unless that
/// signature names a concrete one, so `g`'s own declaration is the only
/// source for the nested call's type. `ret` stays out of the interned type
/// table: a declared return type that is still a type parameter is not a
/// resolved type, and interning it would make it look like one.
fn buildNestedCallFixture(
    alloc: std.mem.Allocator,
    ret: types.Type,
    callee_generics: []const []const u8,
) !NestedCallFixture {
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer types_list.deinit(alloc);
    try types_list.appendSlice(alloc, &.{ .{ .prim = .u8 }, .{ .prim = .u16 } });

    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "1u8",
                .value = 1,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "0u8",
                .value = 0,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = 0 }, .args = &.{1} } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = 2 }, .args = &.{ 0, nested_call_node } } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 5,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
        },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
        },
    };
    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 3 } },
    };
    const callee_params = [_]items.Param{
        .{ .name = "x", .ty = .{ .prim = .u8 }, .span = span },
    };
    const caller_params = [_]items.Param{
        .{ .name = "a", .ty = .{ .prim = .u8 }, .span = span },
        .{ .name = "b", .ty = ret, .span = span },
    };
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{ .params = &callee_params, .ret = ret, .generic_params = callee_generics, .body = 5 } },
        .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 4 } },
        .{ .fn_ = .{ .params = &caller_params, .ret = .{ .prim = .unit }, .body = 6 } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &.{}, &generated);
    b.types = types_list.items;
    return .{
        .types = types_list,
        .inferred = try infer.solveWithGen(alloc, &b, &generated),
    };
}

test "a call in argument position takes the callee's declared u16 return type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `g` returns a concrete `u16`, so `f(1u8, g(0u8))` types the nested call
    // even though no signature passes a type into that position.
    var fixture = try buildNestedCallFixture(alloc, .{ .prim = .u16 }, &.{});
    defer fixture.deinit(alloc);

    try std.testing.expectEqual(types.Type{ .prim = .u16 }, try fixture.typeOf(nested_call_node));
}

/// Expr-table layout shared by the `assert_eq!` fixtures, which model
/// `assert_eq!(from_hex(0u8), Ok([1, 2, 3, 4, 5, 6]))`:
///   0     = the `[1, 2, 3, 4, 5, 6]` array literal
///   1     = `Ok(<array>)`
///   2     = `0u8`, the call's argument
///   3     = `from_hex(0u8)`
///   4     = the `==` comparison
///   5     = the `assert_eq!` marker, which names node 4
///   6     = the tested function's body block
///   7     = `from_hex`'s empty body block
///   8..13 = the array's six unsuffixed integer literals
const comparison_array_node: exprs.NodeId = 0;
const comparison_ok_node: exprs.NodeId = 1;

const ComparisonFixture = struct {
    types: std.ArrayListUnmanaged(types.Type),
    inferred: infer.Inferred,

    fn deinit(self: *ComparisonFixture, alloc: std.mem.Allocator) void {
        self.inferred.deinit(alloc);
        self.types.deinit(alloc);
        self.* = undefined;
    }

    fn typeOf(self: *const ComparisonFixture, node: exprs.NodeId) !types.Type {
        const type_id = self.inferred.getType(node) orelse return error.MissingInferredType;
        return self.types.items[type_id];
    }
};

/// Assert the node carries a `Result` whose `Ok` payload is `[element; len]`.
fn expectResultArray(ty: types.Type, element: types.Prim, len: u64) !void {
    const result = switch (ty) {
        .result => |value| value,
        else => return error.NotAResultType,
    };
    try expectArrayType(result.ok, element, len);
}

/// Build the `assert_eq!` fixture with `from_hex` declared
/// `-> Result<[element; 6], FromHexError>`. `Ok(..)` states nothing about its
/// payload, so the array literal can only be typed from the `Result` the call
/// it is compared against declares.
fn buildComparisonFixture(
    alloc: std.mem.Allocator,
    element: types.Prim,
) !ComparisonFixture {
    const array = try alloc.create(types.Array);
    array.* = .{ .elem = .{ .prim = element }, .len = .{ .literal = 6 } };
    const payload = types.Result{
        .ok = .{ .array = array },
        .err = .{ .external_nominal = .{ .path = &.{"FromHexError"} } },
        .is_error_unionable = true,
    };
    const result = try alloc.create(types.Result);
    result.* = payload;

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer types_list.deinit(alloc);
    try types_list.appendSlice(alloc, &.{
        .{ .prim = .u8 },
        .{ .prim = .unit },
        .{ .result = result },
    });

    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .array = .{ .elements = &.{ 8, 9, 10, 11, 12, 13 }, .repeat = null } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .enum_variant = .{
                .def = 2,
                .variant = "Ok",
                .tuple_fields = &.{0},
                .named_fields = &.{},
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "0u8",
                .value = 0,
                .base = .dec,
                .ty_suffix = "u8",
            } } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .free = 0 }, .args = &.{2} } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .binary = .{ .op = .eq, .overflow = .wrapping, .lhs = 3, .rhs = 1 } },
        },
        .{
            .id = 5,
            .span = span,
            .ty = null,
            .kind = .{ .unsupported = .{ .reason = "assertion:4", .suggested_version = .v1 } },
        },
        .{
            .id = 6,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 7,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
        },
    } ++ [_]exprs.Expr{
        .{
            .id = 8,
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
            .id = 9,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "2",
                .value = 2,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 10,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "3",
                .value = 3,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 11,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "4",
                .value = 4,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 12,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "5",
                .value = 5,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 13,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "6",
                .value = 6,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
    };
    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 5 } },
    };
    const callee_params = [_]items.Param{
        .{ .name = "hex", .ty = .{ .prim = .u8 }, .span = span },
    };
    const variant_params = [_]types.Type{
        .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } },
    };
    const result_variants = [_]items.Variant{.{
        .name = "Ok",
        .fields = .{ .tuple = &variant_params },
        .discriminant = null,
    }};
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{ .params = &callee_params, .ret = .{ .result = result }, .body = 7 } },
        .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 6 } },
        .{ .enum_ = .{ .kind = .data, .variants = &result_variants } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &.{}, &generated);
    b.types = types_list.items;
    return .{
        .types = types_list,
        .inferred = try infer.solveWithGen(alloc, &b, &generated),
    };
}

test "an Ok(array) compared against Result<[u8; 6], E> types the array as [u8; 6]" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // This is the shape `hex::test_from_hex_array` reaches through
    // `assert_eq!(<[u8; 6] as FromHex>::from_hex(..), Ok([0x66, ..]))`: the
    // comparison yields `bool`, so the only type the `Ok` payload can take is
    // the one the call declares.
    var fixture = try buildComparisonFixture(alloc, .u8);
    defer fixture.deinit(alloc);

    try expectResultArray(try fixture.typeOf(comparison_ok_node), .u8, 6);
    try expectArrayType(try fixture.typeOf(comparison_array_node), .u8, 6);
}

test "the Ok(array) payload type follows the compared Result's element type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The same source shape with a `[u16; 6]` payload: the element type is
    // carried by the compared operand, never fixed by `Ok` itself.
    var fixture = try buildComparisonFixture(alloc, .u16);
    defer fixture.deinit(alloc);

    try expectResultArray(try fixture.typeOf(comparison_ok_node), .u16, 6);
    try expectArrayType(try fixture.typeOf(comparison_array_node), .u16, 6);
}

/// `receiver.chunks(2).enumerate()` — the shape `hex::from_hex` reaches at
/// `hex.chunks(2).enumerate().map(..).collect()`:
///   0 = the receiver path
///   1 = the `2` chunk-size argument
///   2 = `chunks(2)`
///   3 = `enumerate()`
///   4 = the tested function's body block
const chunks_receiver_node: exprs.NodeId = 0;
const chunks_call_node: exprs.NodeId = 2;
const chunks_enumerate_node: exprs.NodeId = 3;

/// The body block reaches the two calls through statements, not directly.
const chunks_call_stmt: exprs.NodeId = 0;
const chunks_enumerate_stmt: exprs.NodeId = 1;

const ChunksFixture = struct {
    graph: ir.graph.CrateGraph,
    types: std.ArrayListUnmanaged(types.Type),
    inferred: infer.Inferred,

    fn deinit(self: *ChunksFixture, alloc: std.mem.Allocator) void {
        self.inferred.deinit(alloc);
        self.types.deinit(alloc);
        self.graph.deinit();
        self.* = undefined;
    }

    fn typeOf(self: *const ChunksFixture, node: exprs.NodeId) !types.Type {
        const type_id = self.inferred.getType(node) orelse return error.MissingInferredType;
        return self.types.items[type_id];
    }

    /// The type the node ended up with, or null when inference left it
    /// untyped. A `chunks` receiver outside the slice whitelist must stay
    /// here, never in `typeOf`'s error.
    fn typeOrNull(self: *const ChunksFixture, node: exprs.NodeId) ?types.Type {
        const type_id = self.inferred.getType(node) orelse return null;
        return self.types.items[type_id];
    }
};

/// Assert `ty` is the `core::slice::<name><element>` chunked-slice carrier.
fn expectSliceChunkCarrier(
    ty: types.Type,
    name: []const u8,
    element: types.Prim,
) !void {
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return error.NotAnExternalNominalType,
    };
    try std.testing.expectEqual(@as(usize, 3), external.path.len);
    try std.testing.expectEqualStrings("core", external.path[0]);
    try std.testing.expectEqualStrings("slice", external.path[1]);
    try std.testing.expectEqualStrings(name, external.path[2]);
    try std.testing.expectEqual(@as(usize, 1), external.args.len);
    const expected: types.Type = .{ .prim = element };
    try std.testing.expectEqual(expected, external.args[0]);
}

/// Assert `ty` is `core::iter::Enumerate<core::slice::Chunks<element>>`, the
/// receiver type `.enumerate()` hands to the next call in the chain.
fn expectEnumerateOfChunks(ty: types.Type, element: types.Prim) !void {
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return error.NotAnExternalNominalType,
    };
    try std.testing.expectEqual(@as(usize, 3), external.path.len);
    try std.testing.expectEqualStrings("core", external.path[0]);
    try std.testing.expectEqualStrings("iter", external.path[1]);
    try std.testing.expectEqualStrings("Enumerate", external.path[2]);
    try std.testing.expectEqual(@as(usize, 1), external.args.len);
    try expectSliceChunkCarrier(external.args[0], "Chunks", element);
}

/// Build `receiver.chunks(2).enumerate()` with `receiver` as the receiver
/// node's declared type. The element follows the receiver, so one builder
/// serves the plain-slice, `&[T]` and non-slice cases.
fn buildChunksFixture(alloc: std.mem.Allocator, receiver: types.Type) !ChunksFixture {
    var graph = ir.graph.CrateGraph.init(alloc);
    errdefer graph.deinit();
    const chunks_ent = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "chunks"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const enumerate_ent = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "enumerate"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Type 0 is the receiver; type 1 is the tested function's `()` return.
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer types_list.deinit(alloc);
    try types_list.appendSlice(alloc, &.{ receiver, .{ .prim = .unit } });

    // The receiver def names no entity, so only its declared type is read.
    const recv_def: exprs.DefId = @intCast(graph.symbol_table.count());
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .path = .{ .def = recv_def, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "2",
                .value = 2,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = chunks_receiver_node,
                .receiver_mode = .shared,
                .method = chunks_ent,
                .args = &.{1},
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = chunks_call_node,
                .receiver_mode = .value,
                .method = enumerate_ent,
                .args = &.{},
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{ chunks_call_stmt, chunks_enumerate_stmt },
                .tail = null,
                .labelled = null,
            } },
        },
    };
    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = chunks_call_node } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = chunks_enumerate_node } },
    };
    var bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 4 } },
    };

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.genWithGraph(alloc, &b, &graph);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &.{}, &generated);
    b.types = types_list.items;
    return .{
        .graph = graph,
        .types = types_list,
        .inferred = try infer.solveWithGen(alloc, &b, &generated),
    };
}

test "slice.chunks(n) infers core::slice::Chunks<T> and types its .enumerate() receiver" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A bare `[u8]`: the element comes off the slice itself, so the carrier is
    // `Chunks<u8>` and the chained `.enumerate()` sees a typed receiver.
    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    var fixture = try buildChunksFixture(alloc, .{ .slice = slice });
    defer fixture.deinit(alloc);

    try expectSliceChunkCarrier(try fixture.typeOf(chunks_call_node), "Chunks", .u8);
    try expectEnumerateOfChunks(try fixture.typeOf(chunks_enumerate_node), .u8);
}

test "a &[T] receiver infers the same core::slice::Chunks<T> a bare [T] does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `&[T]` must reach the same element as `[T]`: the reference is peeled
    // before the carrier is named, and mutability must not change the result.
    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = false, .elem = .{ .prim = .u8 } };
    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = .{ .slice = slice } };
    var fixture = try buildChunksFixture(alloc, .{ .reference = reference });
    defer fixture.deinit(alloc);

    try expectSliceChunkCarrier(try fixture.typeOf(chunks_call_node), "Chunks", .u8);
    try expectEnumerateOfChunks(try fixture.typeOf(chunks_enumerate_node), .u8);
}

test "chunks infers nothing for a receiver that is not a slice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `core::option::Option<u8>` is a three-segment external nominal with one
    // generic argument, the shape a `chunks` whitelist keyed on arity alone
    // would swallow. Nothing may be inferred, so the whole chain stays
    // untyped instead of inventing a `Chunks<u8>`.
    var fixture = try buildChunksFixture(alloc, .{ .external_nominal = .{
        .path = &.{ "core", "option", "Option" },
        .args = &.{.{ .prim = .u8 }},
    } });
    defer fixture.deinit(alloc);

    try std.testing.expectEqual(@as(?types.Type, null), fixture.typeOrNull(chunks_call_node));
    try std.testing.expectEqual(@as(?types.Type, null), fixture.typeOrNull(chunks_enumerate_node));
}

// ── `as _` in a struct-literal field ────────────────────────────────────────

/// Expr-table layout shared by the wildcard-field fixtures, modelling
/// ```rust
/// pub struct Buf<T> { pub off: usize }
/// pub fn go(n: u32) -> Buf<u8> { Buf { off: n as _ } }
/// ```
///   0 = `n`, the `u32` parameter the cast reads
///   1 = `n as _`, a wildcard cast sitting in a struct-literal field
///   2 = `Buf { off: n as _ }`, a literal of a generic struct
///   3 = `go`'s body block, whose tail is the literal
const wildcard_field_cast_node: exprs.NodeId = 1;

const WildcardFieldFixture = struct {
    types: std.ArrayListUnmanaged(types.Type),
    exprs_store: []exprs.Expr,
    inferred: infer.Inferred,

    fn deinit(self: *WildcardFieldFixture, alloc: std.mem.Allocator) void {
        self.inferred.deinit(alloc);
        alloc.free(self.exprs_store);
        self.types.deinit(alloc);
        self.* = undefined;
    }

    fn typeOf(self: *const WildcardFieldFixture, node: exprs.NodeId) !types.Type {
        const type_id = self.inferred.getType(node) orelse return error.MissingInferredType;
        return self.types.items[type_id];
    }
};

/// Build the `Buf<T> { off: source as _ }` fixture with `off` declared
/// `field_ty` and the cast operand of primitive `source_prim`. The declared
/// field type is the wildcard's only destination, so this is what decides the
/// cast's target.
fn buildWildcardFieldFixture(
    alloc: std.mem.Allocator,
    field_ty: types.Type,
    source_prim: types.Prim,
) !WildcardFieldFixture {
    // Type table: 0 = the operand's type, 1 = the `as _` placeholder,
    // 2 = the field's declared type, 3 = `Buf<u8>`, the declared return type.
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    errdefer types_list.deinit(alloc);
    try types_list.appendSlice(alloc, &.{
        .{ .prim = source_prim },
        .{ .external_nominal = .{ .path = &.{"_"}, .args = &.{} } },
        field_ty,
        .{ .generic_inst = .{ .decl = 0, .args = .{ .params = &.{.{ .prim = .u8 }} } } },
    });

    // The table outlives this frame: the caller reads the cast the solver
    // wrote back off it after the builder returns, and `deinit` is what frees
    // it, so it is owned rather than borrowed from this stack frame.
    const exprs_store = try alloc.alloc(exprs.Expr, 4);
    errdefer alloc.free(exprs_store);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = 1,
        .kind = .{ .cast = .{
            .kind = .as_,
            .operand = 0,
            .source_type = .{ .unsupported = .{
                .reason = .iterators,
                .message = "cast source type pending inference",
                .span = span,
            } },
            .target = 1,
        } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .struct_lit = .{
            .def = 0,
            .fields = &.{.{ .field = "off", .value = 1, .shorthand = false }},
            .base = null,
        } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 2,
            .labelled = null,
        } },
    };

    var stmts_store = [_]exprs.Statement{};
    const struct_fields = [_]items.Field{
        .{ .name = "off", .ty = field_ty, .visibility = .public, .span = span },
    };
    const fn_params = [_]items.Param{
        .{ .name = "n", .ty = .{ .prim = source_prim }, .span = span },
    };
    var bodies_store = [_]bodies.BodyKind{
        .{ .struct_ = .{
            .generic_params = &.{"T"},
            .trait_bounds = &.{},
            .layout = .named,
            .fields = &struct_fields,
            .methods = &.{},
        } },
        .{ .fn_ = .{
            .params = &fn_params,
            .ret = types_list.items[3],
            .body = 3,
        } },
    };

    var b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &.{}, &generated);
    b.types = types_list.items;
    b.exprs = exprs_store;
    var inferred = try infer.solveWithGen(alloc, &b, &generated);
    inferred.apply(exprs_store);
    return .{
        .types = types_list,
        .exprs_store = exprs_store,
        .inferred = inferred,
    };
}

test "a wildcard cast in a struct-literal field takes the field's declared type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `Buf<T> { off: n as _ }` with `off: usize`. Nothing at the use site
    // annotates the cast, so the field declaration is the only destination:
    // the cast must resolve to `usize` and record `u32` as its source.
    var fixture = try buildWildcardFieldFixture(alloc, .{ .prim = .usize }, .u32);
    defer fixture.deinit(alloc);

    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        try fixture.typeOf(wildcard_field_cast_node),
    );
    const cast = fixture.exprs_store[wildcard_field_cast_node].kind.cast;
    try std.testing.expectEqual(
        types.Type{ .prim = .u32 },
        cast.source_type,
    );
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        fixture.types.items[cast.target],
    );
}

test "a struct field's declared type beats the wildcard cast's source type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A field declared `u64` fed a `u8`: defaulting the destination to the
    // source type, or to any primitive of the source's class, would silently
    // emit the wrong destination. The declaration wins.
    var fixture = try buildWildcardFieldFixture(alloc, .{ .prim = .u64 }, .u8);
    defer fixture.deinit(alloc);

    try std.testing.expectEqual(
        types.Type{ .prim = .u64 },
        try fixture.typeOf(wildcard_field_cast_node),
    );
    const cast = fixture.exprs_store[wildcard_field_cast_node].kind.cast;
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, cast.source_type);
    try std.testing.expectEqual(
        types.Type{ .prim = .u64 },
        fixture.types.items[cast.target],
    );
}

test "a wildcard cast in a field whose declared type is a type parameter is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `Buf<T> { off: n as _ }` with `T` left unbound, so `off`'s declaration
    // is the symbolic `T`. A field declaration resolves a wildcard only while
    // it is concrete; one that still names a type parameter constrains
    // nothing, so the cast must stay unresolved and be refused rather than
    // pinned to a path the backend cannot emit.
    const type_param: types.Type = .{ .path = .{ .segments = &.{.{ .name = "T", .id = null }} } };
    try std.testing.expectError(
        error.InvalidCast,
        buildWildcardFieldFixture(alloc, type_param, .u32),
    );
}

// A second builder call must not overwrite the first fixture's expressions.
// Distinct source/target types make stale shared storage observable.
test "a wildcard-field fixture's expression table outlives the builder's frame" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var first = try buildWildcardFieldFixture(alloc, .{ .prim = .usize }, .u32);
    defer first.deinit(alloc);
    var second = try buildWildcardFieldFixture(alloc, .{ .prim = .u64 }, .u8);
    defer second.deinit(alloc);

    const cast = first.exprs_store[wildcard_field_cast_node].kind.cast;
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, cast.source_type);
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        try first.typeOf(wildcard_field_cast_node),
    );
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        first.types.items[cast.target],
    );

    // The second fixture is a separate object and still reads as itself.
    const second_cast = second.exprs_store[wildcard_field_cast_node].kind.cast;
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, second_cast.source_type);
    try std.testing.expectEqual(
        types.Type{ .prim = .u64 },
        second.types.items[second_cast.target],
    );
}

// Check both successful and rejected inference with allocator ownership checks.
test "a wildcard-field fixture frees only the storage it allocated" {
    const alloc = std.testing.allocator;

    var fixture = try buildWildcardFieldFixture(alloc, .{ .prim = .usize }, .u32);
    defer fixture.deinit(alloc);

    // Every read happens after the builder has returned, which is the only
    // moment a caller can see whether the table is real storage.
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        try fixture.typeOf(wildcard_field_cast_node),
    );
    const cast = fixture.exprs_store[wildcard_field_cast_node].kind.cast;
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, cast.source_type);
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        fixture.types.items[cast.target],
    );
    // The driver writes the resolved destination back onto the expression, so
    // the table the caller holds has to be the one that received it.
    try std.testing.expectEqual(
        cast.target,
        fixture.exprs_store[wildcard_field_cast_node].ty.?,
    );

    // A refused cast must not leave a half-built fixture behind either: the
    // table is built before the solve that refuses it, so the refusal has to
    // hand it back rather than keep it.
    const reference = try alloc.create(types.Ref);
    defer alloc.destroy(reference);
    reference.* = .{ .mut = false, .pointee = .{ .prim = .u64 } };
    try std.testing.expectError(
        error.InvalidCast,
        buildWildcardFieldFixture(alloc, .{ .reference = reference }, .u8),
    );
}

test "two wildcard casts sharing one placeholder slot both reach their field type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Every `as _` lowers to the same `_` entry in the type table, so both
    // casts here start out aimed at one slot. Resolving the first rewrites
    // that slot, which used to leave the second looking like a cast whose
    // destination was always concrete: it was skipped, kept the raw slot as
    // its target, and then disagreed with the type the solver wrote to it.
    // Exprs:
    //   0 = `n`, 1 = `n as _`, 2 = the first literal, 3 = the second cast,
    //   4 = the second literal, 5 = the body block
    // Types:
    //   0 = u32, 1 = `_`, 2 = usize, 3 = unit
    var types_store = [_]types.Type{
        .{ .prim = .u32 },
        .{ .external_nominal = .{ .path = &.{"_"}, .args = &.{} } },
        .{ .prim = .usize },
        .{ .prim = .unit },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = 1,
            .kind = .{ .cast = .{
                .kind = .as_,
                .operand = 0,
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = 1,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .struct_lit = .{
                .def = 0,
                .fields = &.{.{ .field = "off", .value = 1, .shorthand = false }},
                .base = null,
            } },
        },
        .{
            .id = 3,
            .span = span,
            .ty = 1,
            .kind = .{ .cast = .{
                .kind = .as_,
                .operand = 0,
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = 1,
            } },
        },
        .{
            .id = 4,
            .span = span,
            .ty = null,
            .kind = .{ .struct_lit = .{
                .def = 0,
                .fields = &.{.{ .field = "off", .value = 3, .shorthand = false }},
                .base = null,
            } },
        },
        .{
            .id = 5,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{ 0, 1 },
                .tail = null,
                .labelled = null,
            } },
        },
    };
    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 2 } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .expr = 4 } },
    };
    const struct_fields = [_]items.Field{
        .{ .name = "off", .ty = .{ .prim = .usize }, .visibility = .public, .span = span },
    };
    const fn_params = [_]items.Param{
        .{ .name = "n", .ty = .{ .prim = .u32 }, .span = span },
    };
    var bodies_store = [_]bodies.BodyKind{
        .{ .struct_ = .{
            .generic_params = &.{"T"},
            .trait_bounds = &.{},
            .layout = .named,
            .fields = &struct_fields,
            .methods = &.{},
        } },
        .{ .fn_ = .{
            .params = &fn_params,
            .ret = .{ .prim = .unit },
            .body = 5,
        } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);
    inferred.apply(exprs_store[0..]);

    // Both casts name the field's `usize`, and both end up agreeing with the
    // type the driver writes back onto them.
    for ([_]exprs.NodeId{ 1, 3 }) |cast_node| {
        const cast = exprs_store[cast_node].kind.cast;
        try std.testing.expectEqual(types.Type{ .prim = .u32 }, cast.source_type);
        try std.testing.expectEqual(
            types.Type{ .prim = .usize },
            types_store[cast.target],
        );
        try std.testing.expectEqual(cast.target, exprs_store[cast_node].ty.?);
    }
}

// ── Untyped cast operand: named refusal, not an opaque abort ───────────────

/// Expr-table layout shared by the untyped-cast-operand fixture, modelling the
/// seahash shape `tail.to_le_bytes()[..n].len() as u64`: the cast reads an
/// operand the frontend never typed, and the cast's recorded source type is
/// the frontend's own "still pending" placeholder rather than a real type.
///   0 = the operand — a path naming no entity, so nothing can type it
///   1 = the cast
///   2 = the body block
/// Types:
///   0 = u64, the cast's destination
///   1 = unit, the function return
const untyped_cast_operand_node: exprs.NodeId = 0;
const untyped_cast_node: exprs.NodeId = 1;

/// The name the frontend publishes for this refusal. `ir.validate` carries it
/// out of `error.UnsupportedExpression`, so it is what a caller actually reads
/// — which is the whole point: the old path reported `error.InvalidCast` and
/// said nothing about which expression was at fault.
const untyped_cast_operand_reason = "unresolved cast operand type";

test "a cast over an untyped operand is named, not an opaque InvalidCast" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `operand as u64` where the operand's type is unknown to the frontend.
    // There is no source type to check the destination against, so this is an
    // unresolved construct rather than a wrong one. It must be reported by
    // name, and the surrounding crate must keep going: an untyped operand
    // aborting the whole solve was the defect, not the ambiguity.
    var types_store = [_]types.Type{
        .{ .prim = .u64 },
        .{ .prim = .unit },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = span,
            .ty = null,
            .kind = .{ .cast = .{
                .kind = .as_,
                .operand = untyped_cast_operand_node,
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = 0,
            } },
        },
        .{
            .id = 2,
            .span = span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
    };
    var stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = untyped_cast_node },
    }};
    var bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 2 } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    // Without the escalation this is `error.InvalidCast`, and the test fails
    // here rather than ever reaching the marker below.
    var inferred = try infer.solve(alloc, &b);
    defer inferred.deinit(alloc);

    const marker = switch (exprs_store[untyped_cast_node].kind) {
        .unsupported => |unsupported| unsupported,
        else => return error.ExpectedUntypedCastMarker,
    };
    try std.testing.expectEqualStrings(untyped_cast_operand_reason, marker.reason);
    try std.testing.expect(marker.suggested_version == .v1);
}

test "a wrong cast whose operand IS typed still raises InvalidCast" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The counterweight, and the one that matters: the untyped-operand escape
    // hatch must not become a hole for wrong casts. `Buf<T> { off: n as _ }`
    // with `off: &u64` and `n: u8` — the operand IS typed, the solver resolves
    // the source to `u8`, and `u8 as &u64` is a conversion this translator
    // does not admit. Generation does not record it either, because a wildcard
    // target is only resolved in this pass, so `isValidCast` is the sole gate
    // and it sits immediately after the branch the new marker precedes.
    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = .{ .prim = .u64 } };
    try std.testing.expectError(
        error.InvalidCast,
        buildWildcardFieldFixture(alloc, .{ .reference = reference }, .u8),
    );
}

/// A method call on a nominal receiver whose declared method return type is
/// the bare type parameter `T`. Nothing but a turbofish can name `T`, so any
/// concrete result the solver reaches for this call came from the turbofish.
///
/// `receiver_type` is what the receiver expression is pinned to, so a test can
/// make the receiver imply a type that disagrees with the turbofish.
const TurbofishFixture = struct {
    exprs_store: []exprs.Expr,
    types_store: []types.Type,
    bodies_store: []bodies.BodyKind,
    b: bodies.Bodies,
    graph: crate_graph.CrateGraph,
    call_node: exprs.NodeId,

    fn deinit(self: *TurbofishFixture, alloc: std.mem.Allocator) void {
        self.graph.deinit();
        const fn_body = self.bodies_store[2].fn_;
        alloc.free(fn_body.params);
        alloc.free(fn_body.generic_params);
        // The declared return is the bare parameter `T`; the segment name is
        // a string literal, so only the slice itself is owned.
        alloc.free(fn_body.ret.path.segments);
        alloc.free(self.bodies_store);
        alloc.free(self.types_store);
        alloc.free(self.exprs_store);
    }
};

fn buildTurbofishFixture(
    alloc: std.mem.Allocator,
    turbofish: []const types.Type,
    method_name: []const u8,
    receiver_type: types.Type,
) !TurbofishFixture {
    var graph = crate_graph.CrateGraph.init(alloc);
    errdefer graph.deinit();

    // 0 = module, 1 = struct `Parser` (the receiver's named type), 2 = the
    // method `read`. The method is a plain `fn_` so `getGenericParamNames`
    // reads its declared `T` and `walkMethodCall` can substitute into it.
    _ = try graph.symbol_table.add(.{
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
    const receiver_def: exprs.DefId = 1;
    _ = try graph.symbol_table.add(.{
        .id = receiver_def,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Parser"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const method_id: exprs.DefId = 2;
    _ = try graph.symbol_table.add(.{
        .id = method_id,
        .kind = .fn_,
        .name = try alloc.dupe(u8, method_name),
        .span = span,
        .visibility = .public,
        .parent = receiver_def,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try alloc.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(spine.EntityId, &.{ receiver_def, method_id }),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = try alloc.dupe(u8, "turbofish"),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    // Types: 0 = the receiver's pinned type, 1 = the turbofish argument.
    // 2 = the slice `T` would fall back to when no turbofish is present.
    const types_store = try alloc.alloc(types.Type, 3);
    types_store[0] = receiver_type;
    types_store[1] = turbofish[0];
    types_store[2] = .{ .prim = .i32 };

    const declared_return: types.Type = .{ .path = .{
        .segments = try alloc.dupe(types.PathSegment, &.{.{ .name = "T", .id = null }}),
    } };
    const exprs_store = try alloc.alloc(exprs.Expr, 3);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = receiver_def, .generic_args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = span,
        .ty = null,
        .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = method_id,
            .generic_args = turbofish,
            .args = &.{},
        } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 1,
            .labelled = null,
        } },
    };

    // The body table is indexed by EntityId, so the method's `fn_` must sit at
    // its own entity id (2), not at the front of the table.
    const bodies_store = try alloc.alloc(bodies.BodyKind, 3);
    bodies_store[0] = .none;
    bodies_store[1] = .{ .struct_ = .{} };
    bodies_store[2] = .{ .fn_ = .{
        .params = try alloc.dupe(items.Param, &.{}),
        .ret = declared_return,
        .generic_params = try alloc.dupe([]const u8, &.{"T"}),
        .body = 2,
    } };

    return .{
        .exprs_store = exprs_store,
        .types_store = types_store,
        .bodies_store = bodies_store,
        .b = .{
            .exprs = exprs_store,
            .stmts = &.{},
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_store,
        },
        .graph = graph,
        .call_node = 1,
    };
}

test "a method turbofish names the call's result type" {
    const alloc = std.testing.allocator;
    const turbofish = [_]types.Type{.{ .prim = .u32 }};
    var fixture = try buildTurbofishFixture(
        alloc,
        &turbofish,
        "read",
        .{ .prim = .u8 },
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);
    const result_id = inferred.getType(fixture.call_node) orelse
        return error.UntypedTurbofishMethodCall;
    // The declared return type is `T` and the turbofish says `u32`, so `u32`
    // is the only type the solver can have reached.
    try std.testing.expectEqual(
        types.Type{ .prim = .u32 },
        fixture.b.types[result_id],
    );
}

test "a method turbofish overrides the receiver-implied result type" {
    const alloc = std.testing.allocator;
    // The receiver is a `u8` and a `.as_bytes()`-shaped method name would make
    // the receiver drive the result; here the declared return is `T`, so the
    // only competitor is the receiver's own `u8`. Rust binds the turbofish.
    const turbofish = [_]types.Type{.{ .prim = .u32 }};
    var fixture = try buildTurbofishFixture(
        alloc,
        &turbofish,
        "read",
        .{ .prim = .u8 },
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);
    const result_id = inferred.getType(fixture.call_node) orelse
        return error.UntypedTurbofishMethodCall;
    try std.testing.expectEqual(
        types.Type{ .prim = .u32 },
        fixture.b.types[result_id],
    );
}

test "a method call without a turbofish keeps its inferred result type" {
    const alloc = std.testing.allocator;
    // No turbofish: the recorded list is empty and the walk behaves exactly as
    // it did before the field existed, leaving the call to fall through to the
    // receiver-implied type.
    var fixture = try buildTurbofishFixture(
        alloc,
        &.{.{ .prim = .u32 }},
        "read",
        .{ .prim = .u8 },
    );
    defer fixture.deinit(alloc);
    fixture.exprs_store[fixture.call_node].kind.method_call.generic_args = &.{};

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);
    // The untyped call must not borrow the turbofish that the fixture used to
    // parameterise its type table: the receiver is `u8` and that is the only
    // concrete type the walk can reach here.
    const result_id = inferred.getType(fixture.call_node);
    if (result_id) |id| {
        try std.testing.expectEqual(
            types.Type{ .prim = .u8 },
            fixture.b.types[id],
        );
    }
}

/// The receiver of `generate_iter(..).collect::<Vec<_>>()`: an OPAQUE whose
/// only bound is `Iterator`, with the element type spelled out in the bound's
/// own `associated_types` when `declare_item` is set. The recovered concrete
/// is a `u8` on purpose — a carrier that says nothing about the element, which
/// is the whole point: the bound, not the concrete, is what names it.
fn iteratorItemBoundReceiver(alloc: std.mem.Allocator, declare_item: bool) !types.Type {
    const item = try alloc.alloc(types.Type, 2);
    item[0] = .{ .prim = .usize };
    item[1] = .{ .prim = .usize };
    const bindings = try alloc.alloc(types.AssociatedTypeBinding, if (declare_item) 1 else 0);
    if (declare_item) bindings[0] = .{ .name = "Item", .ty = .{ .tuple = item } };
    const bounds = try alloc.alloc(types.Bound, 1);
    bounds[0] = .{
        .path = .{ .segments = &.{.{ .name = "Iterator", .id = null }} },
        .associated_types = bindings,
    };
    const concrete: types.Type = .{ .prim = .u8 };
    return .{ .@"opaque" = .{ .bounds = bounds, .concrete = &concrete } };
}

/// `collect::<Vec<_>>()` exactly as the frontend records it: the container is
/// named and the element is a bare inference placeholder.
fn collectElementTurbofish(alloc: std.mem.Allocator) ![]const types.Type {
    const element = try alloc.alloc(types.Type, 1);
    element[0] = .{ .external_nominal = .{ .path = &.{"_"} } };
    const container = try alloc.alloc(types.Type, 1);
    container[0] = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = element,
    } };
    return container;
}

test "a collect turbofish takes its element from the receiver's declared Item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const turbofish = try collectElementTurbofish(alloc);
    var fixture = try buildTurbofishFixture(
        alloc,
        turbofish,
        "collect",
        try iteratorItemBoundReceiver(alloc, true),
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    // The `_` is gone. `impl Iterator<Item = (usize, usize)>` is the only
    // place the element type is written down, and the container the turbofish
    // named keeps its own path and arity.
    const element = try alloc.alloc(types.Type, 2);
    element[0] = .{ .prim = .usize };
    element[1] = .{ .prim = .usize };
    const expected_args = try alloc.alloc(types.Type, 1);
    expected_args[0] = .{ .tuple = element };
    const expected: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = expected_args,
    } };
    const bound = fixture.exprs_store[fixture.call_node].kind.method_call.generic_args[0];
    try std.testing.expect(types.deepEqual(expected, bound));
}

test "a collect turbofish stays open when the opaque bound declares no Item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const turbofish = try collectElementTurbofish(alloc);
    var fixture = try buildTurbofishFixture(
        alloc,
        turbofish,
        "collect",
        try iteratorItemBoundReceiver(alloc, false),
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    // Nothing declares the element, so nothing may stand in for it. A
    // placeholder is left standing rather than filled from the concrete
    // carrier, which names a `u8` and would be a different type entirely.
    const bound = fixture.exprs_store[fixture.call_node].kind.method_call.generic_args[0];
    try std.testing.expect(types.deepEqual(turbofish[0], bound));
    try std.testing.expect(infer.isInferPlaceholderType(bound.external_nominal.args[0]));
}

test "a slice receiver collects nothing, declared Item or not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const element = try alloc.create(types.Slice);
    element.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const turbofish = try collectElementTurbofish(alloc);
    var fixture = try buildTurbofishFixture(
        alloc,
        turbofish,
        "collect",
        .{ .slice = element },
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    // A slice is a list, not an iterator carrier: it declares no bound, so
    // there is no `Item` to read and the element stays a placeholder.
    const bound = fixture.exprs_store[fixture.call_node].kind.method_call.generic_args[0];
    try std.testing.expect(types.deepEqual(turbofish[0], bound));
    try std.testing.expect(infer.isInferPlaceholderType(bound.external_nominal.args[0]));
}

test "a tail collect follows the enclosing return type, not the items it yields" {
    // `input.iter().copied().map(|v| check(v)).collect()` in a function
    // declared `-> Result<Vec<u8>, u8>` collects a `Vec<u8>` and reports the
    // first failure. Reading the target off the `Result<u8, u8>` items instead
    // makes the same call a `Vec<Result<u8, u8>>`, which is a different
    // program: the items say what the container is FILLED with, never what it
    // is.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try buildTurbofishFixture(
        alloc,
        &.{.{ .prim = .unit }},
        "collect",
        try iteratorItemBoundReceiver(alloc, true),
    );
    // The position supplies the target, so the call writes no turbofish.
    fixture.exprs_store[fixture.call_node].kind.method_call.generic_args = &.{};

    const elements = try alloc.alloc(types.Type, 1);
    elements[0] = .{ .prim = .u8 };
    const payload: types.Result = .{
        .ok = .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = elements,
        } },
        .err = .{ .prim = .u8 },
        .is_error_unionable = true,
    };
    const collected: types.Type = .{ .result = &payload };
    // The declared return IS the expected type, and the solver can only pin a
    // type that is already interned.
    fixture.bodies_store[2] = .{ .fn_ = .{
        .params = &.{},
        .ret = collected,
        .body = 2,
    } };
    fixture.types_store[2] = collected;

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    const result_id = inferred.getType(fixture.call_node) orelse
        return error.UntypedTailCollect;
    try std.testing.expect(types.deepEqual(collected, fixture.b.types[result_id]));
}

test "a tail collect into a generic target follows the type parameter" {
    // `fn collect_chars<C: core::iter::FromIterator<char>>(..) -> C { ..collect() }`,
    // instantiated as a `String` and as a `Vec<char>`. The target is the
    // parameter, and what the parameter becomes is the instantiation's
    // business; the `char` items decide only what each container is FILLED
    // with. Reading the items would pin both instantiations to one container
    // and make the other wrong.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var fixture = try buildTurbofishFixture(
        alloc,
        &.{.{ .prim = .unit }},
        "collect",
        try iteratorItemBoundReceiver(alloc, true),
    );
    defer fixture.deinit(alloc);
    fixture.exprs_store[fixture.call_node].kind.method_call.generic_args = &.{};
    // The fixture's declared return is the bare parameter `T`; intern it so the
    // solver records a PIN for it instead of a derived type it will not
    // materialise.
    fixture.types_store[2] = fixture.bodies_store[2].fn_.ret;

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    const result_id = inferred.getType(fixture.call_node) orelse
        return error.UntypedTailCollect;
    const segments = switch (fixture.b.types[result_id]) {
        .path => |path| path.segments,
        else => return error.CollectTargetNotTheTypeParameter,
    };
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("T", segments[0].name);
}

// ── The shape body lowering actually produces ────────────────────────────────

/// A method call whose callee is the `.method_ref` body lowering synthesizes
/// per call site, not the concrete `fn_` `TurbofishFixture` stands in for.
///
/// `pushMethodRef` parents the reference to the enclosing callable and gives it
/// an empty body-table slot, so `bodies[callee]` is `.none` and
/// `methodDeclaredReturnType` has no `fn_` to read and no trait to reach: its
/// parent is a function. That is the whole point of the fixture — nothing on
/// the callee answers a signature lookup, so only the rule under test can name
/// the result. A second entry in `trait_methods` declares a same-named method on
/// a second trait, which is what the ambiguity guard reads.
const MethodRefTurbofishFixture = struct {
    exprs_store: []exprs.Expr,
    types_store: []types.Type,
    bodies_store: []bodies.BodyKind,
    method_sigs_store: []bodies.TraitMethodSig,
    b: bodies.Bodies,
    graph: crate_graph.CrateGraph,
    call_node: exprs.NodeId,

    fn deinit(self: *MethodRefTurbofishFixture, alloc: std.mem.Allocator) void {
        self.graph.deinit();
        alloc.free(self.method_sigs_store);
        alloc.free(self.bodies_store);
        alloc.free(self.types_store);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

const method_ref_test_span: spine.Span = span;

/// `xs.<method_name><turbofish>() == other`, lowered by hand into the shape the
/// frontend records. Entity ids: 0 = module, 1 = struct `Bytes`, then one
/// `.trait_` per entry in `trait_methods`, then the callable that owns the
/// call, then the `.method_ref` callee.
fn buildMethodRefTurbofishFixture(
    alloc: std.mem.Allocator,
    method_name: []const u8,
    turbofish: []const types.Type,
    receiver_type: types.Type,
    expected_result: types.Type,
    trait_methods: []const []const []const u8,
) !MethodRefTurbofishFixture {
    var graph = crate_graph.CrateGraph.init(alloc);
    errdefer graph.deinit();

    const trait_count = trait_methods.len;
    const callable_id: exprs.DefId = 2 + @as(exprs.DefId, @intCast(trait_count));
    const callee_id: exprs.DefId = callable_id + 1;

    _ = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = method_ref_test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const receiver_def: exprs.DefId = 1;
    _ = try graph.symbol_table.add(.{
        .id = receiver_def,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Bytes"),
        .span = method_ref_test_span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // Every trait declares a method under the SAME name, differing only in the
    // type parameter its return is spelled with. That is what makes the arity
    // and the one-trait rule testable rather than incidental.
    for (trait_methods, 0..) |_, index| {
        _ = try graph.symbol_table.add(.{
            .id = @intCast(receiver_def + 1 + index),
            .kind = .trait_,
            .name = try alloc.dupe(u8, if (index == 0) "ToHex" else "AlsoToHex"),
            .span = method_ref_test_span,
            .visibility = .public,
            .parent = 0,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
    }
    _ = try graph.symbol_table.add(.{
        .id = callable_id,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "describe"),
        .span = method_ref_test_span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try graph.symbol_table.add(.{
        .id = callee_id,
        .kind = .method_ref,
        .name = try alloc.dupe(u8, method_name),
        .span = method_ref_test_span,
        .visibility = .public,
        .parent = callable_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try graph.addModule(.{
        .id = 0,
        .kind = .root,
        .name = try alloc.dupe(u8, ""),
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = method_ref_test_span,
        .items = try alloc.dupe(spine.EntityId, &.{ receiver_def, callee_id }),
        .attributes = &.{},
    });
    try graph.addCrate(.{
        .name = try alloc.dupe(u8, "method_ref_turbofish"),
        .edition = 2021,
        .kind = .lib,
        .root = 0,
        .deps = &.{},
        .is_translated = true,
    });

    // Types: 0 = the receiver, 1 = the turbofish as written, 2 = the result the
    // call must land on. Interning the expected result is what lets the solver
    // record a PIN rather than a derived type; `solveWithGraph` does not
    // materialize the derived list, which only the pipeline does.
    const types_store = try alloc.alloc(types.Type, 3);
    types_store[0] = receiver_type;
    types_store[1] = turbofish[0];
    types_store[2] = expected_result;

    // Exprs: 0 = the receiver, 1 = the call, 2 = the other operand of `==`,
    // 3 = the `==` the call is an operand of, 4 = the fn body block.
    const exprs_store = try alloc.alloc(exprs.Expr, 5);
    exprs_store[0] = .{
        .id = 0,
        .span = method_ref_test_span,
        .ty = 0,
        .kind = .{ .path = .{ .def = receiver_def, .generic_args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = method_ref_test_span,
        .ty = null,
        .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = callee_id,
            .generic_args = turbofish,
            .args = &.{},
        } },
    };
    // The other side of the `==`. An unsuffixed integer literal carries a
    // literal CLASS, not a type, so `getKnownType` finds nothing on it and the
    // equality edge cannot type the call from this side — which is what makes
    // a `null` result in the negative tests mean "nothing named it".
    exprs_store[2] = .{
        .id = 2,
        .span = method_ref_test_span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "0",
            .value = 0,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = method_ref_test_span,
        .ty = null,
        .kind = .{ .binary = .{
            .op = .eq,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } },
    };
    exprs_store[4] = .{
        .id = 4,
        .span = method_ref_test_span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{},
            .tail = 3,
            .labelled = null,
        } },
    };

    // Each trait's method returns its own bare parameter, so a turbofish is the
    // only thing that can resolve the return to anything concrete.
    const method_sigs_store = try alloc.alloc(bodies.TraitMethodSig, trait_count);
    for (trait_methods, 0..) |method_params, index| {
        method_sigs_store[index] = .{
            .name = try alloc.dupe(u8, method_name),
            .ret = .{ .path = .{ .segments = try alloc.dupe(types.PathSegment, &.{
                .{ .name = try alloc.dupe(u8, method_params[0]), .id = null },
            }) } },
            .generic_params = try alloc.dupe([]const u8, method_params),
        };
    }

    // The body table is indexed by entity id, so each trait's `trait_` sits at
    // its own entity id and the callee's slot is left `.none`.
    const bodies_store = try alloc.alloc(bodies.BodyKind, callee_id + 1);
    bodies_store[0] = .none;
    bodies_store[1] = .{ .struct_ = .{} };
    for (trait_methods, 0..) |_, index| {
        bodies_store[2 + index] = .{ .trait_ = .{
            .name = try alloc.dupe(u8, if (index == 0) "ToHex" else "AlsoToHex"),
            .methods = method_sigs_store[index .. index + 1],
        } };
    }
    bodies_store[callable_id] = .{ .fn_ = .{
        .params = try alloc.dupe(items.Param, &.{}),
        .ret = .{ .prim = .bool },
        .body = 4,
    } };
    bodies_store[callee_id] = .none;

    return .{
        .exprs_store = exprs_store,
        .types_store = types_store,
        .bodies_store = bodies_store,
        .method_sigs_store = method_sigs_store,
        .b = .{
            .exprs = exprs_store,
            .stmts = &.{},
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_store,
        },
        .graph = graph,
        .call_node = 1,
    };
}

/// The container `Vec<(usize, usize)>` that `collect::<Vec<_>>()` over an
/// `Iterator<Item = (usize, usize)>` hands back, written as the type table
/// needs it so the call's PIN resolves to an interned entry.
fn collectedPairVec(alloc: std.mem.Allocator) !types.Type {
    const element = try alloc.alloc(types.Type, 2);
    element[0] = .{ .prim = .usize };
    element[1] = .{ .prim = .usize };
    const args = try alloc.alloc(types.Type, 1);
    args[0] = .{ .tuple = element };
    return .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = args,
    } };
}

test "a collect turbofish names the call's result on a bodiless call-site callee" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `generate_iter(5).collect::<Vec<_>>() == result`. The callee is the
    // `.method_ref` body lowering synthesizes, so nothing on it names the
    // result and `pinTurbofishResultType` cannot fire: the container comes
    // from the call's own turbofish instead. That is what an operator over the
    // call reads, and an operator over an untyped operand is the refusal this
    // pins down — the call must come out NAMED.
    const turbofish = try collectElementTurbofish(alloc);
    const expected = try collectedPairVec(alloc);
    var fixture = try buildMethodRefTurbofishFixture(
        alloc,
        "collect",
        turbofish,
        try iteratorItemBoundReceiver(alloc, true),
        expected,
        &.{},
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    const result_id = inferred.getType(fixture.call_node) orelse
        return error.UntypedCollectedMethodCall;
    try std.testing.expectEqual(@as(exprs.TypeId, 2), result_id);
    try std.testing.expect(types.deepEqual(
        expected,
        fixture.b.types[result_id],
    ));
}

/// `alloc::string::String` as a turbofish argument spells it. A comptime
/// constant, because the path is a string literal and nothing is allocated.
const string_turbofish: types.Type = .{
    .external_nominal = .{ .path = &.{ "alloc", "string", "String" } },
};

test "a trait method turbofish names the call's result on a bodiless callee" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `[0x66, ..].encode_hex::<String>()`. `ToHex::encode_hex` declares
    // `fn encode_hex<T: FromIterator<char>>(&self) -> T`, so the declared
    // return is the bare parameter and the turbofish is the only thing that can
    // resolve it. The callee is the `.method_ref` body lowering synthesizes,
    // which carries no signature at all, so the trait's own signature is the
    // only place the return type and the parameter names both come from.
    const element = try alloc.create(types.Slice);
    element.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const turbofish = [_]types.Type{string_turbofish};
    var fixture = try buildMethodRefTurbofishFixture(
        alloc,
        "encode_hex",
        &turbofish,
        .{ .slice = element },
        turbofish[0],
        &.{&.{"T"}},
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    const result_id = inferred.getType(fixture.call_node) orelse
        return error.UntypedTraitTurbofishMethodCall;
    try std.testing.expectEqual(@as(exprs.TypeId, 1), result_id);
    try std.testing.expect(types.deepEqual(
        turbofish[0],
        fixture.b.types[result_id],
    ));
}

test "two traits declaring the same turbofish method leave the call untyped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Two traits, one method name, same arity: `xs.render::<String>()` names no
    // one of them, and Rust would have rejected the call too. Neither trait's
    // return wins here, so the call stays untyped and an operator over it keeps
    // the general refusal.
    const element = try alloc.create(types.Slice);
    element.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const turbofish = [_]types.Type{string_turbofish};
    var fixture = try buildMethodRefTurbofishFixture(
        alloc,
        "render",
        &turbofish,
        .{ .slice = element },
        turbofish[0],
        &.{ &.{"T"}, &.{"T"} },
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    try std.testing.expectEqual(@as(?exprs.TypeId, null), inferred.getType(fixture.call_node));
}

test "a trait method whose arity differs from the turbofish leaves the call untyped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `fn render<T, U>(&self) -> T` with a one-argument turbofish: the trait
    // that declares the method is not the method this call names, and guessing
    // which argument `String` is would be inventing a binding nobody wrote.
    const element = try alloc.create(types.Slice);
    element.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const turbofish = [_]types.Type{string_turbofish};
    var fixture = try buildMethodRefTurbofishFixture(
        alloc,
        "render",
        &turbofish,
        .{ .slice = element },
        turbofish[0],
        &.{&.{ "T", "U" }},
    );
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    try std.testing.expectEqual(@as(?exprs.TypeId, null), inferred.getType(fixture.call_node));
}

// ── Unconstrained literal defaults need their type interned ────────────────
//
// The Defaults Phase resolves an unconstrained integer class through
// `primTypeId(b, .i32)`, and that lookup only SEARCHES the type list: it
// never interns. A crate whose source never names `i32` therefore had no
// TypeId to hand the class, the phase silently did nothing, and every
// unconstrained integer expression kept `ty = null` — which the operator
// pass then reads as a non-primitive operand. `materializeDerivedTypes` owns
// the type list and runs immediately before the solver, so it is where the
// default becomes reachable.

/// The TypeId of `prim` in the type list, or a failure naming what is missing.
///
/// The Defaults Phase reaches its default through the type table, so "this
/// unconstrained operand is an `i32`" is only answerable once the table names
/// one. Asserting the operand rather than the table's length says what the
/// solver owes, and says it the same way whichever entry ended up carrying it.
fn defaultPrimTypeId(type_list: []const types.Type, prim: types.Prim) !exprs.TypeId {
    for (type_list, 0..) |entry, index| {
        if (entry == .prim and entry.prim == prim) return @intCast(index);
    }
    return error.DefaultLiteralTypeNotInterned;
}

test "an unconstrained integer comparison defaults to i32 the crate never named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `pub fn f() -> bool { let n = 0; n < 3 }` with a type table that holds
    // `bool` and nothing else. The comparison is the shape that has to work:
    // nothing but the literal class says these operands are integers.
    var pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "n",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    }};
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "0",
            .value = 0,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .path = .{
            .def = 0,
            .generic_args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "3",
            .value = 3,
            .base = .dec,
            .ty_suffix = null,
        } } } },
        .{ .id = 3, .span = span, .ty = null, .kind = .{ .binary = .{
            .op = .lt,
            .overflow = .checked,
            .lhs = 1,
            .rhs = 2,
        } } },
        .{ .id = 4, .span = span, .ty = null, .kind = .{ .block = .{
            .statements = &.{0},
            .tail = 3,
            .labelled = null,
        } } },
    };
    var stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 0, .init = 0, .ty = null } },
    }};
    var bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .bool }, .body = 4 },
    }};

    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    try types_list.append(alloc, .{ .prim = .bool });

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &pats_store, &generated);
    b.types = types_list.items;

    // The default the class selects has to exist as a TypeId at all.
    const i32_id = try defaultPrimTypeId(types_list.items, .i32);

    var inferred = try infer.solveWithGen(alloc, &b, &generated);
    defer inferred.deinit(alloc);

    // The local and both literals read as `i32`; the comparison keeps the
    // `bool` its own result is pinned to.
    try std.testing.expectEqual(@as(?exprs.TypeId, i32_id), inferred.getType(0));
    try std.testing.expectEqual(@as(?exprs.TypeId, i32_id), inferred.getType(1));
    try std.testing.expectEqual(@as(?exprs.TypeId, i32_id), inferred.getType(2));
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(3));

    // Exactly one entry was added, and no `f64` rode along: this body has no
    // unannotated float to default.
    try std.testing.expectEqual(@as(usize, 2), types_list.items.len);
}

test "an unconstrained float defaults to f64 the crate never named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `pub fn f() { 3.14; }` in a crate that names no float type. The literal
    // is the crate's only evidence that a default is reachable at all.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .float = .{
            .text = "3.14",
            .value = 3.14,
        } } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } } },
    };
    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 0 } },
    };
    var bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 1 },
    }};
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    try types_list.append(alloc, .{ .prim = .bool });

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &.{}, &generated);
    b.types = types_list.items;

    const f64_id = try defaultPrimTypeId(types_list.items, .f64);

    var inferred = try infer.solveWithGen(alloc, &b, &generated);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(@as(?exprs.TypeId, f64_id), inferred.getType(0));

    // Only the float default was added: no `i32` for a body that never has an
    // unannotated integer.
    try std.testing.expectEqual(@as(usize, 2), types_list.items.len);
}

test "a crate with no unannotated literal keeps the type table it had" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A suffixed literal is pinned, never classed, so this body has nothing to
    // default. Interning `i32` and `f64` unconditionally would still be
    // harmless for the solver, but it would add two entries every crate's type
    // table carries and nothing can select.
    var exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .literal = .{ .int = .{
            .text = "5u8",
            .value = 5,
            .base = .dec,
            .ty_suffix = "u8",
        } } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } } },
    };
    var stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 0 } },
    };
    var bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 1 },
    }};
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    try types_list.append(alloc, .{ .prim = .bool });
    try types_list.append(alloc, .{ .prim = .u8 });

    var b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = types_list.items,
        .bodies = &bodies_store,
    };
    var generated = try infer.gen(alloc, &b);
    defer generated.deinit(alloc);
    try infer.materializeDerivedTypes(alloc, &types_list, &.{}, &generated);
    b.types = types_list.items;

    try std.testing.expectEqual(@as(usize, 2), types_list.items.len);

    var inferred = try infer.solveWithGen(alloc, &b, &generated);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(@as(?exprs.TypeId, 1), inferred.getType(0));
}

/// `ToOwned` on one borrowed value, with the receiver's pointee as the ONLY
/// difference between runs.
///
/// `impl ToOwned for str { type Owned = String }` and
/// `impl ToOwned for [T] { type Owned = Vec<T> }` are different traits for
/// different pointees, so a receiver that says only "borrowed bytes" cannot
/// answer for text, and a receiver that says `str` must not answer with a
/// `Vec`. This is the question a `Cow<'a, str>` conversion asks of an item the
/// source spells `&str`, so the pointee has to be what decides it.
fn borrowedToOwnedResultType(alloc: std.mem.Allocator, pointee: types.Type) !?types.Type {
    var graph = ir.graph.CrateGraph.init(alloc);
    defer graph.deinit();
    const to_owned = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "to_owned"),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    // Types: 0 = String, 1 = Vec<u8>, 2 = the borrowed receiver itself. Both
    // owners are pre-seeded so what is under test is WHICH one the call
    // reaches, not whether this pass could invent the other.
    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = pointee };
    const types_store = [_]types.Type{
        .{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        .{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
        .{ .reference = reference },
    };

    // 0 = the borrowed receiver, 1 = its `to_owned()`, 2 = the body block.
    // The call is a STATEMENT rather than the block's tail on purpose: a tail
    // is pinned to the declared return type, and the declared return is not
    // what this fixture is asking about.
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = span, .ty = 2, .kind = .{ .path = .{ .def = 0, .generic_args = &.{} } } },
        .{ .id = 1, .span = span, .ty = null, .kind = .{ .method_call = .{
            .receiver = 0,
            .receiver_mode = .shared,
            .method = to_owned,
            .args = &.{},
        } } },
        .{ .id = 2, .span = span, .ty = null, .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } } },
    };
    const stmts_store = [_]exprs.Statement{
        .{ .id = 0, .span = span, .ty = null, .kind = .{ .expr = 1 } },
    };
    const bodies_store = [_]bodies.BodyKind{.{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 2,
    } }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var inferred = try infer.solveWithGraph(alloc, &b, &graph);
    defer inferred.deinit(alloc);
    const type_id = inferred.getType(1) orelse return null;
    return types_store[type_id];
}

test "a borrowed str and a borrowed byte slice own differently" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const byte_slice = try alloc.create(types.Slice);
    byte_slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };

    // Same call, same receiver shape, same everything but the pointee — so the
    // two results can differ only because `str` and `[u8]` are different types.
    try std.testing.expectEqual(
        types.Type{ .external_nominal = .{ .path = &.{ "alloc", "string", "String" } } },
        (try borrowedToOwnedResultType(alloc, types.str_type)).?,
    );
    try std.testing.expectEqual(
        types.Type{ .external_nominal = .{
            .path = &.{ "alloc", "vec", "Vec" },
            .args = &.{.{ .prim = .u8 }},
        } },
        (try borrowedToOwnedResultType(alloc, .{ .slice = byte_slice })).?,
    );
}

// ── Source-declared method dispatch ────────────────────────────────────────
//
// A method a crate declares for its OWN type is the answer to every question
// about that type. The lookups below all run BEFORE the receiver-shaped
// standard rules, so a crate's `len`, `next` or `write` is its own and not the
// runtime's, and an `impl Trait for Type` block is as much a declaration as an
// inherent one — which is the whole reason `WyRng`'s `RngCore` methods answer
// at all.
//
// Entity ids are fixed because the body table is indexed by entity id, and
// every lookup here is a walk over the graph rather than a pointer chase.
const source_method_module: exprs.DefId = 0;
const source_method_struct: exprs.DefId = 1;
const source_method_impl: exprs.DefId = 2;
const source_method_method: exprs.DefId = 3;
const source_method_owner: exprs.DefId = 4;
/// The `impl Source for <type>` entity, whose name is the only place the trait
/// and the type are both spelled.
const source_method_trait_name = "Source";

/// Expr table of the source-method fixture:
///   0 = the `&mut T` receiver
///   1 = `receiver.wide()`
///   2 = `receiver.wide() as u32` — the call under a scalar cast
///   3 = the declared method's own (empty) body block
///   4 = the enclosing `fn`'s body block, whose only statement is the cast
const source_method_receiver_node: exprs.NodeId = 0;
const source_method_call_node: exprs.NodeId = 1;
const source_method_cast_node: exprs.NodeId = 2;

/// Types of the source-method fixture: 0 = `&mut <type>`, 1 = the method's own
/// declared return (interned so the solver records a pin rather than a derived
/// type `solveWithGraph` never materializes), 2 = the cast destination.
const source_method_receiver_type: exprs.TypeId = 0;
const source_method_declared_type: exprs.TypeId = 1;
const source_method_cast_type: exprs.TypeId = 2;

const SourceMethodFixture = struct {
    exprs_store: []exprs.Expr,
    types_store: []types.Type,
    /// The pattern table `b` views. `materializeDerivedTypes` writes the rows it
    /// publishes back into it, so it is a store this fixture owns rather than
    /// the immutable empty literal the frontend's own tables are built from.
    pats_store: []exprs.Pattern,
    stmts_store: []exprs.Statement,
    bodies_store: []bodies.BodyKind,
    b: bodies.Bodies,
    graph: crate_graph.CrateGraph,

    fn deinit(self: *SourceMethodFixture, alloc: std.mem.Allocator) void {
        self.graph.deinit();
        alloc.free(self.bodies_store);
        alloc.free(self.stmts_store);
        alloc.free(self.pats_store);
        alloc.free(self.types_store);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

const SourceMethodSpec = struct {
    /// The method the enclosing call names. Deliberately free of every name a
    /// standard rule claims, except in the test that says so out loud.
    method_name: []const u8,
    type_name: []const u8,
    /// The `->` the trait impl's method declares.
    declared_return: types.Type,
    /// The method's OWN type parameters (`fn choose<U>(..) -> U`).
    method_generic_params: []const []const u8 = &.{},
    /// The impl block's type parameters (`impl<T> Source for Cell<T>`).
    impl_type_params: []const []const u8 = &.{},
    /// Non-empty makes the receiver `&mut <type><args>`, so the declared return
    /// is substituted from the receiver's own arguments.
    receiver_args: []const types.Type = &.{},
    /// A second trait declaring the same method on the same type. Two answers
    /// is not an answer, and neither is "whichever came first".
    competing_return: ?types.Type = null,
};

/// `receiver.wide() as u32` inside `fn narrow()`, with `wide` declared only by
/// `impl Source for <type>`. Nothing in this fixture puts `u64` on the call
/// except that declaration: no inherent block, no turbofish, no annotation,
/// and no standard rule — so a call that comes out `u64` can only have come
/// from reading the source.
fn buildSourceMethodFixture(
    alloc: std.mem.Allocator,
    spec: SourceMethodSpec,
) !SourceMethodFixture {
    var graph = crate_graph.CrateGraph.init(alloc);
    errdefer graph.deinit();

    const module_id = try graph.symbol_table.add(.{
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
    try std.testing.expectEqual(source_method_module, module_id);
    const struct_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try alloc.dupe(u8, spec.type_name),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(source_method_struct, struct_id);
    // The trait impl is a single named entity: `lookupSourceMethod` reads the
    // trait and the type out of that one string.
    const impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try std.fmt.allocPrint(
            alloc,
            "{s} for {s}",
            .{ source_method_trait_name, spec.type_name },
        ),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(source_method_impl, impl_id);
    const method_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, spec.method_name),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(source_method_method, method_id);
    const owner_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "narrow"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(source_method_owner, owner_id);

    var entity_count: exprs.DefId = source_method_owner + 1;
    var competing_impl_id: exprs.DefId = 0;
    var competing_method_id: exprs.DefId = 0;
    if (spec.competing_return != null) {
        competing_impl_id = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .impl_,
            .name = try std.fmt.allocPrint(
                alloc,
                "Alternate for {s}",
                .{spec.type_name},
            ),
            .span = span,
            .visibility = .public,
            .parent = module_id,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        try std.testing.expectEqual(entity_count, competing_impl_id);
        competing_method_id = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .fn_,
            .name = try alloc.dupe(u8, spec.method_name),
            .span = span,
            .visibility = .public,
            .parent = competing_impl_id,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        try std.testing.expectEqual(entity_count + 1, competing_method_id);
        entity_count += 2;
    }

    // Types. `Path`/`GenericArgs` rows are owned: they outlive this call.
    const type_segments = try alloc.dupe(types.PathSegment, &.{.{
        .name = try alloc.dupe(u8, spec.type_name),
        .id = source_method_struct,
    }});
    const receiver_args = try alloc.dupe(types.Type, spec.receiver_args);
    const self_type: types.Type = if (receiver_args.len == 0)
        .{ .path = .{ .segments = type_segments } }
    else
        .{ .generic_inst = .{
            .decl = source_method_struct,
            .args = .{ .params = receiver_args },
        } };
    // `&mut self` is a borrow, and the borrow is what the receiver expression
    // carries: `canonicalReceiverName` has to peel it to reach the type.
    const receiver_reference = try alloc.create(types.Ref);
    receiver_reference.* = .{ .mut = true, .pointee = self_type };

    const types_store = try alloc.alloc(types.Type, 3);
    types_store[source_method_receiver_type] = .{ .reference = receiver_reference };
    types_store[source_method_declared_type] = spec.declared_return;
    types_store[source_method_cast_type] = .{ .prim = .u32 };

    // Nothing in this fixture binds a pattern — the only statement is an
    // expression statement around a cast — so the store stays empty. It is
    // still a store the fixture owns: `solveSourceMethodFixture` hands it to
    // `materializeDerivedTypes`, which writes back every pattern row it
    // publishes, and an empty slice literal cannot be written to.
    const pats_store = try alloc.alloc(exprs.Pattern, 0);

    const trait_path: types.Type = .{ .path = .{ .segments = try alloc.dupe(
        types.PathSegment,
        &.{.{ .name = source_method_trait_name, .id = null }},
    ) } };

    var impl_generics: ?types.Generics = null;
    if (spec.impl_type_params.len != 0) {
        const params = try alloc.alloc(types.GenericParam, spec.impl_type_params.len);
        for (spec.impl_type_params, 0..) |name, index| {
            params[index] = .{ .type_ = .{ .name = name, .bounds = &.{} } };
        }
        impl_generics = .{ .params = params, .where_clauses = &.{} };
    }

    const exprs_store = try alloc.alloc(exprs.Expr, 5);
    exprs_store[source_method_receiver_node] = .{
        .id = source_method_receiver_node,
        .span = span,
        .ty = source_method_receiver_type,
        .kind = .{ .path = .{ .def = source_method_struct, .generic_args = &.{} } },
    };
    exprs_store[source_method_call_node] = .{
        .id = source_method_call_node,
        .span = span,
        .ty = null,
        .kind = .{ .method_call = .{
            .receiver = source_method_receiver_node,
            .receiver_mode = .mutable,
            .method = source_method_method,
            .generic_args = &.{},
            .args = &.{},
        } },
    };
    exprs_store[source_method_cast_node] = .{
        .id = source_method_cast_node,
        .span = span,
        .ty = null,
        .kind = .{
            .cast = .{
                .kind = .as_,
                .operand = source_method_call_node,
                // What CST lowering writes when it could not type the operand yet.
                .source_type = .{ .unsupported = .{
                    .reason = .iterators,
                    .message = "cast source type pending inference",
                    .span = span,
                } },
                .target = source_method_cast_type,
            },
        },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
    };
    exprs_store[4] = .{
        .id = 4,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 1);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = source_method_cast_node },
    };

    const bodies_store = try alloc.alloc(bodies.BodyKind, entity_count);
    bodies_store[source_method_module] = .none;
    bodies_store[source_method_struct] = .{ .struct_ = .{} };
    bodies_store[source_method_impl] = .{ .impl_ = .{
        .self_ty = self_type,
        .trait_path = switch (trait_path) {
            .path => |value| value,
            else => unreachable,
        },
        .generics = impl_generics,
        .assoc_items = try alloc.dupe(spine.EntityId, &.{source_method_method}),
    } };
    bodies_store[source_method_method] = .{ .fn_ = .{
        .params = &.{},
        .ret = spec.declared_return,
        .generic_params = spec.method_generic_params,
        .body = 3,
    } };
    bodies_store[source_method_owner] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u32 },
        .body = 4,
    } };
    if (spec.competing_return) |competing| {
        bodies_store[competing_impl_id] = .{ .impl_ = .{
            .self_ty = self_type,
            .assoc_items = try alloc.dupe(spine.EntityId, &.{competing_method_id}),
        } };
        bodies_store[competing_method_id] = .{ .fn_ = .{
            .params = &.{},
            .ret = competing,
            .body = 3,
        } };
    }

    return .{
        .exprs_store = exprs_store,
        .types_store = types_store,
        .pats_store = pats_store,
        .stmts_store = stmts_store,
        .bodies_store = bodies_store,
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = pats_store,
            .types = types_store,
            .bodies = bodies_store,
        },
        .graph = graph,
    };
}

/// Solve a `buildSourceMethodFixture` the way the pipeline does: generate,
/// materialize the derived types, then solve. `infer.solveWithGraph` runs the
/// first and last of those and skips the middle one, so a fixture whose answer
/// the declaration only names through substitution — `impl<T> Source for
/// Counter<T> { fn get(&self) -> T }` reaching `Counter<u8>` — has its
/// substituted row recorded as a derived pin that nothing ever publishes, and
/// the call it belongs to stays untyped. Materializing here is that fixture's
/// own precondition, not a widening of the solver: `solveWithGraph` is what
/// every other fixture uses, and it is left alone.
///
/// The pool is a growable list, exactly as the frontend's own context owns it,
/// and appending keeps every row the fixture already handed out — the cast's
/// `target` names row 2, so a pool restarted from empty would leave the
/// destination the substitution's own row had been about to fill. The grown
/// list is left for the caller's arena to reclaim, because `fixture.b.types`
/// reads it after this returns.
fn solveSourceMethodFixture(
    alloc: std.mem.Allocator,
    fixture: *SourceMethodFixture,
) !infer.Inferred {
    var generated = try infer.genWithGraph(alloc, &fixture.b, &fixture.graph);
    errdefer generated.deinit(alloc);
    var type_list: std.ArrayListUnmanaged(types.Type) = .empty;
    try type_list.appendSlice(alloc, fixture.b.types);
    // `bodies.Bodies` holds every table as a view, and the pattern table is no
    // exception, so the mutable store this fixture owns is handed over through
    // the same `@constCast` the production replay uses at `infer.zig`'s own
    // `materializeDerivedTypes` call. The cast is what the derived-pattern
    // channel has always been given; the fixture does not widen it.
    try infer.materializeDerivedTypes(alloc, &type_list, @constCast(fixture.b.pats), &generated);
    fixture.b.types = type_list.items;
    var inferred = try infer.solveWithGen(alloc, &fixture.b, &generated);
    errdefer inferred.deinit(alloc);
    // Adopted onto the nodes, not merely reported: a test that reads a cast's
    // recorded source reads the record this solve produced.
    inferred.apply(fixture.exprs_store);
    generated.deinit(alloc);
    // `type_list` is deliberately not freed: `fixture.b.types` reads its
    // buffer for the rest of the test, and the caller's arena reclaims it.
    return inferred;
}

test "a trait impl method declared u64 types the &mut self call a cast narrows to u32" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `impl Source for Counter { fn wide(&mut self) -> u64 }` reached from
    // `receiver.wide() as u32`. The method name is one no standard rule
    // claims, so the answer can only be the declaration's.
    var fixture = try buildSourceMethodFixture(alloc, .{
        .method_name = "wide",
        .type_name = "Counter",
        .declared_return = .{ .prim = .u64 },
    });
    defer fixture.deinit(alloc);

    var inferred = try solveSourceMethodFixture(alloc, &fixture);
    defer inferred.deinit(alloc);

    // The cast's recorded source stopped being the frontend's "still pending"
    // placeholder and became the declared `u64`: the cast survived, and it
    // survived with the operand's real type on it.
    const cast = switch (fixture.exprs_store[source_method_cast_node].kind) {
        .cast => |value| value,
        else => return error.CastWasReplaced,
    };
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, cast.source_type);
    try std.testing.expectEqual(source_method_call_node, cast.operand);
    try std.testing.expectEqual(
        types.Type{ .prim = .u32 },
        fixture.b.types[cast.target],
    );

    const operand_id = inferred.getType(source_method_call_node) orelse
        return error.SourceMethodCallStayedUntyped;
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, fixture.b.types[operand_id]);
    const result_id = inferred.getType(source_method_cast_node) orelse
        return error.NarrowedSourceMethodStayedUntyped;
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, fixture.b.types[result_id]);
}

test "a source method named len keeps its declared u64 instead of the standard usize" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A crate is free to declare its own `len`. The receiver-shaped standard
    // rule for `len` is an early `return`, so a lookup that consulted it first
    // would leave this call untyped rather than wrongly typed — which is why
    // this fixture has to answer the question the other way round.
    var fixture = try buildSourceMethodFixture(alloc, .{
        .method_name = "len",
        .type_name = "Counter",
        .declared_return = .{ .prim = .u64 },
    });
    defer fixture.deinit(alloc);

    var inferred = try solveSourceMethodFixture(alloc, &fixture);
    defer inferred.deinit(alloc);

    const operand_id = inferred.getType(source_method_call_node) orelse
        return error.SourceLenLostToTheStandardRule;
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, fixture.b.types[operand_id]);
    try std.testing.expectEqual(
        types.Type{ .prim = .u64 },
        fixture.exprs_store[source_method_cast_node].kind.cast.source_type,
    );
}

test "two traits declaring the same method leave the call untyped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `impl Source for Counter` and `impl Alternate for Counter`, both with
    // `fn wide`. Rust would have rejected the call too, so neither declaration
    // may be picked: ambiguity is a different answer from absence, and this
    // call must not acquire the receiver's argument as a substitute.
    var fixture = try buildSourceMethodFixture(alloc, .{
        .method_name = "wide",
        .type_name = "Counter",
        .declared_return = .{ .prim = .u64 },
        .receiver_args = &.{.{ .prim = .u8 }},
        .competing_return = .{ .prim = .u32 },
    });
    defer fixture.deinit(alloc);

    var inferred = try solveSourceMethodFixture(alloc, &fixture);
    defer inferred.deinit(alloc);

    try std.testing.expectEqual(
        @as(?exprs.TypeId, null),
        inferred.getType(source_method_call_node),
    );
}

test "a trait impl method returning the impl's own parameter follows the receiver's argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `impl<T> Source for Counter<T> { fn get(&self) -> T }` reached as
    // `counter.get() as u32` with `counter: &mut Counter<u8>`. The declared
    // return is a type parameter and the receiver's argument is the only thing
    // that can name it, so a call that stays untyped here means the receiver's
    // arguments are not reaching a trait impl's signature.
    const declared_param: types.Type = .{ .path = .{ .segments = &.{.{
        .name = "T",
        .id = null,
    }} } };
    var fixture = try buildSourceMethodFixture(alloc, .{
        .method_name = "get",
        .type_name = "Counter",
        .declared_return = declared_param,
        .impl_type_params = &.{"T"},
        .receiver_args = &.{.{ .prim = .u8 }},
    });
    defer fixture.deinit(alloc);

    var inferred = try solveSourceMethodFixture(alloc, &fixture);
    defer inferred.deinit(alloc);

    const operand_id = inferred.getType(source_method_call_node) orelse
        return error.SubstitutedSourceReturnStayedUntyped;
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, fixture.b.types[operand_id]);
    try std.testing.expectEqual(
        types.Type{ .prim = .u8 },
        fixture.exprs_store[source_method_cast_node].kind.cast.source_type,
    );
}

test "a trait impl method whose return is its own type parameter leaves the call untyped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `impl<T> Source for Counter<T> { fn choose<U>(&self) -> U }`. `U` is the
    // method's own parameter and no turbofish binds it, so the receiver's `u8`
    // is not an answer for it. Pinning anything here — the receiver's
    // argument, the bare `U`, or a default — would invent a type the source
    // never wrote.
    const declared_param: types.Type = .{ .path = .{ .segments = &.{.{
        .name = "U",
        .id = null,
    }} } };
    var fixture = try buildSourceMethodFixture(alloc, .{
        .method_name = "choose",
        .type_name = "Counter",
        .declared_return = declared_param,
        .method_generic_params = &.{"U"},
        .impl_type_params = &.{"T"},
        .receiver_args = &.{.{ .prim = .u8 }},
    });
    defer fixture.deinit(alloc);

    var inferred = try solveSourceMethodFixture(alloc, &fixture);
    defer inferred.deinit(alloc);

    try std.testing.expectEqual(
        @as(?exprs.TypeId, null),
        inferred.getType(source_method_call_node),
    );
}

/// The whole generic-source-return path over ONE injected allocator: build the
/// fixture, generate, materialize, solve, adopt. The fixture fixes the answer —
/// `impl<T> Source for Counter<T> { fn wide(&mut self) -> T }` reached on a
/// `&mut Counter<u64>` IS a `u64` — so a run that neither propagates
/// `error.OutOfMemory` nor lands on that answer has left a WRONG type behind.
/// That is the case a generic return makes reachable: the substitution is
/// assembled out of allocations, and a half-assembled one must never read as an
/// answer the backend then emits.
fn checkGenericSourceReturnAllocationFailures(alloc: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared_param: types.Type = .{ .path = .{ .segments = &.{.{
        .name = "T",
        .id = null,
    }} } };
    var fixture = try buildSourceMethodFixture(arena, .{
        .method_name = "wide",
        .type_name = "Counter",
        .declared_return = declared_param,
        .impl_type_params = &.{"T"},
        .receiver_args = &.{.{ .prim = .u64 }},
    });
    defer fixture.deinit(arena);

    var generated = try infer.genWithGraph(arena, &fixture.b, &fixture.graph);
    defer generated.deinit(arena);

    // The type pool is a growable list here, exactly as the frontend's own
    // context owns it: materializing appends the rows the deferred pins need,
    // and every row keeps the id the fixture already handed out — the cast's
    // `target` names row 2, so a pool restarted from empty would leave the
    // destination the substitution's own row had been about to fill.
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    defer types_list.deinit(arena);
    try types_list.appendSlice(arena, fixture.b.types);
    try infer.materializeDerivedTypes(arena, &types_list, &.{}, &generated);
    fixture.b.types = types_list.items;

    var inferred = try infer.solveWithGen(arena, &fixture.b, &generated);
    defer inferred.deinit(arena);
    inferred.apply(fixture.exprs_store);

    // Adopted onto the nodes, not merely reported: the substituted return and
    // the source the cast records are the same `u64`, and the cast narrowed to
    // the `u32` its target row always named.
    const operand_id = fixture.exprs_store[source_method_call_node].ty orelse
        return error.GenericSourceReturnStayedUntyped;
    try std.testing.expectEqual(
        types.Type{ .prim = .u64 },
        fixture.b.types[operand_id],
    );
    const cast = switch (fixture.exprs_store[source_method_cast_node].kind) {
        .cast => |value| value,
        else => return error.GenericSourceReturnCastWasRewritten,
    };
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, cast.source_type);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, fixture.b.types[cast.target]);
    const result_id = fixture.exprs_store[source_method_cast_node].ty orelse
        return error.NarrowedGenericSourceReturnStayedUntyped;
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, fixture.b.types[result_id]);
}

test "a generic trait impl return propagates allocation failures instead of a wrong type" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkGenericSourceReturnAllocationFailures,
        .{},
    );
}

// ── Struct destructuring ───────────────────────────────────────────────────
//
// `let State { a, b, c, d, written } = self;` binds five captures to five
// fields of ONE struct. Each capture is a `u64`, not the struct it came from:
// a capture that is equated with the whole initializer unifies a primitive
// with its aggregate, and every operator over the chain then reads an operand
// that is not the one the source wrote.

/// One `field: binding` pair of a struct pattern. They differ exactly when the
/// source renamed the capture (`let Pair { big: hi } = pair;`).
const DestructureField = struct {
    field: []const u8,
    binding: []const u8,
};

const DestructureFixture = struct {
    exprs_store: []exprs.Expr,
    types_store: []types.Type,
    bodies_store: []bodies.BodyKind,
    pats_store: []exprs.Pattern,
    stmts_store: []exprs.Statement,
    b: bodies.Bodies,
    graph: crate_graph.CrateGraph,
    /// The `self` initializer the pattern destructures.
    init_node: exprs.NodeId,
    /// The first of `capture_use_count` path expressions naming the captures.
    capture_use_node: exprs.NodeId,
    capture_use_count: usize,
    /// The block tail: the `^` chain over every capture.
    tail_node: exprs.NodeId,

    fn deinit(self: *DestructureFixture, alloc: std.mem.Allocator) void {
        self.graph.deinit();
        alloc.free(self.pats_store);
        alloc.free(self.stmts_store);
        alloc.free(self.bodies_store);
        alloc.free(self.types_store);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

/// `fn finalize(self) -> u64 { let Struct { ..fields } = self;
/// binding_0 ^ binding_1 ^ .. }`, with every declared field a `u64` — which is
/// the shape `SeaHash`'s `State::finalize` writes.
fn buildDestructureFixture(
    alloc: std.mem.Allocator,
    type_name: []const u8,
    fields: []const DestructureField,
) !DestructureFixture {
    const capture_count = fields.len;
    std.debug.assert(capture_count >= 2);

    var graph = crate_graph.CrateGraph.init(alloc);
    errdefer graph.deinit();

    // 0 = the crate module, 1 = the struct, 2 = its inherent impl, 3 = the
    // method. The captures follow, as `.field` entities parented to the method
    // so `claimLocal` can find each one by the name it is bound to.
    const module_id = try graph.symbol_table.add(.{
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
    const struct_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try alloc.dupe(u8, type_name),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try alloc.dupe(u8, type_name),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const method_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "finalize"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const receiver_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "self"),
        .span = span,
        .visibility = .private,
        .parent = method_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const capture_ids = try alloc.alloc(exprs.DefId, capture_count);
    for (fields, 0..) |field, index| {
        capture_ids[index] = try graph.symbol_table.add(.{
            .id = 0,
            .kind = .field,
            .name = try alloc.dupe(u8, field.binding),
            .span = span,
            .visibility = .private,
            .parent = method_id,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
    }

    const struct_type_segments = try alloc.dupe(types.PathSegment, &.{.{
        .name = try alloc.dupe(u8, type_name),
        .id = struct_id,
    }});
    const struct_type: types.Type = .{ .path = .{ .segments = struct_type_segments } };
    const types_store = try alloc.alloc(types.Type, 2);
    types_store[0] = struct_type;
    types_store[1] = .{ .prim = .u64 };

    const declared_fields = try alloc.alloc(items.Field, capture_count);
    for (fields, 0..) |field, index| {
        declared_fields[index] = .{
            .name = try alloc.dupe(u8, field.field),
            .ty = types_store[1],
            .visibility = .private,
            .span = span,
        };
    }

    const field_pats = try alloc.alloc(exprs.FieldPat, capture_count);
    const pats_store = try alloc.alloc(exprs.Pattern, capture_count + 1);
    for (fields, 0..) |field, index| {
        // The pattern index of this capture: pats are laid out struct-pattern
        // first so the field table and the binding table read the same order.
        const pattern_id: exprs.NodeId = @intCast(index + 1);
        field_pats[index] = .{
            .field = try alloc.dupe(u8, field.field),
            .pat = pattern_id,
            .shorthand = std.mem.eql(u8, field.field, field.binding),
        };
        pats_store[index + 1] = .{
            .id = pattern_id,
            .span = span,
            .ty = null,
            .kind = .{ .binding = .{
                .name = try alloc.dupe(u8, field.binding),
                .mode = .{ .value = {} },
                .mutable = false,
            } },
        };
    }
    pats_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .struct_pat = .{
            .def = struct_id,
            .fields = field_pats,
            .rest = false,
        } },
    };

    // Expr table: 0 = the `self` initializer, 1..n = the capture uses, the
    // n-1 `^` nodes after them, then the body block.
    const expr_count = 2 * capture_count + 1;
    const exprs_store = try alloc.alloc(exprs.Expr, expr_count);
    exprs_store[0] = .{
        .id = 0,
        .span = span,
        .ty = 0,
        .kind = .{ .path = .{ .def = receiver_id, .generic_args = &.{} } },
    };
    for (0..capture_count) |index| {
        const node: exprs.NodeId = @intCast(index + 1);
        exprs_store[node] = .{
            .id = node,
            .span = span,
            .ty = null,
            .kind = .{ .path = .{ .def = capture_ids[index], .generic_args = &.{} } },
        };
    }
    var accumulator: exprs.NodeId = 1;
    for (1..capture_count) |index| {
        const node: exprs.NodeId = @intCast(capture_count + index);
        exprs_store[node] = .{
            .id = node,
            .span = span,
            .ty = null,
            .kind = .{ .binary = .{
                .op = .bit_xor,
                .overflow = .checked,
                .lhs = accumulator,
                .rhs = @intCast(index + 1),
            } },
        };
        accumulator = node;
    }
    const tail_node: exprs.NodeId = @intCast(expr_count - 2);
    const block_node: exprs.NodeId = @intCast(expr_count - 1);
    exprs_store[block_node] = .{
        .id = block_node,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{0},
            .tail = tail_node,
            .labelled = null,
        } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 1);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 0, .init = 0, .ty = null } },
    };

    const params = try alloc.alloc(items.Param, 1);
    params[0] = .{ .name = "self", .ty = struct_type, .span = span };
    const entity_count = graph.symbol_table.entities.items.len;
    const bodies_store = try alloc.alloc(bodies.BodyKind, entity_count);
    for (bodies_store) |*body| body.* = .none;
    bodies_store[struct_id] = .{ .struct_ = .{ .fields = declared_fields } };
    bodies_store[impl_id] = .{ .impl_ = .{
        .self_ty = struct_type,
        .assoc_items = try alloc.dupe(spine.EntityId, &.{method_id}),
    } };
    bodies_store[method_id] = .{ .fn_ = .{
        .params = params,
        .ret = types_store[1],
        .body = block_node,
    } };

    return .{
        .exprs_store = exprs_store,
        .types_store = types_store,
        .bodies_store = bodies_store,
        .pats_store = pats_store,
        .stmts_store = stmts_store,
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = pats_store,
            .types = types_store,
            .bodies = bodies_store,
        },
        .graph = graph,
        .init_node = 0,
        .capture_use_node = 1,
        .capture_use_count = capture_count,
        .tail_node = tail_node,
    };
}

/// The five-field shape `SeaHash` writes, kept as its own constant so the test
/// below reads as the source it is about.
const seahash_state_fields = [_]DestructureField{
    .{ .field = "a", .binding = "a" },
    .{ .field = "b", .binding = "b" },
    .{ .field = "c", .binding = "c" },
    .{ .field = "d", .binding = "d" },
    .{ .field = "written", .binding = "written" },
};

test "a struct destructuring capture keeps its field's primitive type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `let State { a, b, c, d, written } = self; a ^ b ^ c ^ d ^ written`.
    // Every capture is a `u64`; the aggregate they came from is `State`. Both
    // facts are asserted on nodes that would have been unified into one class
    // by a capture equated with its initializer, which is why the struct's own
    // node is checked here too.
    var fixture = try buildDestructureFixture(alloc, "State", &seahash_state_fields);
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    const struct_id = inferred.getType(fixture.init_node) orelse
        return error.DestructuredInitializerStayedUntyped;
    try std.testing.expect(fixture.b.types[struct_id] == .path);
    for (0..fixture.capture_use_count) |index| {
        const node: exprs.NodeId = @intCast(fixture.capture_use_node + index);
        const capture_id = inferred.getType(node) orelse
            return error.DestructuredCaptureStayedUntyped;
        try std.testing.expectEqual(types.Type{ .prim = .u64 }, fixture.b.types[capture_id]);
        try std.testing.expect(capture_id != struct_id);
    }
    const tail_id = inferred.getType(fixture.tail_node) orelse
        return error.XorChainStayedUntyped;
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, fixture.b.types[tail_id]);
    try std.testing.expectEqual(
        exprs.BinaryOp.bit_xor,
        fixture.exprs_store[fixture.tail_node].kind.binary.op,
    );
}

test "a renamed struct capture binds the field it renames, not the whole struct" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `let Pair { big: hi, small } = pair; hi ^ small`. The field name and the
    // bound name differ, so a capture resolved by name lookup instead of by the
    // pattern it sits under would bind the wrong slot — or none.
    const fields = [_]DestructureField{
        .{ .field = "big", .binding = "hi" },
        .{ .field = "small", .binding = "small" },
    };
    var fixture = try buildDestructureFixture(alloc, "Pair", &fields);
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    const struct_id = inferred.getType(fixture.init_node) orelse
        return error.DestructuredInitializerStayedUntyped;
    for (0..fixture.capture_use_count) |index| {
        const node: exprs.NodeId = @intCast(fixture.capture_use_node + index);
        const capture_id = inferred.getType(node) orelse
            return error.RenamedCaptureStayedUntyped;
        try std.testing.expectEqual(types.Type{ .prim = .u64 }, fixture.b.types[capture_id]);
        try std.testing.expect(capture_id != struct_id);
    }
}

// ── Casts that wait for dispatch ────────────────────────────────────────────
//
// `x as T` over an operand nothing has typed yet is not a wrong cast, it is an
// unresolved one: the frontend records a placeholder source and leaves the
// verdict to whoever ends up holding a type for the operand. A standalone
// solver has no later phase, so it names the refusal on the spot — the
// `untyped cast operand` test above pins that. The full compiler does have a
// later phase: it asks the solver to leave the cast alone, adopts the
// resolver's final tables, and finishes the cast once the operand has a type.
const pending_cast_operand_node: exprs.NodeId = 0;
const pending_cast_node: exprs.NodeId = 1;
const pending_cast_body_node: exprs.NodeId = 2;

const PendingCastFixture = struct {
    exprs_store: []exprs.Expr,
    types_store: []types.Type,
    stmts_store: []exprs.Statement,
    bodies_store: []bodies.BodyKind,
    b: bodies.Bodies,

    fn deinit(self: *PendingCastFixture, alloc: std.mem.Allocator) void {
        alloc.free(self.bodies_store);
        alloc.free(self.stmts_store);
        alloc.free(self.types_store);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

/// `operand as <target>` with the recorded source still the frontend's pending
/// placeholder. Type row 0 is the destination and row 1 the operand's; the
/// operand carries row 1 only when `operand_typed` says the solve itself
/// already holds it, which is the difference between "the resolver will hand
/// this over" and "this arrived typed".
fn buildPendingCastFixture(
    alloc: std.mem.Allocator,
    kind: exprs.ConversionKind,
    operand_type: types.Type,
    operand_typed: bool,
    target_type: types.Type,
) !PendingCastFixture {
    const types_store = try alloc.alloc(types.Type, 2);
    types_store[0] = target_type;
    types_store[1] = operand_type;

    const exprs_store = try alloc.alloc(exprs.Expr, 3);
    exprs_store[pending_cast_operand_node] = .{
        .id = pending_cast_operand_node,
        .span = span,
        .ty = if (operand_typed) @as(?exprs.TypeId, 1) else null,
        // A `def` naming no entity, so nothing in the graph can type this path
        // however long the solve runs.
        .kind = .{ .path = .{ .def = 7, .generic_args = &.{} } },
    };
    exprs_store[pending_cast_node] = .{
        .id = pending_cast_node,
        .span = span,
        .ty = null,
        .kind = .{ .cast = .{
            .kind = kind,
            .operand = pending_cast_operand_node,
            .source_type = .{ .unsupported = .{
                .reason = .iterators,
                .message = "cast source type pending inference",
                .span = span,
            } },
            .target = 0,
        } },
    };
    exprs_store[pending_cast_body_node] = .{
        .id = pending_cast_body_node,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 1);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = pending_cast_node },
    };

    const bodies_store = try alloc.alloc(bodies.BodyKind, 1);
    bodies_store[0] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = pending_cast_body_node,
    } };

    return .{
        .exprs_store = exprs_store,
        .types_store = types_store,
        .stmts_store = stmts_store,
        .bodies_store = bodies_store,
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_store,
        },
    };
}

test "the deferred-cast opt-in leaves the cast exactly as the frontend recorded it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The same shape the standalone refusal test builds, run with the opt-in
    // on. Every field the frontend wrote has to come back out unchanged: the
    // conversion syntax, the operand it reads, the destination it named, and
    // the placeholder source that says "not yet".
    var fixture = try buildPendingCastFixture(
        alloc,
        .as_,
        .{ .prim = .u64 },
        false,
        .{ .prim = .u64 },
    );
    defer fixture.deinit(alloc);

    var generated = try infer.gen(alloc, &fixture.b);
    defer generated.deinit(alloc);
    generated.defer_pending_casts = true;

    var inferred = try infer.solveWithGen(alloc, &fixture.b, &generated);
    defer inferred.deinit(alloc);

    const cast = switch (fixture.exprs_store[pending_cast_node].kind) {
        .cast => |value| value,
        else => return error.DeferredCastWasRewritten,
    };
    try std.testing.expect(cast.kind == .as_);
    try std.testing.expectEqual(pending_cast_operand_node, cast.operand);
    try std.testing.expectEqual(@as(exprs.TypeId, 0), cast.target);
    try std.testing.expect(std.meta.activeTag(cast.source_type) == .unsupported);
    try std.testing.expectEqual(@as(?exprs.TypeId, null), inferred.getType(pending_cast_node));
}

test "the deferred-cast finalizer completes a resolved u64 source into a u32 destination" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The solver left the cast pending because the operand had no type yet.
    // Adopting the resolver's tables is what gives the operand one, and the
    // finalizer then has everything it needs: a genuine `u64` source and a
    // `u32` destination it may check against `isValidCast`.
    var fixture = try buildPendingCastFixture(
        alloc,
        .as_,
        .{ .prim = .u64 },
        false,
        .{ .prim = .u32 },
    );
    defer fixture.deinit(alloc);

    var generated = try infer.gen(alloc, &fixture.b);
    defer generated.deinit(alloc);
    generated.defer_pending_casts = true;
    var inferred = try infer.solveWithGen(alloc, &fixture.b, &generated);
    inferred.deinit(alloc);

    fixture.exprs_store[pending_cast_operand_node].ty = 1;
    try infer.completePendingCasts(&fixture.b);

    const cast = switch (fixture.exprs_store[pending_cast_node].kind) {
        .cast => |value| value,
        else => return error.CompletedCastWasRewritten,
    };
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, cast.source_type);
    try std.testing.expectEqual(@as(exprs.TypeId, 0), cast.target);
    try std.testing.expectEqual(
        @as(?exprs.TypeId, 0),
        fixture.exprs_store[pending_cast_node].ty,
    );
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, fixture.b.types[cast.target]);
}

test "the deferred-cast finalizer still names a cast whose operand never resolved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Waiting did not help this one. The operand is still untyped when the
    // finalizer runs, so there is no source type to rule on and any verdict
    // would be a guess — the same named refusal the standalone solver gives,
    // reached at the other end of the pipeline.
    var fixture = try buildPendingCastFixture(
        alloc,
        .as_,
        .{ .prim = .u64 },
        false,
        .{ .prim = .u32 },
    );
    defer fixture.deinit(alloc);

    try infer.completePendingCasts(&fixture.b);

    const marker = switch (fixture.exprs_store[pending_cast_node].kind) {
        .unsupported => |value| value,
        else => return error.UnresolvedCastWasGuessed,
    };
    try std.testing.expectEqualStrings(untyped_cast_operand_reason, marker.reason);
    try std.testing.expect(marker.suggested_version == .v1);
}

test "the deferred-cast finalizer stays strict about a conversion it cannot admit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Two conversions valid Rust writes down and this translator does not
    // admit, so the finalizer cannot become a hole the solver's strictness
    // used to close. `u64 as u32` through `From` narrows, and a thin pointer
    // cast off a slice drops the length the slice type carries.
    var narrowing = try buildPendingCastFixture(
        alloc,
        .primitive_from,
        .{ .prim = .u64 },
        true,
        .{ .prim = .u32 },
    );
    defer narrowing.deinit(alloc);
    try std.testing.expectError(error.InvalidCast, infer.completePendingCasts(&narrowing.b));

    const byte_slice = try alloc.create(types.Slice);
    byte_slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const borrowed_slice = try alloc.create(types.Ref);
    borrowed_slice.* = .{ .mut = false, .pointee = .{ .slice = byte_slice } };
    const thin_pointer = try alloc.create(types.RawPtr);
    thin_pointer.* = .{ .mut = false, .pointee = .{ .prim = .u16 } };
    var fat_to_thin = try buildPendingCastFixture(
        alloc,
        .as_,
        .{ .reference = borrowed_slice },
        true,
        .{ .raw_ptr = thin_pointer },
    );
    defer fat_to_thin.deinit(alloc);
    try std.testing.expectError(error.InvalidCast, infer.completePendingCasts(&fat_to_thin.b));
}

// ── Source regressions: real Rust through the pipeline ──────────────────────
//
// Everything above builds the IR by hand, which is the right way to ask what
// one decision does. These ask the other question — what a crate actually
// produces — so they drive Rust text through `pipeline` and then assert over
// the WHOLE type pool rather than the rows an expression still points at. A
// partial row the solver never needed is exactly where a hole survives, so a
// walk that follows only live expressions would stop one row short of it.

/// The one seam: real source in, the frontend's own model out.
fn analyzeSourceRegression(alloc: std.mem.Allocator, source: []const u8) !ir.RustIr {
    return pipeline.analyzeSource(alloc, "tuple_materialization", "2021", source);
}

fn typeAt(model: *const ir.RustIr, type_id: exprs.TypeId) ?types.Type {
    if (type_id >= model.bodies.types.len) return null;
    return model.bodies.types[type_id];
}

fn exprType(model: *const ir.RustIr, node: exprs.NodeId) ?types.Type {
    if (node >= model.bodies.exprs.len) return null;
    return typeAt(model, model.bodies.exprs[node].ty orelse return null);
}

fn entityName(model: *const ir.RustIr, def: exprs.DefId) ?[]const u8 {
    return (model.graph.symbol_table.get(def) orelse return null).name;
}

fn callCallee(model: *const ir.RustIr, call: exprs.Call) ?[]const u8 {
    const def = switch (call.call_kind) {
        .free => |id| id,
        .associated => |id| id,
        .constructor => |id| id,
    };
    return entityName(model, def);
}

/// The elements of a tuple literal's resolved type, or null when this node is
/// not one. A Rust `(a, b)` lowers to the same `.array` node an array literal
/// does, so the resolved type is what tells the two apart.
fn tupleElements(model: *const ir.RustIr, node: exprs.NodeId) ?[]const types.Type {
    if (node >= model.bodies.exprs.len) return null;
    if (model.bodies.exprs[node].kind != .array) return null;
    const type_id = model.bodies.exprs[node].ty orelse return null;
    return switch (typeAt(model, type_id) orelse return null) {
        .tuple => |elements| elements,
        else => null,
    };
}

/// The elements of a resolved tuple, whether this node IS the literal or the
/// binding that names it.
///
/// `hash(&s)` borrows through the `let` binding, not through the literal `s`
/// was built from, so the node a borrow points at is a path whose resolved
/// type is the tuple. What has to carry the leaves is the BORROW's own record;
/// which shape of node the borrow happens to name is not part of that question,
/// so reading it through a path is not a weaker check.
fn resolvedTupleElements(model: *const ir.RustIr, node: exprs.NodeId) ?[]const types.Type {
    if (node >= model.bodies.exprs.len) return null;
    const type_id = model.bodies.exprs[node].ty orelse return null;
    return switch (typeAt(model, type_id) orelse return null) {
        .tuple => |elements| elements,
        else => null,
    };
}

fn isPrim(ty: types.Type, prim: types.Prim) bool {
    return ty == .prim and ty.prim == prim;
}

/// `&str`: a shared borrow of the `str` primitive, which is what a string
/// literal is. The qualifier is part of the answer, so it is checked too.
fn isSharedStrRef(ty: types.Type) bool {
    const reference = switch (ty) {
        .reference => |value| value,
        else => return false,
    };
    return !reference.mut and types.isStr(reference.pointee);
}
/// A `&[i32]` — the shape a borrowed slice view reaches the type table as.
fn isBorrowedI32Slice(ty: types.Type) bool {
    const reference = switch (ty) {
        .reference => |value| value,
        else => return false,
    };
    const slice = switch (reference.pointee) {
        .slice => |value| value,
        else => return false,
    };
    return isPrim(slice.elem, .i32);
}

/// A slice view of `i32` elements, whether the node carries the slice itself
/// or a borrow of it: a range index and the `&` written in front of it are the
/// same view seen one layer apart.
fn isI32SliceView(ty: types.Type) bool {
    const slice = switch (ty) {
        .slice => |value| value,
        .reference => |reference| switch (reference.pointee) {
            .slice => |value| value,
            else => return false,
        },
        else => return false,
    };
    return isPrim(slice.elem, .i32);
}

test "source tuple strings stay &str leaves through the borrowed Hash argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `let s = ("aa", "bb"); hash(&s)`. A string literal is a borrow of `str`,
    // so a tuple of them is a tuple of borrows, and the borrow of THAT tuple is
    // what `hash` is asked to hash. A leaf that came back as a bare `str`, or a
    // tuple argument that lost its leaves, hashes the wrong bytes.
    const source =
        \\use core::hash::{Hash, Hasher};
        \\struct Trace { state: u64 }
        \\impl Hasher for Trace {
        \\    fn finish(&self) -> u64 { self.state }
        \\    fn write(&mut self, bytes: &[u8]) {
        \\        for &byte in bytes {
        \\            self.state = (self.state ^ byte as u64).wrapping_mul(1099511628211);
        \\        }
        \\    }
        \\}
        \\fn hash<T: Hash>(value: &T) -> u64 {
        \\    let mut state = Trace { state: 14695981039346656037 };
        \\    value.hash(&mut state);
        \\    state.finish()
        \\}
        \\pub fn tuple_strings() -> bool {
        \\    let s = ("aa", "bb");
        \\    let t = ("aabb", "");
        \\    let u = ("a", "abb");
        \\    hash(&s) != hash(&t) && hash(&s) != hash(&u)
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var string_leaves: usize = 0;
    var str_tuples: usize = 0;
    var borrowed_str_tuples: usize = 0;
    for (model.bodies.exprs, 0..) |expression, index| {
        const node: exprs.NodeId = @intCast(index);
        switch (expression.kind) {
            .literal => |literal| switch (literal) {
                .string => {
                    const leaf = exprType(&model, node) orelse
                        return error.UntypedStringLiteral;
                    if (!isSharedStrRef(leaf)) return error.StringLeafIsNotASharedStrRef;
                    string_leaves += 1;
                },
                else => {},
            },
            .array => {
                const elements = tupleElements(&model, node) orelse continue;
                if (elements.len != 2) continue;
                if (!isSharedStrRef(elements[0]) or !isSharedStrRef(elements[1])) continue;
                str_tuples += 1;
            },
            .unary => |unary| {
                if (unary.op != .ref) continue;
                const elements = resolvedTupleElements(&model, unary.operand) orelse continue;
                if (elements.len != 2) continue;
                if (!isSharedStrRef(elements[0]) or !isSharedStrRef(elements[1])) continue;
                borrowed_str_tuples += 1;
                // `hash(&s)` is asked about a REFERENCE to the tuple, so the
                // borrow node itself has to carry it, leaves and all.
                const borrow = exprType(&model, node) orelse
                    return error.UntypedBorrowedTuple;
                const reference = switch (borrow) {
                    .reference => |value| value,
                    else => return error.BorrowedTupleLostItsReference,
                };
                const borrowed = switch (reference.pointee) {
                    .tuple => |value| value,
                    else => return error.BorrowedTupleIsNotATuple,
                };
                if (borrowed.len != 2) return error.BorrowedTupleArityChanged;
                if (!isSharedStrRef(borrowed[0]) or !isSharedStrRef(borrowed[1])) {
                    return error.BorrowedTupleLeavesIncomplete;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6), string_leaves);
    try std.testing.expectEqual(@as(usize, 3), str_tuples);
    // One borrow per borrow SITE, not per tuple: the source writes `hash(&s)`
    // twice alongside `hash(&t)` and `hash(&u)`, so four borrowed tuples reach
    // the table and all four have to carry their leaves.
    try std.testing.expectEqual(@as(usize, 4), borrowed_str_tuples);
}

test "source tuple of borrowed slices defaults its elements to i32 and its indices to usize" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `let u = [1, 0, 0, 0]; (&u[..1], &u[1..3], &u[3..])`. Nothing here names
    // the element type: `i32` is what an unsuffixed integer defaults to once
    // Rust's own context has had its say. The range endpoints are a different
    // question — they are sequence indices, so they carry `usize` — and the
    // Range node itself is a view, never the scalar an endpoint happens to be.
    const source =
        \\use core::hash::{Hash, Hasher};
        \\struct Trace { state: u64 }
        \\impl Hasher for Trace {
        \\    fn finish(&self) -> u64 { self.state }
        \\    fn write(&mut self, bytes: &[u8]) {
        \\        for &byte in bytes {
        \\            self.state = (self.state ^ byte as u64).wrapping_mul(1099511628211);
        \\        }
        \\    }
        \\}
        \\fn hash<T: Hash>(value: &T) -> u64 {
        \\    let mut state = Trace { state: 14695981039346656037 };
        \\    value.hash(&mut state);
        \\    state.finish()
        \\}
        \\pub fn tuple_slices() -> bool {
        \\    let u = [1, 0, 0, 0];
        \\    let v = (&u[..1], &u[1..3], &u[3..]);
        \\    let w = (&u[..], &u[4..4], &u[4..4]);
        \\    hash(&v) != hash(&w)
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var array_literals: usize = 0;
    var range_views: usize = 0;
    var usize_endpoints: usize = 0;
    var borrowed_slice_views: usize = 0;
    var borrowed_slice_tuples: usize = 0;
    for (model.bodies.exprs, 0..) |expression, index| {
        const node: exprs.NodeId = @intCast(index);
        switch (expression.kind) {
            .array => {
                // `[1, 0, 0, 0]` and `(a, b)` reach the IR as the same node: an
                // array of elements with no repeat. What separates them is the
                // row the literal carries — one homogeneous element and a count
                // the source fixed, or one type per position. `repeat` is the
                // count in `[e; N]`, and this crate writes no such literal, so
                // gating on it would skip the one array it means to check and
                // read a tuple as an array beside it.
                const ty = exprType(&model, node) orelse return error.UntypedArrayLiteral;
                if (tupleElements(&model, node)) |elements| {
                    if (elements.len != 3) continue;
                    var all_borrowed = true;
                    for (elements) |element| {
                        if (!isBorrowedI32Slice(element)) all_borrowed = false;
                    }
                    if (all_borrowed) borrowed_slice_tuples += 1;
                    continue;
                }
                const row = switch (ty) {
                    .array => |value| value,
                    else => return error.ArrayLiteralHasNoArrayType,
                };
                if (!isPrim(row.elem, .i32)) return error.ArrayElementIsNotI32;
                if (row.len != .literal or row.len.literal != 4) {
                    return error.ArrayLiteralIsNotFourLong;
                }
                array_literals += 1;
            },
            .range => |range| {
                // The endpoints are sequence indices, so they carry `usize` —
                // they are not unconstrained integers that happened to default.
                const start_type = exprType(&model, range.start) orelse
                    return error.UntypedRangeStart;
                if (!isPrim(start_type, .usize)) return error.RangeStartIsNotUsize;
                usize_endpoints += 1;
                if (range.end) |end| {
                    const end_type = exprType(&model, end) orelse
                        return error.UntypedRangeEnd;
                    if (!isPrim(end_type, .usize)) return error.RangeEndIsNotUsize;
                    usize_endpoints += 1;
                }
                // A Range is a view over a sequence, and a view is never the
                // scalar its own endpoint happens to be.
                if (exprType(&model, node)) |ty| {
                    if (isPrim(ty, .usize)) return error.RangeNodeLabeledAsUsize;
                }
                // The view itself is over the array's element type.
                if (exprType(&model, node)) |ty| {
                    if (!isI32SliceView(ty)) return error.RangeViewIsNotAnI32Slice;
                    range_views += 1;
                }
            },
            .unary => |unary| {
                if (unary.op != .ref) continue;
                const operand_type = exprType(&model, unary.operand) orelse continue;
                if (!isI32SliceView(operand_type)) continue;
                const borrow_type = exprType(&model, node) orelse
                    return error.UntypedSliceBorrow;
                if (!isBorrowedI32Slice(borrow_type)) return error.SliceBorrowLostItsType;
                borrowed_slice_views += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), array_literals);
    try std.testing.expect(range_views >= 6);
    try std.testing.expect(usize_endpoints >= 8);
    try std.testing.expectEqual(@as(usize, 6), borrowed_slice_views);
    try std.testing.expectEqual(@as(usize, 2), borrowed_slice_tuples);
}

/// Whether any nested type in `ty` still carries the frontend's `_` hole. The
/// hole only ever appears as the last segment of an external nominal, so that
/// is where it is looked for — at every depth, because a hole one wrapper down
/// is still a hole the consumer cannot emit.
fn carriesInferenceHole(ty: types.Type) bool {
    return switch (ty) {
        .external_nominal => |external| blk: {
            if (external.path.len == 0) break :blk false;
            if (std.mem.eql(u8, external.path[external.path.len - 1], "_")) break :blk true;
            for (external.args) |arg| {
                if (carriesInferenceHole(arg)) break :blk true;
            }
            break :blk false;
        },
        .reference => |reference| carriesInferenceHole(reference.pointee),
        .raw_ptr => |pointer| carriesInferenceHole(pointer.pointee),
        .slice => |slice| carriesInferenceHole(slice.elem),
        .array => |array| carriesInferenceHole(array.elem),
        .tuple => |elements| blk: {
            for (elements) |element| {
                if (carriesInferenceHole(element)) break :blk true;
            }
            break :blk false;
        },
        .boxed => |boxed| carriesInferenceHole(boxed.*),
        .option => |payload| carriesInferenceHole(payload.*),
        .result => |value| carriesInferenceHole(value.ok) or
            carriesInferenceHole(value.err),
        .generic_inst => |instance| blk: {
            for (instance.args.params) |param| {
                if (carriesInferenceHole(param)) break :blk true;
            }
            break :blk false;
        },
        .@"opaque" => |opaque_type| blk: {
            const concrete = opaque_type.concrete orelse break :blk false;
            break :blk carriesInferenceHole(concrete.*);
        },
        .fn_ptr, .dyn_trait, .path, .prim, .unsupported => false,
    };
}

/// Every row of the type pool, not only the ones an expression still names: a
/// literal-private row the solver repointed away from is precisely the row a
/// filtered walk would stop looking at.
fn expectCompleteTypePool(model: *const ir.RustIr) !void {
    for (model.bodies.types, 0..) |row, index| {
        if (!carriesInferenceHole(row)) continue;
        std.debug.print("type row {d} still carries an inference hole\n", .{index});
        return error.IncompleteTypeRow;
    }
}

/// The strict validator and the canonical codec, both over the whole pool.
/// The decode is the consumer's own view of the same rows, so a hole that
/// survives either of them is a hole the generated package would carry.
fn expectCanonicalRoundTrip(alloc: std.mem.Allocator, model: *const ir.RustIr) !void {
    const encoded = try ir.serialize.encode(alloc, model);

    var decoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded_arena.deinit();
    const decoded_alloc = decoded_arena.allocator();

    var decoded = try ir.serialize.decode(decoded_alloc, encoded);
    defer decoded.graph.deinit();
    defer decoded.deinitInstantiations(decoded_alloc);

    try ir.validateForTranslation(&decoded);
    try expectCompleteTypePool(&decoded);
}

/// What every source regression below asserts about its own model, before it
/// says anything specific: it is a crate the rest of the pipeline would
/// accept, its whole type pool is complete, and that pool survives the wire.
fn expectValidAndCanonical(alloc: std.mem.Allocator, model: *const ir.RustIr) !void {
    try ir.validateForTranslation(model);
    try expectCompleteTypePool(model);
    try expectCanonicalRoundTrip(alloc, model);
}

test "atoi's Option map unwrap_or tuple keeps the enum identity and the usize offset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `.map(|sign| (sign, 1)).unwrap_or((Sign::Plus, 0))`. The `1` and the `0`
    // are unsuffixed and unknown until the positions around them say what they
    // are; the offset really is a `usize` and the sign really is the same enum
    // on both sides. A hand-built tuple with the answer already written into it
    // would say nothing about how the answer is reached.
    const source =
        \\#[derive(Clone, Copy)]
        \\enum Sign { Plus, Minus }
        \\impl Sign {
        \\    fn try_from(byte: u8) -> Option<Self> {
        \\        match byte {
        \\            b'+' => Some(Sign::Plus),
        \\            b'-' => Some(Sign::Minus),
        \\            _ => None,
        \\        }
        \\    }
        \\}
        \\pub fn atoi_offset(text: &[u8]) -> usize {
        \\    let (sign, offset) = text.first()
        \\        .and_then(|&byte| Sign::try_from(byte))
        \\        .map(|sign| (sign, 1))
        \\        .unwrap_or((Sign::Plus, 0));
        \\    let mut index;
        \\    index = offset;
        \\    while index != text.len() { let _ = text[index]; index += 1; }
        \\    match sign { Sign::Plus => index, Sign::Minus => index }
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var usize_tuples: usize = 0;
    var sign_slot: ?types.Type = null;
    for (model.bodies.exprs, 0..) |_, index| {
        const elements = tupleElements(&model, @intCast(index)) orelse continue;
        if (elements.len != 2) continue;
        if (!isPrim(elements[1], .usize)) continue;
        usize_tuples += 1;
        if (isPrim(elements[0], .u8) or isPrim(elements[0], .u32)) {
            return error.SignSlotCollapsedToAPrimitive;
        }
        if (sign_slot) |previous| {
            if (!types.deepEqual(previous, elements[0])) return error.SignSlotIdentitySplit;
        } else {
            sign_slot = elements[0];
        }
    }
    try std.testing.expect(usize_tuples >= 2);
    try std.testing.expect(sign_slot != null);

    // The tuple pattern the `let` binds carries the same two types, and each
    // leaf carries its own slot's type rather than the tuple's.
    var pattern_checked = false;
    for (model.bodies.pats) |pattern| {
        const tuple_pattern = switch (pattern.kind) {
            .tuple => |value| value,
            else => continue,
        };
        if (tuple_pattern.elements.len != 2) continue;
        const pattern_id = pattern.ty orelse return error.UntypedTuplePattern;
        const pattern_type = typeAt(&model, pattern_id) orelse
            return error.UntypedTuplePattern;
        const slots = switch (pattern_type) {
            .tuple => |value| value,
            else => return error.TuplePatternHasNoTupleType,
        };
        if (slots.len != 2) return error.TuplePatternArityChanged;
        if (!isPrim(slots[1], .usize)) return error.TuplePatternOffsetIsNotUsize;
        if (sign_slot) |expected| {
            if (!types.deepEqual(expected, slots[0])) return error.TuplePatternSignDiverged;
        }
        for (tuple_pattern.elements, 0..) |element, slot| {
            const leaf_id = model.bodies.pats[element].ty orelse
                return error.UntypedTuplePatternLeaf;
            const leaf = typeAt(&model, leaf_id) orelse
                return error.UntypedTuplePatternLeaf;
            if (!types.deepEqual(leaf, slots[slot])) {
                return error.TuplePatternLeafDivergedFromItsSlot;
            }
        }
        pattern_checked = true;
        break;
    }
    try std.testing.expect(pattern_checked);
}

/// `Option<u8>`, in either of the two spellings this IR writes it.
///
/// `preludeVariantType` builds the nominal — `core::option::Option` with the
/// one argument it was given — because that is the identity a CONSTRUCTOR
/// carries. A type the SOURCE spells `Option<u8>` is the builtin `.option`
/// instead (`mapCstNamedType`), and a peer's declared return is spelled by the
/// source, so the demand a comparison pushes into a `None` slot is that
/// spelling. Both are `Option<u8>`; neither is a weaker answer than the other,
/// and reading only one of them made this predicate report a correctly named
/// option as unnamed. What it still insists on is the substance: the option
/// `core::option::Option` names, over exactly `payload`.
fn isOptionOf(ty: types.Type, payload: types.Prim) bool {
    switch (ty) {
        .option => |inner| return isPrim(inner.*, payload),
        .external_nominal => {},
        else => return false,
    }
    const external = ty.external_nominal;
    if (external.path.len != 3) return false;
    if (!std.mem.eql(u8, external.path[0], "core")) return false;
    if (!std.mem.eql(u8, external.path[1], "option")) return false;
    if (!std.mem.eql(u8, external.path[2], "Option")) return false;
    if (external.args.len != 1) return false;
    return isPrim(external.args[0], payload);
}

test "a comparison names the option a `None` slot stands for" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `(None, 3) == pair()` beside `fn pair() -> (Option<u8>, usize)`. `None`
    // carries no payload, so nothing inside the literal says what it is:
    // `preludeVariantType` reads a payload to build the option from and
    // `knownSourceEnumVariantType` refuses a generic enum, which is exactly
    // what `Option` is. The private row the literal built was therefore
    // `(_, _)`, and the Defaults Phase turned the second slot into the `i32`
    // an unconstrained integer literal becomes. The comparison is the only
    // thing in the source that names either slot, and reading its peer as
    // already answered is what left the `_` standing in a row `validate` then
    // refuses as `IncompleteGenericMetadata`. This is the shape of `atoi`'s own
    // `assert_eq!((None, 3), u8::from_radix_10_checked(b"256"))`.
    const source =
        \\fn pair() -> (Option<u8>, usize) { (Some(1u8), 2) }
        \\pub fn agrees() -> bool { (None, 3) == pair() }
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var compared: usize = 0;
    for (model.bodies.exprs) |expression| {
        const binary = switch (expression.kind) {
            .binary => |value| value,
            else => continue,
        };
        if (binary.op != .eq) continue;
        const elements = tupleElements(&model, binary.lhs) orelse continue;
        if (elements.len != 2) continue;
        compared += 1;
        if (!isPrim(elements[1], .usize)) return error.OffsetSlotIsNotUsize;
        if (!isOptionOf(elements[0], .u8)) return error.NoneSlotIsNotAnOptionOfU8;
    }
    // One comparison in the source, and it is the one that has to be resolved:
    // a count that reached zero would let the loop pass without ever asking.
    try std.testing.expectEqual(@as(usize, 1), compared);
}

test "a source private generic return row survives the return expression being repointed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `fn generic_return<I: Clone>(number: I, text: &[u8]) -> (I, usize)`. The
    // declared return is a tuple whose first slot is a lexical type parameter.
    // `I` is neither a hole nor a primitive: it is a name the crate wrote, and
    // the row the tuple literal built privately has to keep saying so even when
    // the solver repoints the expression at the declared row.
    const source =
        \\pub fn generic_return<I: Clone>(number: I, text: &[u8]) -> (I, usize) {
        \\    let mut index = 0;
        \\    while index != text.len() { index += 1; }
        \\    (number, index)
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    const return_id = for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind == .fn_ and std.mem.eql(u8, entity.name, "generic_return")) break entity.id;
    } else return error.GenericReturnNotFound;
    const declared = switch (model.bodies.bodies[return_id]) {
        .fn_ => |fn_body| fn_body.ret,
        else => return error.GenericReturnHasNoBody,
    };
    const slots = switch (declared) {
        .tuple => |value| value,
        else => return error.GenericReturnIsNotATuple,
    };
    if (slots.len != 2) return error.GenericReturnArityChanged;
    if (!isPrim(slots[1], .usize)) return error.GenericReturnSecondSlotIsNotUsize;
    const parameter = switch (slots[0]) {
        .path => |value| value,
        else => return error.GenericReturnFirstSlotIsNotALexicalPath,
    };
    if (parameter.segments.len != 1 or !std.mem.eql(u8, parameter.segments[0].name, "I")) {
        return error.GenericReturnFirstSlotIsNotTheTypeParameter;
    }

    // The literal's own row is a second row with the same shape, and it is the
    // one a walk that only follows live expressions would never look at.
    var literal_tuples: usize = 0;
    for (model.bodies.exprs, 0..) |_, index| {
        const elements = tupleElements(&model, @intCast(index)) orelse continue;
        if (elements.len != 2) continue;
        literal_tuples += 1;
        if (!types.deepEqual(elements[0], slots[0])) return error.LiteralRowLostItsParameter;
        if (!isPrim(elements[1], .usize)) return error.LiteralRowLostItsUsize;
    }
    try std.testing.expectEqual(@as(usize, 1), literal_tuples);

    // Every arity-2 row that carries a `usize` in its second slot must still
    // carry the parameter in its first: no row anywhere was left half-built.
    var complete_rows: usize = 0;
    for (model.bodies.types) |row| {
        const row_slots = switch (row) {
            .tuple => |value| value,
            else => continue,
        };
        if (row_slots.len != 2) continue;
        if (!isPrim(row_slots[1], .usize)) continue;
        complete_rows += 1;
        if (!types.deepEqual(row_slots[0], slots[0])) {
            return error.PoolRowLostItsTypeParameter;
        }
    }
    try std.testing.expect(complete_rows >= 1);
}

test "a nested borrowed tuple takes the contextual u8 rather than a defaulted i32" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `let borrowed = &7; let pair = ((borrowed, true), 0); byte_ref(pair.0.0)`.
    // Nothing near the `7` says `u8`; the callee's own parameter is what says
    // so. Seeding the borrow as `&i32` on the way in makes the nested tuple's
    // first slot wrong for every reader downstream, and the seeding is invisible
    // afterwards.
    const source =
        \\fn byte_ref(value: &u8) -> u8 { *value }
        \\pub fn nested_borrow() -> u8 {
        \\    let borrowed = &7;
        \\    let pair = ((borrowed, true), 0);
        \\    let result = byte_ref(pair.0.0);
        \\    let count: usize = pair.1;
        \\    result + count as u8
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    // Nothing in this crate is a borrow of a defaulted integer.
    for (model.bodies.exprs) |expression| {
        const ty = exprType(&model, expression.ty orelse continue) orelse continue;
        const reference = switch (ty) {
            .reference => |value| value,
            else => continue,
        };
        if (isPrim(reference.pointee, .i32)) return error.BorrowSeededAsAReferenceToI32;
    }

    // `&7` and the `7` inside it both came out `&u8` / `u8`.
    var borrowed_literals: usize = 0;
    for (model.bodies.exprs, 0..) |expression, index| {
        const node: exprs.NodeId = @intCast(index);
        const literal = switch (expression.kind) {
            .literal => |value| value,
            else => continue,
        };
        const integer = switch (literal) {
            .int => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, integer.text, "7")) continue;
        const literal_ty = exprType(&model, node) orelse continue;
        if (!isPrim(literal_ty, .u8)) return error.BorrowedLiteralIsNotU8;

        for (model.bodies.exprs, 0..) |_, outer| {
            const outer_node: exprs.NodeId = @intCast(outer);
            const unary = switch (model.bodies.exprs[outer_node].kind) {
                .unary => |value| value,
                else => continue,
            };
            if (unary.op != .ref or unary.operand != node) continue;
            borrowed_literals += 1;
            const borrow = exprType(&model, outer_node) orelse
                return error.UntypedBorrow;
            const reference = switch (borrow) {
                .reference => |value| value,
                else => return error.BorrowIsNotAReference,
            };
            if (reference.mut) return error.BorrowOfALiteralIsMutable;
            if (!isPrim(reference.pointee, .u8)) return error.BorrowOfALiteralIsNotU8;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), borrowed_literals);

    // `byte_ref(pair.0.0)` is what supplied the type; its argument has to be
    // the borrow the callee declares, or the chain never got there.
    var argument_checked = false;
    for (model.bodies.exprs) |expression| {
        const call = switch (expression.kind) {
            .call => |value| value,
            else => continue,
        };
        const name = callCallee(&model, call) orelse continue;
        if (!std.mem.eql(u8, name, "byte_ref")) continue;
        if (call.args.len != 1) return error.ByteRefArgumentCountChanged;
        const argument = exprType(&model, call.args[0]) orelse
            return error.UntypedByteRefArgument;
        const reference = switch (argument) {
            .reference => |value| value,
            else => return error.ByteRefArgumentIsNotABorrow,
        };
        if (!isPrim(reference.pointee, .u8)) return error.ByteRefArgumentIsNotAU8Borrow;
        argument_checked = true;
    }
    try std.testing.expect(argument_checked);

    // `let count: usize = pair.1;` — the annotated slot keeps what it declared.
    var annotated_slot = false;
    for (model.bodies.exprs) |expression| {
        const field = switch (expression.kind) {
            .field => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, field.field, "1")) continue;
        const base_type = exprType(&model, field.base) orelse continue;
        const inner = switch (base_type) {
            .tuple => |value| value,
            else => continue,
        };
        if (inner.len != 2) continue;
        if (!isPrim(inner[1], .usize)) return error.AnnotatedTupleSlotIsNotUsize;
        annotated_slot = true;
    }
    try std.testing.expect(annotated_slot);
}

test "a shadowed tuple binding stays a separate row from the one it shadows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `let pair = (7, true);` and, inside a block, `let pair = (9, false);`.
    // Two bindings, two tuples, two rows — the inner one a `u64` because
    // `wide` asks for one and the outer a `u8` because `byte` does. A scope
    // keyed by the NAME rather than by the definition the binding resolved to
    // would hand both of them the same row.
    const source =
        \\fn byte(value: u8) -> u8 { value }
        \\fn wide(value: u64) -> u64 { value }
        \\pub fn shadowed_rows() -> u64 {
        \\    let pair = (7, true);
        \\    let small = byte(pair.0);
        \\    let large = { let pair = (9, false); wide(pair.0) };
        \\    small as u64 + large
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var narrow_row: ?exprs.TypeId = null;
    var wide_row: ?exprs.TypeId = null;
    for (model.bodies.exprs, 0..) |_, index| {
        const node: exprs.NodeId = @intCast(index);
        const elements = tupleElements(&model, node) orelse continue;
        if (elements.len != 2) continue;
        if (!isPrim(elements[1], .bool)) continue;
        if (isPrim(elements[0], .u8)) narrow_row = model.bodies.exprs[node].ty;
        if (isPrim(elements[0], .u64)) wide_row = model.bodies.exprs[node].ty;
    }
    const narrow_id = narrow_row orelse return error.ShadowedNarrowRowMissing;
    const wide_id = wide_row orelse return error.ShadowedWideRowMissing;
    try std.testing.expect(narrow_id != wide_id);

    const encoded = try ir.serialize.encode(alloc, &model);
    var decoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded_arena.deinit();
    const decoded_alloc = decoded_arena.allocator();
    var decoded = try ir.serialize.decode(decoded_alloc, encoded);
    defer decoded.graph.deinit();
    defer decoded.deinitInstantiations(decoded_alloc);

    // The two rows stay two rows across the wire, each with its own first slot.
    var decoded_narrow: usize = 0;
    var decoded_wide: usize = 0;
    for (decoded.bodies.types) |row| {
        const slots = switch (row) {
            .tuple => |value| value,
            else => continue,
        };
        if (slots.len != 2) continue;
        if (!isPrim(slots[1], .bool)) continue;
        if (isPrim(slots[0], .u8)) decoded_narrow += 1;
        if (isPrim(slots[0], .u64)) decoded_wide += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), decoded_narrow);
    try std.testing.expectEqual(@as(usize, 1), decoded_wide);
}

test "a trait method on u64 returning &'static str types its receiver and feeds a cast" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `impl Label for u64 { fn label_text(&self) -> &'static str }` reached as
    // `value.label_text().len() as isize`. The receiver is a primitive, which is
    // the one shape a source method lookup cannot read a nominal name out of,
    // and the trait impl is the only thing in this crate that can type the call
    // at all — so if the receiver names no type, nothing downstream has a `&str`
    // to take a length of.
    const source =
        \\pub trait Label {
        \\    fn label_text(&self) -> &'static str;
        \\}
        \\impl Label for u64 {
        \\    fn label_text(&self) -> &'static str { "kib" }
        \\}
        \\pub fn label_width() -> isize {
        \\    let value: u64 = 4096;
        \\    value.label_text().len() as isize
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var label_call: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |expression, index| {
        const node: exprs.NodeId = @intCast(index);
        const call = switch (expression.kind) {
            .method_call => |value| value,
            else => continue,
        };
        const name = entityName(&model, call.method) orelse continue;
        if (!std.mem.eql(u8, name, "label_text")) continue;
        const ty = exprType(&model, node) orelse return error.UntypedLabelCall;
        if (!isSharedStrRef(ty)) return error.LabelCallIsNotASharedStrRef;
        label_call = node;
    }
    const str_node = label_call orelse return error.LabelCallNotFound;

    var len_call: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |_, index| {
        const node: exprs.NodeId = @intCast(index);
        const call = switch (model.bodies.exprs[node].kind) {
            .method_call => |value| value,
            else => continue,
        };
        if (call.receiver != str_node) continue;
        const name = entityName(&model, call.method) orelse continue;
        if (!std.mem.eql(u8, name, "len")) continue;
        if (!isPrim(exprType(&model, node) orelse return error.UntypedLenCall, .usize)) {
            return error.LenOfASharedStrIsNotUsize;
        }
        len_call = node;
    }
    const len_node = len_call orelse return error.LenCallNotFound;

    var cast_checked = false;
    for (model.bodies.exprs, 0..) |_, index| {
        const node: exprs.NodeId = @intCast(index);
        const cast = switch (model.bodies.exprs[node].kind) {
            .cast => |value| value,
            else => continue,
        };
        if (cast.operand != len_node) continue;
        if (!isPrim(cast.source_type, .usize)) return error.CastSourceIsNotTheLenUsize;
        const destination = typeAt(&model, cast.target) orelse return error.UntypedCastTarget;
        if (!isPrim(destination, .isize)) return error.CastDestinationIsNotIsize;
        cast_checked = true;
    }
    try std.testing.expect(cast_checked);
}

test "a dynamic vec repeat count is visited and typed before the vector is built" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `vec![7u8; count()]`. The count is an EXPRESSION, not a literal, so it is
    // a node of its own that has to be walked and typed like any other. A
    // walker that looked only at the repeat's text, or skipped the node
    // entirely, would leave the count — and the locals inside it — untyped.
    const source =
        \\fn count() -> usize { 3 }
        \\pub fn repeated() -> usize {
        \\    let values = vec![7u8; { let extra = 2; count() + extra }];
        \\    values.len()
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    // The count subtree: the `count()` call, its `usize` return, the block that
    // holds it and the `extra` local inside that block.
    var count_call: ?exprs.NodeId = null;
    var extra_local_usize = false;
    var vec_u8 = false;
    for (model.bodies.exprs, 0..) |expression, index| {
        const node: exprs.NodeId = @intCast(index);
        switch (expression.kind) {
            .call => |call| {
                const name = callCallee(&model, call) orelse continue;
                if (!std.mem.eql(u8, name, "count")) continue;
                if (!isPrim(exprType(&model, node) orelse return error.UntypedCountCall, .usize)) {
                    return error.CountCallIsNotUsize;
                }
                count_call = node;
            },
            .vec_lit => {
                // `Vec` is ONE canonical external nominal, and the element the
                // macro names is its single argument. A `generic_inst` here
                // would be a different type wearing the same name — and its
                // `decl` is an ENTITY id, so nothing in the type table is
                // addressed by it at all.
                try std.testing.expect(types.deepEqual(
                    types.Type{ .external_nominal = .{
                        .path = &.{ "alloc", "vec", "Vec" },
                        .args = &.{.{ .prim = .u8 }},
                    } },
                    exprType(&model, node) orelse return error.UntypedVecLiteral,
                ));
                vec_u8 = true;
            },
            .path => |path| {
                const name = entityName(&model, path.def) orelse continue;
                if (!std.mem.eql(u8, name, "extra")) continue;
                if (isPrim(exprType(&model, node) orelse continue, .usize)) {
                    extra_local_usize = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(count_call != null);
    try std.testing.expect(extra_local_usize);
    try std.testing.expect(vec_u8);

    // The repeat is an EXPRESSION, and the node it names is the count the
    // source wrote — the block that holds the call, not the call itself. So
    // the question is not whether the repeat points AT `count()`, but whether
    // the count subtree it does name is typed: the block, the `extra` local it
    // declares and the call all survive as nodes the backend can emit, rather
    // than as a constant the frontend invented.
    const count_node = count_call.?;
    var count_root: ?exprs.NodeId = null;
    for (model.bodies.exprs) |expression| {
        const vector = switch (expression.kind) {
            .vec_lit => |value| value,
            else => continue,
        };
        const repeat = vector.repeat orelse continue;
        switch (repeat) {
            .literal => continue,
            .expression => |root| count_root = root,
        }
    }
    const root = count_root orelse return error.DynamicCountRootMissing;
    if (!isPrim(exprType(&model, root) orelse return error.UntypedCountRoot, .usize)) {
        return error.CountRootIsNotUsize;
    }

    // Reach is a fact about the WALK from the root the vec literal actually
    // names, not about one node: the count subtree has to be reachable whether
    // the root is the block, its tail, or the call the block ends in.
    var walker = try exprs.NodeWalker.init(
        alloc,
        model.bodies.exprs,
        model.bodies.stmts,
        model.bodies.pats,
        model.bodies.types,
    );
    defer walker.deinit();
    try walker.reset(root);
    var reaches_call = false;
    var reaches_extra = false;
    while (try walker.next()) |reachable| {
        const reached = switch (reachable) {
            .expression => |id| id,
            else => continue,
        };
        if (reached == count_node) reaches_call = true;
        const path = switch (model.bodies.exprs[reached].kind) {
            .path => |value| value,
            else => continue,
        };
        const name = entityName(&model, path.def) orelse continue;
        if (std.mem.eql(u8, name, "extra")) reaches_extra = true;
    }
    try std.testing.expect(reaches_call);
    try std.testing.expect(reaches_extra);
}

test "a source trait method declared u64 types the &mut self call its cast narrows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `trait Wide { fn wide(&mut self) -> u64 }` implemented for a local
    // struct, reached as `counter.wide() as u32` on a `&mut Counter`. Nothing
    // at the use site names a type: no inherent block, no turbofish, no
    // annotation, and no standard rule claims `wide`. So the call's `u64` can
    // only have come from the trait impl's declaration, and the cast that
    // consumed it is where that answer is visible — a call left untyped leaves
    // the cast carrying the frontend's "source type pending" placeholder.
    const source =
        \\pub trait Wide {
        \\    fn wide(&mut self) -> u64;
        \\}
        \\pub struct Counter {
        \\    value: u64,
        \\}
        \\impl Wide for Counter {
        \\    fn wide(&mut self) -> u64 { self.value }
        \\}
        \\pub fn narrow(counter: &mut Counter) -> u32 {
        \\    counter.wide() as u32
        \\}
    ;
    const model = try analyzeSourceRegression(alloc, source);
    try expectValidAndCanonical(alloc, &model);

    var wide_call: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |_, index| {
        const node: exprs.NodeId = @intCast(index);
        const call = switch (model.bodies.exprs[node].kind) {
            .method_call => |value| value,
            else => continue,
        };
        const name = entityName(&model, call.method) orelse continue;
        if (!std.mem.eql(u8, name, "wide")) continue;
        if (!isPrim(exprType(&model, node) orelse return error.UntypedWideCall, .u64)) {
            return error.TraitDeclaredWideCallIsNotU64;
        }
        wide_call = node;
    }
    const call_node = wide_call orelse return error.WideCallNotFound;

    var cast_checked = false;
    for (model.bodies.exprs, 0..) |_, index| {
        const node: exprs.NodeId = @intCast(index);
        const cast = switch (model.bodies.exprs[node].kind) {
            .cast => |value| value,
            else => continue,
        };
        if (cast.operand != call_node) continue;
        // The cast SURVIVED, and it survived carrying the declared `u64` as its
        // source and the `u32` the source spelled as its destination.
        if (!isPrim(cast.source_type, .u64)) return error.CastSourceIsNotTheDeclaredU64;
        const destination = typeAt(&model, cast.target) orelse return error.UntypedCastTarget;
        if (!isPrim(destination, .u32)) return error.CastDestinationIsNotU32;
        cast_checked = true;
    }
    try std.testing.expect(cast_checked);
}

// ── Inherited generic parameters ──────────────────────────────────────────────
//
// A method that declares no type parameter of its own binds the ones the
// DECLARATION it is nested in declares, and that is the only question
// `getGenericParamNames` answers. `impl<S: Sip> Hasher<S> { fn new_with_keys(k0:
// u64, k1: u64) -> Hasher<S> }` records zero parameters on the function and one
// on the impl; the call still has to produce `Hasher<Sip24Rounds>`, and a row
// naming the FUNCTION with one argument is an instantiation no declaration can
// have — `validateInstantiations` counts the entity's own parameters and finds
// none.

/// Entity ids are fixed because the body table is indexed by entity id.
const inherited_module: exprs.DefId = 0;
const inherited_struct: exprs.DefId = 1;
const inherited_impl: exprs.DefId = 2;
const inherited_method: exprs.DefId = 3;
const inherited_owner: exprs.DefId = 4;

/// Expr table: 0 = the argument that carries the parameter, 1 =
/// `Cell::<..>::from_radix_10_checked(..)`, 2 = the callee's own empty body,
/// 3 = the enclosing `fn`'s body block.
const inherited_arg_node: exprs.NodeId = 0;
const inherited_call_node: exprs.NodeId = 1;
const inherited_method_body_node: exprs.NodeId = 2;
const inherited_owner_body_node: exprs.NodeId = 3;

/// Type rows: 0 = the BARE type parameter, 1 = the argument's own type,
/// 2 = the substituted result, 3 = the owner's declared return.
const inherited_param_row: exprs.TypeId = 0;
const inherited_arg_type: exprs.TypeId = 1;
const inherited_result_type: exprs.TypeId = 2;
const inherited_owner_return_type: exprs.TypeId = 3;

const InheritedParamFixture = struct {
    exprs_store: []exprs.Expr,
    stmts_store: []exprs.Statement,
    types_store: []types.Type,
    bodies_store: []bodies.BodyKind,
    b: bodies.Bodies,
    graph: crate_graph.CrateGraph,

    fn deinit(self: *InheritedParamFixture, alloc: std.mem.Allocator) void {
        self.graph.deinit();
        alloc.free(self.bodies_store);
        alloc.free(self.types_store);
        alloc.free(self.stmts_store);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

const InheritedParamSpec = struct {
    /// What `struct Cell<..>` declares. Non-empty also parents the method to
    /// the STRUCT, which is where Rust puts a method written inside it.
    struct_type_params: []const []const u8 = &.{},
    /// What `impl<..> FromRadix10Checked for Cell` declares. Non-empty parents
    /// the method to the impl instead.
    impl_type_params: []const []const u8 = &.{},
    /// The callee's OWN parameters, in the order the call passes them. It
    /// declares no type parameter of its own whatever these carry.
    callee_params: []const items.Param,
    /// The `->` the callee declares.
    declared_return: types.Type,
    /// What the one argument is written with; also the concrete every inherited
    /// parameter is instantiated at.
    argument_type: types.Type,
    /// The row the substitution is expected to land on.
    expected_result: types.Type,
};

fn buildInheritedParamFixture(
    alloc: std.mem.Allocator,
    spec: InheritedParamSpec,
) !InheritedParamFixture {
    const parameter_name = if (spec.struct_type_params.len != 0)
        spec.struct_type_params[0]
    else if (spec.impl_type_params.len != 0)
        spec.impl_type_params[0]
    else
        return error.NoDeclarationBindsTheParameter;
    try std.testing.expectEqual(@as(usize, 1), spec.callee_params.len);

    var graph = crate_graph.CrateGraph.init(alloc);
    errdefer graph.deinit();

    const module_id = try graph.symbol_table.add(.{
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
    try std.testing.expectEqual(inherited_module, module_id);
    const struct_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Cell"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(inherited_struct, struct_id);
    const impl_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try alloc.dupe(u8, "FromRadix10Checked for Cell"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(inherited_impl, impl_id);
    // A method written inside an `impl` belongs to that impl, and a method
    // written inside a `struct` block belongs to that struct. Which one this
    // fixture models is exactly what the parameter under test is inherited from.
    const method_parent: spine.EntityId = if (spec.impl_type_params.len == 0)
        struct_id
    else
        impl_id;
    const method_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "from_radix_10_checked"),
        .span = span,
        .visibility = .public,
        .parent = method_parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(inherited_method, method_id);
    const owner_id = try graph.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "run"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try std.testing.expectEqual(inherited_owner, owner_id);

    const parameter_path: types.Type = .{ .path = .{ .segments = try alloc.dupe(
        types.PathSegment,
        &.{.{ .name = try alloc.dupe(u8, parameter_name), .id = null }},
    ) } };
    const parameter_args = try alloc.dupe(types.Type, &.{parameter_path});
    const impl_self_ty: types.Type = .{ .generic_inst = .{
        .decl = struct_id,
        .args = .{ .params = parameter_args },
    } };
    const impl_generics: ?types.Generics = blk: {
        if (spec.impl_type_params.len == 0) break :blk null;
        const params = try alloc.alloc(types.GenericParam, spec.impl_type_params.len);
        for (spec.impl_type_params, 0..) |name, index| {
            params[index] = .{ .type_ = .{
                .name = try alloc.dupe(u8, name),
                .bounds = &.{},
            } };
        }
        break :blk .{ .params = params, .where_clauses = &.{} };
    };

    const types_store = try alloc.alloc(types.Type, 4);
    // The bare parameter IS interned here, on purpose. A name scan contributes
    // a one-segment path only when that path has no row of its own, so with
    // this row present the scan sees nothing at all — which is what makes the
    // scope walk, and not the signature, the only thing that can bind it.
    types_store[inherited_param_row] = parameter_path;
    types_store[inherited_arg_type] = spec.argument_type;
    types_store[inherited_result_type] = spec.expected_result;
    types_store[inherited_owner_return_type] = .{ .prim = .unit };

    const exprs_store = try alloc.alloc(exprs.Expr, 4);
    exprs_store[inherited_arg_node] = .{
        .id = inherited_arg_node,
        .span = span,
        .ty = inherited_arg_type,
        .kind = .{ .path = .{ .def = module_id, .generic_args = &.{} } },
    };
    exprs_store[inherited_call_node] = .{
        .id = inherited_call_node,
        .span = span,
        .ty = null,
        .kind = .{ .call = .{
            .call_kind = .{ .associated = method_id },
            .args = try alloc.dupe(exprs.NodeId, &.{inherited_arg_node}),
        } },
    };
    exprs_store[inherited_method_body_node] = .{
        .id = inherited_method_body_node,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
    };
    // The call is a STATEMENT, not the enclosing function's tail. A tail call
    // is additionally handed the owner's own declared return as an expectation,
    // and what this fixture is about is the substitution the callee's scope
    // produces, not which of two answers to the same node arrives last.
    exprs_store[inherited_owner_body_node] = .{
        .id = inherited_owner_body_node,
        .span = span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 1);
    stmts_store[0] = .{
        .id = 0,
        .span = span,
        .ty = null,
        .kind = .{ .expr = inherited_call_node },
    };

    const bodies_store = try alloc.alloc(bodies.BodyKind, 5);
    bodies_store[inherited_module] = .none;
    bodies_store[inherited_struct] = .{ .struct_ = .{
        .generic_params = spec.struct_type_params,
    } };
    bodies_store[inherited_impl] = .{ .impl_ = .{
        .self_ty = impl_self_ty,
        .trait_path = .{ .segments = try alloc.dupe(
            types.PathSegment,
            &.{.{ .name = "FromRadix10Checked", .id = null }},
        ) },
        .generics = impl_generics,
        .assoc_items = try alloc.dupe(spine.EntityId, &.{method_id}),
    } };
    // The callee declares NOTHING of its own. That is the point: every parameter
    // it binds belongs to the declaration above it.
    bodies_store[inherited_method] = .{ .fn_ = .{
        .params = spec.callee_params,
        .ret = spec.declared_return,
        .generic_params = &.{},
        .body = inherited_method_body_node,
    } };
    bodies_store[inherited_owner] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = inherited_owner_body_node,
    } };

    return .{
        .exprs_store = exprs_store,
        .stmts_store = stmts_store,
        .types_store = types_store,
        .bodies_store = bodies_store,
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_store,
        },
        .graph = graph,
    };
}

test "a method of a generic struct binds the parameter the struct declares" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `struct Hasher<S> { .. }` with `fn from_radix_10_checked(payload: S) ->
    // Hasher<S>` written inside it, reached as `Hasher::from_radix_10_checked(x)`
    // with `x: u8`. The function's own body records no parameter, and the bare
    // `S` already has a row in the type table, so nothing in the signature can
    // be read as a parameter name — only the scope walk finds it.
    const parameter_segments = [_]types.PathSegment{.{ .name = "S", .id = null }};
    const parameter_path: types.Type = .{ .path = .{ .segments = &parameter_segments } };
    const parameter_args = [_]types.Type{parameter_path};
    const concrete_args = [_]types.Type{.{ .prim = .u8 }};
    const callee_params = [_]items.Param{.{
        .name = "payload",
        .ty = parameter_path,
        .span = span,
    }};
    const declared_return: types.Type = .{ .generic_inst = .{
        .decl = inherited_struct,
        .args = .{ .params = &parameter_args },
    } };
    const expected_result: types.Type = .{ .generic_inst = .{
        .decl = inherited_struct,
        .args = .{ .params = &concrete_args },
    } };

    var fixture = try buildInheritedParamFixture(alloc, .{
        .struct_type_params = &.{"S"},
        .callee_params = &callee_params,
        .declared_return = declared_return,
        .argument_type = .{ .prim = .u8 },
        .expected_result = expected_result,
    });
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    // The struct's parameter binds, and the declared return substitutes to the
    // `Hasher<u8>` the type table already holds.
    try std.testing.expectEqual(
        @as(?exprs.TypeId, inherited_result_type),
        inferred.getType(inherited_call_node),
    );
    // No row names the method: it declares no parameter of its own, so
    // `(from_radix_10_checked, [u8])` is an instantiation it cannot have.
    try std.testing.expect(inferred.getInstantiation(inherited_call_node) == null);
}

test "a method of a generic impl binds the parameter the impl declares" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `impl<I: Integer> FromRadix10Checked<I> for I { fn from_radix_10_checked(..)
    // -> (Option<I>, usize) }` reached with `I = u8`. The impl declares `I`, the
    // function declares nothing, and the answer the call owes is
    // `(Option<u8>, usize)` — the tuple atoi's `u8::from_radix_10_checked(..)`
    // has to complete to.
    //
    // The receiver is spelled as a parameter because this is an ASSOCIATED call:
    // `source: &Cell<I>` is the same statement about `I` that `self` makes when
    // the call goes through a method call, and it is what lets the signature
    // bind `I` at all. Nothing in the function's own body records it.
    const parameter_segments = [_]types.PathSegment{.{ .name = "I", .id = null }};
    const parameter_path: types.Type = .{ .path = .{ .segments = &parameter_segments } };
    const parameter_args = [_]types.Type{parameter_path};
    const declared_cell: types.Type = .{ .generic_inst = .{
        .decl = inherited_struct,
        .args = .{ .params = &parameter_args },
    } };
    // `.reference` carries a pointer, so the borrow is allocated rather than
    // taken from a local: the table has to own every node it points at.
    const declared_receiver = try alloc.create(types.Ref);
    declared_receiver.* = .{ .mut = false, .pointee = declared_cell };
    const callee_params = [_]items.Param{.{
        .name = "source",
        .ty = .{ .reference = declared_receiver },
        .span = span,
    }};

    const declared_option = try alloc.create(types.Type);
    declared_option.* = parameter_path;
    const declared_return: types.Type = .{ .tuple = &.{
        .{ .option = declared_option },
        .{ .prim = .usize },
    } };

    const concrete_args = [_]types.Type{.{ .prim = .u8 }};
    const concrete_cell: types.Type = .{ .generic_inst = .{
        .decl = inherited_struct,
        .args = .{ .params = &concrete_args },
    } };
    const concrete_receiver = try alloc.create(types.Ref);
    concrete_receiver.* = .{ .mut = false, .pointee = concrete_cell };
    const result_option = try alloc.create(types.Type);
    result_option.* = .{ .prim = .u8 };
    const expected_result: types.Type = .{ .tuple = &.{
        .{ .option = result_option },
        .{ .prim = .usize },
    } };

    var fixture = try buildInheritedParamFixture(alloc, .{
        .impl_type_params = &.{"I"},
        .callee_params = &callee_params,
        .declared_return = declared_return,
        .argument_type = .{ .reference = concrete_receiver },
        .expected_result = expected_result,
    });
    defer fixture.deinit(alloc);

    var inferred = try infer.solveWithGraph(alloc, &fixture.b, &fixture.graph);
    defer inferred.deinit(alloc);

    // The impl's parameter binds, and `(Option<I>, usize)` substitutes to the
    // `(Option<u8>, usize)` the type table already holds.
    try std.testing.expectEqual(
        @as(?exprs.TypeId, inherited_result_type),
        inferred.getType(inherited_call_node),
    );
    // And no row names the method: `I` is the impl's, so the one-argument
    // record the call could otherwise write describes an instantiation the
    // function does not have.
    try std.testing.expect(inferred.getInstantiation(inherited_call_node) == null);
}
