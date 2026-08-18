//! infer — constraint generation & unification solver for P3.
//!
//! See notes/design/source-model-type-inference.md §2.2 + §3.1 + §3.2.
//!
//! Stage 1 (Gen): Walks the losslessly-lowered untyped body graph of each `.fn_`
//! body and:
//! (a) PINS authoritative `Expr.ty` slots (type annotations on `let`, suffixed
//!     literals, floats/booleans, cast results).
//! (b) RECORDS unification edges (operator operands, control-flow branch
//!     agreement, return expressions <-> fn return type, def linkages).
//! (c) MARKS unannotated literal classes (integer -> .integer, float -> .float).
//!
//! Stage 2 (Solve): Union-find unification over all expression nodes:
//! - Merges equivalence classes across operator operands, defs, branches.
//! - Propagates pinned concrete types through equivalence sets.
//! - Applies Rust defaults: unconstrained integer literals -> `i32`,
//!   unconstrained float literals -> `f64`.
//! - Inscribes inferred concrete `TypeId`s on all reachable nodes.
//!
//! C-free: imports only `exprs`, `bodies`, `types`, `spine` (no tree-sitter C).

const std = @import("std");
const exprs = @import("exprs.zig");
const bodies = @import("bodies.zig");
const types = @import("types.zig");

/// Unannotated literal class for defaulting unconstrained variables.
pub const Class = enum {
    none,
    integer,
    float,
};

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

/// Collection of generated pins, edges, and literal classes.
pub const Gen = struct {
    pub const Self = Gen;

    pins: std.ArrayListUnmanaged(Pin) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    classes: std.AutoHashMapUnmanaged(exprs.NodeId, Class) = .empty,

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.pins.deinit(alloc);
        self.edges.deinit(alloc);
        self.classes.deinit(alloc);
        self.* = undefined;
    }
};

/// Result of type inference: dense array of inferred concrete TypeIds.
pub const Inferred = struct {
    types: []?exprs.TypeId,

    pub fn deinit(self: *Inferred, alloc: std.mem.Allocator) void {
        alloc.free(self.types);
        self.* = undefined;
    }

    pub fn getType(self: *const Inferred, node: exprs.NodeId) ?exprs.TypeId {
        if (node < self.types.len) return self.types[node];
        return null;
    }

    pub fn apply(self: *const Inferred, exprs_slice: []exprs.Expr) void {
        std.debug.assert(self.types.len >= 0);
        for (exprs_slice, 0..) |*e, i| {
            if (i < self.types.len) {
                if (self.types[i]) |t| e.ty = t;
            }
        }
    }
};

