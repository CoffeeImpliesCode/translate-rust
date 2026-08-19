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
const ir = @import("translate_rust.ir");
const exprs = ir.exprs;
const bodies = ir.bodies;
const types = ir.types;
const spine = ir.spine;
const items = ir.items;

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

/// Collection of generated pins, edges, literal classes, and instantiations.
pub const Gen = struct {
    pub const Self = Gen;

    pins: std.ArrayListUnmanaged(Pin) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    classes: std.AutoHashMapUnmanaged(exprs.NodeId, Class) = .empty,
    instantiations: std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation) = .empty,

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.pins.deinit(alloc);
        self.edges.deinit(alloc);
        self.classes.deinit(alloc);
        deinitInstantiationMap(alloc, &self.instantiations);
        self.* = undefined;
    }
};

/// Result of type inference: dense array of inferred concrete TypeIds and instantiation records.
pub const Inferred = struct {
    types: []?exprs.TypeId,
    instantiations: std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation) = .empty,

    pub fn deinit(self: *Inferred, alloc: std.mem.Allocator) void {
        alloc.free(self.types);
        deinitInstantiationMap(alloc, &self.instantiations);
        self.* = undefined;
    }

    pub fn getType(self: *const Inferred, node: exprs.NodeId) ?exprs.TypeId {
        if (node < self.types.len) return self.types[node];
        return null;
    }

    pub fn getInstantiation(self: *const Inferred, node: exprs.NodeId) ?types.Instantiation {
        return self.instantiations.get(node);
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

fn isTypeParam(t: types.Type, param_names: []const []const u8) ?usize {
    switch (t) {
        .path => |p| {
            if (p.segments.len == 1) {
                const seg_name = p.segments[0].name;
                for (param_names, 0..) |pn, idx| {
                    if (std.mem.eql(u8, seg_name, pn)) return idx;
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn substType(
    alloc: std.mem.Allocator,
    t: types.Type,
    param_names: []const []const u8,
    args: []const types.Type,
) std.mem.Allocator.Error!types.Type {
    if (param_names.len == 0 or args.len == 0) return t;

    if (isTypeParam(t, param_names)) |idx| {
        if (idx < args.len) return args[idx];
    }

    switch (t) {
        .prim => return t,
        .path => |p| {
            if (p.segments.len == 1) {
                if (isTypeParam(t, param_names)) |idx| {
                    if (idx < args.len) return args[idx];
                }
            }
            return t;
        },
        .reference => |r| {
            const sub_pointee = try substType(alloc, r.pointee, param_names, args);
            if (typeEqual(sub_pointee, r.pointee)) return t;
            const ref_ptr = try alloc.create(types.Ref);
            ref_ptr.* = .{ .mut = r.mut, .pointee = sub_pointee };
            return .{ .reference = ref_ptr };
        },
        .raw_ptr => |rp| {
            const sub_pointee = try substType(alloc, rp.pointee, param_names, args);
            if (typeEqual(sub_pointee, rp.pointee)) return t;
            const raw_ptr = try alloc.create(types.RawPtr);
            raw_ptr.* = .{ .mut = rp.mut, .pointee = sub_pointee };
            return .{ .raw_ptr = raw_ptr };
        },
        .slice => |s| {
            const sub_elem = try substType(alloc, s.elem, param_names, args);
            if (typeEqual(sub_elem, s.elem)) return t;
            const slice_ptr = try alloc.create(types.Slice);
            slice_ptr.* = .{ .const_ = s.const_, .elem = sub_elem };
            return .{ .slice = slice_ptr };
        },
        .array => |arr| {
            const sub_elem = try substType(alloc, arr.elem, param_names, args);
            if (typeEqual(sub_elem, arr.elem)) return t;
            const array_ptr = try alloc.create(types.Array);
            array_ptr.* = .{ .len = arr.len, .elem = sub_elem };
            return .{ .array = array_ptr };
        },
        .tuple => |tup| {
            var changed = false;
            const sub_elems = try alloc.alloc(types.Type, tup.len);
            for (tup, 0..) |elem, i| {
                sub_elems[i] = try substType(alloc, elem, param_names, args);
                if (!typeEqual(sub_elems[i], elem)) changed = true;
            }
            if (!changed) {
                alloc.free(sub_elems);
                return t;
            }
            return .{ .tuple = sub_elems };
        },
        .option => |opt| {
            const sub_inner = try substType(alloc, opt.*, param_names, args);
            if (typeEqual(sub_inner, opt.*)) return t;
            const opt_ptr = try alloc.create(types.Type);
            opt_ptr.* = sub_inner;
            return .{ .option = opt_ptr };
        },
        .result => |res| {
            const sub_ok = try substType(alloc, res.ok, param_names, args);
            const sub_err = try substType(alloc, res.err, param_names, args);
            if (typeEqual(sub_ok, res.ok) and typeEqual(sub_err, res.err)) return t;
            const res_ptr = try alloc.create(types.Result);
            res_ptr.* = .{ .ok = sub_ok, .err = sub_err, .is_error_unionable = res.is_error_unionable };
            return .{ .result = res_ptr };
        },
        .boxed => |bx| {
            const sub_inner = try substType(alloc, bx.*, param_names, args);
            if (typeEqual(sub_inner, bx.*)) return t;
            const bx_ptr = try alloc.create(types.Type);
            bx_ptr.* = sub_inner;
            return .{ .boxed = bx_ptr };
        },
        .generic_inst, .fn_ptr, .unsupported => return t,
    }
}

fn matchGenericType(
    param_ty: types.Type,
    actual_ty: types.Type,
    param_names: []const []const u8,
    inferred_args: []?types.Type,
) void {
    if (isTypeParam(param_ty, param_names)) |idx| {
        if (idx < inferred_args.len and inferred_args[idx] == null) {
            inferred_args[idx] = actual_ty;
        }
        return;
    }
    const p_tag = std.meta.activeTag(param_ty);
    const a_tag = std.meta.activeTag(actual_ty);
    if (p_tag != a_tag) return;
    switch (param_ty) {
        .reference => |r| matchGenericType(r.pointee, actual_ty.reference.pointee, param_names, inferred_args),
        .slice => |s| matchGenericType(s.elem, actual_ty.slice.elem, param_names, inferred_args),
        .array => |arr| matchGenericType(arr.elem, actual_ty.array.elem, param_names, inferred_args),
        .tuple => |tup| {
            if (tup.len == actual_ty.tuple.len) {
                for (tup, actual_ty.tuple) |p_elem, a_elem| {
                    matchGenericType(p_elem, a_elem, param_names, inferred_args);
                }
            }
        },
        .option => |opt| matchGenericType(opt.*, actual_ty.option.*, param_names, inferred_args),
        .result => |res| {
            matchGenericType(res.ok, actual_ty.result.ok, param_names, inferred_args);
            matchGenericType(res.err, actual_ty.result.err, param_names, inferred_args);
        },
        .boxed => |bx| matchGenericType(bx.*, actual_ty.boxed.*, param_names, inferred_args),
        else => {},
    }
}

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

/// Record an instantiation for an expression node, overwriting any prior entry.
/// Duplicates the args slice so the recorded value remains valid after the
/// caller's temporary storage is freed.
fn addInstantiation(ctx: *Ctx, node: exprs.NodeId, inst: types.Instantiation) std.mem.Allocator.Error!void {
    const owned = try ctx.alloc.dupe(types.Type, inst.args.params);
    const gop = try ctx.g.instantiations.getOrPut(ctx.alloc, node);
    if (gop.found_existing) {
        // Supersede the prior record's args without leaking it.
        ctx.alloc.free(gop.value_ptr.args.params);
    }
    gop.value_ptr.* = .{
        .generic_id = inst.generic_id,
        .args = .{ .params = owned },
        .zig_suffix = inst.zig_suffix,
    };
}

/// Free every recorded value's duplicated args slice, then the map itself.
fn deinitInstantiationMap(
    alloc: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation),
) void {
    var it = map.iterator();
    while (it.next()) |entry| alloc.free(entry.value_ptr.args.params);
    map.deinit(alloc);
    map.* = .empty;
}

/// Deep-clone an instantiation map into a new map (each value args dup'd).
fn cloneInstantiationMap(
    alloc: std.mem.Allocator,
    source: std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation),
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation) {
    var out: std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation) = .empty;
    errdefer deinitInstantiationMap(alloc, &out);
    var it = source.iterator();
    while (it.next()) |entry| {
        const owned = try alloc.dupe(types.Type, entry.value_ptr.args.params);
        try out.put(alloc, entry.key_ptr.*, .{
            .generic_id = entry.value_ptr.generic_id,
            .args = .{ .params = owned },
            .zig_suffix = entry.value_ptr.zig_suffix,
        });
    }
    return out;
}

fn collectTypeParamNamesFromType(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    buf: *std.ArrayListUnmanaged([]const u8),
    t: types.Type,
) std.mem.Allocator.Error!void {
    switch (t) {
        .prim => {},
        .path => |p| {
            if (p.segments.len == 1 and p.segments[0].id == null) {
                const name = p.segments[0].name;
                if (findTypeIndex(b, t) == null) {
                    for (buf.items) |existing| {
                        if (std.mem.eql(u8, existing, name)) return;
                    }
                    try buf.append(alloc, name);
                }
            }
        },
        .reference => |r| try collectTypeParamNamesFromType(alloc, b, buf, r.pointee),
        .raw_ptr => |rp| try collectTypeParamNamesFromType(alloc, b, buf, rp.pointee),
        .slice => |s| try collectTypeParamNamesFromType(alloc, b, buf, s.elem),
        .array => |arr| try collectTypeParamNamesFromType(alloc, b, buf, arr.elem),
        .tuple => |tup| {
            for (tup) |elem| try collectTypeParamNamesFromType(alloc, b, buf, elem);
        },
        .fn_ptr => |fp| {
            for (fp.params) |elem| try collectTypeParamNamesFromType(alloc, b, buf, elem);
            try collectTypeParamNamesFromType(alloc, b, buf, fp.ret);
        },
        .generic_inst => |gi| {
            for (gi.args.params) |elem| try collectTypeParamNamesFromType(alloc, b, buf, elem);
        },
        .option => |opt| try collectTypeParamNamesFromType(alloc, b, buf, opt.*),
        .result => |res| {
            try collectTypeParamNamesFromType(alloc, b, buf, res.ok);
            try collectTypeParamNamesFromType(alloc, b, buf, res.err);
        },
        .boxed => |bx| try collectTypeParamNamesFromType(alloc, b, buf, bx.*),
        .unsupported => {},
    }
}

/// Collect the generic type-parameter names of a callee definition by scanning
/// its lowered signature (fn params/ret, struct fields, const/type-alias target).
/// Returns a temporary, caller-freed duplicate of the found names.
fn getGenericParamNames(
    ctx: *Ctx,
    def: exprs.DefId,
) (std.mem.Allocator.Error || error{Unsupported})![]const []const u8 {
    const alloc = ctx.alloc;
    if (def >= ctx.b.bodies.len) return error.Unsupported;
    var buf: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer buf.deinit(alloc);
    switch (ctx.b.bodies[def]) {
        .fn_ => |fb| {
            for (fb.params) |param| {
                try collectTypeParamNamesFromType(alloc, ctx.b, &buf, param.ty);
            }
            try collectTypeParamNamesFromType(alloc, ctx.b, &buf, fb.ret);
        },
        .struct_ => |sb| {
            for (sb.fields) |field| {
                try collectTypeParamNamesFromType(alloc, ctx.b, &buf, field.ty);
            }
        },
        .const_ => |cb| try collectTypeParamNamesFromType(alloc, ctx.b, &buf, cb.ty),
        .type_alias => |ta| try collectTypeParamNamesFromType(alloc, ctx.b, &buf, ta.target),
        else => return error.Unsupported,
    }
    const names = try buf.toOwnedSlice(alloc);
    return names;
}

/// Derive a concrete Type for an argument expression node where possible.
fn getKnownType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    const e = ctx.b.exprs[node];
    if (e.ty) |tid| {
        if (tid < ctx.b.types.len) return ctx.b.types[tid];
    }
    switch (e.kind) {
        .literal => |lit| switch (lit) {
            .int => |il| {
                if (il.ty_suffix) |s| {
                    if (intSuffixPrim(s)) |p| return .{ .prim = p };
                }
                return .{ .prim = .i32 };
            },
            .float => |fl| return .{ .prim = floatSuffixPrim(fl.text) },
            .boolean => return .{ .prim = .bool },
            .character => return .{ .prim = .char },
            .string => return .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
            .byte_array => return .{ .array = &.{ .len = .{ .literal = @intCast(lit.byte_array.items.len) }, .elem = .{ .prim = .u8 } } },
        },
        .path => |p| {
            if (ctx.def_map.get(p.def)) |first| {
                if (first < ctx.b.exprs.len) {
                    if (ctx.b.exprs[first].ty) |tid| {
                        if (tid < ctx.b.types.len) return ctx.b.types[tid];
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Walk a free/associated/constructor call: recurse into args and, when the
/// callee is generic, unify argument types with instantiated parameter types.
fn handleCall(ctx: *Ctx, node: exprs.NodeId, c: exprs.Call, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    for (c.args) |a| try walkExpr(ctx, a, fn_body);
    const def = switch (c.call_kind) {
        .free => |d| d,
        .associated => |d| d,
        .constructor => |d| d,
    };
    try instantiateGenericDef(ctx, node, def, null, c.args, &.{});
}

/// Walk a struct literal: recurse into field values and, when the struct is
/// generic, unify field expression types with instantiated field types.
fn handleStructLit(ctx: *Ctx, node: exprs.NodeId, s: exprs.StructLit) std.mem.Allocator.Error!void {
    for (s.fields) |f| try walkExpr(ctx, f.value, node);
    if (s.base) |b0| try walkExpr(ctx, b0, node);
    try instantiateGenericDef(ctx, node, s.def, null, &.{}, s.fields);
}

/// Match argument expression types against the callee's substituted parameter
/// types (unification) and record the concrete instantiation arguments.
fn instantiateGenericDef(
    ctx: *Ctx,
    node: exprs.NodeId,
    def: exprs.DefId,
    stashed: ?types.GenericArgs,
    args: []const exprs.NodeId,
    fields: []const exprs.FieldInit,
) std.mem.Allocator.Error!void {
    if (def >= ctx.b.bodies.len) return;
    const caller_names = getGenericParamNames(ctx, def) catch return;
    if (caller_names.len == 0) return;
    defer ctx.alloc.free(caller_names);
    const param_names = caller_names;

    var param_types: []const types.Type = &.{};
    var ret_ty: ?types.Type = null;
    switch (ctx.b.bodies[def]) {
        .fn_ => |fb| {
            const types_buf = ctx.alloc.alloc(types.Type, fb.params.len) catch return;
            defer ctx.alloc.free(types_buf);
            for (fb.params, 0..) |p, i| types_buf[i] = p.ty;
            param_types = types_buf;
            ret_ty = fb.ret;
        },
        .struct_ => |sb| {
            const types_buf = ctx.alloc.alloc(types.Type, sb.fields.len) catch return;
            defer ctx.alloc.free(types_buf);
            for (sb.fields, 0..) |field, i| types_buf[i] = field.ty;
            param_types = types_buf;
        },
        else => return,
    }

    const inferred_args = ctx.alloc.alloc(?types.Type, param_names.len) catch return;
    defer ctx.alloc.free(inferred_args);
    for (inferred_args) |*slot| slot.* = null;

    // Seeding from explicit type arguments.
    if (stashed) |sa| {
        if (sa.params.len >= param_names.len) {
            for (sa.params[0..param_names.len], 0..) |t, i| {
                inferred_args[i] = t;
            }
        }
    }

    // Unify argument expressions with instantiated parameter types.
    switch (ctx.b.bodies[def]) {
        .fn_ => |fb| {
            const arg_count = @min(args.len, fb.params.len);
            for (0..arg_count) |i| {
                const actual_ty = getKnownType(ctx, args[i]) orelse continue;
                matchGenericType(fb.params[i].ty, actual_ty, param_names, inferred_args);
            }
        },
        .struct_ => |sb| {
            for (fields) |field| {
                for (sb.fields) |sb_field| {
                    if (std.mem.eql(u8, sb_field.name, field.field)) {
                        if (getKnownType(ctx, field.value)) |actual_ty| {
                            matchGenericType(sb_field.ty, actual_ty, param_names, inferred_args);
                        }
                        break;
                    }
                }
            }
        },
        else => {},
    }

    // Finalize concrete arguments.
    const concrete_args = ctx.alloc.alloc(types.Type, param_names.len) catch return;
    defer ctx.alloc.free(concrete_args);
    for (inferred_args, 0..) |slot, i| {
        concrete_args[i] = slot orelse .{ .prim = .i32 };
    }

    try addInstantiation(ctx, node, .{
        .generic_id = def,
        .args = .{ .params = concrete_args },
        .zig_suffix = "",
    });

    // Pin the instantiated return/field type when it resolves to an existing TypeId.
    if (ret_ty) |rt| {
        if (try substitutedTypeId(ctx, rt, param_names, concrete_args)) |tid| {
            try addPin(ctx, node, tid);
        }
    }
}

/// Resolve a type after substituting generic parameter names with concrete args,
/// returning the TypeId of an already-present structural match. Heap-free: scans
/// `b.types` applying the substitution conceptually rather than allocating.
fn substitutedTypeId(
    ctx: *Ctx,
    t: types.Type,
    param_names: []const []const u8,
    args: []const types.Type,
) std.mem.Allocator.Error!?exprs.TypeId {
    if (isTypeParam(t, param_names)) |idx| {
        if (idx < args.len) {
            const concrete = args[idx];
            if (findTypeIndex(ctx.b, concrete)) |cid| return cid;
        }
        return null;
    }
    // When the type has no generic-parameter references, it is already concrete.
    if (!typeContainsParam(t, param_names)) {
        return findTypeIndex(ctx.b, t);
    }
    // Otherwise substitute and look up; discard the temporary.
    const subst = try substType(ctx.alloc, t, param_names, args);
    const found = findTypeIndex(ctx.b, subst);
    freeTypeTree(ctx.alloc, subst);
    return found;
}

fn typeContainsParam(t: types.Type, param_names: []const []const u8) bool {
    switch (t) {
        .prim, .unsupported => return false,
        .path => |p| {
            if (p.segments.len == 1) {
                return isTypeParam(t, param_names) != null;
            }
            return false;
        },
        .reference => |r| return typeContainsParam(r.pointee, param_names),
        .raw_ptr => |rp| return typeContainsParam(rp.pointee, param_names),
        .slice => |s| return typeContainsParam(s.elem, param_names),
        .array => |arr| return typeContainsParam(arr.elem, param_names),
        .tuple => |tup| {
            for (tup) |elem| {
                if (typeContainsParam(elem, param_names)) return true;
            }
            return false;
        },
        .fn_ptr => |fp| {
            for (fp.params) |elem| {
                if (typeContainsParam(elem, param_names)) return true;
            }
            return typeContainsParam(fp.ret, param_names);
        },
        .generic_inst => |gi| {
            for (gi.args.params) |elem| {
                if (typeContainsParam(elem, param_names)) return true;
            }
            return false;
        },
        .option => |opt| return typeContainsParam(opt.*, param_names),
        .result => |res| {
            return typeContainsParam(res.ok, param_names) or typeContainsParam(res.err, param_names);
        },
        .boxed => |bx| return typeContainsParam(bx.*, param_names),
    }
}

fn freeTypeTree(alloc: std.mem.Allocator, t: types.Type) void {
    switch (t) {
        .prim, .path, .unsupported => {},
        .reference => |r| {
            freeTypeTree(alloc, r.pointee);
            alloc.destroy(r);
        },
        .raw_ptr => |rp| {
            freeTypeTree(alloc, rp.pointee);
            alloc.destroy(rp);
        },
        .slice => |s| {
            freeTypeTree(alloc, s.elem);
            alloc.destroy(s);
        },
        .array => |arr| {
            freeTypeTree(alloc, arr.elem);
            alloc.destroy(arr);
        },
        .tuple => |tup| {
            for (tup) |elem| freeTypeTree(alloc, elem);
            alloc.free(tup);
        },
        .fn_ptr => |fp| {
            for (fp.params) |elem| freeTypeTree(alloc, elem);
            alloc.free(fp.params);
            freeTypeTree(alloc, fp.ret);
            alloc.destroy(fp);
        },
        .generic_inst => |gi| {
            for (gi.args.params) |elem| freeTypeTree(alloc, elem);
            alloc.free(gi.args.params);
        },
        .option => |opt| {
            freeTypeTree(alloc, opt.*);
            alloc.destroy(opt);
        },
        .result => |res| {
            freeTypeTree(alloc, res.ok);
            freeTypeTree(alloc, res.err);
            alloc.destroy(res);
        },
        .boxed => |bx| {
            freeTypeTree(alloc, bx.*);
            alloc.destroy(bx);
        },
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
        .path => |p| {
            try walkPath(ctx, node, p);
            if (p.generic_args.len > 0) {
                try addInstantiation(ctx, node, .{
                    .generic_id = p.def,
                    .args = .{ .params = p.generic_args },
                    .zig_suffix = "",
                });
            }
        },
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
            try handleCall(ctx, node, c, fn_body);
        },
        .method_call => |m| {
            try walkExpr(ctx, m.receiver, fn_body);
            for (m.args) |a| try walkExpr(ctx, a, fn_body);
        },
        .struct_lit => |s| {
            try handleStructLit(ctx, node, s);
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
        .array => |a| for (a.elements) |el| try walkExpr(ctx, el, fn_body),
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
        // Zero exprs: still hand over any recorded instantiations (rare no-body case).
        return .{
            .types = try alloc.alloc(?exprs.TypeId, 0),
            .instantiations = cloneInstantiationMap(alloc, g.instantiations) catch .empty,
        };
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

    return .{
        .types = result_types,
        .instantiations = cloneInstantiationMap(alloc, g.instantiations) catch .empty,
    };
}

/// Generate constraints and run full unification solver with defaults on `b`.
pub fn solve(alloc: std.mem.Allocator, b: *const bodies.Bodies) std.mem.Allocator.Error!Inferred {
    std.debug.assert(b.exprs.len >= 0);
    var g = try gen(alloc, b);
    defer g.deinit(alloc);
    return solveWithGen(alloc, b, &g);
}

// ── Tests: generic parameter unification & instantiation tracking ──────────

fn testPrimPath(alloc: std.mem.Allocator, name: []const u8) !types.Type {
    const seg = try alloc.dupe(types.PathSegment, &.{.{ .name = name, .id = null }});
    return .{ .path = .{ .segments = seg } };
}

// Compile-time span reused across fixtures.
const test_span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };
test "generic PathExpr with type arguments records an instantiation" {
    const a = std.testing.allocator;

    // Types: 0 = u64, 1 = u32.
    const types_store = try a.alloc(types.Type, 2);
    types_store[0] = .{ .prim = .u64 };
    types_store[1] = .{ .prim = .u32 };

    // Expr 0: path `foo::<u64>` (def 1) in an empty block body so gen walks it.
    const fake_path = try a.alloc(types.Type, 1);
    defer a.free(fake_path);
    fake_path[0] = .{ .prim = .u64 };
    const exprs_store = try a.alloc(exprs.Expr, 1);
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .path = .{ .def = 1, .generic_args = fake_path } },
    };

    const bodies_store = try a.alloc(bodies.BodyKind, 1);
    bodies_store[0] = .{ .fn_ = .{
        .params = try a.dupe(items.Param, &.{}),
        .ret = .{ .prim = .unit },
        .body = 0,
    } };

    defer {
        a.free(bodies_store[0].fn_.params);
        a.free(bodies_store);
        a.free(exprs_store);
        a.free(types_store);
    }

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var g = try gen(a, &b);
    defer g.deinit(a);

    const inst = g.instantiations.get(0);
    try std.testing.expect(inst != null);
    try std.testing.expectEqual(@as(exprs.DefId, 1), inst.?.generic_id);
    try std.testing.expectEqual(@as(usize, 1), inst.?.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, inst.?.args.params[0]);
}

test "generic fn call unifies argument type and records instantiation" {
    const a = std.testing.allocator;

    // Types: 0 = u32.
    const types_store = try a.alloc(types.Type, 1);
    defer a.free(types_store);
    types_store[0] = .{ .prim = .u32 };

    // Callee `id` at body index 1: fn id<T>(x: T) -> T.
    const param = try testPrimPath(a, "T");
    defer a.free(param.path.segments);
    const id_fn_params = try a.alloc(items.Param, 1);
    defer a.free(id_fn_params);
    id_fn_params[0] = .{ .name = "x", .ty = param, .span = test_span };

    // Expr table (caller body):
    // 0: block body
    // 1: literal 5u32
    // 2: call free(id) arg=1
    const exprs_store = try a.alloc(exprs.Expr, 3);
    defer a.free(exprs_store);
    const stmt_ids = try a.alloc(exprs.NodeId, 1);
    defer a.free(stmt_ids);
    stmt_ids[0] = 0;
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .block = .{ .statements = stmt_ids, .tail = null, .labelled = null } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = test_span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "5u32", .value = 5, .base = .dec, .ty_suffix = "u32" } } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = test_span,
        .ty = null,
        .kind = .{ .call = .{ .call_kind = .{ .free = 1 }, .args = &.{1} } },
    };

    const stmts_store = try a.alloc(exprs.Statement, 1);
    defer a.free(stmts_store);
    stmts_store[0] = .{ .id = 0, .span = test_span, .ty = null, .kind = .{ .expr = 2 } };

    const bodies_store = try a.alloc(bodies.BodyKind, 2);
    defer a.free(bodies_store);
    // 0: caller fn (body = block node 0)
    const caller_params = try a.dupe(items.Param, &.{});
    defer a.free(caller_params);
    bodies_store[0] = .{ .fn_ = .{ .params = caller_params, .ret = .{ .prim = .u32 }, .body = 0 } };
    // 1: id<T>(x: T) -> T (generic callee).
    bodies_store[1] = .{ .fn_ = .{ .params = id_fn_params, .ret = param, .body = 0 } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var inferred = try solve(a, &b);
    defer inferred.deinit(a);

    // Instantiation recorded on call node 2: id<u32>.
    const inst = inferred.getInstantiation(2);
    try std.testing.expect(inst != null);
    try std.testing.expectEqual(@as(exprs.DefId, 1), inst.?.generic_id);
    try std.testing.expectEqual(@as(usize, 1), inst.?.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, inst.?.args.params[0]);

    // Call node pinned to the substituted return type u32 (TypeId 0).
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(2));
}

test "generic struct literal records instantiation" {
    const a = std.testing.allocator;

    const types_store = try a.alloc(types.Type, 1);
    defer a.free(types_store);
    types_store[0] = .{ .prim = .u32 };

    // Generic struct `Pair<T>` at body index 1 with two fields of type T.
    const field_t = try testPrimPath(a, "T");
    defer a.free(field_t.path.segments);
    const struct_fields = try a.alloc(items.Field, 2);
    defer a.free(struct_fields);
    struct_fields[0] = .{ .name = "x", .ty = field_t, .visibility = .public, .span = test_span };
    struct_fields[1] = .{ .name = "y", .ty = field_t, .visibility = .public, .span = test_span };

    const exprs_store = try a.alloc(exprs.Expr, 3);
    defer a.free(exprs_store);
    const stmt_ids = try a.alloc(exprs.NodeId, 1);
    defer a.free(stmt_ids);
    stmt_ids[0] = 0;
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .block = .{ .statements = stmt_ids, .tail = null, .labelled = null } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = test_span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "5u32", .value = 5, .base = .dec, .ty_suffix = "u32" } } },
    };
    exprs_store[2] = .{
        .id = 2,
        .span = test_span,
        .ty = null,
        .kind = .{ .struct_lit = .{
            .def = 1,
            .fields = &.{.{ .field = "x", .value = 1, .shorthand = false }},
            .base = null,
        } },
    };

    const stmts_store = try a.alloc(exprs.Statement, 1);
    defer a.free(stmts_store);
    stmts_store[0] = .{ .id = 0, .span = test_span, .ty = null, .kind = .{ .expr = 2 } };

    const bodies_store = try a.alloc(bodies.BodyKind, 2);
    defer a.free(bodies_store);
    const caller_params = try a.dupe(items.Param, &.{});
    defer a.free(caller_params);
    bodies_store[0] = .{ .fn_ = .{ .params = caller_params, .ret = .{ .prim = .u32 }, .body = 0 } };
    bodies_store[1] = .{ .struct_ = .{
        .generic_params = &.{},
        .trait_bounds = &.{},
        .layout = .named,
        .fields = struct_fields,
        .methods = &.{},
    } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    var inferred = try solve(a, &b);
    defer inferred.deinit(a);

    const inst = inferred.getInstantiation(2);
    try std.testing.expect(inst != null);
    try std.testing.expectEqual(@as(exprs.DefId, 1), inst.?.generic_id);
    try std.testing.expectEqual(@as(usize, 1), inst.?.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, inst.?.args.params[0]);
}

test "substType substitutes generic type parameters structurally" {
    const a = std.testing.allocator;

    const t_inner = try testPrimPath(a, "T");
    defer a.free(t_inner.path.segments);
    const param_names = try a.alloc([]const u8, 1);
    defer a.free(param_names);
    param_names[0] = "T";
    const args = try a.alloc(types.Type, 1);
    defer a.free(args);
    args[0] = .{ .prim = .u32 };

    // &T -> &u32.
    const ref_heap = try a.create(types.Ref);
    defer a.destroy(ref_heap);
    const ref_t: types.Type = .{ .reference = ref_heap };
    init_heap: {
        ref_heap.* = .{ .mut = false, .pointee = t_inner };
        const subst = try substType(a, ref_t, param_names, args);
        try std.testing.expect(subst == .reference);
        try std.testing.expectEqual(types.Type{ .prim = .u32 }, subst.reference.pointee);
        // Free the substituted Allocation's pointee (a prim — nothing to free)
        // and the substituted reference node itself.
        a.destroy(subst.reference);
        break :init_heap;
    }
}
