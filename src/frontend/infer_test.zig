//! infer_test — tests for P2 constraint generation (infer.zig).
//!
//! C-free: this file links under `zig build test` without tree-sitter C.
//!
//! Asserts the 5 contract requirements:
//! (a) Suffixed literal 0x1u64 is pinned to u64.
//! (b) Type-annotated `let x: u32 = e` pins init expression `e` to u32.
//! (c) `.return_` inner expression produces an Edge.ret.
//! (d) Binary `a + b` produces Edge.eq(a, result) and Edge.eq(b, result).
//! (e) A body containing an `.unsupported` node completes without error and
//!     emits its supported pins/edges (unsupported node absent).

const std = @import("std");
const infer = @import("infer.zig");
const ir = @import("translate_rust.ir");
const exprs = ir.exprs;
const bodies = ir.bodies;
const types = ir.types;
const items = ir.items;
const spine = ir.spine;
const crate_graph = ir.graph;

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
    const resolved = exprs_store[3].kind.cast.source_type;
    try std.testing.expect(resolved == .raw_ptr);
    try std.testing.expect(!resolved.raw_ptr.mut);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, resolved.raw_ptr.pointee);
    try std.testing.expectEqual(@as(?exprs.TypeId, 2), inferred.getType(3));
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
