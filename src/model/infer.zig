//! infer — constraint generation for P2 (code model type inference).
//!
//! See notes/design/source-model-type-inference.md §2.2 + §3.1.
//!
//! Walks the losslessly-lowered untyped body graph of each `.fn_` body and:
//! (a) PINS authoritative `Expr.ty` slots (type annotations on `let`, suffixed
//!     literals, floats/booleans, cast results).
//! (b) RECORDS unification edges (operator operands, control-flow branch
//!     agreement, return expressions <-> fn body).
//!
//! Full unification and solving is P3 (out of scope for this pass).
//!
//! Tolerates `.unsupported` nodes (skips them; never errors). Non-fn bodies
//! (`.none`, `.const_`, `.struct_`, `.enum_`, `.trait_`, `.type_alias`) are
//! skipped in this phase.
//!
//! C-free: imports only `exprs`, `bodies`, `types`, `spine` (no tree-sitter C).

const std = @import("std");
const exprs = @import("exprs.zig");
const bodies = @import("bodies.zig");
const types = @import("types.zig");

/// Authoritative assertion: this expression node IS this type.
pub const Pin = struct {
    node: exprs.NodeId,
    ty: exprs.TypeId,
};

/// Constraint edge between nodes or between a return expr and its fn body.
pub const Edge = union(enum) {
    /// Unify `ty(a) = ty(b)`.
    eq: struct {
        a: exprs.NodeId,
        b: exprs.NodeId,
    },
    /// Unify `ty(expr)` with the enclosing function's return type.
    ret: struct {
        expr: exprs.NodeId,
        fn_body: exprs.NodeId,
    },
};

/// Collection of generated pins and edges. Caller owns and must call `deinit`.
pub const Gen = struct {
    pub const Self = Gen;

    pins: std.ArrayListUnmanaged(Pin) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.pins.deinit(alloc);
        self.edges.deinit(alloc);
        self.* = undefined;
    }
};

const Ctx = struct {
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    g: *Gen,
    bool_ty: ?exprs.TypeId = null,

    fn boolId(self: *Ctx) ?exprs.TypeId {
        if (self.bool_ty) |t| return t;
        const t = primTypeId(self.b, .bool) orelse return null;
        self.bool_ty = t;
        return t;
    }
};

/// Locate the TypeId of a primitive type in `b.types`. Returns null if absent.
fn primTypeId(b: *const bodies.Bodies, prim: types.Prim) ?exprs.TypeId {
    for (b.types, 0..) |t, i| {
        if (t == .prim and t.prim == prim) return @intCast(i);
    }
    return null;
}

/// Map an integer literal's type-suffix string (e.g. "u64", "i32") to a Prim.
fn intSuffixPrim(suffix: []const u8) ?types.Prim {
    if (std.mem.eql(u8, suffix, "u8")) return .u8;
    if (std.mem.eql(u8, suffix, "u16")) return .u16;
    if (std.mem.eql(u8, suffix, "u32")) return .u32;
    if (std.mem.eql(u8, suffix, "u64")) return .u64;
    if (std.mem.eql(u8, suffix, "u128")) return .u128;
    if (std.mem.eql(u8, suffix, "i8")) return .i8;
    if (std.mem.eql(u8, suffix, "i16")) return .i16;
    if (std.mem.eql(u8, suffix, "i32")) return .i32;
    if (std.mem.eql(u8, suffix, "i64")) return .i64;
    if (std.mem.eql(u8, suffix, "i128")) return .i128;
    if (std.mem.eql(u8, suffix, "usize")) return .usize;
    if (std.mem.eql(u8, suffix, "isize")) return .isize;
    return null;
}

/// Case-insensitive suffix check helper.
fn endsWithCi(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    const tail = s[s.len - suffix.len ..];
    for (tail, suffix) |c, t| {
        if (std.ascii.toLower(c) != std.ascii.toLower(t)) return false;
    }
    return true;
}

/// Determine a float literal's primitive type. Defaults to `f64` unless the raw
/// token text ends with an `f32` suffix (case-insensitive).
fn floatSuffixPrim(text: []const u8) types.Prim {
    if (endsWithCi(text, "f32")) return .f32;
    return .f64;
}

/// Append a Pin, deduplicating identical (node, ty) pairs.
fn addPin(ctx: *Ctx, node: exprs.NodeId, ty: exprs.TypeId) std.mem.Allocator.Error!void {
    for (ctx.g.pins.items) |p| {
        if (p.node == node and p.ty == ty) return;
    }
    try ctx.g.pins.append(ctx.alloc, .{ .node = node, .ty = ty });
}

/// Append an `eq` edge, deduplicating identical (a, b) pairs.
fn addEq(ctx: *Ctx, a: exprs.NodeId, b: exprs.NodeId) std.mem.Allocator.Error!void {
    for (ctx.g.edges.items) |e| {
        if (e == .eq and e.eq.a == a and e.eq.b == b) return;
    }
    try ctx.g.edges.append(ctx.alloc, .{ .eq = .{ .a = a, .b = b } });
}