const Ctx = struct {
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    g: *Gen,
    bool_ty: ?exprs.TypeId = null,
    def_map: std.AutoHashMapUnmanaged(exprs.DefId, exprs.NodeId) = .empty,

    fn boolId(self: *Ctx) ?exprs.TypeId {
        if (self.bool_ty) |t| return t;
        const t = primTypeId(self.b, .bool) orelse return null;
        self.bool_ty = t;
        return t;
    }

    fn deinit(self: *Ctx) void {
        self.def_map.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Locate the TypeId of a primitive type in `b.types`. Returns null if absent.
pub fn primTypeId(b: *const bodies.Bodies, prim: types.Prim) ?exprs.TypeId {
    std.debug.assert(b.types.len >= 0);
    for (b.types, 0..) |t, i| {
        if (t == .prim and t.prim == prim) return @intCast(i);
    }
    return null;
}

/// Structural equality check for types to resolve TypeId in `b.types`.
fn typeEqual(a: types.Type, b: types.Type) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return false;
    switch (a) {
        .prim => |p| return p == b.prim,
        .path => |p| {
            if (p.segments.len != b.path.segments.len) return false;
            for (p.segments, b.path.segments) |s_a, s_b| {
                if (!std.mem.eql(u8, s_a.name, s_b.name)) return false;
            }
            return true;
        },
        .reference => |r| return r.mut == b.reference.mut and typeEqual(r.pointee, b.reference.pointee),
        .slice => |s| return s.const_ == b.slice.const_ and typeEqual(s.elem, b.slice.elem),
        .array => |arr| {
            if (!std.meta.eql(arr.len, b.array.len)) return false;
            return typeEqual(arr.elem, b.array.elem);
        },
        .tuple => |t| {
            if (t.len != b.tuple.len) return false;
            for (t, b.tuple) |elem_a, elem_b| {
                if (!typeEqual(elem_a, elem_b)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Find the TypeId corresponding to target type in `b.types`.
pub fn findTypeIndex(b: *const bodies.Bodies, target: types.Type) ?exprs.TypeId {
    std.debug.assert(b.types.len >= 0);
    for (b.types, 0..) |t, i| {
        if (typeEqual(t, target)) return @intCast(i);
    }
    return null;
}

/// Map an integer literal's type-suffix string (e.g. "u64", "i32") to a Prim.
fn intSuffixPrim(suffix: []const u8) ?types.Prim {
    std.debug.assert(suffix.len > 0);
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
    std.debug.assert(node < ctx.b.exprs.len);
    for (ctx.g.pins.items) |p| {
        if (p.node == node and p.ty == ty) return;
    }
    try ctx.g.pins.append(ctx.alloc, .{ .node = node, .ty = ty });
}

/// Append an `eq` edge, deduplicating identical (a, b) pairs.
fn addEq(ctx: *Ctx, a: exprs.NodeId, b: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(a < ctx.b.exprs.len);
    std.debug.assert(b < ctx.b.exprs.len);
    if (a == b) return;
    for (ctx.g.edges.items) |e| {
        if (e == .eq and ((e.eq.a == a and e.eq.b == b) or (e.eq.a == b and e.eq.b == a))) return;
    }
    try ctx.g.edges.append(ctx.alloc, .{ .eq = .{ .a = a, .b = b } });
}

/// Append a `ret` edge, deduplicating identical (expr, fn_body) pairs.
fn addRet(ctx: *Ctx, expr: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(expr < ctx.b.exprs.len);
    for (ctx.g.edges.items) |e| {
        if (e == .ret and e.ret.expr == expr and e.ret.fn_body == fn_body) return;
    }
    try ctx.g.edges.append(ctx.alloc, .{ .ret = .{ .expr = expr, .fn_body = fn_body } });
}

/// Set literal class for defaulting unconstrained literal nodes.
fn setClass(ctx: *Ctx, node: exprs.NodeId, class: Class) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    try ctx.g.classes.put(ctx.alloc, node, class);
}

/// Walk a literal expression, pinning authoritative types or recording classes.
fn walkLiteral(ctx: *Ctx, node: exprs.NodeId, lit: exprs.Literal) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    switch (lit) {
        .int => |il| {
            if (il.ty_suffix) |s| {
                if (intSuffixPrim(s)) |p| {
                    if (primTypeId(ctx.b, p)) |tid| try addPin(ctx, node, tid);
                }
            } else {
                try setClass(ctx, node, .integer);
            }
        },
        .float => |fl| {
            if (endsWithCi(fl.text, "f32")) {
                if (primTypeId(ctx.b, .f32)) |tid| try addPin(ctx, node, tid);
            } else if (endsWithCi(fl.text, "f64")) {
                if (primTypeId(ctx.b, .f64)) |tid| try addPin(ctx, node, tid);
            } else {
                try setClass(ctx, node, .float);
            }
        },
        .boolean => {
            if (ctx.boolId()) |tid| try addPin(ctx, node, tid);
        },
        .character, .string, .byte_array => {},
    }
}

/// Walk a binary expression: recurse into operands and emit equivalence edges.
fn walkBinary(ctx: *Ctx, node: exprs.NodeId, bin: exprs.BinaryExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(bin.lhs < ctx.b.exprs.len);
    std.debug.assert(bin.rhs < ctx.b.exprs.len);
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
        => {
            try addEq(ctx, bin.lhs, node);
            try addEq(ctx, bin.rhs, node);
        },
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        => {
            try addEq(ctx, bin.lhs, bin.rhs);
            if (ctx.boolId()) |bid| try addPin(ctx, node, bid);
        },
        .shl, .shr => {
            try addEq(ctx, bin.lhs, node);
        },
        .boolean_and, .boolean_or => {
            if (ctx.boolId()) |bid| {
                try addPin(ctx, bin.lhs, bid);
                try addPin(ctx, bin.rhs, bid);
                try addPin(ctx, node, bid);
            }
        },
    }
}

/// Walk an `if_else` expression: condition is bool; branches unify with if node.
fn walkIf(ctx: *Ctx, node: exprs.NodeId, ie: exprs.IfExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    std.debug.assert(ie.cond < ctx.b.exprs.len);
    if (ctx.boolId()) |bid| try addPin(ctx, ie.cond, bid);
    try walkExpr(ctx, ie.cond, fn_body);
    try walkBlock(ctx, ie.then_, fn_body, null);
    if (ie.then_.tail) |tt| {
        try addEq(ctx, node, tt);
    }
    switch (ie.@"else") {
        .none => {},
        .block => |blk| {
            try walkBlock(ctx, blk, fn_body, null);
            if (blk.tail) |et| {
                try addEq(ctx, node, et);
            }
        },
        .chain => |n| {
            try walkExpr(ctx, n, fn_body);
            try addEq(ctx, node, n);
        },
    }
}

/// Walk a `match` expression: unify the body expressions of all arms with match node.
fn walkMatch(ctx: *Ctx, node: exprs.NodeId, m: exprs.MatchExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    std.debug.assert(m.scrutinee < ctx.b.exprs.len);
    try walkExpr(ctx, m.scrutinee, fn_body);
    for (m.arms) |arm| {
        try addEq(ctx, node, arm.body);
        try walkExpr(ctx, arm.body, fn_body);
    }
}

/// Walk a statement, linking `let` bindings and initializers.
fn walkStmt(ctx: *Ctx, node: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    if (node >= ctx.b.stmts.len) return;
    const s = &ctx.b.stmts[node];
    switch (s.kind) {
        .let => |ls| {
            if (ls.init) |init| {
                if (ls.ty) |ty| try addPin(ctx, init, ty);
                try walkExpr(ctx, init, fn_body);
                // Link init with def_id if pattern is a binding.
                if (ls.pattern < ctx.b.pats.len) {
                    const pat = &ctx.b.pats[ls.pattern];
                    if (pat.kind == .binding) {
                        // The binding def_id can be tracked via the pattern id.
                        const def_key: exprs.DefId = @intCast(ls.pattern);
                        try ctx.def_map.put(ctx.alloc, def_key, init);
                    }
                }
            }
        },
        .let_else => |le| {
            try walkExpr(ctx, le.init, fn_body);
            try walkBlock(ctx, le.else_block, fn_body, null);
        },
        .expr => |n| try walkExpr(ctx, n, fn_body),
        .item => {},
    }
}

/// Walk a block expression's statements and optional tail expression.
fn walkBlock(ctx: *Ctx, blk: exprs.BlockExpr, fn_body: exprs.NodeId, blk_node: ?exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(fn_body < ctx.b.exprs.len);
    for (blk.statements) |s| try walkStmt(ctx, s, fn_body);
    if (blk.tail) |t| {
        if (blk_node) |bn| try addEq(ctx, bn, t);
        try walkExpr(ctx, t, fn_body);
    }
}

/// Walk a path expression: link occurrences with the same def_id.
fn walkPath(ctx: *Ctx, node: exprs.NodeId, p: exprs.PathExpr) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    if (ctx.def_map.get(p.def)) |first_node| {
        try addEq(ctx, first_node, node);
    } else {
        try ctx.def_map.put(ctx.alloc, p.def, node);
    }
}

/// Recursively walk an expression node in the graph.
fn walkExpr(ctx: *Ctx, node: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    if (node >= ctx.b.exprs.len) return;
    const e = &ctx.b.exprs[node];
    switch (e.kind) {
        .literal => |lit| try walkLiteral(ctx, node, lit),
        .path => |p| try walkPath(ctx, node, p),
        .block => |blk| try walkBlock(ctx, blk, fn_body, node),
        .unit => {},
        .if_else => |ie| try walkIf(ctx, node, ie, fn_body),
        .if_let => |il| {
            try walkExpr(ctx, il.scrutinee, fn_body);
            try walkBlock(ctx, il.then_, fn_body, null);
            switch (il.@"else") {
                .none => {},
                .block => |blk| try walkBlock(ctx, blk, fn_body, null),
                .chain => |n| try walkExpr(ctx, n, fn_body),
            }
        },
        .match => |m| try walkMatch(ctx, node, m, fn_body),
        .loop_ => |l| try walkBlock(ctx, l.body, fn_body, null),
        .while_ => |w| {
            if (ctx.boolId()) |bid| try addPin(ctx, w.cond, bid);
            try walkExpr(ctx, w.cond, fn_body);
            try walkBlock(ctx, w.body, fn_body, null);
        },
        .for_ => |f| {
            try walkExpr(ctx, f.iterable, fn_body);
            try walkBlock(ctx, f.body, fn_body, null);
        },
        .break_ => |br| {
            if (br.value) |v| try walkExpr(ctx, v, fn_body);
        },
        .continue_ => {},
        .call => |c| {
            for (c.args) |a| try walkExpr(ctx, a, fn_body);
        },
        .method_call => |m| {
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
            try walkExpr(ctx, f.base, fn_body);
        },
        .index => |ix| {
            try walkExpr(ctx, ix.base, fn_body);
            try walkExpr(ctx, ix.index, fn_body);
        },
        .binary => |bin| try walkBinary(ctx, node, bin, fn_body),
        .unary => |u| {
            try walkExpr(ctx, u.operand, fn_body);
            switch (u.op) {
                .negate, .bit_not => try addEq(ctx, u.operand, node),
                .logical_not => {
                    if (ctx.boolId()) |bid| {
                        try addPin(ctx, u.operand, bid);
                        try addPin(ctx, node, bid);
                    }
                },
                .deref, .ref => {},
            }
        },
        .assign => |a| {
            try walkExpr(ctx, a.target, fn_body);
            try walkExpr(ctx, a.value, fn_body);
            try addEq(ctx, a.target, a.value);
            try addEq(ctx, node, a.target);
        },
        .try_ => |t| try walkExpr(ctx, t.inner, fn_body),
        .return_ => |r| {
            if (r.value) |v| {
                try walkExpr(ctx, v, fn_body);
                try addRet(ctx, v, fn_body);
                try addEq(ctx, node, v);
            }
        },
        .closure, .iterator_chain, .unsupported => {},
    }
}

/// Walk the lossless code model of every `.fn_` body in `b` and generate
/// authoritative type pins and unification edges.
pub fn gen(alloc: std.mem.Allocator, b: *const bodies.Bodies) std.mem.Allocator.Error!Gen {
    std.debug.assert(b.bodies.len >= 0);
    var g: Gen = .{};
    errdefer g.deinit(alloc);

    var ctx: Ctx = .{
        .alloc = alloc,
        .b = b,
        .g = &g,
    };
    defer ctx.deinit();

    for (b.bodies) |bk| {
        switch (bk) {
            .fn_ => |fb| {
                ctx.def_map.clearRetainingCapacity();
                if (fb.body < b.exprs.len) {
                    if (b.exprs[fb.body].kind == .block) {
                        try walkBlock(&ctx, b.exprs[fb.body].kind.block, fb.body, fb.body);
                    } else {
                        try walkExpr(&ctx, fb.body, fb.body);
                    }
                }
            },
            .none, .const_, .struct_, .enum_, .trait_, .type_alias => {},
        }
    }

    return g;
}

// ── Unification Solver (P3) ─────────────────────────────────────────────────

fn findRoot(parent: []exprs.NodeId, i: exprs.NodeId) exprs.NodeId {
    std.debug.assert(i < parent.len);
    var root = i;
    while (parent[root] != root) {
        root = parent[root];
    }
    var curr = i;
    while (curr != root) {
        const next = parent[curr];
        parent[curr] = root;
        curr = next;
    }
    return root;
}

fn unionNodes(
    parent: []exprs.NodeId,
    rank: []u8,
    concrete: []?exprs.TypeId,
    classes: []Class,
    a: exprs.NodeId,
    b: exprs.NodeId,
) void {
    if (a >= parent.len or b >= parent.len) return;
    const root_a = findRoot(parent, a);
    const root_b = findRoot(parent, b);
    if (root_a == root_b) return;

    const merged_concrete = concrete[root_a] orelse concrete[root_b];
    const merged_class: Class = if (classes[root_a] != .none) classes[root_a] else classes[root_b];

    if (rank[root_a] < rank[root_b]) {
        parent[root_a] = root_b;
        concrete[root_b] = merged_concrete;
        classes[root_b] = merged_class;
    } else if (rank[root_a] > rank[root_b]) {
        parent[root_b] = root_a;
        concrete[root_a] = merged_concrete;
        classes[root_a] = merged_class;
    } else {
        parent[root_b] = root_a;
        rank[root_a] += 1;
        concrete[root_a] = merged_concrete;
        classes[root_a] = merged_class;
    }
}

fn findFnRetTypeId(b: *const bodies.Bodies, body_node: exprs.NodeId) ?exprs.TypeId {
    std.debug.assert(b.bodies.len >= 0);
    for (b.bodies) |bk| {
        switch (bk) {
            .fn_ => |fb| {
                if (fb.body == body_node) {
                    return findTypeIndex(b, fb.ret);
                }
            },
            else => {},
        }
    }
    return null;
}

/// Run unification solver on pre-computed constraint Gen over `b`.
pub fn solveWithGen(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    g: *const Gen,
) std.mem.Allocator.Error!Inferred {
    const num_exprs = b.exprs.len;
    if (num_exprs == 0) {
        return .{ .types = try alloc.alloc(?exprs.TypeId, 0) };
    }

    const parent = try alloc.alloc(exprs.NodeId, num_exprs);
    defer alloc.free(parent);
    const rank = try alloc.alloc(u8, num_exprs);
    defer alloc.free(rank);
    const concrete = try alloc.alloc(?exprs.TypeId, num_exprs);
    defer alloc.free(concrete);
    const classes = try alloc.alloc(Class, num_exprs);
    defer alloc.free(classes);

    for (0..num_exprs) |i| {
        parent[i] = @intCast(i);
        rank[i] = 0;
        concrete[i] = b.exprs[i].ty;
        classes[i] = .none;
    }

    // Apply literal classes.
    var class_it = g.classes.iterator();
    while (class_it.next()) |entry| {
        const n = entry.key_ptr.*;
        if (n < num_exprs) classes[n] = entry.value_ptr.*;
    }

    // Apply pinned authoritative types.
    for (g.pins.items) |p| {
        if (p.node < num_exprs) {
            concrete[p.node] = p.ty;
        }
    }

    // Unify equivalence edges.
    for (g.edges.items) |e| {
        switch (e) {
            .eq => |eq_edge| {
                unionNodes(parent, rank, concrete, classes, eq_edge.a, eq_edge.b);
            },
            .ret => {},
        }
    }

    // Unify function return expressions.
    for (g.edges.items) |e| {
        switch (e) {
            .ret => |ret_edge| {
                if (ret_edge.expr < num_exprs) {
                    if (findFnRetTypeId(b, ret_edge.fn_body)) |ret_tid| {
                        const root = findRoot(parent, ret_edge.expr);
                        concrete[root] = concrete[root] orelse ret_tid;
                    }
                }
            },
            .eq => {},
        }
    }

    // Unify function body block tail expressions with function return type.
    for (b.bodies) |bk| {
        switch (bk) {
            .fn_ => |fb| {
                if (fb.body < num_exprs and b.exprs[fb.body].kind == .block) {
                    const blk = b.exprs[fb.body].kind.block;
                    if (blk.tail) |tail_id| {
                        if (tail_id < num_exprs) {
                            if (findTypeIndex(b, fb.ret)) |ret_tid| {
                                const root = findRoot(parent, tail_id);
                                concrete[root] = concrete[root] orelse ret_tid;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Defaults Phase: unconstrained integer -> i32, float -> f64.
    const default_int_ty = primTypeId(b, .i32);
    const default_float_ty = primTypeId(b, .f64);

    for (0..num_exprs) |i| {
        const root = findRoot(parent, @intCast(i));
        if (concrete[root] == null) {
            if (classes[root] == .integer) {
                if (default_int_ty) |itid| concrete[root] = itid;
            } else if (classes[root] == .float) {
                if (default_float_ty) |ftid| concrete[root] = ftid;
            }
        }
    }

    // Assemble Inferred result array.
    const result_types = try alloc.alloc(?exprs.TypeId, num_exprs);
    for (0..num_exprs) |i| {
        const root = findRoot(parent, @intCast(i));
        result_types[i] = concrete[root];
    }

    return .{ .types = result_types };
}

/// Generate constraints and run full unification solver with defaults on `b`.
pub fn solve(alloc: std.mem.Allocator, b: *const bodies.Bodies) std.mem.Allocator.Error!Inferred {
    std.debug.assert(b.exprs.len >= 0);
    var g = try gen(alloc, b);
    defer g.deinit(alloc);
    return solveWithGen(alloc, b, &g);
}
