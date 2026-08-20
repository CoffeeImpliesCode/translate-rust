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
const graph = ir.graph;
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
        .generic_inst => |gi| {
            var changed = false;
            const sub_args = try alloc.alloc(types.Type, gi.args.params.len);
            for (gi.args.params, 0..) |arg, i| {
                sub_args[i] = try substType(alloc, arg, param_names, args);
                if (!typeEqual(sub_args[i], arg)) changed = true;
            }
            if (!changed) {
                alloc.free(sub_args);
                return t;
            }
            return .{ .generic_inst = .{
                .decl = gi.decl,
                .args = .{ .params = sub_args },
            } };
        },
        .fn_ptr => |fp| {
            var changed = false;
            const sub_params = try alloc.alloc(types.Type, fp.params.len);
            for (fp.params, 0..) |param, i| {
                sub_params[i] = try substType(alloc, param, param_names, args);
                if (!typeEqual(sub_params[i], param)) changed = true;
            }
            const sub_ret = try substType(alloc, fp.ret, param_names, args);
            if (!typeEqual(sub_ret, fp.ret)) changed = true;
            if (!changed) {
                alloc.free(sub_params);
                return t;
            }
            const fn_ptr = try alloc.create(types.FnPtr);
            fn_ptr.* = .{ .params = sub_params, .ret = sub_ret };
            return .{ .fn_ptr = fn_ptr };
        },
        .unsupported => return t,
    }
}

/// Match one generic signature type against one concrete argument type.
/// Every repeated parameter occurrence must bind to the same structural type.
/// A false result rejects the whole instantiation; callers must not fill gaps
/// with Rust's unrelated integer-literal default.
fn matchGenericType(
    param_ty: types.Type,
    actual_ty: types.Type,
    param_names: []const []const u8,
    inferred_args: []?types.Type,
) bool {
    if (isTypeParam(param_ty, param_names)) |idx| {
        if (idx >= inferred_args.len) return false;
        if (inferred_args[idx]) |previous| {
            return typeEqual(previous, actual_ty);
        }
        inferred_args[idx] = actual_ty;
        return true;
    }

    const p_tag = std.meta.activeTag(param_ty);
    const a_tag = std.meta.activeTag(actual_ty);
    if (p_tag != a_tag) return false;

    return switch (param_ty) {
        .prim => |p| p == actual_ty.prim,
        .path => |p| {
            const other = actual_ty.path;
            if (p.segments.len != other.segments.len) return false;
            for (p.segments, other.segments) |left, right| {
                if (!std.mem.eql(u8, left.name, right.name)) return false;
            }
            return true;
        },
        .reference => |r| r.mut == actual_ty.reference.mut and
            matchGenericType(r.pointee, actual_ty.reference.pointee, param_names, inferred_args),
        .raw_ptr => |r| r.mut == actual_ty.raw_ptr.mut and
            matchGenericType(r.pointee, actual_ty.raw_ptr.pointee, param_names, inferred_args),
        .slice => |s| s.const_ == actual_ty.slice.const_ and
            matchGenericType(s.elem, actual_ty.slice.elem, param_names, inferred_args),
        .array => |arr| std.meta.eql(arr.len, actual_ty.array.len) and
            matchGenericType(arr.elem, actual_ty.array.elem, param_names, inferred_args),
        .tuple => |tuple| {
            const other = actual_ty.tuple;
            if (tuple.len != other.len) return false;
            for (tuple, other) |left, right| {
                if (!matchGenericType(left, right, param_names, inferred_args)) return false;
            }
            return true;
        },
        .fn_ptr => |fp| {
            const other = actual_ty.fn_ptr;
            if (fp.params.len != other.params.len) return false;
            for (fp.params, other.params) |left, right| {
                if (!matchGenericType(left, right, param_names, inferred_args)) return false;
            }
            return matchGenericType(fp.ret, other.ret, param_names, inferred_args);
        },
        .generic_inst => |gi| {
            const other = actual_ty.generic_inst;
            if (gi.decl != other.decl) return false;
            if (gi.args.params.len != other.args.params.len) return false;
            for (gi.args.params, other.args.params) |left, right| {
                if (!matchGenericType(left, right, param_names, inferred_args)) return false;
            }
            return true;
        },
        .option => |opt| matchGenericType(opt.*, actual_ty.option.*, param_names, inferred_args),
        .result => |res| {
            const other = actual_ty.result;
            if (res.is_error_unionable != other.is_error_unionable) return false;
            if (!matchGenericType(res.ok, other.ok, param_names, inferred_args)) return false;
            return matchGenericType(res.err, other.err, param_names, inferred_args);
        },
        .boxed => |boxed| matchGenericType(boxed.*, actual_ty.boxed.*, param_names, inferred_args),
        .unsupported => |unsupported| {
            const other = actual_ty.unsupported;
            return unsupported.reason == other.reason and
                std.mem.eql(u8, unsupported.message, other.message);
        },
    };
}