/// Append a `ret` edge, deduplicating identical (expr, fn_body) pairs.
fn addRet(ctx: *Ctx, expr: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    for (ctx.g.edges.items) |e| {
        if (e == .ret and e.ret.expr == expr and e.ret.fn_body == fn_body) return;
    }
    try ctx.g.edges.append(ctx.alloc, .{ .ret = .{ .expr = expr, .fn_body = fn_body } });
}

/// Walk a literal expression, pinning authoritative types when recognizable.
fn walkLiteral(ctx: *Ctx, node: exprs.NodeId, lit: exprs.Literal) std.mem.Allocator.Error!void {
    switch (lit) {
        .int => |il| {
            if (il.ty_suffix) |s| {
                if (intSuffixPrim(s)) |p| {
                    if (primTypeId(ctx.b, p)) |tid| try addPin(ctx, node, tid);
                }
            }
        },
        .float => |fl| {
            const p = floatSuffixPrim(fl.text);
            if (primTypeId(ctx.b, p)) |tid| try addPin(ctx, node, tid);
        },
        .boolean => {
            if (ctx.boolId()) |tid| try addPin(ctx, node, tid);
        },
        // Characters, strings, byte-arrays: non-authoritative at P2 gen-phase
        // (types might be [N]u8, []const u8, u21; resolved during P3/P4).
        .character, .string, .byte_array => {},
    }
}

/// Walk a binary expression: recurse into operands and emit equivalence edges.
/// Arithmetic, bitwise, and comparison operators emit LHS <-> result and
/// RHS <-> result. Shift operators emit only LHS <-> result (RHS is usize/comptime_int).
/// Logical `&&`/`||` are short-circuiting bool operators (skipped in P2 gen).
fn walkBinary(ctx: *Ctx, node: exprs.NodeId, bin: exprs.BinaryExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    try walkExpr(ctx, bin.lhs, fn_body);
    try walkExpr(ctx, bin.rhs, fn_body);
    switch (bin.op) {
        .add,
        .sub,
        .mul,
        .div,
        .rem,
        .bit_and,
        .bit_or,
        .bit_xor,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        => {
            try addEq(ctx, bin.lhs, node);
            try addEq(ctx, bin.rhs, node);
        },
        .shl, .shr => {
            try addEq(ctx, bin.lhs, node);
        },
        .boolean_and, .boolean_or => {
            // Short-circuiting logical operators: result is bool; operands are bool.
            // Deferred to P3 unification.
        },
    }
}

/// Walk an `if_else` expression: unify condition with bool if it is a bare
/// non-literal path; unify then-tail with else-tail when both branches have
/// tail expressions.
fn walkIf(ctx: *Ctx, ie: exprs.IfExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    // Pin condition to bool if it's a bare non-literal path expression.
    if (ie.cond < ctx.b.exprs.len and ctx.b.exprs[ie.cond].kind == .path) {
        if (ctx.boolId()) |bid| try addPin(ctx, ie.cond, bid);
    }
    try walkExpr(ctx, ie.cond, fn_body);
    try walkBlock(ctx, ie.then_, fn_body);
    switch (ie.@"else") {
        .none => {},
        .block => |blk| {
            try walkBlock(ctx, blk, fn_body);
            // Unify branches when both have value-producing tail expressions.
            if (ie.then_.tail) |tt| {
                if (blk.tail) |et| {
                    try addEq(ctx, tt, et);
                }
            }
        },
        .chain => |n| {
            // `else if` chain: recurse into the chained IfExpr.
            try walkExpr(ctx, n, fn_body);
        },
    }
}

/// Walk a `match` expression: unify the body expressions of all arms.
fn walkMatch(ctx: *Ctx, m: exprs.MatchExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    try walkExpr(ctx, m.scrutinee, fn_body);
    if (m.arms.len >= 2) {
        const first = m.arms[0].body;
        for (m.arms[1..]) |arm| {
            try addEq(ctx, first, arm.body);
        }
    }
    for (m.arms) |arm| {
        try walkExpr(ctx, arm.body, fn_body);
    }
}

/// Walk a statement, pinning `let`-annotated initializers and recursing into
/// expressions. Path-pinning of let bindings and fn-params is skipped because
/// `Binding` and `Param` carry only names, while `PathExpr` carries a `DefId`;
/// the symbol table does not model locals/bindings, so there is no def linkage.
fn walkStmt(ctx: *Ctx, node: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    if (node >= ctx.b.stmts.len) return;
    const s = &ctx.b.stmts[node];
    switch (s.kind) {
        .let => |ls| {
            if (ls.init) |init| {
                if (ls.ty) |ty| try addPin(ctx, init, ty);
                try walkExpr(ctx, init, fn_body);
            }
        },
        .let_else => |le| {
            try walkExpr(ctx, le.init, fn_body);
            try walkBlock(ctx, le.else_block, fn_body);
        },
        .expr => |n| try walkExpr(ctx, n, fn_body),
        .item => {}, // Nested item: its body is a separate entity (skipped).
    }
}

