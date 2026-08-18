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
const exprs = @import("exprs.zig");
const bodies = @import("bodies.zig");
const types = @import("types.zig");
const items = @import("items.zig");
const spine = @import("spine.zig");

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
    const types_store = try alloc.alloc(types.Type, 3);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .u32 };
    types_store[2] = .{ .prim = .bool };

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

test "full fn f produces exact pins and edges" {
    const a = std.testing.allocator;
    var fx = try buildFixtureF(a);
    defer {
        deinitFixtureFStatements(a, &fx);
        fx.deinit(a);
    }

    var g = try infer.gen(a, &fx.b);
    defer g.deinit(a);

    // Exact count: 3 pins (init of x, init of acc, 0x1u64), 3 edges (LHS<->res, RHS<->res, ret).
    try std.testing.expectEqual(@as(usize, 3), g.pins.items.len);
    try std.testing.expectEqual(@as(usize, 3), g.edges.items.len);

    // Pins:
    // 0: let x: u32 = 5 -> {node: 0, ty: 1}
    // 1: var acc: u64 = 0u64 -> {node: 1, ty: 0}
    // 2: 0x1u64 -> {node: 2, ty: 0}
    try std.testing.expectEqual(@as(exprs.NodeId, 0), g.pins.items[0].node);
    try std.testing.expectEqual(@as(exprs.TypeId, 1), g.pins.items[0].ty);

    try std.testing.expectEqual(@as(exprs.NodeId, 1), g.pins.items[1].node);
    try std.testing.expectEqual(@as(exprs.TypeId, 0), g.pins.items[1].ty);

    try std.testing.expectEqual(@as(exprs.NodeId, 2), g.pins.items[2].node);
    try std.testing.expectEqual(@as(exprs.TypeId, 0), g.pins.items[2].ty);

    // Edges:
    // 0: eq(3, 4) — acc <-> add result
    // 1: eq(2, 4) — 0x1u64 <-> add result
    // 2: ret(3, 7) — return acc <-> fn body block
    try std.testing.expectEqual(infer.Edge{ .eq = .{ .a = 3, .b = 4 } }, g.edges.items[0]);
    try std.testing.expectEqual(infer.Edge{ .eq = .{ .a = 2, .b = 4 } }, g.edges.items[1]);
    try std.testing.expectEqual(infer.Edge{ .ret = .{ .expr = 3, .fn_body = 7 } }, g.edges.items[2]);
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