const Ctx = struct {
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    g: *Gen,
    cg: ?*const graph.CrateGraph = null,
    bool_ty: ?exprs.TypeId = null,
    def_map: std.AutoHashMapUnmanaged(exprs.DefId, exprs.NodeId) = .empty,
    /// Concrete signature types for local parameters, keyed by their resolved
    /// field entity. This keeps a path argument's type available before the
    /// unification result has been applied to the expression table.
    local_types: std.AutoHashMapUnmanaged(exprs.DefId, types.Type) = .empty,
    current_fn: ?exprs.DefId = null,
    local_defs: []exprs.DefId = &.{},
    local_claimed: []bool = &.{},
    fn boolId(self: *Ctx) ?exprs.TypeId {
        if (self.bool_ty) |t| return t;
        const t = primTypeId(self.b, .bool) orelse return null;
        self.bool_ty = t;
        return t;
    }

    fn clearLocals(self: *Ctx) void {
        if (self.local_defs.len > 0) self.alloc.free(self.local_defs);
        if (self.local_claimed.len > 0) self.alloc.free(self.local_claimed);
        self.local_defs = &.{};
        self.local_claimed = &.{};
        self.local_types.clearRetainingCapacity();
        self.current_fn = null;
    }

    fn prepareLocals(
        self: *Ctx,
        fn_id: exprs.DefId,
        params: []const items.Param,
    ) std.mem.Allocator.Error!void {
        self.clearLocals();
        self.current_fn = fn_id;
        const cg = self.cg orelse return;

        var count: usize = 0;
        for (cg.symbol_table.entities.items) |entity| {
            if (entity.kind == .field and entity.parent == fn_id) count += 1;
        }
        if (count == 0) return;

        self.local_defs = try self.alloc.alloc(exprs.DefId, count);
        errdefer {
            self.alloc.free(self.local_defs);
            self.local_defs = &.{};
        }
        self.local_claimed = try self.alloc.alloc(bool, count);
        for (self.local_claimed) |*claimed| claimed.* = false;

        var index: usize = 0;
        for (cg.symbol_table.entities.items) |entity| {
            if (entity.kind == .field and entity.parent == fn_id) {
                self.local_defs[index] = entity.id;
                index += 1;
            }
        }
        for (params) |param| {
            if (self.claimLocal(param.name)) |def| {
                try self.local_types.put(self.alloc, def, param.ty);
            }
        }
    }

    fn claimLocal(self: *Ctx, name: []const u8) ?exprs.DefId {
        const cg = self.cg orelse return null;
        for (self.local_defs, 0..) |def, index| {
            if (self.local_claimed[index]) continue;
            const entity = cg.symbol_table.get(def) orelse continue;
            if (!std.mem.eql(u8, entity.name, name)) continue;
            self.local_claimed[index] = true;
            return def;
        }
        return null;
    }

    fn deinit(self: *Ctx) void {
        self.clearLocals();
        self.local_types.deinit(self.alloc);
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

/// Structural equality check for types to resolve TypeId in `b.types` and to
/// validate repeated generic bindings. Qualifiers are part of the identity:
/// `&[T]` and `&mut [T]` must never unify.
fn typeEqual(a: types.Type, b: types.Type) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return false;
    return switch (a) {
        .prim => |p| p == b.prim,
        .path => |p| {
            const other = b.path;
            if (p.segments.len != other.segments.len) return false;
            for (p.segments, other.segments) |left, right| {
                if (!std.mem.eql(u8, left.name, right.name)) return false;
            }
            return true;
        },
        .reference => |r| r.mut == b.reference.mut and
            typeEqual(r.pointee, b.reference.pointee),
        .raw_ptr => |r| r.mut == b.raw_ptr.mut and
            typeEqual(r.pointee, b.raw_ptr.pointee),
        .slice => |s| s.const_ == b.slice.const_ and
            typeEqual(s.elem, b.slice.elem),
        .array => |arr| std.meta.eql(arr.len, b.array.len) and
            typeEqual(arr.elem, b.array.elem),
        .tuple => |tuple| {
            if (tuple.len != b.tuple.len) return false;
            for (tuple, b.tuple) |left, right| {
                if (!typeEqual(left, right)) return false;
            }
            return true;
        },
        .fn_ptr => |fp| {
            const other = b.fn_ptr;
            if (fp.params.len != other.params.len) return false;
            for (fp.params, other.params) |left, right| {
                if (!typeEqual(left, right)) return false;
            }
            return typeEqual(fp.ret, other.ret);
        },
        .generic_inst => |gi| {
            const other = b.generic_inst;
            if (gi.decl != other.decl) return false;
            if (gi.args.params.len != other.args.params.len) return false;
            for (gi.args.params, other.args.params) |left, right| {
                if (!typeEqual(left, right)) return false;
            }
            return true;
        },
        .option => |opt| typeEqual(opt.*, b.option.*),
        .result => |res| {
            const other = b.result;
            return res.is_error_unionable == other.is_error_unionable and
                typeEqual(res.ok, other.ok) and typeEqual(res.err, other.err);
        },
        .boxed => |boxed| typeEqual(boxed.*, b.boxed.*),
        .unsupported => |unsupported| {
            const other = b.unsupported;
            return unsupported.reason == other.reason and
                std.mem.eql(u8, unsupported.message, other.message);
        },
    };
}

/// Find the TypeId corresponding to target type in `b.types`.
pub fn findTypeIndex(b: *const bodies.Bodies, target: types.Type) ?exprs.TypeId {
    std.debug.assert(b.types.len >= 0);
    for (b.types, 0..) |t, i| {
        if (typeEqual(t, target)) return @intCast(i);
    }
    return null;
}

/// Locate the TypeId of a slice with the given primitive element type.
pub fn findSliceTypeId(b: *const bodies.Bodies, elem_prim: types.Prim) ?exprs.TypeId {
    std.debug.assert(b.types.len >= 0);
    for (b.types, 0..) |t, i| {
        switch (t) {
            .slice => |s| {
                if (s.elem == .prim and s.elem.prim == elem_prim) return @intCast(i);
            },
            else => {},
        }
    }
    return null;
}

/// Locate the TypeId of a slice with the given element type.
pub fn findSliceTypeForElem(b: *const bodies.Bodies, elem: types.Type) ?exprs.TypeId {
    std.debug.assert(b.types.len >= 0);
    for (b.types, 0..) |t, i| {
        switch (t) {
            .slice => |s| {
                if (typeEqual(s.elem, elem)) return @intCast(i);
            },
            else => {},
        }
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
        for (arm.patterns) |pattern| try bindPattern(ctx, pattern, null);
        if (arm.guard) |guard| try walkExpr(ctx, guard, fn_body);
        try addEq(ctx, node, arm.body);
        try walkExpr(ctx, arm.body, fn_body);
    }
}

/// Claim local entities in a pattern in lowering order. `let` bindings map
/// their resolved EntityId to the initializer; other patterns only reserve the
/// entity so later shadowed bindings keep their distinct ids.
fn bindPattern(
    ctx: *Ctx,
    pattern_id: exprs.NodeId,
    init: ?exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (pattern_id >= ctx.b.pats.len) return;
    switch (ctx.b.pats[pattern_id].kind) {
        .binding => |binding| {
            const def_id = ctx.claimLocal(binding.name) orelse blk: {
                if (ctx.cg == null) break :blk @as(?exprs.DefId, @intCast(pattern_id));
                break :blk null;
            };
            if (init) |init_node| {
                if (def_id) |def| try ctx.def_map.put(ctx.alloc, def, init_node);
            }
        },
        .tuple => |tuple| {
            for (tuple.elements) |element| try bindPattern(ctx, element, init);
        },
        .slice => |slice| {
            for (slice.elements) |element| try bindPattern(ctx, element, init);
            if (slice.rest) |rest| try bindPattern(ctx, rest, init);
        },
        .struct_pat => |struct_pat| {
            for (struct_pat.fields) |field| {
                if (field.pat) |field_pattern| {
                    try bindPattern(ctx, field_pattern, init);
                } else if (field.shorthand) {
                    const def_id = ctx.claimLocal(field.field);
                    if (init) |init_node| {
                        if (def_id) |def| try ctx.def_map.put(ctx.alloc, def, init_node);
                    }
                }
            }
        },
        .reference => |reference| try bindPattern(ctx, reference.inner, init),
        .@"or" => |or_pattern| {
            for (or_pattern.alternatives) |alternative| {
                try bindPattern(ctx, alternative, init);
            }
        },
        .wildcard, .literal, .path, .range => {},
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
                try bindPattern(ctx, ls.pattern, init);
            } else {
                try bindPattern(ctx, ls.pattern, null);
            }
        },
        .let_else => |le| {
            try walkExpr(ctx, le.init, fn_body);
            try bindPattern(ctx, le.pattern, le.init);
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
            if (fb.generic_params.len > 0) {
                try buf.appendSlice(alloc, fb.generic_params);
            } else {
                for (fb.params) |param| {
                    try collectTypeParamNamesFromType(alloc, ctx.b, &buf, param.ty);
                }
                try collectTypeParamNamesFromType(alloc, ctx.b, &buf, fb.ret);
            }
        },
        .struct_ => |sb| {
            if (sb.generic_params.len > 0) {
                try buf.appendSlice(alloc, sb.generic_params);
            } else {
                for (sb.fields) |field| {
                    try collectTypeParamNamesFromType(alloc, ctx.b, &buf, field.ty);
                }
                for (sb.methods) |method| {
                    for (method.params) |param| {
                        try collectTypeParamNamesFromType(alloc, ctx.b, &buf, param.ty);
                    }
                    try collectTypeParamNamesFromType(alloc, ctx.b, &buf, method.ret);
                }
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
    switch (e.kind) {
        .path => |p| {
            if (ctx.local_types.get(p.def)) |local_ty| return local_ty;
            if (p.generic_args.len > 0) {
                return .{ .generic_inst = .{
                    .decl = p.def,
                    .args = .{ .params = p.generic_args },
                } };
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
            if (ctx.def_map.get(p.def)) |first| {
                if (first < ctx.b.exprs.len) {
                    if (ctx.b.exprs[first].ty) |tid| {
                        if (tid < ctx.b.types.len) return ctx.b.types[tid];
                    }
                }
            }
        },
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
            .string => {},
            .byte_array => return .{
                .array = &.{
                    .len = .{ .literal = @intCast(lit.byte_array.items.len) },
                    .elem = .{ .prim = .u8 },
                },
            },
        },
        else => {
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
    }
    return null;
}
/// Recover explicit concrete generic arguments carried by a resolved result
/// type. The IR keeps path arguments directly on `PathExpr`; call and struct
/// nodes have no separate callee-type field, so their lowered generic result
/// type is the only lossless carrier available at this stage.
fn explicitArgsForNode(ctx: *Ctx, node: exprs.NodeId) ?types.GenericArgs {
    if (node >= ctx.b.exprs.len) return null;
    const type_id = ctx.b.exprs[node].ty orelse return null;
    if (type_id >= ctx.b.types.len) return null;
    return switch (ctx.b.types[type_id]) {
        .generic_inst => |generic_inst| generic_inst.args,
        else => null,
    };
}
/// Recover the expected generic result for a tail call. This is deliberately
/// limited to the enclosing block tail: using a function's return type for an
/// arbitrary nested call would bind unrelated call sites to the same record.
fn expectedGenericTypeForTail(
    ctx: *Ctx,
    node: exprs.NodeId,
    fn_body: exprs.NodeId,
    def: exprs.DefId,
) ?types.Type {
    if (fn_body >= ctx.b.exprs.len) return null;
    const body_expr = ctx.b.exprs[fn_body];
    if (body_expr.kind != .block) return null;
    if (body_expr.kind.block.tail != node) return null;
    const type_id = findFnRetTypeId(ctx.b, fn_body) orelse return null;
    if (type_id >= ctx.b.types.len) return null;
    return switch (ctx.b.types[type_id]) {
        .generic_inst => |inst| if (inst.decl == def) ctx.b.types[type_id] else null,
        else => null,
    };
}
/// Check explicit arguments against a known declaration signature. Definitions
/// without a lowered body cannot be checked here, so their explicit arguments
/// remain lossless and are preserved for the later monomorphization pass.
fn explicitArgsMatchSignature(
    ctx: *Ctx,
    def: exprs.DefId,
    args: []const types.Type,
) bool {
    if (def >= ctx.b.bodies.len) return true;
    switch (ctx.b.bodies[def]) {
        .none => return true,
        .fn_, .struct_, .const_, .type_alias => {
            const names = getGenericParamNames(ctx, def) catch return false;
            defer ctx.alloc.free(names);
            return names.len == args.len;
        },
        .enum_, .trait_ => return false,
    }
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
    const expected_type = expectedGenericTypeForTail(ctx, node, fn_body, def);
    const explicit: ?types.GenericArgs = if (explicitArgsForNode(ctx, node)) |args|
        args
    else if (expected_type) |expected|
        switch (expected) {
            .generic_inst => |inst| inst.args,
            else => null,
        }
    else
        null;
    try instantiateGenericDef(
        ctx,
        node,
        def,
        explicit,
        c.args,
        &.{},
    );
    if (expected_type) |expected| {
        if (findTypeIndex(ctx.b, expected)) |type_id| {
            try addPin(ctx, node, type_id);
        }
    }
}

/// Walk a struct literal: recurse into field values and, when the struct is
/// generic, unify field expression types with instantiated field types.
fn handleStructLit(ctx: *Ctx, node: exprs.NodeId, s: exprs.StructLit) std.mem.Allocator.Error!void {
    for (s.fields) |f| try walkExpr(ctx, f.value, node);
    if (s.base) |b0| try walkExpr(ctx, b0, node);
    try instantiateGenericDef(
        ctx,
        node,
        s.def,
        explicitArgsForNode(ctx, node),
        &.{},
        s.fields,
    );
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
    defer ctx.alloc.free(caller_names);

    var ret_ty: ?types.Type = null;
    switch (ctx.b.bodies[def]) {
        .fn_ => |fb| ret_ty = fb.ret,
        .struct_ => {},
        else => return,
    }

    // Non-generic functions still carry useful concrete nominal return types.
    // Preserve those types on call nodes so a following local binding can
    // propagate the constructor result through its resolved EntityId.
    if (caller_names.len == 0) {
        if (ret_ty) |return_ty| {
            if (findTypeIndex(ctx.b, return_ty)) |return_type_id| {
                try addPin(ctx, node, return_type_id);
            }
        }
        return;
    }
    const param_names = caller_names;

    const inferred_args = ctx.alloc.alloc(?types.Type, param_names.len) catch return;
    defer ctx.alloc.free(inferred_args);
    for (inferred_args) |*slot| slot.* = null;

    // Explicit arguments are authoritative and must have exact arity.
    if (stashed) |explicit| {
        if (explicit.params.len != param_names.len) return;
        for (explicit.params, 0..) |arg, i| inferred_args[i] = arg;
    }

    var valid = true;
    switch (ctx.b.bodies[def]) {
        .fn_ => |fb| {
            if (args.len != fb.params.len) return;
            for (fb.params, args) |param, arg_node| {
                const actual_ty = getKnownType(ctx, arg_node) orelse {
                    valid = false;
                    break;
                };
                if (!matchGenericType(param.ty, actual_ty, param_names, inferred_args)) {
                    valid = false;
                    break;
                }
            }
        },
        .struct_ => |sb| {
            if (fields.len > 0) {
                for (fields) |field| {
                    var found = false;
                    for (sb.fields) |struct_field| {
                        if (!std.mem.eql(u8, struct_field.name, field.field)) continue;
                        found = true;
                        const actual_ty = getKnownType(ctx, field.value) orelse {
                            valid = false;
                            break;
                        };
                        if (!matchGenericType(
                            struct_field.ty,
                            actual_ty,
                            param_names,
                            inferred_args,
                        )) {
                            valid = false;
                        }
                        break;
                    }
                    if (!found) valid = false;
                    if (!valid) break;
                }
            } else if (args.len > 0) {
                if (args.len != sb.fields.len) return;
                for (sb.fields, args) |struct_field, arg_node| {
                    const actual_ty = getKnownType(ctx, arg_node) orelse {
                        valid = false;
                        break;
                    };
                    if (!matchGenericType(
                        struct_field.ty,
                        actual_ty,
                        param_names,
                        inferred_args,
                    )) {
                        valid = false;
                        break;
                    }
                }
            }
        },
        else => return,
    }
    if (!valid) return;

    // Every declared type parameter must be bound by an explicit argument or
    // by a concrete signature match. Unbound parameters are ambiguous.
    for (inferred_args) |slot| {
        if (slot == null) return;
    }

    const concrete_args = ctx.alloc.alloc(types.Type, param_names.len) catch return;
    defer ctx.alloc.free(concrete_args);
    for (inferred_args, 0..) |slot, i| concrete_args[i] = slot.?;

    try addInstantiation(ctx, node, .{
        .generic_id = def,
        .args = .{ .params = concrete_args },
        .zig_suffix = "",
    });

    // Pin the instantiated return type when it resolves to an existing type.
    if (ret_ty) |return_ty| {
        if (try substitutedTypeId(ctx, return_ty, param_names, concrete_args)) |tid| {
            try addPin(ctx, node, tid);
        }
    }
}

/// Resolve a type after substituting generic parameter names with concrete args,
/// returning the TypeId of an already-present structural match. Temporary
/// substitution nodes are released without taking ownership of borrowed types.
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
    // Otherwise substitute, look up, and release only owned temporary nodes.
    const subst = try substType(ctx.alloc, t, param_names, args);
    const found = findTypeIndex(ctx.b, subst);
    freeSubstitutedType(ctx.alloc, t, subst, param_names, args);
    return found;
}

/// Release only nodes allocated by `substType`; source and argument types stay borrowed.
fn freeSubstitutedType(
    alloc: std.mem.Allocator,
    original: types.Type,
    substituted: types.Type,
    param_names: []const []const u8,
    args: []const types.Type,
) void {
    if (param_names.len == 0 or args.len == 0) return;
    if (isTypeParam(original, param_names) != null) return;

    switch (original) {
        .reference => |ref| {
            const sub_ref = switch (substituted) {
                .reference => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, ref.pointee, sub_ref.pointee, param_names, args);
            if (!typeEqual(sub_ref.pointee, ref.pointee)) alloc.destroy(sub_ref);
        },
        .raw_ptr => |raw_ptr| {
            const sub_raw_ptr = switch (substituted) {
                .raw_ptr => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, raw_ptr.pointee, sub_raw_ptr.pointee, param_names, args);
            if (!typeEqual(sub_raw_ptr.pointee, raw_ptr.pointee)) alloc.destroy(sub_raw_ptr);
        },
        .slice => |slice| {
            const sub_slice = switch (substituted) {
                .slice => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, slice.elem, sub_slice.elem, param_names, args);
            if (!typeEqual(sub_slice.elem, slice.elem)) alloc.destroy(sub_slice);
        },
        .array => |array| {
            const sub_array = switch (substituted) {
                .array => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, array.elem, sub_array.elem, param_names, args);
            if (!typeEqual(sub_array.elem, array.elem)) alloc.destroy(sub_array);
        },
        .tuple => |tuple| {
            const sub_tuple = switch (substituted) {
                .tuple => |value| value,
                else => return,
            };
            if (sub_tuple.len != tuple.len) return;

            var changed = false;
            for (tuple, sub_tuple) |original_elem, substituted_elem| {
                freeSubstitutedType(
                    alloc,
                    original_elem,
                    substituted_elem,
                    param_names,
                    args,
                );
                if (!typeEqual(substituted_elem, original_elem)) changed = true;
            }
            if (changed) alloc.free(sub_tuple);
        },
        .option => |option| {
            const sub_option = switch (substituted) {
                .option => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, option.*, sub_option.*, param_names, args);
            if (!typeEqual(sub_option.*, option.*)) alloc.destroy(sub_option);
        },
        .result => |result| {
            const sub_result = switch (substituted) {
                .result => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, result.ok, sub_result.ok, param_names, args);
            freeSubstitutedType(alloc, result.err, sub_result.err, param_names, args);
            if (!typeEqual(sub_result.ok, result.ok) or
                !typeEqual(sub_result.err, result.err))
            {
                alloc.destroy(sub_result);
            }
        },
        .boxed => |boxed| {
            const sub_boxed = switch (substituted) {
                .boxed => |value| value,
                else => return,
            };
            freeSubstitutedType(alloc, boxed.*, sub_boxed.*, param_names, args);
            if (!typeEqual(sub_boxed.*, boxed.*)) alloc.destroy(sub_boxed);
        },
        .fn_ptr => |fn_ptr| {
            const sub_fn_ptr = switch (substituted) {
                .fn_ptr => |value| value,
                else => return,
            };
            if (sub_fn_ptr.params.len != fn_ptr.params.len) return;
            var changed = false;
            for (fn_ptr.params, sub_fn_ptr.params) |original_param, substituted_param| {
                freeSubstitutedType(
                    alloc,
                    original_param,
                    substituted_param,
                    param_names,
                    args,
                );
                if (!typeEqual(original_param, substituted_param)) changed = true;
            }
            freeSubstitutedType(alloc, fn_ptr.ret, sub_fn_ptr.ret, param_names, args);
            if (!typeEqual(fn_ptr.ret, sub_fn_ptr.ret)) changed = true;
            if (changed) {
                alloc.free(sub_fn_ptr.params);
                alloc.destroy(sub_fn_ptr);
            }
        },
        .generic_inst => |generic_inst| {
            const sub_generic_inst = switch (substituted) {
                .generic_inst => |value| value,
                else => return,
            };
            if (sub_generic_inst.args.params.len != generic_inst.args.params.len) return;
            var changed = false;
            for (generic_inst.args.params, sub_generic_inst.args.params) |
                original_arg,
                substituted_arg,
            | {
                freeSubstitutedType(
                    alloc,
                    original_arg,
                    substituted_arg,
                    param_names,
                    args,
                );
                if (!typeEqual(original_arg, substituted_arg)) changed = true;
            }
            if (changed) alloc.free(sub_generic_inst.args.params);
        },
        .prim, .path, .unsupported => {},
    }
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

/// Walk a path expression: link occurrences with the same def_id.
fn walkPath(ctx: *Ctx, node: exprs.NodeId, p: exprs.PathExpr) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    if (ctx.def_map.get(p.def)) |first_node| {
        try addEq(ctx, first_node, node);
    } else {
        try ctx.def_map.put(ctx.alloc, p.def, node);
    }
    if (ctx.local_types.get(p.def)) |local_ty| {
        if (findTypeIndex(ctx.b, local_ty)) |type_id| {
            try addPin(ctx, node, type_id);
        }
    }
}

/// Recursively walk an expression node in the graph.
fn walkExpr(ctx: *Ctx, node: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    if (node >= ctx.b.exprs.len) return;
    const e = &ctx.b.exprs[node];
    switch (e.kind) {
        .literal => |lit| try walkLiteral(ctx, node, lit),
        .unit => {},
        .path => |p| {
            try walkPath(ctx, node, p);
            if (p.generic_args.len > 0 and
                explicitArgsMatchSignature(ctx, p.def, p.generic_args))
            {
                try addInstantiation(ctx, node, .{
                    .generic_id = p.def,
                    .args = .{ .params = p.generic_args },
                    .zig_suffix = "",
                });
            }
        },
        .block => |blk| try walkBlock(ctx, blk, fn_body, node),
        .if_else => |ie| try walkIf(ctx, node, ie, fn_body),
        .if_let => |il| {
            try walkExpr(ctx, il.scrutinee, fn_body);
            try bindPattern(ctx, il.pattern, null);
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
            if (w.capture) |capture| try bindPattern(ctx, capture, null);
            if (ctx.boolId()) |bid| try addPin(ctx, w.cond, bid);
            try walkExpr(ctx, w.cond, fn_body);
            try walkBlock(ctx, w.body, fn_body, null);
        },
        .for_ => |f| {
            try bindPattern(ctx, f.pattern, null);
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
            try walkMethodCall(ctx, node, m, fn_body);
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
        .vec_lit => |vec| for (vec.elements) |el| try walkExpr(ctx, el, fn_body),
    }
}

fn getMethodName(ctx: *Ctx, def: exprs.DefId) ?[]const u8 {
    if (ctx.cg) |cg| {
        if (cg.symbol_table.get(def)) |ent| {
            if (ent.renamed_to) |rn| return rn;
            if (ent.name.len > 0) return ent.name;
        }
    }
    if (def < ctx.b.bodies.len) {
        switch (ctx.b.bodies[def]) {
            .struct_ => |sb| {
                for (sb.methods) |sm| {
                    if (sm.name.len > 0) return sm.name;
                }
            },
            else => {},
        }
    }
    return null;
}

fn walkMethodCall(ctx: *Ctx, node: exprs.NodeId, m: exprs.MethodCall, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    try walkExpr(ctx, m.receiver, fn_body);
    for (m.args) |a| try walkExpr(ctx, a, fn_body);

    const m_name = getMethodName(ctx, m.method) orelse return;

    // .len() -> usize
    if (std.mem.eql(u8, m_name, "len")) {
        if (primTypeId(ctx.b, .usize)) |uid| {
            try addPin(ctx, node, uid);
        }
        return;
    }

    // .clone() on copy/cloneable types -> infer return type as self type
    if (std.mem.eql(u8, m_name, "clone")) {
        try addEq(ctx, m.receiver, node);
        return;
    }

    // .as_ref(), .as_bytes(), .borrow(), .as_slice() -> infer return type as slice ([]const u8 or []T)
    if (std.mem.eql(u8, m_name, "as_ref") or
        std.mem.eql(u8, m_name, "as_bytes") or
        std.mem.eql(u8, m_name, "borrow") or
        std.mem.eql(u8, m_name, "as_slice"))
    {
        if (getKnownType(ctx, m.receiver)) |recv_ty| {
            const elem_ty: ?types.Type = switch (recv_ty) {
                .slice => |s| s.elem,
                .array => |arr| arr.elem,
                .reference => |r| switch (r.pointee) {
                    .slice => |s| s.elem,
                    .array => |arr| arr.elem,
                    .prim => |p| if (p == .u8 and std.mem.eql(u8, m_name, "as_bytes")) types.Type{ .prim = .u8 } else null,
                    else => null,
                },
                .prim => |p| if (p == .u8 and std.mem.eql(u8, m_name, "as_bytes")) types.Type{ .prim = .u8 } else null,
                else => null,
            };
            if (elem_ty) |elem| {
                if (findSliceTypeForElem(ctx.b, elem)) |stid| {
                    try addPin(ctx, node, stid);
                    return;
                }
            }
        }
        if (std.mem.eql(u8, m_name, "as_bytes")) {
            if (findSliceTypeId(ctx.b, .u8)) |stid| {
                try addPin(ctx, node, stid);
                return;
            }
        }
        try addEq(ctx, m.receiver, node);
        return;
    }

    // .to_vec() on slice -> infer return type as slice / allocated slice
    if (std.mem.eql(u8, m_name, "to_vec")) {
        if (getKnownType(ctx, m.receiver)) |recv_ty| {
            const elem_ty: ?types.Type = switch (recv_ty) {
                .slice => |s| s.elem,
                .array => |arr| arr.elem,
                .reference => |r| switch (r.pointee) {
                    .slice => |s| s.elem,
                    .array => |arr| arr.elem,
                    else => null,
                },
                else => null,
            };
            if (elem_ty) |elem| {
                if (findSliceTypeForElem(ctx.b, elem)) |stid| {
                    try addPin(ctx, node, stid);
                    return;
                }
            }
        }
        try addEq(ctx, m.receiver, node);
        return;
    }

    // Operator trait methods (.bitxor, .bitor, .bitand, .add, .sub, .mul, wrapping_*, saturating_*)
    if (std.mem.eql(u8, m_name, "bitxor") or
        std.mem.eql(u8, m_name, "bitor") or
        std.mem.eql(u8, m_name, "bitand") or
        std.mem.eql(u8, m_name, "add") or
        std.mem.eql(u8, m_name, "sub") or
        std.mem.eql(u8, m_name, "mul") or
        std.mem.eql(u8, m_name, "wrapping_add") or
        std.mem.eql(u8, m_name, "wrapping_sub") or
        std.mem.eql(u8, m_name, "wrapping_mul") or
        std.mem.eql(u8, m_name, "saturating_add") or
        std.mem.eql(u8, m_name, "saturating_sub") or
        std.mem.eql(u8, m_name, "saturating_mul"))
    {
        try addEq(ctx, m.receiver, node);
        if (m.args.len > 0) {
            try addEq(ctx, m.receiver, m.args[0]);
        }
        return;
    }

    if (std.mem.eql(u8, m_name, "shl") or std.mem.eql(u8, m_name, "shr")) {
        try addEq(ctx, m.receiver, node);
        return;
    }

    if (std.mem.eql(u8, m_name, "not") or std.mem.eql(u8, m_name, "neg")) {
        try addEq(ctx, m.receiver, node);
        return;
    }
}

/// Walk the lossless code model of every `.fn_` body in `b` and generate
/// authoritative type pins and unification edges.
pub fn gen(alloc: std.mem.Allocator, b: *const bodies.Bodies) std.mem.Allocator.Error!Gen {
    return genWithGraph(alloc, b, null);
}

pub fn genWithGraph(alloc: std.mem.Allocator, b: *const bodies.Bodies, cg: ?*const graph.CrateGraph) std.mem.Allocator.Error!Gen {
    std.debug.assert(b.bodies.len >= 0);
    var g: Gen = .{};
    errdefer g.deinit(alloc);

    var ctx: Ctx = .{
        .alloc = alloc,
        .b = b,
        .g = &g,
        .cg = cg,
    };
    defer ctx.deinit();

    for (b.bodies, 0..) |bk, fn_index| {
        switch (bk) {
            .fn_ => |fb| {
                const fn_id: exprs.DefId = @intCast(fn_index);
                ctx.def_map.clearRetainingCapacity();
                try ctx.prepareLocals(fn_id, fb.params);
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
    return solveWithGraph(alloc, b, null);
}

pub fn solveWithGraph(alloc: std.mem.Allocator, b: *const bodies.Bodies, cg: ?*const graph.CrateGraph) std.mem.Allocator.Error!Inferred {
    std.debug.assert(b.exprs.len >= 0);
    var g = try genWithGraph(alloc, b, cg);
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