/// Walk a block expression's statements and optional tail expression.
fn walkBlock(ctx: *Ctx, blk: exprs.BlockExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    for (blk.statements) |s| try walkStmt(ctx, s, fn_body);
    if (blk.tail) |t| try walkExpr(ctx, t, fn_body);
}

/// Recursively walk an expression node in the graph.
fn walkExpr(ctx: *Ctx, node: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    if (node >= ctx.b.exprs.len) return;
    const e = &ctx.b.exprs[node];
    switch (e.kind) {
        .literal => |lit| try walkLiteral(ctx, node, lit),
        .path => {}, // No pinning possible without def-to-name resolution; skipped.
        .block => |blk| try walkBlock(ctx, blk, fn_body),
        .unit => {},
        .if_else => |ie| try walkIf(ctx, ie, fn_body),
        .if_let => |il| {
            try walkExpr(ctx, il.scrutinee, fn_body);
            try walkBlock(ctx, il.then_, fn_body);
            switch (il.@"else") {
                .none => {},
                .block => |blk| try walkBlock(ctx, blk, fn_body),
                .chain => |n| try walkExpr(ctx, n, fn_body),
            }
        },
        .match => |m| try walkMatch(ctx, m, fn_body),
        .loop_ => |l| try walkBlock(ctx, l.body, fn_body),
        .while_ => |w| {
            try walkExpr(ctx, w.cond, fn_body);
            try walkBlock(ctx, w.body, fn_body);
        },
        .for_ => |f| {
            try walkExpr(ctx, f.iterable, fn_body);
            try walkBlock(ctx, f.body, fn_body);
        },
        .break_ => |br| {
            if (br.value) |v| try walkExpr(ctx, v, fn_body);
        },
        .continue_ => {},
        .call => |c| {
            // Recurse into argument expressions to find nested pins/edges.
            // The call itself is resolved at P4 (needs signature).
            for (c.args) |a| try walkExpr(ctx, a, fn_body);
        },
        .method_call => |m| {
            // Recurse into receiver and argument expressions.
            // Method resolution is P4 (needs receiver type).
            try walkExpr(ctx, m.receiver, fn_body);
            for (m.args) |a| try walkExpr(ctx, a, fn_body);
        },
        .struct_lit => |s| {
            for (s.fields) |f| try walkExpr(ctx, f.value, fn_body);
            if (s.base) |b0| try walkExpr(ctx, b0, fn_body);
        },
        .enum_variant => |ev| {
            for (ev.tuple_fields) |f| try walkExpr(ctx, f, fn_body);
            for (ev.named_fields) |f| try walkExpr(ctx, f.value, fn_body);
        },
        .field => |f| {
            // Recurse into base to find nested pins. Field resolution is P4.
            try walkExpr(ctx, f.base, fn_body);
        },
        .index => |ix| {
            // Recurse into base and index expressions.
            try walkExpr(ctx, ix.base, fn_body);
            try walkExpr(ctx, ix.index, fn_body);
        },
        .binary => |bin| try walkBinary(ctx, node, bin, fn_body),
        .unary => |u| try walkExpr(ctx, u.operand, fn_body),
        .assign => |a| {
            try walkExpr(ctx, a.target, fn_body);
            try walkExpr(ctx, a.value, fn_body);
        },
        .try_ => |t| try walkExpr(ctx, t.inner, fn_body),
        .return_ => |r| {
            if (r.value) |v| {
                try walkExpr(ctx, v, fn_body);
                try addRet(ctx, v, fn_body);
            }
        },
        // Casts: exprs.zig has no dedicated Cast ExprKind (unsupported/raw_ptr);
        // skipped in P2 gen-phase per design.
        // Closures, iterator chains, and unsupported nodes: deferred seams;
        // skipped without recursing and without erroring.
        .closure, .iterator_chain, .unsupported => {},
    }
}

/// Walk the lossless code model of every `.fn_` body in `b` and generate
/// authoritative type pins and unification edges.
///
/// Non-fn bodies (`.none`, `.const_`, `.struct_`, `.enum_`, `.trait_`,
/// `.type_alias`) are skipped.
pub fn gen(alloc: std.mem.Allocator, b: *const bodies.Bodies) std.mem.Allocator.Error!Gen {
    var g: Gen = .{};
    errdefer g.deinit(alloc);

    var ctx: Ctx = .{
        .alloc = alloc,
        .b = b,
        .g = &g,
    };

    for (b.bodies) |bk| {
        switch (bk) {
            .fn_ => |fb| {
                if (fb.body < b.exprs.len) {
                    if (b.exprs[fb.body].kind == .block) {
                        try walkBlock(&ctx, b.exprs[fb.body].kind.block, fb.body);
                    } else {
                        try walkExpr(&ctx, fb.body, fb.body);
                    }
                }
            },
            .none, .const_, .struct_, .enum_, .trait_, .type_alias => {
                // Non-fn bodies are skipped in this phase.
            },
        }
    }

    return g;
}
