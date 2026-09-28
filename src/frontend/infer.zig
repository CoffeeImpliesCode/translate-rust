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
const resolve_methods = @import("resolve_methods.zig");
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
pub const DerivedPin = struct {
    node: exprs.NodeId,
    ty: types.Type,
};

pub const Gen = struct {
    pub const Self = Gen;

    pins: std.ArrayListUnmanaged(Pin) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    classes: std.AutoHashMapUnmanaged(exprs.NodeId, Class) = .empty,
    instantiations: std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation) = .empty,
    invalid_casts: std.ArrayListUnmanaged(exprs.NodeId) = .empty,
    derived_types: std.ArrayListUnmanaged(types.Type) = .empty,
    derived_pins: std.ArrayListUnmanaged(DerivedPin) = .empty,
    derived_pattern_pins: std.ArrayListUnmanaged(DerivedPin) = .empty,
    derived_error: bool = false,

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.pins.deinit(alloc);
        self.edges.deinit(alloc);
        self.classes.deinit(alloc);
        deinitInstantiationMap(alloc, &self.instantiations);
        self.invalid_casts.deinit(alloc);
        self.derived_types.deinit(alloc);
        self.derived_pins.deinit(alloc);
        self.derived_pattern_pins.deinit(alloc);
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
        .@"opaque" => |opaque_type| {
            const sub_bounds = try substBoundSlice(alloc, opaque_type.bounds, param_names, args);
            const sub_concrete = if (opaque_type.concrete) |concrete| blk: {
                const concrete_ptr = try alloc.create(types.Type);
                concrete_ptr.* = try substType(alloc, concrete.*, param_names, args);
                break :blk @as(?*const types.Type, concrete_ptr);
            } else null;
            const opaque_copy = types.Opaque{
                .bounds = sub_bounds,
                .concrete = sub_concrete,
            };
            return .{ .@"opaque" = opaque_copy };
        },
        .dyn_trait => |bounds| return .{ .dyn_trait = try substBoundSlice(alloc, bounds, param_names, args) },
        .external_nominal => |external| {
            var changed = false;
            const sub_args = try alloc.alloc(types.Type, external.args.len);
            for (external.args, 0..) |arg, i| {
                sub_args[i] = try substType(alloc, arg, param_names, args);
                if (!typeEqual(sub_args[i], arg)) changed = true;
            }
            if (!changed) {
                alloc.free(sub_args);
                return t;
            }
            return .{ .external_nominal = .{
                .path = external.path,
                .args = sub_args,
            } };
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
fn substTypeSlice(
    alloc: std.mem.Allocator,
    source: []const types.Type,
    param_names: []const []const u8,
    args: []const types.Type,
) std.mem.Allocator.Error![]const types.Type {
    if (source.len == 0) return &.{};
    const substituted = try alloc.alloc(types.Type, source.len);
    var initialized: usize = 0;
    errdefer {
        for (source[0..initialized], substituted[0..initialized]) |original, replacement| {
            freeSubstitutedType(alloc, original, replacement, param_names, args);
        }
        alloc.free(substituted);
    }
    for (source, 0..) |original, index| {
        substituted[index] = try substType(alloc, original, param_names, args);
        initialized += 1;
    }
    return substituted;
}

fn substBoundSlice(
    alloc: std.mem.Allocator,
    source: []const types.Bound,
    param_names: []const []const u8,
    args: []const types.Type,
) std.mem.Allocator.Error![]const types.Bound {
    if (source.len == 0) return &.{};
    const substituted = try alloc.alloc(types.Bound, source.len);
    var initialized: usize = 0;
    errdefer {
        freeSubstitutedBounds(alloc, source[0..initialized], substituted[0..initialized], param_names, args);
        alloc.free(substituted);
    }
    for (source, 0..) |original, index| {
        const bound_args = try substTypeSlice(alloc, original.args, param_names, args);
        const associated_types = try alloc.alloc(types.AssociatedTypeBinding, original.associated_types.len);
        var associated_initialized: usize = 0;
        errdefer {
            for (
                original.associated_types[0..associated_initialized],
                associated_types[0..associated_initialized],
            ) |original_binding, replacement_binding| {
                freeSubstitutedType(
                    alloc,
                    original_binding.ty,
                    replacement_binding.ty,
                    param_names,
                    args,
                );
            }
            if (associated_types.len > 0) alloc.free(associated_types);
        }
        for (original.associated_types, 0..) |binding, binding_index| {
            associated_types[binding_index] = .{
                .name = binding.name,
                .ty = try substType(alloc, binding.ty, param_names, args),
            };
            associated_initialized += 1;
        }
        substituted[index] = .{
            .path = original.path,
            .args = bound_args,
            .associated_types = if (associated_types.len > 0) associated_types else &.{},
            .optional = original.optional,
        };
        initialized += 1;
    }
    return substituted;
}

fn matchBoundSlice(
    expected: []const types.Bound,
    actual: []const types.Bound,
    param_names: []const []const u8,
    inferred_args: []?types.Type,
) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |expected_bound, actual_bound| {
        if (expected_bound.optional != actual_bound.optional) return false;
        if (expected_bound.path.segments.len != actual_bound.path.segments.len) return false;
        for (expected_bound.path.segments, actual_bound.path.segments) |expected_segment, actual_segment| {
            if (!std.mem.eql(u8, expected_segment.name, actual_segment.name)) return false;
        }
        if (expected_bound.args.len != actual_bound.args.len) return false;
        for (expected_bound.args, actual_bound.args) |expected_arg, actual_arg| {
            if (!matchGenericType(expected_arg, actual_arg, param_names, inferred_args)) return false;
        }
        if (expected_bound.associated_types.len != actual_bound.associated_types.len) return false;
        for (expected_bound.associated_types, actual_bound.associated_types) |
            expected_binding,
            actual_binding,
        | {
            if (!std.mem.eql(u8, expected_binding.name, actual_binding.name)) return false;
            if (!matchGenericType(expected_binding.ty, actual_binding.ty, param_names, inferred_args)) return false;
        }
    }
    return true;
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
        .external_nominal => |external| {
            const other = actual_ty.external_nominal;
            if (external.path.len != other.path.len or
                external.args.len != other.args.len)
            {
                return false;
            }
            for (external.path, other.path) |left, right| {
                if (!std.mem.eql(u8, left, right)) return false;
            }
            for (external.args, other.args) |left, right| {
                if (!matchGenericType(left, right, param_names, inferred_args)) return false;
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
        .@"opaque" => |opaque_type| {
            const actual_opaque = actual_ty.@"opaque";
            if (!matchBoundSlice(opaque_type.bounds, actual_opaque.bounds, param_names, inferred_args)) return false;
            if (opaque_type.concrete) |expected_concrete| {
                const actual_concrete = actual_opaque.concrete orelse return false;
                if (!matchGenericType(expected_concrete.*, actual_concrete.*, param_names, inferred_args)) return false;
            }
            return true;
        },
        .dyn_trait => |bounds| matchBoundSlice(bounds, actual_ty.dyn_trait, param_names, inferred_args),
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
    known_nodes: std.AutoHashMapUnmanaged(exprs.NodeId, types.Type) = .empty,
    /// Return types expected by enclosing expression tails.  Abstract
    /// associated calls need this context before a concrete impl is selected.
    expected_types: std.AutoHashMapUnmanaged(exprs.NodeId, types.Type) = .empty,
    current_fn: ?exprs.DefId = null,
    type_expression_depth: usize = 0,
    /// Innermost value-producing loop, for constraining `break value`.
    loop_result: ?exprs.NodeId = null,
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
        if (count > 0) {
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
        }
        for (params) |param| {
            if (self.claimLocal(param.name)) |def| {
                try self.local_types.put(self.alloc, def, param.ty);
            }
        }
        if (currentImplSelfType(self)) |self_ty| {
            if (self.claimLocal("self")) |def| {
                try self.local_types.put(self.alloc, def, self_ty);
            }
        }
    }
    fn deinit(self: *Ctx) void {
        self.clearLocals();
        self.local_types.deinit(self.alloc);
        self.known_nodes.deinit(self.alloc);
        self.expected_types.deinit(self.alloc);
        self.def_map.deinit(self.alloc);
        self.* = undefined;
    }

    fn recordDerivedType(self: *Ctx, node: exprs.NodeId, ty: types.Type) void {
        if (ty == .unsupported) return;
        if (findTypeIndex(self.b, ty) != null) return;
        var found = false;
        for (self.g.derived_types.items) |known| {
            if (typeEqual(known, ty)) {
                found = true;
                break;
            }
        }
        if (!found) {
            self.g.derived_types.append(self.alloc, ty) catch {
                self.g.derived_error = true;
                return;
            };
        }
        for (self.g.derived_pins.items) |pin| {
            if (pin.node == node and typeEqual(pin.ty, ty)) return;
        }
        self.g.derived_pins.append(self.alloc, .{ .node = node, .ty = ty }) catch {
            self.g.derived_error = true;
        };
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
pub fn typeEqual(a: types.Type, b: types.Type) bool {
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
        .external_nominal => |external| {
            const other = b.external_nominal;
            if (external.path.len != other.path.len or
                external.args.len != other.args.len)
            {
                return false;
            }
            for (external.path, other.path) |left, right| {
                if (!std.mem.eql(u8, left, right)) return false;
            }
            for (external.args, other.args) |left, right| {
                if (!typeEqual(left, right)) return false;
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
        .@"opaque" => |opaque_type| {
            const other = b.@"opaque";
            if (!boundsEqual(opaque_type.bounds, other.bounds)) return false;
            const concrete = opaque_type.concrete orelse return other.concrete == null;
            const other_concrete = other.concrete orelse return false;
            return typeEqual(concrete.*, other_concrete.*);
        },
        .dyn_trait => |bounds| boundsEqual(bounds, b.dyn_trait),
        .unsupported => |unsupported| {
            const other = b.unsupported;
            return unsupported.reason == other.reason and
                std.mem.eql(u8, unsupported.message, other.message);
        },
    };
}

fn boundsEqual(left: []const types.Bound, right: []const types.Bound) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_bound, right_bound| {
        if (left_bound.optional != right_bound.optional) return false;
        if (left_bound.path.segments.len != right_bound.path.segments.len) return false;
        for (left_bound.path.segments, right_bound.path.segments) |left_segment, right_segment| {
            if (!std.mem.eql(u8, left_segment.name, right_segment.name)) return false;
        }
        if (left_bound.args.len != right_bound.args.len) return false;
        for (left_bound.args, right_bound.args) |left_arg, right_arg| {
            if (!typeEqual(left_arg, right_arg)) return false;
        }
        if (left_bound.associated_types.len != right_bound.associated_types.len) return false;
        for (left_bound.associated_types, right_bound.associated_types) |
            left_binding,
            right_binding,
        | {
            if (!std.mem.eql(u8, left_binding.name, right_binding.name)) return false;
            if (!typeEqual(left_binding.ty, right_binding.ty)) return false;
        }
    }
    return true;
}
/// Return whether a derived type is safe to add to the global type table.
/// Generic parameters and associated projections retain unresolved path
/// segments and are valid only in their declaration's generic context.
fn isConcreteDerivedType(t: types.Type) bool {
    return switch (t) {
        .prim => true,
        .path => |path| blk: {
            if (path.segments.len == 0) break :blk false;
            break :blk path.segments[path.segments.len - 1].id != null;
        },
        .external_nominal => |external| blk: {
            if (external.path.len == 0) break :blk false;
            for (external.args) |arg| {
                if (!isConcreteDerivedType(arg)) break :blk false;
            }
            break :blk true;
        },
        .reference => |reference| isConcreteDerivedType(reference.pointee),
        .raw_ptr => |raw_ptr| isConcreteDerivedType(raw_ptr.pointee),
        .slice => |slice| isConcreteDerivedType(slice.elem),
        .array => |array| blk: {
            switch (array.len) {
                .literal, .expression => {},
                .generic => break :blk false,
            }
            break :blk isConcreteDerivedType(array.elem);
        },
        .tuple => |tuple| blk: {
            for (tuple) |element| {
                if (!isConcreteDerivedType(element)) break :blk false;
            }
            break :blk true;
        },
        .fn_ptr => |fn_ptr| blk: {
            for (fn_ptr.params) |param| {
                if (!isConcreteDerivedType(param)) break :blk false;
            }
            break :blk isConcreteDerivedType(fn_ptr.ret);
        },
        .generic_inst => |generic| blk: {
            if (generic.decl == std.math.maxInt(spine.EntityId)) break :blk false;
            for (generic.args.params) |arg| {
                if (!isConcreteDerivedType(arg)) break :blk false;
            }
            break :blk true;
        },
        .option => |inner| isConcreteDerivedType(inner.*),
        .result => |result| isConcreteDerivedType(result.ok) and
            isConcreteDerivedType(result.err),
        .boxed => |inner| isConcreteDerivedType(inner.*),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete|
            isConcreteDerivedType(concrete.*)
        else
            false,
        .dyn_trait => |bounds| concreteBounds(bounds),
        .unsupported => false,
    };
}

pub fn isConcreteType(t: types.Type) bool {
    return isConcreteDerivedType(t);
}

fn concreteBounds(bounds: []const types.Bound) bool {
    for (bounds) |bound| {
        for (bound.args) |arg| {
            if (!isConcreteDerivedType(arg)) return false;
        }
        for (bound.associated_types) |binding| {
            if (!isConcreteDerivedType(binding.ty)) return false;
        }
    }
    return true;
}

/// Find the TypeId corresponding to target type in `b.types`.
pub fn findTypeIndex(b: *const bodies.Bodies, target: types.Type) ?exprs.TypeId {
    std.debug.assert(b.types.len >= 0);
    for (b.types, 0..) |t, i| {
        if (typeEqual(t, target)) return @intCast(i);
    }
    return null;
}
pub fn findTypeIndexInSlice(type_list: []const types.Type, target: types.Type) ?exprs.TypeId {
    for (type_list, 0..) |candidate, index| {
        if (typeEqual(candidate, target)) return @intCast(index);
    }
    return null;
}

/// Intern all concrete types discovered while generating constraints, then
/// convert their deferred expression pins to final TypeIds.
pub fn materializeDerivedTypes(
    alloc: std.mem.Allocator,
    type_list: *std.ArrayListUnmanaged(types.Type),
    patterns: []exprs.Pattern,
    g: *Gen,
) !void {
    if (g.derived_error) return error.OutOfMemory;
    for (g.derived_types.items) |derived| {
        if (findTypeIndexInSlice(type_list.items, derived) == null) {
            try type_list.append(alloc, derived);
        }
    }
    for (g.derived_pins.items) |derived_pin| {
        const type_id = findTypeIndexInSlice(type_list.items, derived_pin.ty) orelse
            return error.MissingDerivedType;
        try g.pins.append(alloc, .{ .node = derived_pin.node, .ty = type_id });
    }
    for (g.derived_pattern_pins.items) |pin| {
        if (pin.node >= patterns.len) return error.InvalidPatternRef;
        const type_id = findTypeIndexInSlice(type_list.items, pin.ty) orelse blk: {
            const id: exprs.TypeId = @intCast(type_list.items.len);
            try type_list.append(alloc, pin.ty);
            break :blk id;
        };
        patterns[pin.node].ty = type_id;
    }
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
                    try pinKnownType(ctx, node, .{ .prim = p });
                }
            } else {
                try setClass(ctx, node, .integer);
            }
        },
        .float => |fl| {
            if (endsWithCi(fl.text, "f32")) {
                try pinKnownType(ctx, node, .{ .prim = .f32 });
            } else if (endsWithCi(fl.text, "f64")) {
                try pinKnownType(ctx, node, .{ .prim = .f64 });
            } else {
                try setClass(ctx, node, .float);
            }
        },
        .boolean => try pinKnownType(ctx, node, .{ .prim = .bool }),
        .character, .string, .byte_array => {},
    }
}

/// Walk a binary expression: recurse into operands and emit equivalence edges.
fn walkBinary(ctx: *Ctx, node: exprs.NodeId, bin: exprs.BinaryExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(bin.lhs < ctx.b.exprs.len);
    std.debug.assert(bin.rhs < ctx.b.exprs.len);
    try walkExpr(ctx, bin.lhs, fn_body);
    try walkExpr(ctx, bin.rhs, fn_body);
    if (ctx.b.exprs[node].ty) |type_id| {
        try addPin(ctx, node, type_id);
    }
    const lhs_known = getKnownType(ctx, bin.lhs);
    const rhs_known = getKnownType(ctx, bin.rhs);
    if (lhs_known != null and rhs_known != null) {
        if (knownBinaryType(ctx, bin)) |known| {
            try pinKnownType(ctx, node, known);
        }
    }
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
            if (getKnownType(ctx, bin.lhs)) |lhs_ty| {
                if (lhs_ty != .reference) {
                    try addEq(ctx, bin.lhs, node);
                }
            } else {
                try addEq(ctx, bin.lhs, node);
            }
            if (getKnownType(ctx, bin.rhs)) |rhs_ty| {
                if (rhs_ty != .reference) {
                    try addEq(ctx, bin.rhs, node);
                }
            } else {
                try addEq(ctx, bin.rhs, node);
            }
        },
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        => {
            try addEq(ctx, bin.lhs, bin.rhs);
            try pinKnownType(ctx, node, .{ .prim = .bool });
        },
        .shl, .shr => {
            // Rust auto-derefs reference operands, so a shift result is the
            // pointee type. Equating it with `&u8` would make a following `as`
            // cast record a scalar source against a reference operand.
            if (getKnownType(ctx, bin.lhs)) |lhs_ty| {
                if (lhs_ty != .reference) {
                    try addEq(ctx, bin.lhs, node);
                }
            } else {
                try addEq(ctx, bin.lhs, node);
            }
        },
        .boolean_and, .boolean_or => {
            try pinKnownType(ctx, bin.lhs, .{ .prim = .bool });
            try pinKnownType(ctx, bin.rhs, .{ .prim = .bool });
            try pinKnownType(ctx, node, .{ .prim = .bool });
        },
    }
}

/// Walk an `if_else` expression: condition is bool; branches unify with if node.
fn walkIf(ctx: *Ctx, node: exprs.NodeId, ie: exprs.IfExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    std.debug.assert(ie.cond < ctx.b.exprs.len);
    try pinKnownType(ctx, ie.cond, .{ .prim = .bool });
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
    if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
}

/// Walk a `match` expression: unify the body expressions of all arms with match node.
fn walkMatch(ctx: *Ctx, node: exprs.NodeId, m: exprs.MatchExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    std.debug.assert(m.scrutinee < ctx.b.exprs.len);
    try walkExpr(ctx, m.scrutinee, fn_body);
    const scrutinee_ty = getKnownType(ctx, m.scrutinee);
    for (m.arms) |arm| {
        for (arm.patterns) |pattern| try bindMatchPatternKnownType(ctx, pattern, scrutinee_ty);
        if (arm.guard) |guard| try walkExpr(ctx, guard, fn_body);
        try addEq(ctx, node, arm.body);
        try walkExpr(ctx, arm.body, fn_body);
    }
}

/// Claim local entities in a pattern in lowering order. `let` bindings map
/// their resolved EntityId to the initializer; other patterns only reserve the
/// entity so later shadowed bindings keep their distinct ids.
fn variantPayloadType(
    ctx: *Ctx,
    pattern: exprs.PatternKind,
    known_ty: ?types.Type,
) ?types.Type {
    const struct_pat = switch (pattern) {
        .struct_pat => |value| value,
        else => return known_ty,
    };
    const variant_name = if (ctx.cg) |cg|
        if (cg.symbol_table.get(struct_pat.def)) |entity| entity.name else ""
    else
        "";
    if (known_ty) |ty| {
        if (std.mem.eql(u8, variant_name, "Some")) return optionPayloadType(ty);
        if (std.mem.eql(u8, variant_name, "Ok")) return resultPayloadType(ty, false);
        if (std.mem.eql(u8, variant_name, "Err")) return resultPayloadType(ty, true);
        if (externalCowPayloadType(ctx, ty, variant_name)) |payload| return payload;
        for (struct_pat.fields) |field| {
            if (field.field.len == 0) continue;
            if (fieldTypeForBase(ctx, ty, field.field)) |field_ty| return field_ty;
        }
    }
    return null;
}
fn externalCowPayloadType(ctx: *Ctx, ty: types.Type, variant_name: []const u8) ?types.Type {
    var base = ty;
    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        switch (base) {
            .reference => |reference| base = reference.pointee,
            .boxed => |boxed| base = boxed.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    base = concrete.*;
                } else {
                    break;
                }
            },
            else => break,
        }
    }
    const external = switch (base) {
        .external_nominal => |value| value,
        else => return null,
    };
    if (external.path.len != 3 or external.args.len != 1) return null;
    if ((!std.mem.eql(u8, external.path[0], "alloc") and
        !std.mem.eql(u8, external.path[0], "std")) or
        !std.mem.eql(u8, external.path[1], "borrow") or
        !std.mem.eql(u8, external.path[2], "Cow"))
    {
        return null;
    }
    const borrowed = std.mem.eql(u8, variant_name, "Borrowed");
    const owned = std.mem.eql(u8, variant_name, "Owned");
    if (!borrowed and !owned) return null;
    const payload = external.args[0];
    if (borrowed) return makeReferenceType(ctx, payload, false);
    if (types.isStr(payload)) {
        return makeExternalNominalType(ctx, &.{ "alloc", "string", "String" }, &.{});
    }
    const element = switch (payload) {
        .slice => |slice| slice.elem,
        else => return payload,
    };
    return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{element});
}

fn externalVariantFieldType(
    ctx: *Ctx,
    variant: exprs.ExternalVariantPattern,
    known_ty: ?types.Type,
    field_name: []const u8,
) ?types.Type {
    const payload_ty = externalCowPayloadType(
        ctx,
        known_ty orelse .{ .external_nominal = variant.owner },
        variant.variant,
    ) orelse return null;
    if (std.mem.eql(u8, field_name, "0")) return payload_ty;
    return null;
}

fn bindExternalVariantPattern(
    ctx: *Ctx,
    pattern: exprs.ExternalVariantPattern,
    init: ?exprs.NodeId,
    known_ty: ?types.Type,
) std.mem.Allocator.Error!void {
    for (pattern.fields) |field| {
        const field_ty = externalVariantFieldType(ctx, pattern, known_ty, field.field);
        if (field.pat) |field_pattern| {
            try bindPattern(ctx, field_pattern, init, field_ty);
        } else if (field.shorthand) {
            if (ctx.claimLocal(field.field)) |def| {
                if (init) |init_node| try ctx.def_map.put(ctx.alloc, def, init_node);
                if (field_ty) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
            }
        }
    }
}

fn bindPattern(
    ctx: *Ctx,
    pattern_id: exprs.NodeId,
    init: ?exprs.NodeId,
    known_ty: ?types.Type,
) std.mem.Allocator.Error!void {
    if (pattern_id >= ctx.b.pats.len) return;
    const pattern_type: ?types.Type = if (known_ty) |ty| switch (ctx.b.pats[pattern_id].kind) {
        .binding => |binding| if (binding.mode == .value)
            ty
        else
            makeReferenceType(ctx, ty, binding.mode == .mut_ref) orelse return error.OutOfMemory,
        else => ty,
    } else null;
    if (pattern_type) |ty| {
        try ctx.g.derived_pattern_pins.append(ctx.alloc, .{ .node = pattern_id, .ty = ty });
    }
    switch (ctx.b.pats[pattern_id].kind) {
        .binding => |binding| {
            const def_id = ctx.claimLocal(binding.name) orelse blk: {
                if (ctx.cg == null) break :blk @as(?exprs.DefId, @intCast(pattern_id));
                break :blk null;
            };
            if (def_id) |def| {
                if (init) |init_node| try ctx.def_map.put(ctx.alloc, def, init_node);
                if (pattern_type) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
            }
        },
        .tuple => |tuple| {
            for (tuple.elements, 0..) |element, index| {
                const element_ty: ?types.Type = if (known_ty) |ty| switch (ty) {
                    .tuple => |elements| if (index < elements.len) elements[index] else null,
                    else => null,
                } else null;
                // A destructured binding owns its tuple element type; it must
                // not be equated with the whole tuple initializer.
                try bindPattern(ctx, element, null, element_ty);
            }
        },
        .slice => |slice| {
            const element_ty: ?types.Type = if (known_ty) |ty| switch (ty) {
                .slice => |value| value.elem,
                .array => |value| value.elem,
                .reference => |value| switch (value.pointee) {
                    .slice => |slice_ty| slice_ty.elem,
                    .array => |array_ty| array_ty.elem,
                    else => null,
                },
                else => null,
            } else null;
            for (slice.elements) |element| try bindPattern(ctx, element, init, element_ty);
            if (slice.rest) |rest| try bindPattern(ctx, rest, init, known_ty);
        },
        .struct_pat => |struct_pat| {
            const payload_ty = variantPayloadType(ctx, .{ .struct_pat = struct_pat }, known_ty);
            for (struct_pat.fields) |field| {
                const field_ty = if (payload_ty != null and field.field.len > 0 and
                    std.mem.eql(u8, field.field, "0"))
                    payload_ty
                else if (known_ty) |ty|
                    fieldTypeForBase(ctx, ty, field.field)
                else
                    null;
                if (field.pat) |field_pattern| {
                    try bindPattern(ctx, field_pattern, init, field_ty);
                } else if (field.shorthand) {
                    const def_id = ctx.claimLocal(field.field);
                    if (init) |init_node| {
                        if (def_id) |def| {
                            try ctx.def_map.put(ctx.alloc, def, init_node);
                            if (field_ty) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
                        }
                    } else if (def_id) |def| {
                        if (field_ty) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
                    }
                }
            }
        },
        .external_variant => |external_variant| {
            try bindExternalVariantPattern(ctx, external_variant, init, known_ty);
        },
        .reference => |reference| {
            const inner_ty = if (known_ty) |ty| dereferencedType(ty) orelse ty else null;
            try bindPattern(ctx, reference.inner, init, inner_ty);
        },
        .@"or" => |or_pattern| {
            for (or_pattern.alternatives) |alternative| {
                try bindPattern(ctx, alternative, init, known_ty);
            }
        },
        .unsupported => {},
        .wildcard, .literal, .path, .range => {},
    }
}

/// Bind a match-arm capture to its enum-variant field type.
fn bindMatchPattern(ctx: *Ctx, pattern_id: exprs.NodeId) std.mem.Allocator.Error!void {
    if (pattern_id >= ctx.b.pats.len) return;
    const pattern = ctx.b.pats[pattern_id];
    switch (pattern.kind) {
        .binding => |binding| {
            _ = ctx.claimLocal(binding.name);
        },
        .struct_pat => |struct_pat| {
            const cg = ctx.cg orelse return;
            const variant = cg.symbol_table.get(struct_pat.def) orelse return;
            if (variant.kind != .variant) return;
            const enum_id = variant.parent orelse return;
            if (enum_id >= ctx.b.bodies.len) return;
            const enum_body = switch (ctx.b.bodies[enum_id]) {
                .enum_ => |body| body,
                else => return,
            };
            const fields = for (enum_body.variants) |candidate| {
                if (std.mem.eql(u8, candidate.name, variant.name)) break candidate.fields;
            } else return;
            for (struct_pat.fields) |field| {
                const field_ty: ?types.Type = switch (fields) {
                    .tuple => |tuple| blk: {
                        const index = std.fmt.parseInt(usize, field.field, 10) catch break :blk null;
                        if (index >= tuple.len) break :blk null;
                        break :blk tuple[index];
                    },
                    .named => |named| blk: {
                        for (named) |candidate| {
                            if (std.mem.eql(u8, candidate.name, field.field)) break :blk candidate.ty;
                        }
                        break :blk null;
                    },
                    .none => null,
                };
                if (field.pat) |field_pattern| {
                    try bindMatchPatternType(ctx, field_pattern, field_ty);
                } else if (field.shorthand) {
                    if (field_ty) |ty| {
                        if (ctx.claimLocal(field.field)) |def| try ctx.local_types.put(ctx.alloc, def, ty);
                    } else {
                        _ = ctx.claimLocal(field.field);
                    }
                }
            }
        },
        .external_variant => |external_variant| {
            for (external_variant.fields) |field| {
                if (field.pat) |field_pattern| {
                    try bindMatchPattern(ctx, field_pattern);
                } else if (field.shorthand) {
                    _ = ctx.claimLocal(field.field);
                }
            }
        },
        .tuple => |tuple| for (tuple.elements) |element| try bindMatchPattern(ctx, element),
        .reference => |reference| try bindMatchPattern(ctx, reference.inner),
        .@"or" => |or_pattern| for (or_pattern.alternatives) |alternative| try bindMatchPattern(ctx, alternative),
        .wildcard, .literal, .path, .slice, .range, .unsupported => {},
    }
}

fn bindMatchPatternType(ctx: *Ctx, pattern_id: exprs.NodeId, ty: ?types.Type) std.mem.Allocator.Error!void {
    if (pattern_id >= ctx.b.pats.len) return;
    switch (ctx.b.pats[pattern_id].kind) {
        .binding => |binding| {
            if (ctx.claimLocal(binding.name)) |def| {
                if (ty) |known| try ctx.local_types.put(ctx.alloc, def, known);
            }
        },
        .external_variant => |external_variant| {
            try bindExternalVariantPattern(ctx, external_variant, null, ty);
        },
        else => try bindMatchPattern(ctx, pattern_id),
    }
}

fn bindMatchPatternKnownType(
    ctx: *Ctx,
    pattern_id: exprs.NodeId,
    known_ty: ?types.Type,
) std.mem.Allocator.Error!void {
    if (pattern_id >= ctx.b.pats.len) return;
    switch (ctx.b.pats[pattern_id].kind) {
        .binding, .tuple, .slice, .reference, .@"or", .external_variant => {
            try bindPattern(ctx, pattern_id, null, known_ty);
        },
        .struct_pat => {
            if (variantPayloadType(ctx, ctx.b.pats[pattern_id].kind, known_ty) != null) {
                try bindPattern(ctx, pattern_id, null, known_ty);
            } else {
                try bindMatchPattern(ctx, pattern_id);
            }
        },
        else => try bindMatchPattern(ctx, pattern_id),
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
                const known_ty = annotatedOrKnownType(ctx, ls.ty, init);
                try bindPattern(ctx, ls.pattern, init, known_ty);
            } else {
                try bindPattern(ctx, ls.pattern, null, null);
            }
        },
        .let_else => |le| {
            try walkExpr(ctx, le.init, fn_body);
            const known_ty = annotatedOrKnownType(ctx, null, le.init);
            try bindPattern(ctx, le.pattern, le.init, known_ty);
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
        // The function body's own tail yields the declared return type, so pin
        // it the same way a `return` statement is pinned. Nested blocks yield
        // their own type and must stay unconstrained.
        if (blk_node != null and blk_node.? == fn_body) {
            if (findFnReturnType(ctx.b, fn_body)) |ret_ty| {
                try constrainExpectedType(ctx, t, ret_ty);
            }
        }
    }
}

fn walkClosureTyped(
    ctx: *Ctx,
    closure: exprs.ClosureExpr,
    fn_body: exprs.NodeId,
    param_ty: ?types.Type,
) std.mem.Allocator.Error!void {
    for (closure.params, 0..) |param, index| {
        try bindPattern(ctx, param, null, if (index == 0) param_ty else null);
    }
    try walkBlock(ctx, closure.body, fn_body, null);
}

fn walkClosure(ctx: *Ctx, closure: exprs.ClosureExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    try walkClosureTyped(ctx, closure, fn_body, null);
}

fn walkIteratorChain(
    ctx: *Ctx,
    chain: exprs.IteratorChainExpr,
    fn_body: exprs.NodeId,
) std.mem.Allocator.Error!void {
    try walkExpr(ctx, chain.source, fn_body);
    var current_ty = iteratorSourceItemType(ctx, chain.source);
    for (chain.adapters) |adapter| {
        switch (adapter) {
            .map => |map| {
                if (current_ty) |input_ty| {
                    try walkClosureTyped(ctx, map.closure, fn_body, input_ty);
                } else {
                    try walkClosure(ctx, map.closure, fn_body);
                }
                current_ty = closureValueReturnType(ctx, map.closure);
            },
            .filter => |filter| {
                if (current_ty) |input_ty| {
                    const predicate_input = makeReferenceType(ctx, input_ty, false);
                    if (predicate_input) |typed_input| {
                        try walkClosureTyped(ctx, filter.closure, fn_body, typed_input);
                    } else {
                        try walkClosure(ctx, filter.closure, fn_body);
                    }
                } else {
                    try walkClosure(ctx, filter.closure, fn_body);
                }
            },
            .flat_map => |closure| {
                try walkClosureTyped(ctx, closure, fn_body, current_ty);
                current_ty = if (closureValueReturnType(ctx, closure)) |returned|
                    iteratorItemType(ctx, returned)
                else
                    null;
            },
            .enumerate => {
                if (current_ty) |input_ty| {
                    const tuple = try ctx.alloc.alloc(types.Type, 2);
                    tuple[0] = .{ .prim = .usize };
                    tuple[1] = input_ty;
                    current_ty = .{ .tuple = tuple };
                }
            },
            .zip => |zip| {
                try walkExpr(ctx, zip.other, fn_body);
                if (current_ty) |input_ty| {
                    if (iteratorSourceItemType(ctx, zip.other)) |other_ty| {
                        const tuple = try ctx.alloc.alloc(types.Type, 2);
                        tuple[0] = input_ty;
                        tuple[1] = other_ty;
                        current_ty = .{ .tuple = tuple };
                    } else {
                        current_ty = null;
                    }
                }
            },
            .range_rev, .other => {},
        }
    }
}

/// Record an instantiation for an expression node, overwriting any prior entry.
/// Duplicates the args slice so the recorded value remains valid after the
/// caller's temporary storage is freed.
fn addInstantiation(ctx: *Ctx, node: exprs.NodeId, inst: types.Instantiation) std.mem.Allocator.Error!void {
    for (inst.args.params) |arg| {
        if (!isConcreteDerivedType(arg)) return;
    }
    const owned = try ctx.alloc.dupe(types.Type, inst.args.params);
    errdefer ctx.alloc.free(owned);
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
        out.put(alloc, entry.key_ptr.*, .{
            .generic_id = entry.value_ptr.generic_id,
            .args = .{ .params = owned },
            .zig_suffix = entry.value_ptr.zig_suffix,
        }) catch |err| {
            alloc.free(owned);
            return err;
        };
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
        .external_nominal => |external| {
            for (external.args) |arg| {
                try collectTypeParamNamesFromType(alloc, b, buf, arg);
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
        .@"opaque" => |opaque_type| {
            for (opaque_type.bounds) |bound| {
                for (bound.args) |arg| try collectTypeParamNamesFromType(alloc, b, buf, arg);
                for (bound.associated_types) |binding| {
                    try collectTypeParamNamesFromType(alloc, b, buf, binding.ty);
                }
            }
            if (opaque_type.concrete) |concrete| {
                try collectTypeParamNamesFromType(alloc, b, buf, concrete.*);
            }
        },
        .dyn_trait => |bounds| {
            for (bounds) |bound| {
                for (bound.args) |arg| try collectTypeParamNamesFromType(alloc, b, buf, arg);
                for (bound.associated_types) |binding| {
                    try collectTypeParamNamesFromType(alloc, b, buf, binding.ty);
                }
            }
        },
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

fn isIntegerType(ty: types.Type) bool {
    return switch (ty) {
        .prim => |primitive| switch (primitive) {
            .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => true,
            .f32, .f64, .bool, .char, .unit, .never => false,
        },
        else => false,
    };
}

fn isLenReceiverType(ty: types.Type) bool {
    return switch (ty) {
        .slice, .array => true,
        .reference => |reference| isLenReceiverType(reference.pointee),
        .boxed => |boxed| isLenReceiverType(boxed.*),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete| isLenReceiverType(concrete.*) else false,
        .external_nominal => |external| blk: {
            if (external.path.len < 2) break :blk false;
            const root = std.mem.eql(u8, external.path[0], "alloc") or
                std.mem.eql(u8, external.path[0], "std");
            if (!root) break :blk false;
            if (external.path.len == 3 and
                std.mem.eql(u8, external.path[1], "vec") and
                std.mem.eql(u8, external.path[2], "Vec"))
            {
                break :blk external.args.len == 1;
            }
            if (external.path.len == 3 and
                std.mem.eql(u8, external.path[1], "string") and
                std.mem.eql(u8, external.path[2], "String"))
            {
                break :blk external.args.len == 0;
            }
            if (external.path.len == 3 and
                std.mem.eql(u8, external.path[1], "borrow") and
                std.mem.eql(u8, external.path[2], "Cow"))
            {
                break :blk external.args.len == 1;
            }
            break :blk false;
        },
        else => false,
    };
}
fn indexedElementType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .array => |array| array.elem,
        .slice => |slice| slice.elem,
        .reference => |reference| indexedElementType(reference.pointee),
        .boxed => |boxed| indexedElementType(boxed.*),
        .external_nominal => |external| if (external.path.len == 3 and
            (std.mem.eql(u8, external.path[0], "alloc") or
                std.mem.eql(u8, external.path[0], "std")) and
            std.mem.eql(u8, external.path[1], "vec") and
            std.mem.eql(u8, external.path[2], "Vec") and
            external.args.len == 1)
            external.args[0]
        else
            null,
        else => null,
    };
}
fn sliceElementForMethod(ty: types.Type) ?types.Type {
    return switch (ty) {
        .slice => |slice| slice.elem,
        .array => |array| array.elem,
        .reference => |reference| sliceElementForMethod(reference.pointee),
        .boxed => |boxed| sliceElementForMethod(boxed.*),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete| sliceElementForMethod(concrete.*) else null,
        .external_nominal => |external| blk: {
            if (external.path.len != 3 or external.args.len > 1) break :blk null;
            const root = std.mem.eql(u8, external.path[0], "alloc") or
                std.mem.eql(u8, external.path[0], "std");
            if (!root) break :blk null;
            if (std.mem.eql(u8, external.path[1], "vec") and
                std.mem.eql(u8, external.path[2], "Vec") and
                external.args.len == 1)
            {
                break :blk external.args[0];
            }
            if (std.mem.eql(u8, external.path[1], "string") and
                std.mem.eql(u8, external.path[2], "String") and
                external.args.len == 0)
            {
                break :blk types.Type{ .prim = .u8 };
            }
            if (std.mem.eql(u8, external.path[1], "borrow") and
                std.mem.eql(u8, external.path[2], "Cow") and
                external.args.len == 1)
            {
                break :blk switch (external.args[0]) {
                    .slice => |slice| slice.elem,
                    else => external.args[0],
                };
            }
            break :blk null;
        },
        else => null,
    };
}
fn sliceIteratorElementType(ty: types.Type) ?types.Type {
    var current = ty;
    while (true) {
        switch (current) {
            .reference => |reference| current = reference.pointee,
            .boxed => |boxed| current = boxed.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    current = concrete.*;
                } else {
                    return null;
                }
            },
            else => break,
        }
    }
    return switch (current) {
        .external_nominal => |external| if (external.path.len == 3 and
            (std.mem.eql(u8, external.path[0], "core") or
                std.mem.eql(u8, external.path[0], "std")) and
            std.mem.eql(u8, external.path[1], "slice") and
            (std.mem.eql(u8, external.path[2], "Iter") or
                std.mem.eql(u8, external.path[2], "IterMut")) and
            external.args.len == 1)
            external.args[0]
        else
            null,
        else => null,
    };
}

fn scalarOperandType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .reference => |reference| scalarOperandType(reference.pointee),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete|
            scalarOperandType(concrete.*)
        else
            null,
        .boxed => |boxed| scalarOperandType(boxed.*),
        .prim => |primitive| if (isScalarCastType(.{ .prim = primitive }))
            ty
        else
            null,
        else => null,
    };
}

fn dereferencedType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .reference => |reference| reference.pointee,
        .raw_ptr => |raw_ptr| raw_ptr.pointee,
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete| dereferencedType(concrete.*) else null,
        .boxed => |boxed| dereferencedType(boxed.*),
        else => null,
    };
}
fn dereferencedValueType(ctx: *Ctx, ty: types.Type) ?types.Type {
    if (dereferencedType(ty)) |pointee| return pointee;
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return null,
    };
    if (external.path.len != 3 or external.args.len != 1) return null;
    if ((!std.mem.eql(u8, external.path[0], "alloc") and
        !std.mem.eql(u8, external.path[0], "std")) or
        !std.mem.eql(u8, external.path[1], "vec") or
        !std.mem.eql(u8, external.path[2], "Vec"))
    {
        return null;
    }
    const slice = ctx.alloc.create(types.Slice) catch return null;
    slice.* = .{ .const_ = true, .elem = external.args[0] };
    return .{ .slice = slice };
}

fn optionPayloadType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .reference => |reference| optionPayloadType(reference.pointee),
        .boxed => |boxed| optionPayloadType(boxed.*),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete|
            optionPayloadType(concrete.*)
        else
            null,
        .option => |inner| inner.*,
        .external_nominal => |external| if (external.path.len == 3 and
            (std.mem.eql(u8, external.path[0], "core") or
                std.mem.eql(u8, external.path[0], "std")) and
            std.mem.eql(u8, external.path[1], "option") and
            std.mem.eql(u8, external.path[2], "Option") and
            external.args.len == 1)
            external.args[0]
        else
            null,
        else => null,
    };
}

fn resultPayloadType(ty: types.Type, error_payload: bool) ?types.Type {
    return switch (ty) {
        .reference => |reference| resultPayloadType(reference.pointee, error_payload),
        .boxed => |boxed| resultPayloadType(boxed.*, error_payload),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete|
            resultPayloadType(concrete.*, error_payload)
        else
            null,
        .result => |result| if (error_payload) result.err else result.ok,
        .external_nominal => |external| if (external.path.len == 3 and
            (std.mem.eql(u8, external.path[0], "core") or
                std.mem.eql(u8, external.path[0], "std")) and
            std.mem.eql(u8, external.path[1], "result") and
            std.mem.eql(u8, external.path[2], "Result") and
            external.args.len == 2)
            external.args[if (error_payload) 1 else 0]
        else
            null,
        else => null,
    };
}

fn unwrapTryType(ty: types.Type) ?types.Type {
    if (optionPayloadType(ty)) |payload| return payload;
    return resultPayloadType(ty, false);
}
fn makeRawPtrType(ctx: *Ctx, elem: types.Type, mutable: bool) ?types.Type {
    const pointer = ctx.alloc.create(types.RawPtr) catch return null;
    pointer.* = .{ .mut = mutable, .pointee = elem };
    return .{ .raw_ptr = pointer };
}

fn makeReferenceType(ctx: *Ctx, elem: types.Type, mutable: bool) ?types.Type {
    if (types.isStr(elem)) return makeSliceType(ctx, .{ .prim = .u8 }, mutable);
    const reference = ctx.alloc.create(types.Ref) catch return null;
    reference.* = .{ .mut = mutable, .pointee = elem };
    return .{ .reference = reference };
}
/// Return the nominal definition represented by a value type.
///
/// Field lookup follows the resolved type identity. It never guesses a
/// declaration from a field or type spelling alone.
fn nominalDefForField(ty: types.Type) ?exprs.DefId {
    return switch (ty) {
        .path => |path| if (path.segments.len == 0)
            null
        else
            path.segments[path.segments.len - 1].id,
        .generic_inst => |instance| instance.decl,
        .reference => |reference| nominalDefForField(reference.pointee),
        .raw_ptr => |raw_ptr| nominalDefForField(raw_ptr.pointee),
        else => null,
    };
}

/// Resolve a method receiver's `Self` path to its containing impl type.
///
/// A function can be nested below modules or other graph entities, so the
/// immediate parent is not necessarily the impl body. Walk the entity chain
/// while keeping the body table and graph in lockstep.
fn currentImplSelfType(ctx: *const Ctx) ?types.Type {
    var current = ctx.current_fn;
    const cg = ctx.cg orelse return null;
    var remaining = cg.symbol_table.entities.items.len;
    while (current) |entity_id| {
        if (remaining == 0) return null;
        remaining -= 1;
        if (entity_id < ctx.b.bodies.len) {
            switch (ctx.b.bodies[entity_id]) {
                .impl_ => |impl_body| return impl_body.self_ty,
                else => {},
            }
        }
        const entity = cg.symbol_table.get(entity_id) orelse return null;
        current = entity.parent;
    }
    return null;
}

/// Resolve a field's declared type from its receiver type.
fn fieldTypeForBase(ctx: *Ctx, base_ty: types.Type, field_name: []const u8) ?types.Type {
    switch (base_ty) {
        .tuple => |tuple| {
            const index = std.fmt.parseInt(usize, field_name, 10) catch return null;
            if (index < tuple.len) return tuple[index];
            return null;
        },
        .reference => |reference| return fieldTypeForBase(ctx, reference.pointee, field_name),
        .raw_ptr => |raw_ptr| return fieldTypeForBase(ctx, raw_ptr.pointee, field_name),
        .path => |path| {
            if (path.segments.len == 1 and
                std.mem.eql(u8, path.segments[0].name, "Self"))
            {
                const self_ty = currentImplSelfType(ctx) orelse return null;
                if (self_ty == .path and self_ty.path.segments.len == 1 and
                    std.mem.eql(u8, self_ty.path.segments[0].name, "Self"))
                {
                    return null;
                }
                return fieldTypeForBase(ctx, self_ty, field_name);
            }
        },
        .external_nominal => |external| {
            if (external.path.len == 3 and external.args.len == 1 and
                (std.mem.eql(u8, external.path[0], "core") or
                    std.mem.eql(u8, external.path[0], "std")) and
                std.mem.eql(u8, external.path[1], "ops") and
                std.mem.eql(u8, external.path[2], "Range") and
                (std.mem.eql(u8, field_name, "start") or
                    std.mem.eql(u8, field_name, "end")))
            {
                return external.args[0];
            }
        },
        else => {},
    }

    const def = nominalDefForField(base_ty) orelse return null;
    if (def >= ctx.b.bodies.len) return null;
    const field_ty = switch (ctx.b.bodies[def]) {
        .struct_ => |struct_body| blk: {
            for (struct_body.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) break :blk field.ty;
            }
            break :blk null;
        },
        else => null,
    } orelse return null;

    return switch (base_ty) {
        .generic_inst => |instance| blk: {
            const param_names = getGenericParamNames(ctx, def) catch break :blk field_ty;
            defer ctx.alloc.free(param_names);
            break :blk substType(
                ctx.alloc,
                field_ty,
                param_names,
                instance.args.params,
            ) catch field_ty;
        },
        else => field_ty,
    };
}

fn annotatedOrKnownType(
    ctx: *Ctx,
    annotation: ?exprs.TypeId,
    init: exprs.NodeId,
) ?types.Type {
    if (annotation) |type_id| {
        if (type_id < ctx.b.types.len) return ctx.b.types[type_id];
    }
    return getKnownType(ctx, init);
}

fn makeSliceType(ctx: *Ctx, elem: types.Type, mutable: bool) ?types.Type {
    const slice = ctx.alloc.create(types.Slice) catch return null;
    slice.* = .{ .const_ = !mutable, .elem = elem };
    return .{ .slice = slice };
}

fn chunksExactElement(ty: types.Type) ?types.Type {
    return switch (ty) {
        .external_nominal => |external| blk: {
            if (external.path.len != 3 or external.args.len != 1) break :blk null;
            if (!std.mem.eql(u8, external.path[0], "core") or
                !std.mem.eql(u8, external.path[1], "slice") or
                !std.mem.eql(u8, external.path[2], "ChunksExact"))
            {
                break :blk null;
            }
            break :blk external.args[0];
        },
        else => null,
    };
}

fn chunksExactType(ctx: *Ctx, elem: types.Type) ?types.Type {
    const args = ctx.alloc.alloc(types.Type, 1) catch return null;
    args[0] = elem;
    return .{ .external_nominal = .{
        .path = &.{ "core", "slice", "ChunksExact" },
        .args = args,
    } };
}
fn makeOptionType(ctx: *Ctx, inner: types.Type) ?types.Type {
    const ptr = ctx.alloc.create(types.Type) catch return null;
    ptr.* = inner;
    return .{ .option = ptr };
}

fn makeExternalNominalType(
    ctx: *Ctx,
    path: []const []const u8,
    args: []const types.Type,
) ?types.Type {
    const owned_args: []const types.Type = if (args.len == 0)
        &.{}
    else
        (ctx.alloc.dupe(types.Type, args) catch return null);

    const owned_path: []const []const u8 = if (path.len == 0) &.{} else blk: {
        const copied_path = ctx.alloc.alloc([]const u8, path.len) catch {
            if (args.len > 0) ctx.alloc.free(owned_args);
            return null;
        };
        var copied_count: usize = 0;
        for (path, 0..) |segment, index| {
            copied_path[index] = ctx.alloc.dupe(u8, segment) catch {
                while (copied_count > 0) {
                    copied_count -= 1;
                    ctx.alloc.free(copied_path[copied_count]);
                }
                ctx.alloc.free(copied_path);
                if (args.len > 0) ctx.alloc.free(owned_args);
                return null;
            };
            copied_count += 1;
        }
        break :blk copied_path;
    };
    return .{ .external_nominal = .{ .path = owned_path, .args = owned_args } };
}

fn externalNominalBase(ty: types.Type) ?types.ExternalNominal {
    var base = ty;
    while (true) {
        switch (base) {
            .reference => |reference| base = reference.pointee,
            .boxed => |boxed| base = boxed.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    base = concrete.*;
                } else {
                    return null;
                }
            },
            else => break,
        }
    }
    return switch (base) {
        .external_nominal => |external| external,
        else => null,
    };
}

fn knownAllocMethodType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
) ?types.Type {
    const external = externalNominalBase(receiver_ty);
    if (external) |value| {
        const is_vec = value.path.len == 3 and
            (std.mem.eql(u8, value.path[0], "alloc") or
                std.mem.eql(u8, value.path[0], "std")) and
            std.mem.eql(u8, value.path[1], "vec") and
            std.mem.eql(u8, value.path[2], "Vec") and
            value.args.len == 1;
        const is_string = value.path.len == 3 and
            (std.mem.eql(u8, value.path[0], "alloc") or
                std.mem.eql(u8, value.path[0], "std")) and
            std.mem.eql(u8, value.path[1], "string") and
            std.mem.eql(u8, value.path[2], "String") and
            value.args.len == 0;
        const is_cow = value.path.len == 3 and
            (std.mem.eql(u8, value.path[0], "alloc") or
                std.mem.eql(u8, value.path[0], "std")) and
            std.mem.eql(u8, value.path[1], "borrow") and
            std.mem.eql(u8, value.path[2], "Cow") and
            value.args.len == 1;

        if (is_vec) {
            const element = value.args[0];
            if (std.mem.eql(u8, method_name, "as_ref") or
                std.mem.eql(u8, method_name, "as_slice"))
            {
                return makeSliceType(ctx, element, false);
            }
            if (std.mem.eql(u8, method_name, "as_mut_slice")) {
                return makeSliceType(ctx, element, true);
            }
            if (std.mem.eql(u8, method_name, "to_vec") or
                std.mem.eql(u8, method_name, "to_owned"))
            {
                return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{element});
            }
            if (std.mem.eql(u8, method_name, "push") or
                std.mem.eql(u8, method_name, "extend") or
                std.mem.eql(u8, method_name, "clear") or
                std.mem.eql(u8, method_name, "reserve") or
                std.mem.eql(u8, method_name, "reserve_exact") or
                std.mem.eql(u8, method_name, "truncate") or
                std.mem.eql(u8, method_name, "resize") or
                std.mem.eql(u8, method_name, "shrink_to_fit"))
            {
                return .{ .prim = .unit };
            }
        }
        if (is_string) {
            if (std.mem.eql(u8, method_name, "as_ref") or
                std.mem.eql(u8, method_name, "as_bytes") or
                std.mem.eql(u8, method_name, "as_str"))
            {
                return makeSliceType(ctx, .{ .prim = .u8 }, false);
            }
            if (std.mem.eql(u8, method_name, "into_bytes")) {
                return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{.{ .prim = .u8 }});
            }
            if (std.mem.eql(u8, method_name, "to_owned") or
                std.mem.eql(u8, method_name, "clone"))
            {
                return makeExternalNominalType(ctx, &.{ "alloc", "string", "String" }, &.{});
            }
            if (std.mem.eql(u8, method_name, "push") or
                std.mem.eql(u8, method_name, "push_str") or
                std.mem.eql(u8, method_name, "clear") or
                std.mem.eql(u8, method_name, "reserve") or
                std.mem.eql(u8, method_name, "truncate"))
            {
                return .{ .prim = .unit };
            }
        }
        if (is_cow) {
            const payload = value.args[0];
            if (std.mem.eql(u8, method_name, "as_ref") or
                std.mem.eql(u8, method_name, "borrow"))
            {
                if (types.isStr(payload)) return makeReferenceType(ctx, payload, false);
                return switch (payload) {
                    .slice => |slice| makeSliceType(ctx, slice.elem, false),
                    else => payload,
                };
            }
            if (std.mem.eql(u8, method_name, "into_owned") or
                std.mem.eql(u8, method_name, "to_owned"))
            {
                if (types.isStr(payload)) {
                    return makeExternalNominalType(
                        ctx,
                        &.{ "alloc", "string", "String" },
                        &.{},
                    );
                }
                return switch (payload) {
                    .slice => |slice| makeExternalNominalType(
                        ctx,
                        &.{ "alloc", "vec", "Vec" },
                        &.{slice.elem},
                    ),
                    else => payload,
                };
            }
        }
    }

    if (std.mem.eql(u8, method_name, "to_vec") or
        std.mem.eql(u8, method_name, "to_owned"))
    {
        if (sliceElementForMethod(receiver_ty)) |element| {
            return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{element});
        }
    }
    if (std.mem.eql(u8, method_name, "as_slice") or
        std.mem.eql(u8, method_name, "as_mut_slice"))
    {
        if (sliceElementForMethod(receiver_ty)) |element| {
            return makeSliceType(ctx, element, std.mem.eql(u8, method_name, "as_mut_slice"));
        }
    }
    return null;
}

fn publicIteratorPath(external: types.ExternalNominal, module: []const u8, name: []const u8) bool {
    if (external.path.len != 3) return false;
    if (!std.mem.eql(u8, external.path[0], "core") and
        !std.mem.eql(u8, external.path[0], "std"))
    {
        return false;
    }
    return std.mem.eql(u8, external.path[1], module) and
        std.mem.eql(u8, external.path[2], name);
}
fn closureValueReturnType(ctx: *Ctx, closure: exprs.ClosureExpr) ?types.Type {
    if (closure.body.tail) |tail| {
        if (getKnownType(ctx, tail)) |known| return known;
    }
    if (closure.return_ty) |type_id| {
        if (type_id < ctx.b.types.len) return ctx.b.types[type_id];
    }
    if (closure.body.tail != null) return null;
    return .{ .prim = .unit };
}

fn iteratorSourceItemType(ctx: *Ctx, source: exprs.NodeId) ?types.Type {
    if (source >= ctx.b.exprs.len) return null;
    const source_ty = getKnownType(ctx, source) orelse return null;
    return switch (source_ty) {
        .slice => |slice| slice.elem,
        .array => |array| array.elem,
        .reference => |reference| switch (reference.pointee) {
            .slice => |slice| slice.elem,
            .array => |array| array.elem,
            else => iteratorItemType(ctx, source_ty),
        },
        else => iteratorItemType(ctx, source_ty),
    };
}

fn iteratorChainElementType(ctx: *Ctx, chain: exprs.IteratorChainExpr) ?types.Type {
    var current = iteratorSourceItemType(ctx, chain.source) orelse return null;
    for (chain.adapters) |adapter| {
        current = switch (adapter) {
            .map => |map| closureValueReturnType(ctx, map.closure) orelse return null,
            .filter => current,
            .flat_map => |closure| blk: {
                const returned = closureValueReturnType(ctx, closure) orelse return null;
                break :blk iteratorItemType(ctx, returned) orelse return null;
            },
            .enumerate => blk: {
                const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
                tuple[0] = .{ .prim = .usize };
                tuple[1] = current;
                break :blk .{ .tuple = tuple };
            },
            .zip => |zip| blk: {
                const other_item = iteratorSourceItemType(ctx, zip.other) orelse return null;
                const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
                tuple[0] = current;
                tuple[1] = other_item;
                break :blk .{ .tuple = tuple };
            },
            .range_rev => current,
            .other => return null,
        };
    }
    return current;
}

fn iteratorItemType(ctx: *Ctx, ty: types.Type) ?types.Type {
    var base = ty;
    while (true) {
        switch (base) {
            .reference => |reference| base = reference.pointee,
            .raw_ptr => |raw_ptr| base = raw_ptr.pointee,
            .boxed => |boxed| base = boxed.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    base = concrete.*;
                } else {
                    return null;
                }
            },
            else => break,
        }
    }
    switch (base) {
        .external_nominal => |external| {
            if (publicIteratorPath(external, "ops", "Range") and external.args.len == 1) {
                return external.args[0];
            }
            if (publicIteratorPath(external, "slice", "Iter") and external.args.len == 1) {
                return makeReferenceType(ctx, external.args[0], false);
            }
            if (publicIteratorPath(external, "slice", "IterMut") and external.args.len == 1) {
                return makeReferenceType(ctx, external.args[0], true);
            }
            if ((publicIteratorPath(external, "iter", "StepBy") or
                publicIteratorPath(external, "iter", "Skip") or
                publicIteratorPath(external, "iter", "Rev")) and
                external.args.len == 1)
            {
                return iteratorItemType(ctx, external.args[0]);
            }
            if (publicIteratorPath(external, "iter", "Enumerate") and external.args.len == 1) {
                const element = iteratorItemType(ctx, external.args[0]) orelse return null;
                const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
                tuple[0] = .{ .prim = .usize };
                tuple[1] = element;
                return .{ .tuple = tuple };
            }
            if (publicIteratorPath(external, "iter", "Zip") and external.args.len == 2) {
                const left = iteratorItemType(ctx, external.args[0]) orelse return null;
                const right = iteratorItemType(ctx, external.args[1]) orelse return null;
                const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
                tuple[0] = left;
                tuple[1] = right;
                return .{ .tuple = tuple };
            }
        },
        .slice => |slice| return makeReferenceType(ctx, slice.elem, false),
        .array => |array| return array.elem,
        else => {},
    }
    return null;
}

fn knownIteratorMethodType(
    ctx: *Ctx,
    method_name: []const u8,
    receiver: types.Type,
    args: []const exprs.NodeId,
) ?types.Type {
    if (std.mem.eql(u8, method_name, "iter") or std.mem.eql(u8, method_name, "iter_mut")) {
        const element = sliceElementForMethod(receiver) orelse return null;
        return makeExternalNominalType(
            ctx,
            if (std.mem.eql(u8, method_name, "iter"))
                &.{ "core", "slice", "Iter" }
            else
                &.{ "core", "slice", "IterMut" },
            &.{element},
        );
    }
    if (std.mem.eql(u8, method_name, "step_by") or
        std.mem.eql(u8, method_name, "skip") or
        std.mem.eql(u8, method_name, "rev") or
        std.mem.eql(u8, method_name, "enumerate"))
    {
        const type_name = if (std.mem.eql(u8, method_name, "step_by"))
            "StepBy"
        else if (std.mem.eql(u8, method_name, "skip"))
            "Skip"
        else if (std.mem.eql(u8, method_name, "rev"))
            "Rev"
        else
            "Enumerate";
        return makeExternalNominalType(ctx, &.{ "core", "iter", type_name }, &.{receiver});
    }
    if (std.mem.eql(u8, method_name, "zip")) {
        if (args.len == 0) return null;
        const other = getKnownType(ctx, args[0]) orelse return null;
        return makeExternalNominalType(ctx, &.{ "core", "iter", "Zip" }, &.{ receiver, other });
    }

    return null;
}
fn knownIteratorChainType(ctx: *Ctx, chain: exprs.IteratorChainExpr) ?types.Type {
    if (chain.terminal == .sum) return iteratorChainElementType(ctx, chain);
    if (chain.terminal == .collect_vec) {
        const element = iteratorChainElementType(ctx, chain) orelse return null;
        return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{element});
    }
    if (chain.terminal != .iterator) return null;
    var current = getKnownType(ctx, chain.source) orelse return null;
    for (chain.adapters) |adapter| {
        current = switch (adapter) {
            .map => |map| closureValueReturnType(ctx, map.closure) orelse return null,
            .filter => current,
            .flat_map => |closure| blk: {
                const returned = closureValueReturnType(ctx, closure) orelse return null;
                break :blk makeExternalNominalType(
                    ctx,
                    &.{ "core", "iter", "FlatMap" },
                    &.{ current, returned },
                ) orelse return null;
            },
            .enumerate => makeExternalNominalType(
                ctx,
                &.{ "core", "iter", "Enumerate" },
                &.{current},
            ) orelse return null,
            .zip => |zip| blk: {
                const other = getKnownType(ctx, zip.other) orelse return null;
                break :blk makeExternalNominalType(
                    ctx,
                    &.{ "core", "iter", "Zip" },
                    &.{ current, other },
                ) orelse return null;
            },
            .range_rev => makeExternalNominalType(
                ctx,
                &.{ "core", "iter", "Rev" },
                &.{current},
            ) orelse return null,
            .other => return null,
        };
    }
    return current;
}

fn makeOptionLike(ctx: *Ctx, carrier: types.Type, payload: types.Type) ?types.Type {
    return switch (carrier) {
        .external_nominal => |external| if (external.path.len == 3 and
            (std.mem.eql(u8, external.path[0], "core") or
                std.mem.eql(u8, external.path[0], "std")) and
            std.mem.eql(u8, external.path[1], "option") and
            std.mem.eql(u8, external.path[2], "Option"))
            makeExternalNominalType(ctx, external.path, &.{payload})
        else
            makeOptionType(ctx, payload),
        else => makeOptionType(ctx, payload),
    };
}

fn makeResultLike(
    ctx: *Ctx,
    carrier: types.Type,
    ok: types.Type,
    err: types.Type,
) ?types.Type {
    return switch (carrier) {
        .external_nominal => |external| makeExternalNominalType(ctx, external.path, &.{ ok, err }),
        .result => blk: {
            const result = ctx.alloc.create(types.Result) catch break :blk null;
            result.* = .{ .ok = ok, .err = err, .is_error_unionable = carrier.result.is_error_unionable };
            break :blk .{ .result = result };
        },
        else => null,
    };
}

fn closureReturnType(ctx: *Ctx, closure_node: exprs.NodeId) ?types.Type {
    if (closure_node >= ctx.b.exprs.len) return null;
    const closure = switch (ctx.b.exprs[closure_node].kind) {
        .closure => |value| value,
        else => return null,
    };
    const tail = closure.body.tail orelse return .{ .prim = .unit };
    return getKnownType(ctx, tail);
}

fn methodClosureInputType(method_name: []const u8, receiver_ty: types.Type) ?types.Type {
    if (std.mem.eql(u8, method_name, "map") or
        std.mem.eql(u8, method_name, "and_then"))
    {
        if (optionPayloadType(receiver_ty)) |payload| return payload;
        if (std.mem.eql(u8, method_name, "map")) {
            return resultPayloadType(receiver_ty, false);
        }
        return null;
    }
    if (std.mem.eql(u8, method_name, "map_err")) {
        return resultPayloadType(receiver_ty, true);
    }
    return null;
}

fn isCharType(ty: types.Type) bool {
    var base = ty;
    while (true) {
        switch (base) {
            .reference => |r| base = r.pointee,
            .raw_ptr => |r| base = r.pointee,
            .boxed => |b| base = b.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    base = concrete.*;
                } else {
                    break;
                }
            },
            else => break,
        }
    }
    return switch (base) {
        .prim => |p| p == .char,
        else => false,
    };
}

fn canonicalReceiverName(ctx: *const Ctx, ty: types.Type) ?[]const u8 {
    var base = ty;
    while (true) {
        switch (base) {
            .reference => |reference| base = reference.pointee,
            .raw_ptr => |raw_ptr| base = raw_ptr.pointee,
            .boxed => |boxed| base = boxed.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    base = concrete.*;
                } else {
                    break;
                }
            },
            else => break,
        }
    }

    const cg = ctx.cg orelse return null;
    return switch (base) {
        .path => |path| blk: {
            if (path.segments.len == 0) break :blk null;
            const terminal = path.segments[path.segments.len - 1];
            const def = terminal.id orelse break :blk null;
            const entity = cg.symbol_table.get(def) orelse break :blk null;
            break :blk entity.name;
        },
        .generic_inst => |instance| blk: {
            const entity = cg.symbol_table.get(instance.decl) orelse break :blk null;
            break :blk entity.name;
        },
        .external_nominal => |external| if (external.path.len > 0)
            external.path[external.path.len - 1]
        else
            null,
        else => null,
    };
}

fn callDefinition(call: exprs.Call) exprs.DefId {
    return switch (call.call_kind) {
        .free => |id| id,
        .associated => |id| id,
        .constructor => |id| id,
    };
}

fn nominalTypeForDefinition(ctx: *Ctx, node: exprs.NodeId, def: exprs.DefId) ?types.Type {
    if (node < ctx.b.exprs.len) {
        if (ctx.b.exprs[node].ty) |type_id| {
            if (type_id < ctx.b.types.len) {
                switch (ctx.b.types[type_id]) {
                    .generic_inst => |instance| if (instance.decl == def) return ctx.b.types[type_id],
                    else => {},
                }
            }
        }
    }
    for (ctx.b.types) |candidate| {
        switch (candidate) {
            .path => |path| {
                if (path.segments.len == 0) continue;
                if (path.segments[path.segments.len - 1].id == def) return candidate;
            },
            .generic_inst => |instance| if (instance.decl == def) return candidate,
            else => {},
        }
    }
    if (ctx.cg) |cg| {
        if (cg.symbol_table.get(def)) |entity| {
            if (entity.name.len == 0) return null;
            // Nested type storage shares the materialized IR's allocator lifetime.
            const segments = ctx.alloc.alloc(types.PathSegment, 1) catch {
                ctx.g.derived_error = true;
                return null;
            };
            segments[0] = .{ .name = entity.name, .id = def };
            return .{ .path = .{ .segments = segments } };
        }
    }
    return null;
}

fn callGenericArguments(ctx: *Ctx, node: exprs.NodeId, def: exprs.DefId) ?[]const types.Type {
    if (explicitArgsForNode(ctx, node)) |args| {
        if (if (node < ctx.b.exprs.len) ctx.b.exprs[node].ty else null) |type_id| {
            if (type_id < ctx.b.types.len) switch (ctx.b.types[type_id]) {
                .generic_inst => |instance| if (instance.decl == def) return args.params,
                else => {},
            };
        }
    }
    if (ctx.g.instantiations.get(node)) |inst| {
        if (inst.generic_id == def) return inst.args.params;
    }
    return null;
}

fn traitAssociatedReturnType(ctx: *Ctx, def: exprs.DefId) ?types.Type {
    const cg = ctx.cg orelse return null;
    const entity = cg.symbol_table.get(def) orelse return null;
    const parent = entity.parent orelse return null;
    if (parent >= ctx.b.bodies.len) return null;
    const trait_body = switch (ctx.b.bodies[parent]) {
        .trait_ => |body| body,
        else => return null,
    };
    for (trait_body.methods) |method| {
        if (std.mem.eql(u8, method.name, entity.name)) return method.ret;
    }
    return null;
}

fn knownCallReturnType(ctx: *Ctx, node: exprs.NodeId, call: exprs.Call) ?types.Type {
    const def = callDefinition(call);
    if (ctx.def_map.get(def)) |initializer| {
        if (initializer < ctx.b.exprs.len and ctx.b.exprs[initializer].kind == .closure) {
            return closureValueReturnType(ctx, ctx.b.exprs[initializer].kind.closure);
        }
    }
    var return_type: ?types.Type = null;
    if (def < ctx.b.bodies.len) {
        return_type = switch (ctx.b.bodies[def]) {
            .fn_ => |function| function.ret,
            else => null,
        };
    }
    if (return_type == null) return_type = traitAssociatedReturnType(ctx, def);

    if (return_type) |declared| {
        if (!isConcreteDerivedType(declared)) {
            if (ctx.expected_types.get(node)) |expected| return expected;
        }
        if (callGenericArguments(ctx, node, def)) |generic_args| {
            const names = getGenericParamNames(ctx, def) catch null;
            if (names) |param_names| {
                defer ctx.alloc.free(param_names);
                const substituted = substType(
                    ctx.alloc,
                    declared,
                    param_names,
                    generic_args,
                ) catch null;
                if (substituted) |resolved| {
                    if (isConcreteDerivedType(resolved)) return resolved;
                }
            }
        }
        if (isConcreteDerivedType(declared)) return declared;
    }

    if (call.call_kind == .constructor and
        def < ctx.b.bodies.len and ctx.b.bodies[def] == .struct_)
    {
        return nominalTypeForDefinition(ctx, node, def);
    }
    return ctx.expected_types.get(node);
}

fn knownDeclaredMethodReturnType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
) ?types.Type {
    const cg = ctx.cg orelse return null;
    const type_name = canonicalReceiverName(ctx, receiver_ty) orelse return null;
    const method_def = resolve_methods.lookupInherentMethod(cg, type_name, method_name) orelse
        return null;
    if (method_def >= ctx.b.bodies.len) return null;

    var return_type = switch (ctx.b.bodies[method_def]) {
        .fn_ => |fn_body| fn_body.ret,
        else => return null,
    };

    var base = receiver_ty;
    while (true) {
        switch (base) {
            .reference => |reference| base = reference.pointee,
            .raw_ptr => |raw_ptr| base = raw_ptr.pointee,
            .boxed => |boxed| base = boxed.*,
            .@"opaque" => |opaque_type| {
                if (opaque_type.concrete) |concrete| {
                    base = concrete.*;
                } else {
                    break;
                }
            },
            else => break,
        }
    }
    const generic_args = switch (base) {
        .generic_inst => |instance| instance.args.params,
        else => &[_]types.Type{},
    };
    if (generic_args.len == 0) return return_type;

    const method_entity = cg.symbol_table.get(method_def) orelse return return_type;
    const impl_id = method_entity.parent orelse return return_type;
    if (impl_id >= ctx.b.bodies.len) return return_type;
    const impl_body = switch (ctx.b.bodies[impl_id]) {
        .impl_ => |body| body,
        else => return return_type,
    };
    const generics = impl_body.generics orelse return return_type;
    var type_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer type_names.deinit(ctx.alloc);
    for (generics.params) |param| {
        switch (param) {
            .type_ => |type_param| type_names.append(ctx.alloc, type_param.name) catch return return_type,
            else => {},
        }
    }
    return_type = substType(ctx.alloc, return_type, type_names.items, generic_args) catch return_type;
    return return_type;
}
/// Infer the standard I/O result only when the receiver's generic parameter
/// carries the corresponding non-optional trait bound.
fn knownIoMethodResultType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
) ?types.Type {
    const trait_path: []const []const u8 = if (std.mem.eql(u8, method_name, "read_exact"))
        &.{ "std", "io", "Read" }
    else if (std.mem.eql(u8, method_name, "write_all"))
        &.{ "std", "io", "Write" }
    else
        return null;
    const cg = ctx.cg orelse return null;
    const owner = ctx.current_fn orelse return null;
    if (bodies.genericBound(cg, ctx.b, owner, receiver_ty, trait_path) == null) return null;
    const result = ctx.alloc.create(types.Result) catch {
        ctx.g.derived_error = true;
        return null;
    };
    result.* = .{
        .ok = .{ .prim = .unit },
        .err = .{ .external_nominal = .{
            .path = &.{ "std", "io", "Error" },
        } },
        .is_error_unionable = false,
    };
    return .{ .result = result };
}

fn genericMethodOwner(ctx: *const Ctx, method_def: exprs.DefId) ?exprs.DefId {
    if (ctx.cg) |cg| {
        if (cg.symbol_table.get(method_def)) |entity| {
            if (entity.kind == .method_ref) return entity.parent;
        }
    }
    return ctx.current_fn;
}

fn knownBoundMethodReturnType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
    method_def: exprs.DefId,
) ?types.Type {
    const cg = ctx.cg orelse return null;
    const owner = genericMethodOwner(ctx, method_def) orelse return null;
    const trait_path: []const []const u8 =
        if (std.mem.eql(u8, method_name, "as_ref"))
            &.{ "core", "convert", "AsRef" }
        else if (std.mem.eql(u8, method_name, "as_mut"))
            &.{ "core", "convert", "AsMut" }
        else if (std.mem.eql(u8, method_name, "borrow"))
            &.{ "core", "borrow", "Borrow" }
        else if (std.mem.eql(u8, method_name, "borrow_mut"))
            &.{ "core", "borrow", "BorrowMut" }
        else if (std.mem.eql(u8, method_name, "into"))
            &.{ "core", "convert", "Into" }
        else if (std.mem.eql(u8, method_name, "try_into"))
            &.{ "core", "convert", "TryInto" }
        else
            return null;
    const bound = bodies.genericBound(cg, ctx.b, owner, receiver_ty, trait_path) orelse return null;
    if (bound.args.len == 0) return null;
    const target = substType(ctx.alloc, bound.args[0], &.{"Self"}, &.{receiver_ty}) catch {
        ctx.g.derived_error = true;
        return null;
    };
    if (std.mem.eql(u8, method_name, "into")) return target;
    if (std.mem.eql(u8, method_name, "as_ref") or
        std.mem.eql(u8, method_name, "as_mut") or
        std.mem.eql(u8, method_name, "borrow") or
        std.mem.eql(u8, method_name, "borrow_mut"))
    {
        return makeReferenceType(
            ctx,
            target,
            std.mem.eql(u8, method_name, "as_mut") or
                std.mem.eql(u8, method_name, "borrow_mut"),
        );
    }
    var error_type: types.Type = undefined;
    var has_error_binding = false;
    for (bound.associated_types) |binding| {
        if (std.mem.eql(u8, binding.name, "Error")) {
            error_type = binding.ty;
            has_error_binding = true;
            break;
        }
    }
    if (!has_error_binding) {
        error_type = makeExternalNominalType(
            ctx,
            &.{ "core", "convert", "TryInto", "Error" },
            &.{ receiver_ty, target },
        ) orelse return null;
    }
    const result = ctx.alloc.create(types.Result) catch {
        ctx.g.derived_error = true;
        return null;
    };
    result.* = .{ .ok = target, .err = error_type, .is_error_unionable = false };
    return .{ .result = result };
}

fn knownCoreFunctionType(ctx: *Ctx, function: exprs.CoreFunctionValue) ?types.Type {
    switch (function.function) {
        .default_value, .convert_from => {
            if (function.generic_args.len != 1) return null;
            return function.generic_args[0];
        },
        .mem_transmute => {
            if (function.generic_args.len != 2) return null;
            const params = ctx.alloc.dupe(types.Type, &.{function.generic_args[0]}) catch {
                ctx.g.derived_error = true;
                return null;
            };
            const fn_ptr = ctx.alloc.create(types.FnPtr) catch {
                ctx.alloc.free(params);
                ctx.g.derived_error = true;
                return null;
            };
            fn_ptr.* = .{
                .params = params,
                .ret = function.generic_args[1],
            };
            return .{ .fn_ptr = fn_ptr };
        },
        else => return null,
    }
}

fn coreTypeArgument(ctx: *Ctx, call: exprs.CoreCall) ?types.Type {
    if (call.generic_args.len == 1) return call.generic_args[0];
    if (call.generic_args.len != 0 or call.args.len == 0) return null;
    const first = getKnownType(ctx, call.args[0]);
    if (call.function == .cmp_min or call.function == .cmp_max) {
        if (first) |known| return known;
        return if (call.args.len == 2) getKnownType(ctx, call.args[1]) else null;
    }
    const known = first orelse return null;
    return switch (call.function) {
        .mem_size_of_val => switch (known) {
            .reference => |reference| reference.pointee,
            .slice, .array => known,
            else => null,
        },
        .ptr_copy_nonoverlapping,
        .ptr_write_bytes,
        .ptr_read_unaligned,
        .slice_from_raw_parts,
        .slice_from_raw_parts_mut,
        => switch (known) {
            .raw_ptr => |pointer| pointer.pointee,
            .reference => |reference| reference.pointee,
            else => null,
        },
        else => null,
    };
}
fn knownCoreCallType(ctx: *Ctx, call: exprs.CoreCall) ?types.Type {
    switch (call.function) {
        .default_value, .convert_from => {
            if (call.generic_args.len != 1) return null;
            return call.generic_args[0];
        },
        .mem_size_of => return .{ .prim = .usize },
        .mem_transmute => {
            if (call.generic_args.len != 2) return null;
            return call.generic_args[1];
        },
        .mem_size_of_val => return .{ .prim = .usize },
        .ptr_copy_nonoverlapping, .ptr_write_bytes => return .{ .prim = .unit },
        .ptr_read_unaligned, .cmp_min, .cmp_max => return coreTypeArgument(ctx, call),
        .slice_from_raw_parts, .slice_from_raw_parts_mut => {
            const element = coreTypeArgument(ctx, call) orelse return null;
            const slice = ctx.alloc.create(types.Slice) catch {
                ctx.g.derived_error = true;
                return null;
            };
            slice.* = .{
                .const_ = call.function == .slice_from_raw_parts,
                .elem = element,
            };
            return .{ .slice = slice };
        },
        .str_from_utf8, .str_from_utf8_unchecked => {
            const string: types.Type = .{ .slice = &.{
                .const_ = true,
                .elem = .{ .prim = .u8 },
            } };
            if (call.function == .str_from_utf8_unchecked) return string;
            const result = ctx.alloc.create(types.Result) catch {
                ctx.g.derived_error = true;
                return null;
            };
            result.* = .{
                .ok = string,
                .err = .{ .external_nominal = .{ .path = &.{ "core", "str", "Utf8Error" } } },
                .is_error_unionable = false,
            };
            return .{ .result = result };
        },
        .string_from_utf8 => {
            const string = makeExternalNominalType(
                ctx,
                &.{ "alloc", "string", "String" },
                &.{},
            ) orelse return null;
            const error_type = makeExternalNominalType(
                ctx,
                &.{ "alloc", "string", "FromUtf8Error" },
                &.{},
            ) orelse return null;
            return makeExternalNominalType(
                ctx,
                &.{ "core", "result", "Result" },
                &.{ string, error_type },
            );
        },
        .string_from_utf8_lossy => {
            return makeExternalNominalType(
                ctx,
                &.{ "alloc", "borrow", "Cow" },
                &.{types.str_type},
            );
        },
        .string_from_utf8_unchecked => {
            return makeExternalNominalType(ctx, &.{ "alloc", "string", "String" }, &.{});
        },
    }
}

fn walkTypeExpressions(ctx: *Ctx, ty: types.Type, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    if (ctx.type_expression_depth >= types.traversal_depth_max) return;
    ctx.type_expression_depth += 1;
    defer ctx.type_expression_depth -= 1;
    switch (ty) {
        .array => |array| {
            if (array.len == .expression) try walkExpr(ctx, array.len.expression, fn_body);
            try walkTypeExpressions(ctx, array.elem, fn_body);
        },
        .reference => |reference| try walkTypeExpressions(ctx, reference.pointee, fn_body),
        .raw_ptr => |pointer| try walkTypeExpressions(ctx, pointer.pointee, fn_body),
        .slice => |slice| try walkTypeExpressions(ctx, slice.elem, fn_body),
        .tuple => |elements| for (elements) |element| try walkTypeExpressions(ctx, element, fn_body),
        .external_nominal => |external| for (external.args) |argument| try walkTypeExpressions(ctx, argument, fn_body),
        .generic_inst => |instance| for (instance.args.params) |argument| try walkTypeExpressions(ctx, argument, fn_body),
        .fn_ptr => |function| {
            for (function.params) |parameter| try walkTypeExpressions(ctx, parameter, fn_body);
            try walkTypeExpressions(ctx, function.ret, fn_body);
        },
        .option => |value| try walkTypeExpressions(ctx, value.*, fn_body),
        .result => |result| {
            try walkTypeExpressions(ctx, result.ok, fn_body);
            try walkTypeExpressions(ctx, result.err, fn_body);
        },
        .boxed => |value| try walkTypeExpressions(ctx, value.*, fn_body),
        .@"opaque" => |value| if (value.concrete) |concrete| try walkTypeExpressions(ctx, concrete.*, fn_body),
        .path => |path| {
            if (path.segments.len == 0) return;
            const def = path.segments[path.segments.len - 1].id orelse return;
            if (def >= ctx.b.bodies.len) return;
            switch (ctx.b.bodies[def]) {
                .const_ => |constant| try walkExpr(ctx, constant.init, fn_body),
                else => {},
            }
        },
        .prim, .dyn_trait, .unsupported => {},
    }
}

fn walkCoreCall(ctx: *Ctx, node: exprs.NodeId, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    const call = &@constCast(ctx.b.exprs)[node].kind.core_call;
    for (call.generic_args) |argument| try walkTypeExpressions(ctx, argument, fn_body);
    for (call.args) |arg| try walkExpr(ctx, arg, fn_body);
    if (call.generic_args.len == 0) {
        if (coreTypeArgument(ctx, call.*)) |argument| {
            call.generic_args = try ctx.alloc.dupe(types.Type, &.{argument});
        }
    }
    if (getKnownType(ctx, node)) |result| try pinKnownType(ctx, node, result);
    switch (call.function) {
        .cmp_min, .cmp_max => if (coreTypeArgument(ctx, call.*)) |argument| {
            for (call.args) |arg| try constrainExpectedType(ctx, arg, argument);
        },
        .ptr_copy_nonoverlapping, .ptr_write_bytes => {
            if (call.args.len != 3) return;
            try constrainExpectedType(ctx, call.args[2], .{ .prim = .usize });
            if (call.function == .ptr_write_bytes) {
                try constrainExpectedType(ctx, call.args[1], .{ .prim = .u8 });
            }
        },
        .slice_from_raw_parts, .slice_from_raw_parts_mut => {
            if (call.args.len != 2) return;
            try constrainExpectedType(ctx, call.args[1], .{ .prim = .usize });
        },
        else => {},
    }
}
/// Derive a concrete Type for an argument expression node where possible.
fn getKnownType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    if (ctx.known_nodes.get(node)) |known| return known;
    const e = ctx.b.exprs[node];
    switch (e.kind) {
        .core_call => |call| {
            const known = knownCoreCallType(ctx, call) orelse return null;
            ctx.known_nodes.put(ctx.alloc, node, known) catch {
                ctx.g.derived_error = true;
                return null;
            };
            return known;
        },
        .core_function => |function| {
            const known = knownCoreFunctionType(ctx, function) orelse return null;
            ctx.known_nodes.put(ctx.alloc, node, known) catch {
                ctx.g.derived_error = true;
                return null;
            };
            return known;
        },
        .external_variant => |variant| {
            if (variant.owner.args.len == 0) return null;
            const known: types.Type = .{ .external_nominal = variant.owner };
            ctx.known_nodes.put(ctx.alloc, node, known) catch {
                ctx.g.derived_error = true;
                return null;
            };
            return known;
        },
        .path => |p| {
            if (ctx.local_types.get(p.def)) |local_ty| {
                if (local_ty == .path and local_ty.path.segments.len == 1 and
                    std.mem.eql(u8, local_ty.path.segments[0].name, "Self"))
                {
                    if (currentImplSelfType(ctx)) |self_ty| return self_ty;
                }
                return local_ty;
            }
            if (p.def < ctx.b.bodies.len) {
                switch (ctx.b.bodies[p.def]) {
                    .const_ => |constant| return constant.ty,
                    else => {},
                }
            }
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
                if (first != node and first < ctx.b.exprs.len) {
                    return getKnownType(ctx, first);
                }
            }
        },
        .call => |call| {
            if (knownCallReturnType(ctx, node, call)) |known| {
                ctx.known_nodes.put(ctx.alloc, node, known) catch {
                    ctx.g.derived_error = true;
                    return null;
                };
                return known;
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .if_else => |if_expr| {
            const then_ty = if (if_expr.then_.tail) |tail|
                getKnownType(ctx, tail)
            else
                null;
            const else_ty: ?types.Type = switch (if_expr.@"else") {
                .block => |block| if (block.tail) |tail| getKnownType(ctx, tail) else null,
                .chain => |chain| getKnownType(ctx, chain),
                .none => null,
            };
            if (then_ty) |known_then| {
                if (else_ty) |known_else| {
                    if (typeEqual(known_then, known_else)) return known_then;
                    return null;
                }
                return known_then;
            }
            return else_ty;
        },
        .method_call => |method| {
            if (getMethodName(ctx, method.method)) |method_name| {
                if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                    if (knownAllocMethodType(ctx, receiver_ty, method_name)) |alloc_result| {
                        return alloc_result;
                    }
                    if (knownBoundMethodReturnType(
                        ctx,
                        receiver_ty,
                        method_name,
                        method.method,
                    )) |bound_result| {
                        return bound_result;
                    }
                    if (knownIoMethodResultType(ctx, receiver_ty, method_name)) |io_result| {
                        ctx.known_nodes.put(ctx.alloc, node, io_result) catch {
                            ctx.g.derived_error = true;
                            return null;
                        };
                        return io_result;
                    }
                    if (knownIteratorMethodType(ctx, method_name, receiver_ty, method.args)) |iterator_ty| {
                        return iterator_ty;
                    }
                    if (std.mem.eql(u8, method_name, "ok")) {
                        if (resultPayloadType(receiver_ty, false)) |ok_payload| {
                            return makeOptionLike(ctx, receiver_ty, ok_payload);
                        }
                    }
                    if (std.mem.eql(u8, method_name, "take")) {
                        if (optionPayloadType(receiver_ty)) |payload| {
                            return makeOptionLike(ctx, receiver_ty, payload);
                        }
                    }
                }
                if (std.mem.eql(u8, method_name, "as_ref")) {
                    if (getKnownType(ctx, method.receiver)) |option_ty| {
                        if (optionPayloadType(option_ty)) |payload| {
                            if (makeReferenceType(ctx, payload, false)) |reference| {
                                return makeOptionLike(ctx, option_ty, reference);
                            }
                        }
                    }
                }
                if (std.mem.eql(u8, method_name, "read_exact") or
                    std.mem.eql(u8, method_name, "write_all"))
                {
                    return null;
                }
                if (std.mem.eql(u8, method_name, "map") or
                    std.mem.eql(u8, method_name, "map_err") or
                    std.mem.eql(u8, method_name, "and_then"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (std.mem.eql(u8, method_name, "map") or
                            std.mem.eql(u8, method_name, "and_then"))
                        {
                            if (optionPayloadType(receiver_ty)) |_| {
                                if (method.args.len > 0) {
                                    if (closureReturnType(ctx, method.args[0])) |mapped| {
                                        if (std.mem.eql(u8, method_name, "and_then")) return mapped;
                                        return makeOptionLike(ctx, receiver_ty, mapped);
                                    }
                                }
                            } else if (std.mem.eql(u8, method_name, "map")) {
                                if (resultPayloadType(receiver_ty, false)) |ok| {
                                    if (method.args.len > 0) {
                                        if (closureReturnType(ctx, method.args[0])) |mapped| {
                                            if (resultPayloadType(receiver_ty, true)) |err| {
                                                return makeResultLike(ctx, receiver_ty, mapped, err);
                                            }
                                        }
                                    }
                                    _ = ok;
                                }
                            }
                        } else if (resultPayloadType(receiver_ty, true)) |_| {
                            if (method.args.len > 0) {
                                if (closureReturnType(ctx, method.args[0])) |mapped| {
                                    if (resultPayloadType(receiver_ty, false)) |ok| {
                                        return makeResultLike(ctx, receiver_ty, ok, mapped);
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "clone") or
                    std.mem.eql(u8, method_name, "by_ref"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| return receiver_ty;
                } else if (std.mem.eql(u8, method_name, "wrapping_add") or
                    std.mem.eql(u8, method_name, "wrapping_sub") or
                    std.mem.eql(u8, method_name, "wrapping_mul") or
                    std.mem.eql(u8, method_name, "saturating_add") or
                    std.mem.eql(u8, method_name, "saturating_sub") or
                    std.mem.eql(u8, method_name, "saturating_mul") or
                    std.mem.eql(u8, method_name, "bitxor") or
                    std.mem.eql(u8, method_name, "bitor") or
                    std.mem.eql(u8, method_name, "bitand"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (scalarOperandType(receiver_ty)) |scalar| return scalar;
                    }
                }
                if (std.mem.eql(u8, method_name, "len")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (isLenReceiverType(receiver_ty) or
                            iteratorItemType(ctx, receiver_ty) != null)
                        {
                            return .{ .prim = .usize };
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "count")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (iteratorItemType(ctx, receiver_ty) != null) {
                            return .{ .prim = .usize };
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "size_hint")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (iteratorItemType(ctx, receiver_ty) != null) {
                            const upper = makeOptionType(ctx, .{ .prim = .usize }) orelse return null;
                            const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
                            tuple[0] = .{ .prim = .usize };
                            tuple[1] = upper;
                            return .{ .tuple = tuple };
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "split_at")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (sliceElementForMethod(receiver_ty)) |element| {
                            if (makeSliceType(ctx, element, false)) |slice_type| {
                                const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
                                tuple[0] = slice_type;
                                tuple[1] = slice_type;
                                return .{ .tuple = tuple };
                            }
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "chunks_exact")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (sliceElementForMethod(receiver_ty)) |element| {
                            return chunksExactType(ctx, element);
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "remainder")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (chunksExactElement(receiver_ty)) |element| {
                            return makeSliceType(ctx, element, false);
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "as_slice") or
                    std.mem.eql(u8, method_name, "as_mut_slice"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (sliceIteratorElementType(receiver_ty)) |element| {
                            return makeSliceType(
                                ctx,
                                element,
                                std.mem.eql(u8, method_name, "as_mut_slice"),
                            );
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "as_ptr") or
                    std.mem.eql(u8, method_name, "as_mut_ptr"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (sliceElementForMethod(receiver_ty)) |element| {
                            return makeRawPtrType(
                                ctx,
                                element,
                                std.mem.eql(u8, method_name, "as_mut_ptr"),
                            );
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "get_unchecked") or
                    std.mem.eql(u8, method_name, "get_unchecked_mut"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (sliceElementForMethod(receiver_ty)) |element| {
                            return makeReferenceType(
                                ctx,
                                element,
                                std.mem.eql(u8, method_name, "get_unchecked_mut"),
                            );
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "read") or
                    std.mem.eql(u8, method_name, "read_unaligned") or
                    std.mem.eql(u8, method_name, "read_volatile"))
                {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (dereferencedType(receiver_ty)) |pointee| return pointee;
                    }
                } else if (std.mem.eql(u8, method_name, "to_le") or
                    std.mem.eql(u8, method_name, "to_be") or
                    std.mem.eql(u8, method_name, "from_le") or
                    std.mem.eql(u8, method_name, "from_be") or
                    std.mem.eql(u8, method_name, "swap_bytes"))
                {
                    if (getKnownType(ctx, method.receiver)) |recv_ty| {
                        if (isIntegerType(recv_ty)) return recv_ty;
                    }
                } else if (std.mem.eql(u8, method_name, "offset") or
                    std.mem.eql(u8, method_name, "wrapping_offset") or
                    std.mem.eql(u8, method_name, "add") or
                    std.mem.eql(u8, method_name, "sub") or
                    std.mem.eql(u8, method_name, "wrapping_add") or
                    std.mem.eql(u8, method_name, "wrapping_sub"))
                {
                    if (getKnownType(ctx, method.receiver)) |recv_ty| {
                        if (recv_ty == .raw_ptr) return recv_ty;
                    }
                } else if (std.mem.eql(u8, method_name, "next") or
                    std.mem.eql(u8, method_name, "next_back") or
                    std.mem.eql(u8, method_name, "nth") or
                    std.mem.eql(u8, method_name, "nth_back") or
                    std.mem.eql(u8, method_name, "last"))
                {
                    if (getKnownType(ctx, method.receiver)) |recv_ty| {
                        if (iteratorItemType(ctx, recv_ty)) |item| {
                            return makeOptionLike(ctx, recv_ty, item) orelse
                                makeOptionType(ctx, item);
                        }
                    }
                } else if (std.mem.eql(u8, method_name, "to_digit")) {
                    if (getKnownType(ctx, method.receiver)) |recv_ty| {
                        if (isCharType(recv_ty)) {
                            return makeOptionType(ctx, .{ .prim = .u32 });
                        }
                    }
                }
                if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                    if (knownDeclaredMethodReturnType(ctx, receiver_ty, method_name)) |return_type| {
                        return return_type;
                    }
                }
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .field => |field| {
            if (getKnownType(ctx, field.base)) |base_ty| {
                if (fieldTypeForBase(ctx, base_ty, field.field)) |field_ty| return field_ty;
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .index => |index| {
            if (getKnownType(ctx, index.base)) |base_type| {
                if (indexedElementType(base_type)) |element_type| return element_type;
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
            return null;
        },
        .binary => |binary| {
            if (knownBinaryType(ctx, binary)) |known| return known;
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .unary => |unary| return switch (unary.op) {
            .deref => if (getKnownType(ctx, unary.operand)) |operand_ty|
                dereferencedValueType(ctx, operand_ty)
            else
                null,
            .negate, .bit_not => getKnownType(ctx, unary.operand),
            .logical_not => if (getKnownType(ctx, unary.operand)) |op_ty| blk: {
                if (isIntegerType(op_ty)) break :blk op_ty;
                break :blk types.Type{ .prim = .bool };
            } else types.Type{ .prim = .bool },
            .ref => |mode| if (getKnownType(ctx, unary.operand)) |pointee|
                makeReferenceType(ctx, pointee, mode == .mutable)
            else
                null,
        },
        .iterator_chain => |chain| return knownIteratorChainType(ctx, chain),
        .range => |range| {
            const start_ty = getKnownType(ctx, range.start);
            const end_ty = if (range.end) |end| getKnownType(ctx, end) else null;
            const element_ty: types.Type = if (start_ty) |start| blk: {
                if (end_ty) |end| {
                    if (!typeEqual(start, end)) return null;
                }
                break :blk start;
            } else end_ty orelse return null;
            return makeExternalNominalType(
                ctx,
                &.{ "core", "ops", "Range" },
                &.{element_ty},
            );
        },
        .cast => |cast| {
            if (cast.target >= ctx.b.types.len) return null;
            const target = ctx.b.types[cast.target];
            if (isInferPlaceholderType(target)) return null;
            return target;
        },
        .literal => |lit| switch (lit) {
            .int => |il| {
                if (il.ty_suffix) |s| {
                    if (intSuffixPrim(s)) |p| return .{ .prim = p };
                }
                return null;
            },
            .float => |fl| return .{ .prim = floatSuffixPrim(fl.text) },
            .boolean => return .{ .prim = .bool },
            .character => return .{ .prim = .char },
            .string => {},
            .byte_array => |bytes| {
                const array = ctx.alloc.create(types.Array) catch {
                    ctx.g.derived_error = true;
                    return null;
                };
                array.* = .{
                    .len = .{ .literal = @intCast(bytes.items.len) },
                    .elem = .{ .prim = .u8 },
                };
                const known: types.Type = .{ .array = array };
                ctx.known_nodes.put(ctx.alloc, node, known) catch {
                    ctx.g.derived_error = true;
                    return null;
                };
                return known;
            },
        },
        .try_ => |t| {
            if (getKnownType(ctx, t.inner)) |inner_ty| {
                return unwrapTryType(inner_ty);
            }
            return null;
        },
        .break_, .continue_ => return .{ .prim = .never },
        else => {
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
    }
    return null;
}

fn knownBinaryType(ctx: *Ctx, binary: exprs.BinaryExpr) ?types.Type {
    const lhs = getKnownType(ctx, binary.lhs);
    const rhs = getKnownType(ctx, binary.rhs);
    const lhs_scalar = if (lhs) |value| scalarOperandType(value) else null;
    const rhs_scalar = if (rhs) |value| scalarOperandType(value) else null;
    return switch (binary.op) {
        .add,
        .sub,
        .mul,
        .div,
        .rem,
        .bit_and,
        .bit_or,
        .bit_xor,
        => blk: {
            if (lhs_scalar) |left| {
                if (rhs_scalar) |right| {
                    if (typeEqual(left, right)) break :blk left;
                    break :blk null;
                }
                break :blk left;
            }
            if (rhs_scalar) |right| break :blk right;
            break :blk null;
        },
        .shl, .shr => blk: {
            if (lhs_scalar) |left| {
                if (rhs_scalar) |right| {
                    if (isIntegerType(right)) break :blk left;
                    break :blk null;
                }
                break :blk left;
            }
            break :blk null;
        },
        else => null,
    };
}

fn isScalarCastType(ty: types.Type) bool {
    return switch (ty) {
        .prim => |primitive| switch (primitive) {
            .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize, .f32, .f64, .char => true,
            .bool, .unit, .never => false,
        },
        else => false,
    };
}
const ScalarPointeeLayout = enum {
    byte_1,
    byte_2,
    byte_4,
    byte_8,
    byte_16,
    pointer,
};

fn scalarPointeeLayout(primitive: types.Prim) ?ScalarPointeeLayout {
    return switch (primitive) {
        .i8, .u8, .bool => .byte_1,
        .i16, .u16 => .byte_2,
        .i32, .u32, .f32, .char => .byte_4,
        .i64, .u64, .f64 => .byte_8,
        .i128, .u128 => .byte_16,
        .isize, .usize => .pointer,
        .unit, .never => null,
    };
}

fn pointerPointeesCompatible(source: types.Type, target: types.Type) bool {
    return switch (source) {
        .prim => |source_primitive| switch (target) {
            .prim => |target_primitive| {
                const source_layout = scalarPointeeLayout(source_primitive) orelse return false;
                const target_layout = scalarPointeeLayout(target_primitive) orelse return false;
                return source_layout == target_layout;
            },
            else => false,
        },
        else => false,
    };
}

fn unsignedPrimitiveWidth(primitive: types.Prim) ?u16 {
    return switch (primitive) {
        .u8 => 8,
        .u16 => 16,
        .u32 => 32,
        .u64 => 64,
        .u128 => 128,
        .usize => 64,
        .char => 32,
        else => null,
    };
}

fn isIntegerPrimitive(primitive: types.Prim) bool {
    return switch (primitive) {
        .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => true,
        .f32, .f64, .bool, .char, .unit, .never => false,
    };
}

fn isBoolType(ty: types.Type) bool {
    return switch (ty) {
        .prim => |primitive| primitive == .bool,
        else => false,
    };
}

fn isThinRawPointer(raw_ptr: *const types.RawPtr) bool {
    return switch (raw_ptr.pointee) {
        .slice => false,
        else => true,
    };
}

fn isInferPlaceholderType(ty: types.Type) bool {
    return switch (ty) {
        .external_nominal => |external| external.path.len > 0 and
            std.mem.eql(u8, external.path[external.path.len - 1], "_"),
        .path => |path| path.segments.len > 0 and
            std.mem.eql(u8, path.segments[path.segments.len - 1].name, "_"),
        else => false,
    };
}
fn resolveWildcardRawPointerTarget(
    ctx: *Ctx,
    source: types.Type,
    target: types.Type,
) ?types.Type {
    const target_raw = switch (target) {
        .raw_ptr => |raw| raw,
        else => return null,
    };
    if (!isInferPlaceholderType(target_raw.pointee)) return null;
    const source_pointee: types.Type = switch (source) {
        .reference => |reference| reference.pointee,
        .raw_ptr => |raw| raw.pointee,
        else => return null,
    };
    const resolved = ctx.alloc.create(types.RawPtr) catch {
        ctx.g.derived_error = true;
        return null;
    };
    resolved.* = .{
        .mut = target_raw.mut,
        .pointee = source_pointee,
    };
    return .{ .raw_ptr = resolved };
}

fn resolveWildcardRawPointerSource(
    ctx: *Ctx,
    source: types.Type,
    target: types.Type,
) ?types.Type {
    const source_raw = switch (source) {
        .raw_ptr => |raw| raw,
        else => return null,
    };
    const target_raw = switch (target) {
        .raw_ptr => |raw| raw,
        else => return null,
    };
    if (!isInferPlaceholderType(source_raw.pointee) or
        isInferPlaceholderType(target_raw.pointee))
    {
        return null;
    }
    const resolved = ctx.alloc.create(types.RawPtr) catch {
        ctx.g.derived_error = true;
        return null;
    };
    resolved.* = .{
        .mut = source_raw.mut,
        .pointee = target_raw.pointee,
    };
    return .{ .raw_ptr = resolved };
}

fn referenceToRawPointerCompatible(source_ref: *const types.Ref, target_raw: *const types.RawPtr) bool {
    if (target_raw.mut and !source_ref.mut) return false;
    if (typeEqual(source_ref.pointee, target_raw.pointee)) return true;
    switch (source_ref.pointee) {
        .array => |arr| {
            if (typeEqual(arr.elem, target_raw.pointee)) return true;
            if (target_raw.pointee == .slice and typeEqual(arr.elem, target_raw.pointee.slice.elem)) {
                return true;
            }
        },
        else => {},
    }
    return false;
}
fn referenceArrayToSliceCompatible(
    source_ref: *const types.Ref,
    target_slice: *const types.Slice,
) bool {
    if (!target_slice.const_ and !source_ref.mut) return false;
    const source_array = switch (source_ref.pointee) {
        .array => |array| array,
        else => return false,
    };
    return typeEqual(source_array.elem, target_slice.elem);
}

fn rawPointeesCastCompatible(
    source_ptr: *const types.RawPtr,
    target_ptr: *const types.RawPtr,
) bool {
    const source_is_fat = (source_ptr.pointee == .slice);
    const target_is_fat = (target_ptr.pointee == .slice);
    if (target_is_fat and !source_is_fat) return false;
    return true;
}

fn isValidPrimitiveFrom(source: types.Type, target: types.Type) bool {
    const source_primitive = switch (source) {
        .prim => |primitive| primitive,
        else => return false,
    };
    const target_primitive = switch (target) {
        .prim => |primitive| primitive,
        else => return false,
    };
    const source_width = unsignedPrimitiveWidth(source_primitive) orelse return false;
    const target_width = unsignedPrimitiveWidth(target_primitive) orelse return false;
    return source_width <= target_width;
}
fn isValidCast(
    kind: exprs.ConversionKind,
    source_type: types.Type,
    target: types.Type,
    operand_type: ?types.Type,
) bool {
    const effective_source = if (operand_type) |known| blk: {
        if (std.meta.activeTag(source_type) != .unsupported and
            !isInferPlaceholderType(source_type) and
            !typeEqual(source_type, known))
        {
            return false;
        }
        break :blk known;
    } else blk: {
        if (std.meta.activeTag(source_type) == .unsupported) return false;
        break :blk source_type;
    };
    return switch (kind) {
        .as_ => switch (target) {
            .prim => |target_prim| blk: {
                if (isScalarCastType(target)) {
                    if (isScalarCastType(effective_source) or isBoolType(effective_source)) break :blk true;
                    if (effective_source == .raw_ptr and isThinRawPointer(effective_source.raw_ptr) and isIntegerPrimitive(target_prim)) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .raw_ptr => |target_ptr| switch (effective_source) {
                .raw_ptr => |source_ptr| rawPointeesCastCompatible(source_ptr, target_ptr),
                .reference => |source_ref| referenceToRawPointerCompatible(source_ref, target_ptr),
                .prim => |source_prim| isIntegerPrimitive(source_prim) and isThinRawPointer(target_ptr),
                else => false,
            },
            .slice => |target_slice| switch (effective_source) {
                .reference => |source_ref| referenceArrayToSliceCompatible(source_ref, target_slice),
                else => false,
            },
            .reference => false,
            else => false,
        },
        .primitive_from => isValidPrimitiveFrom(effective_source, target),
    };
}

fn loopCarrierElementType(ctx: *Ctx, iterable: exprs.NodeId) ?types.Type {
    if (iterable >= ctx.b.exprs.len) return null;
    const iterable_ty = getKnownType(ctx, iterable) orelse return null;
    if (chunksExactElement(iterable_ty)) |element| {
        return makeSliceType(ctx, element, false);
    }
    switch (iterable_ty) {
        .external_nominal => return iteratorItemType(ctx, iterable_ty),
        .reference => |reference| switch (reference.pointee) {
            .array => |array| return makeReferenceType(ctx, array.elem, reference.mut),
            else => {},
        },
        .slice => |slice| return makeReferenceType(ctx, slice.elem, !slice.const_),
        .array => |array| return array.elem,
        else => {},
    }
    return iteratorItemType(ctx, iterable_ty);
}

fn loopElementType(ctx: *Ctx, iterable: exprs.NodeId, iter_kind: exprs.IterKind) ?types.Type {
    if (iterable >= ctx.b.exprs.len) return null;
    switch (iter_kind) {
        .range => {
            const range_ty = getKnownType(ctx, iterable) orelse return null;
            return iteratorItemType(ctx, range_ty) orelse range_ty;
        },
        .slice => return loopCarrierElementType(ctx, iterable),
        .enumerate => {
            const element = loopCarrierElementType(ctx, iterable) orelse return null;
            const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
            tuple[0] = .{ .prim = .usize };
            tuple[1] = element;
            return .{ .tuple = tuple };
        },
        .multi => |carriers| {
            if (carriers.len == 0) return null;
            const tuple = ctx.alloc.alloc(types.Type, carriers.len) catch return null;
            for (carriers, 0..) |carrier, index| {
                tuple[index] = loopCarrierElementType(ctx, carrier) orelse return null;
            }
            return .{ .tuple = tuple };
        },
        .adapter => |chain| {
            const iterator_ty = knownIteratorChainType(ctx, chain) orelse return null;
            return iteratorItemType(ctx, iterator_ty);
        },
    }
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
/// Recover the declared return type for a call in an enclosing block tail.
/// This supplies the expected type for abstract associated calls whose
/// declaration still contains `Self` or an associated projection.
fn expectedTypeForTail(
    ctx: *Ctx,
    node: exprs.NodeId,
    fn_body: exprs.NodeId,
) ?types.Type {
    if (fn_body >= ctx.b.exprs.len) return null;
    const body_expr = ctx.b.exprs[fn_body];
    if (body_expr.kind != .block or body_expr.kind.block.tail != node) return null;
    return findFnReturnType(ctx.b, fn_body);
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
    const expected = expectedTypeForTail(ctx, node, fn_body) orelse return null;
    return switch (expected) {
        .generic_inst => |inst| if (inst.decl == def) expected else null,
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
) std.mem.Allocator.Error!bool {
    if (def >= ctx.b.bodies.len) return true;
    switch (ctx.b.bodies[def]) {
        .none => return true,
        .fn_, .struct_, .const_, .type_alias => {
            const names = getGenericParamNames(ctx, def) catch |err| switch (err) {
                error.Unsupported => return false,
                else => |allocator_error| return allocator_error,
            };
            defer ctx.alloc.free(names);
            return names.len == args.len;
        },
        .enum_, .trait_, .impl_ => return false,
    }
}

fn constrainExpectedType(
    ctx: *Ctx,
    node: exprs.NodeId,
    expected: types.Type,
) std.mem.Allocator.Error!void {
    if (node >= ctx.b.exprs.len) return;
    if (getKnownType(ctx, node)) |known| {
        if (known == .prim and known.prim == .never) return;
    }
    var target = expected;
    if (ctx.b.exprs[node].kind == .array and expected == .slice) {
        const literal = ctx.b.exprs[node].kind.array;
        const array = try ctx.alloc.create(types.Array);
        array.* = .{
            .elem = expected.slice.elem,
            .len = .{ .literal = literal.repeat orelse @intCast(literal.elements.len) },
        };
        target = .{ .array = array };
    }
    try pinKnownType(ctx, node, target);
    switch (ctx.b.exprs[node].kind) {
        .array => |array| switch (target) {
            .array => |array_type| {
                for (array.elements) |element| {
                    try constrainExpectedType(ctx, element, array_type.elem);
                }
            },
            .tuple => |elements| {
                if (array.repeat != null or array.elements.len != elements.len) return;
                for (array.elements, elements) |element, element_type| {
                    try constrainExpectedType(ctx, element, element_type);
                }
            },
            else => {},
        },
        .unary => |unary| {
            if (unary.op == .ref) {
                switch (target) {
                    .reference => |reference| try constrainExpectedType(ctx, unary.operand, reference.pointee),
                    .slice => {
                        if (unary.operand < ctx.b.exprs.len and ctx.b.exprs[unary.operand].kind == .array) {
                            try constrainExpectedType(ctx, unary.operand, target);
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn constrainConcreteArguments(
    ctx: *Ctx,
    definition: bodies.BodyKind,
    args: []const exprs.NodeId,
    fields: []const exprs.FieldInit,
) std.mem.Allocator.Error!void {
    switch (definition) {
        .fn_ => |function| {
            if (args.len != function.params.len) return;
            for (args, function.params) |arg, param| {
                try constrainExpectedType(ctx, arg, param.ty);
            }
        },
        .struct_ => |structure| {
            if (fields.len != 0) {
                for (fields) |field| {
                    for (structure.fields) |declared| {
                        if (!std.mem.eql(u8, field.field, declared.name)) continue;
                        try constrainExpectedType(ctx, field.value, declared.ty);
                        break;
                    }
                }
            } else if (args.len == structure.fields.len) {
                for (args, structure.fields) |arg, field| {
                    try constrainExpectedType(ctx, arg, field.ty);
                }
            }
        },
        else => {},
    }
}

/// Walk a free/associated/constructor call: recurse into args and, when the
/// callee is generic, unify argument types with instantiated parameter types.
fn handleCall(ctx: *Ctx, node: exprs.NodeId, c: exprs.Call, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    for (c.args) |a| try walkExpr(ctx, a, fn_body);
    const def = callDefinition(c);
    const expected_type = expectedTypeForTail(ctx, node, fn_body);
    if (expected_type) |expected| {
        try ctx.expected_types.put(ctx.alloc, node, expected);
    }
    const expected_generic = expectedGenericTypeForTail(ctx, node, fn_body, def);
    const explicit: ?types.GenericArgs = if (explicitArgsForNode(ctx, node)) |args|
        args
    else if (expected_generic) |expected|
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
    if (expected_type) |expected| try pinKnownType(ctx, node, expected);
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
    const caller_names = getGenericParamNames(ctx, def) catch |err| switch (err) {
        error.Unsupported => return,
        else => |allocator_error| return allocator_error,
    };
    defer ctx.alloc.free(caller_names);

    var ret_ty: ?types.Type = null;
    switch (ctx.b.bodies[def]) {
        .fn_ => |fb| ret_ty = fb.ret,
        .struct_ => if (caller_names.len == 0) {
            ret_ty = nominalTypeForDefinition(ctx, node, def);
        },
        else => return,
    }

    // Preserve concrete constructor types through local bindings.
    if (caller_names.len == 0) {
        try constrainConcreteArguments(ctx, ctx.b.bodies[def], args, fields);
        if (ret_ty) |return_ty| try pinKnownType(ctx, node, return_ty);
        return;
    }
    const param_names = caller_names;

    const inferred_args = try ctx.alloc.alloc(?types.Type, param_names.len);
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

    const concrete_args = try ctx.alloc.alloc(types.Type, param_names.len);
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

fn freeSubstitutedBounds(
    alloc: std.mem.Allocator,
    original: []const types.Bound,
    substituted: []const types.Bound,
    param_names: []const []const u8,
    args: []const types.Type,
) void {
    if (original.len != substituted.len) return;
    for (original, substituted) |original_bound, substituted_bound| {
        if (original_bound.args.len == substituted_bound.args.len) {
            for (original_bound.args, substituted_bound.args) |original_arg, substituted_arg| {
                freeSubstitutedType(alloc, original_arg, substituted_arg, param_names, args);
            }
        }
        if (substituted_bound.args.len > 0) alloc.free(substituted_bound.args);
        if (original_bound.associated_types.len == substituted_bound.associated_types.len) {
            for (original_bound.associated_types, substituted_bound.associated_types) |
                original_binding,
                substituted_binding,
            | {
                freeSubstitutedType(
                    alloc,
                    original_binding.ty,
                    substituted_binding.ty,
                    param_names,
                    args,
                );
            }
        }
        if (substituted_bound.associated_types.len > 0) alloc.free(substituted_bound.associated_types);
    }
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
            if (!typeEqual(sub_boxed.*, boxed.*)) alloc.destroy(sub_boxed);
        },
        .@"opaque" => |opaque_type| {
            const sub_opaque = switch (substituted) {
                .@"opaque" => |value| value,
                else => return,
            };
            freeSubstitutedBounds(alloc, opaque_type.bounds, sub_opaque.bounds, param_names, args);
            if (sub_opaque.bounds.len > 0) alloc.free(sub_opaque.bounds);
            if (sub_opaque.concrete) |sub_concrete| {
                if (opaque_type.concrete) |original_concrete| {
                    freeSubstitutedType(
                        alloc,
                        original_concrete.*,
                        sub_concrete.*,
                        param_names,
                        args,
                    );
                }
                alloc.destroy(sub_concrete);
            }
        },
        .dyn_trait => |bounds| {
            const sub_bounds = switch (substituted) {
                .dyn_trait => |value| value,
                else => return,
            };
            freeSubstitutedBounds(alloc, bounds, sub_bounds, param_names, args);
            if (sub_bounds.len > 0) alloc.free(sub_bounds);
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
        .external_nominal => |external| {
            const sub_external = switch (substituted) {
                .external_nominal => |value| value,
                else => return,
            };
            if (sub_external.args.len != external.args.len) return;
            var changed = false;
            for (external.args, sub_external.args) |original_arg, substituted_arg| {
                freeSubstitutedType(alloc, original_arg, substituted_arg, param_names, args);
                if (!typeEqual(original_arg, substituted_arg)) changed = true;
            }
            if (changed) alloc.free(sub_external.args);
        },
        .prim, .path, .unsupported => {},
    }
}
fn pinKnownType(ctx: *Ctx, node: exprs.NodeId, known: types.Type) std.mem.Allocator.Error!void {
    const entry = try ctx.known_nodes.getOrPut(ctx.alloc, node);
    if (!entry.found_existing or
        (entry.value_ptr.* == .generic_inst and known != .generic_inst) or
        (isInferPlaceholderType(entry.value_ptr.*) and !isInferPlaceholderType(known)))
    {
        entry.value_ptr.* = known;
    }
    if (findTypeIndex(ctx.b, known)) |type_id| {
        try addPin(ctx, node, type_id);
    } else {
        ctx.recordDerivedType(node, known);
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
        .external_nominal => |external| {
            for (external.args) |arg| {
                if (typeContainsParam(arg, param_names)) return true;
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
        .@"opaque" => |opaque_type| {
            if (opaque_type.concrete) |concrete| {
                if (typeContainsParam(concrete.*, param_names)) return true;
            }
            return boundsContainParam(opaque_type.bounds, param_names);
        },
        .dyn_trait => |bounds| return boundsContainParam(bounds, param_names),
    }
}

fn boundsContainParam(bounds: []const types.Bound, param_names: []const []const u8) bool {
    for (bounds) |bound| {
        for (bound.args) |arg| {
            if (typeContainsParam(arg, param_names)) return true;
        }
        for (bound.associated_types) |binding| {
            if (typeContainsParam(binding.ty, param_names)) return true;
        }
    }
    return false;
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
        } else {
            ctx.recordDerivedType(node, local_ty);
        }
    }
}

/// Parse a valid assertion marker and return its referenced expression node.
fn parseAssertionCondition(reason: []const u8, expr_count: usize) ?exprs.NodeId {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, reason, prefix)) return null;

    const suffix = reason[prefix.len..];
    if (suffix.len == 0) return null;
    for (suffix) |character| {
        if (character < '0' or character > '9') return null;
    }

    const condition = std.fmt.parseInt(exprs.NodeId, suffix, 10) catch return null;
    if (condition >= expr_count) return null;
    return condition;
}

fn constrainCompoundAssignment(
    ctx: *Ctx,
    target: exprs.NodeId,
    value: exprs.NodeId,
) std.mem.Allocator.Error!void {
    const target_ty = getKnownType(ctx, target);
    const value_ty = getKnownType(ctx, value);
    if (target_ty) |known_target| {
        if (value_ty) |known_value| {
            if (typeEqual(known_target, known_value)) {
                try addEq(ctx, target, value);
            }
        } else {
            try constrainExpectedType(ctx, value, known_target);
        }
    } else if (value_ty) |known_value| {
        try constrainExpectedType(ctx, target, known_value);
    } else {
        try addEq(ctx, target, value);
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
                try explicitArgsMatchSignature(ctx, p.def, p.generic_args))
            {
                try addInstantiation(ctx, node, .{
                    .generic_id = p.def,
                    .args = .{ .params = p.generic_args },
                    .zig_suffix = "",
                });
            }
        },
        .block => {
            try walkBlock(ctx, e.kind.block, fn_body, node);
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        },
        .if_else => |ie| try walkIf(ctx, node, ie, fn_body),
        .if_let => |il| {
            try walkExpr(ctx, il.scrutinee, fn_body);
            try bindPattern(ctx, il.pattern, null, getKnownType(ctx, il.scrutinee));
            try walkBlock(ctx, il.then_, fn_body, null);
            switch (il.@"else") {
                .none => {},
                .block => |blk| try walkBlock(ctx, blk, fn_body, null),
                .chain => |n| try walkExpr(ctx, n, fn_body),
            }
        },
        .match => |m| try walkMatch(ctx, node, m, fn_body),
        .loop_ => |l| {
            const previous_loop = ctx.loop_result;
            ctx.loop_result = node;
            defer ctx.loop_result = previous_loop;
            try walkBlock(ctx, l.body, fn_body, null);
        },
        .while_ => |w| {
            if (w.capture == null) try pinKnownType(ctx, w.cond, .{ .prim = .bool });
            try walkExpr(ctx, w.cond, fn_body);
            if (w.capture) |capture| {
                try bindPattern(ctx, capture, null, getKnownType(ctx, w.cond));
            }
            try walkBlock(ctx, w.body, fn_body, null);
        },
        .for_ => |f| {
            try walkExpr(ctx, f.iterable, fn_body);
            switch (f.iter_kind) {
                .range, .slice, .enumerate => {},
                .multi => |ids| for (ids) |id| {
                    if (id != f.iterable) try walkExpr(ctx, id, fn_body);
                },
                .adapter => |chain| try walkIteratorChain(ctx, chain, fn_body),
            }
            const element_ty = loopElementType(ctx, f.iterable, f.iter_kind);
            try bindPattern(ctx, f.pattern, null, element_ty);
            try walkBlock(ctx, f.body, fn_body, null);
        },
        .break_ => |br| {
            if (br.value) |v| {
                try walkExpr(ctx, v, fn_body);
                if (ctx.loop_result) |loop| try addEq(ctx, loop, v);
            }
            try pinKnownType(ctx, node, .{ .prim = .never });
        },
        .continue_ => try pinKnownType(ctx, node, .{ .prim = .never }),
        .call => |c| {
            try handleCall(ctx, node, c, fn_body);
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        },
        .core_call => try walkCoreCall(ctx, node, fn_body),
        .core_function => |function| {
            for (function.generic_args) |argument| try walkTypeExpressions(ctx, argument, fn_body);
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
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
        .external_variant => |variant| {
            for (variant.tuple_fields) |field| try walkExpr(ctx, field, fn_body);
            for (variant.named_fields) |field| try walkExpr(ctx, field.value, fn_body);
            if (expectedTypeForTail(ctx, node, fn_body)) |expected| {
                try constrainExpectedType(ctx, node, expected);
            } else if (getKnownType(ctx, node)) |known| {
                try pinKnownType(ctx, node, known);
            }
        },
        .field => |f| {
            try walkExpr(ctx, f.base, fn_body);
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        },
        .index => |ix| {
            try walkExpr(ctx, ix.base, fn_body);
            try walkExpr(ctx, ix.index, fn_body);
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        },
        .cast => |cast| {
            if (cast.target < ctx.b.types.len) try walkTypeExpressions(ctx, ctx.b.types[cast.target], fn_body);
            try walkTypeExpressions(ctx, cast.source_type, fn_body);
            try walkExpr(ctx, cast.operand, fn_body);
            const source = getKnownType(ctx, cast.operand);
            var source_type = cast.source_type;
            if (source) |known_source| {
                // CST lowering cannot know loop-capture types. Resolve the
                // transient source after the local/pattern environment has
                // been walked, then persist it on the cast itself.
                if (std.meta.activeTag(source_type) == .unsupported) {
                    @constCast(ctx.b.exprs)[node].kind.cast.source_type = known_source;
                    source_type = known_source;
                }
            }
            if (cast.target >= ctx.b.types.len) {
                try ctx.g.invalid_casts.append(ctx.alloc, node);
            } else {
                var target = ctx.b.types[cast.target];
                var source_for_target = source orelse source_type;
                if (resolveWildcardRawPointerSource(ctx, source_type, target)) |resolved| {
                    source_for_target = resolved;
                    source_type = resolved;
                    @constCast(ctx.b.exprs)[node].kind.cast.source_type = resolved;
                } else if (resolveWildcardRawPointerSource(ctx, source_for_target, target)) |resolved| {
                    source_for_target = resolved;
                    source_type = resolved;
                    @constCast(ctx.b.exprs)[node].kind.cast.source_type = resolved;
                }
                if (resolveWildcardRawPointerTarget(ctx, source_for_target, target)) |resolved| {
                    @constCast(ctx.b.types)[cast.target] = resolved;
                    target = resolved;
                }
                if (isInferPlaceholderType(target)) {
                    // Infer an `as _` destination from surrounding constraints
                    // during solving; never reuse the source type as a target.
                } else if (source == null and
                    std.meta.activeTag(source_type) == .unsupported)
                {
                    // Keep casts whose operand type depends on an earlier
                    // projection/local binding for the solved-type pass below.
                } else if (!isValidCast(
                    cast.kind,
                    source_type,
                    target,
                    if (source != null) source_for_target else null,
                )) {
                    try ctx.g.invalid_casts.append(ctx.alloc, node);
                } else {
                    try addPin(ctx, node, cast.target);
                }
            }
        },
        .binary => |bin| try walkBinary(ctx, node, bin, fn_body),
        .unary => |u| {
            try walkExpr(ctx, u.operand, fn_body);
            switch (u.op) {
                .negate, .bit_not => try addEq(ctx, u.operand, node),
                .logical_not => {
                    if (getKnownType(ctx, u.operand)) |op_ty| {
                        if (isIntegerType(op_ty)) {
                            try addEq(ctx, u.operand, node);
                        } else {
                            try pinKnownType(ctx, u.operand, .{ .prim = .bool });
                            try pinKnownType(ctx, node, .{ .prim = .bool });
                        }
                    } else {
                        try addEq(ctx, u.operand, node);
                    }
                },
                .deref => {
                    if (getKnownType(ctx, node)) |known| {
                        if (findTypeIndex(ctx.b, known)) |type_id| {
                            try addPin(ctx, node, type_id);
                        } else {
                            ctx.recordDerivedType(node, known);
                        }
                    }
                },
                .ref => if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known),
            }
        },
        .assign => |a| {
            try walkExpr(ctx, a.target, fn_body);
            try walkExpr(ctx, a.value, fn_body);
            switch (a.op) {
                .plain => try addEq(ctx, a.target, a.value),
                .add, .sub, .mul, .div, .rem, .bit_and, .bit_or, .bit_xor, .shl, .shr => try constrainCompoundAssignment(ctx, a.target, a.value),
            }
            try pinKnownType(ctx, node, .{ .prim = .unit });
        },
        .try_ => |t| {
            try walkExpr(ctx, t.inner, fn_body);
            if (getKnownType(ctx, t.inner)) |inner_ty| {
                if (unwrapTryType(inner_ty)) |unwrapped_ty| {
                    if (findTypeIndex(ctx.b, unwrapped_ty)) |tid| {
                        try addPin(ctx, node, tid);
                    } else {
                        ctx.recordDerivedType(node, unwrapped_ty);
                    }
                }
            }
        },
        .return_ => |r| {
            if (r.value) |v| {
                try walkExpr(ctx, v, fn_body);
                try addRet(ctx, v, fn_body);
                try addEq(ctx, node, v);
                // A declared return type that is not already interned (such as
                // `Option<u32>`) never reaches the solver's `ret` edge, so pin
                // the value here instead. Without this, a bare `return None;`
                // reaches the backend untyped.
                if (findFnReturnType(ctx.b, fn_body)) |ret_ty| {
                    try constrainExpectedType(ctx, v, ret_ty);
                }
            }
        },
        .closure => |closure| try walkClosure(ctx, closure, fn_body),
        .iterator_chain => |chain| {
            try walkIteratorChain(ctx, chain, fn_body);
            if (getKnownType(ctx, node)) |known| {
                if (findTypeIndex(ctx.b, known)) |type_id| {
                    try addPin(ctx, node, type_id);
                } else {
                    ctx.recordDerivedType(node, known);
                }
            }
        },
        .format_write => |format| {
            try walkExpr(ctx, format.writer, fn_body);
            for (format.args) |arg| try walkExpr(ctx, arg, fn_body);
        },
        .unsupported => |unsupported| {
            if (parseAssertionCondition(unsupported.reason, ctx.b.exprs.len)) |condition| {
                if (condition != node) try walkExpr(ctx, condition, fn_body);
            }
        },
        .array => |a| for (a.elements) |el| try walkExpr(ctx, el, fn_body),
        .vec_lit => |vec| for (vec.elements) |el| try walkExpr(ctx, el, fn_body),
        .range => |range| {
            try walkExpr(ctx, range.start, fn_body);
            if (range.end) |end| {
                try walkExpr(ctx, end, fn_body);
                try addEq(ctx, range.start, end);
            }
            if (getKnownType(ctx, node)) |known| {
                try pinKnownType(ctx, node, known);
            }
        },
        .panic_ => try pinKnownType(ctx, node, .{ .prim = .never }),
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

/// Rust method-call arguments exclude the receiver, while the declaration keeps
/// it as the first parameter. Constrain each argument against the matching
/// declared parameter so literals such as `&[0; 32]` receive their element type.
fn constrainInherentMethodArguments(
    ctx: *Ctx,
    method_name: []const u8,
    receiver_ty: ?types.Type,
    args: []const exprs.NodeId,
) std.mem.Allocator.Error!void {
    const cg = ctx.cg orelse return;
    const known_receiver = receiver_ty orelse return;
    const type_name = canonicalReceiverName(ctx, known_receiver) orelse return;
    const method_def =
        resolve_methods.lookupInherentMethod(cg, type_name, method_name) orelse return;
    if (method_def >= ctx.b.bodies.len) return;
    const function = switch (ctx.b.bodies[method_def]) {
        .fn_ => |fn_body| fn_body,
        else => return,
    };
    const params = function.params;
    const offset: usize = if (params.len == args.len + 1) 1 else 0;
    if (params.len != args.len + offset) return;
    for (args, params[offset..]) |arg, param| {
        try constrainExpectedType(ctx, arg, param.ty);
    }
}

fn walkMethodCall(ctx: *Ctx, node: exprs.NodeId, m: exprs.MethodCall, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    const m_name = getMethodName(ctx, m.method) orelse {
        try walkExpr(ctx, m.receiver, fn_body);
        for (m.args) |a| try walkExpr(ctx, a, fn_body);
        return;
    };
    try walkExpr(ctx, m.receiver, fn_body);
    const receiver_ty = getKnownType(ctx, m.receiver);
    for (m.args) |a| {
        if (receiver_ty) |known_receiver| {
            if (methodClosureInputType(m_name, known_receiver)) |input_ty| {
                if (a < ctx.b.exprs.len and ctx.b.exprs[a].kind == .closure) {
                    try walkClosureTyped(ctx, ctx.b.exprs[a].kind.closure, fn_body, input_ty);
                    continue;
                }
            }
        }
        try walkExpr(ctx, a, fn_body);
    }
    try constrainInherentMethodArguments(ctx, m_name, receiver_ty, m.args);
    if (std.mem.eql(u8, m_name, "ok")) {
        if (receiver_ty) |known_receiver| {
            if (resultPayloadType(known_receiver, false)) |ok_payload| {
                if (makeOptionLike(ctx, known_receiver, ok_payload)) |option_result| {
                    try pinKnownType(ctx, node, option_result);
                }
            }
        }
        return;
    }
    if (receiver_ty) |known_receiver| {
        if (knownAllocMethodType(ctx, known_receiver, m_name)) |alloc_result| {
            try pinKnownType(ctx, node, alloc_result);
            return;
        }
        if (knownBoundMethodReturnType(ctx, known_receiver, m_name, m.method)) |bound_result| {
            try pinKnownType(ctx, node, bound_result);
            return;
        }
        if ((std.mem.eql(u8, m_name, "as_ref") or std.mem.eql(u8, m_name, "take")) and
            optionPayloadType(known_receiver) != null)
        {
            if (getKnownType(ctx, node)) |option_result| {
                try pinKnownType(ctx, node, option_result);
                return;
            }
        }
    }
    if (receiver_ty) |known_receiver| {
        if (knownIoMethodResultType(ctx, known_receiver, m_name)) |io_result| {
            try pinKnownType(ctx, node, io_result);
            return;
        }
    }
    if (receiver_ty) |known_receiver| {
        if (knownIteratorMethodType(ctx, m_name, known_receiver, m.args)) |iterator_ty| {
            try pinKnownType(ctx, node, iterator_ty);
            return;
        }
    }

    // .len() -> usize for slices, arrays, and canonical iterators.
    if (std.mem.eql(u8, m_name, "len")) {
        if (receiver_ty) |known_receiver| {
            if (isLenReceiverType(known_receiver) or
                iteratorItemType(ctx, known_receiver) != null)
            {
                try pinKnownType(ctx, node, .{ .prim = .usize });
            }
        }
        return;
    }
    if (std.mem.eql(u8, m_name, "map") or
        std.mem.eql(u8, m_name, "map_err") or
        std.mem.eql(u8, m_name, "and_then"))
    {
        if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        return;
    }
    if (std.mem.eql(u8, m_name, "as_ptr") or
        std.mem.eql(u8, m_name, "as_mut_ptr") or
        std.mem.eql(u8, m_name, "get_unchecked") or
        std.mem.eql(u8, m_name, "get_unchecked_mut"))
    {
        if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        return;
    }

    if (std.mem.eql(u8, m_name, "split_at") or
        std.mem.eql(u8, m_name, "chunks_exact") or
        std.mem.eql(u8, m_name, "remainder"))
    {
        if (getKnownType(ctx, node)) |known| {
            if (findTypeIndex(ctx.b, known)) |type_id| {
                try addPin(ctx, node, type_id);
            } else {
                ctx.recordDerivedType(node, known);
            }
        }
        return;
    }

    // .clone()/.by_ref() -> infer return type as self type.
    if (std.mem.eql(u8, m_name, "clone") or std.mem.eql(u8, m_name, "by_ref")) {
        try addEq(ctx, m.receiver, node);
        return;
    }
    if (std.mem.eql(u8, m_name, "to_le") or
        std.mem.eql(u8, m_name, "to_be") or
        std.mem.eql(u8, m_name, "from_le") or
        std.mem.eql(u8, m_name, "from_be") or
        std.mem.eql(u8, m_name, "swap_bytes"))
    {
        try addEq(ctx, m.receiver, node);
        return;
    }

    if (std.mem.eql(u8, m_name, "offset") or
        std.mem.eql(u8, m_name, "wrapping_offset") or
        std.mem.eql(u8, m_name, "add") or
        std.mem.eql(u8, m_name, "sub") or
        std.mem.eql(u8, m_name, "wrapping_add") or
        std.mem.eql(u8, m_name, "wrapping_sub"))
    {
        if (getKnownType(ctx, m.receiver)) |recv_ty| {
            if (recv_ty == .raw_ptr) {
                try addEq(ctx, m.receiver, node);
                return;
            }
        }
    }

    if (std.mem.eql(u8, m_name, "read") or
        std.mem.eql(u8, m_name, "read_unaligned") or
        std.mem.eql(u8, m_name, "read_volatile") or
        std.mem.eql(u8, m_name, "next") or
        std.mem.eql(u8, m_name, "next_back") or
        std.mem.eql(u8, m_name, "nth") or
        std.mem.eql(u8, m_name, "nth_back") or
        std.mem.eql(u8, m_name, "last") or
        std.mem.eql(u8, m_name, "count") or
        std.mem.eql(u8, m_name, "size_hint") or
        std.mem.eql(u8, m_name, "to_digit"))
    {
        if (getKnownType(ctx, node)) |known| {
            if (findTypeIndex(ctx.b, known)) |type_id| {
                try addPin(ctx, node, type_id);
            } else {
                ctx.recordDerivedType(node, known);
            }
        }
        return;
    }

    // .as_ref(), .as_bytes(), .borrow(), .as_slice() -> infer return type as slice ([]const u8 or []T)
    if (std.mem.eql(u8, m_name, "as_ref") or
        std.mem.eql(u8, m_name, "as_bytes") or
        std.mem.eql(u8, m_name, "borrow") or
        std.mem.eql(u8, m_name, "as_slice") or
        std.mem.eql(u8, m_name, "as_mut_slice"))
    {
        if (getKnownType(ctx, m.receiver)) |recv_ty| {
            if (std.mem.eql(u8, m_name, "as_slice") or
                std.mem.eql(u8, m_name, "as_mut_slice"))
            {
                if (sliceIteratorElementType(recv_ty)) |element| {
                    if (makeSliceType(
                        ctx,
                        element,
                        std.mem.eql(u8, m_name, "as_mut_slice"),
                    )) |slice_type| {
                        try pinKnownType(ctx, node, slice_type);
                        return;
                    }
                }
            }

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
    if (receiver_ty) |known_receiver| {
        if (knownDeclaredMethodReturnType(ctx, known_receiver, m_name)) |return_type| {
            try pinKnownType(ctx, node, return_type);
        }
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
            .none, .const_, .struct_, .enum_, .trait_, .impl_, .type_alias => {},
        }
    }
    if (g.derived_error) return error.OutOfMemory;
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

fn isNeverTypeId(type_list: []const types.Type, type_id: ?exprs.TypeId) bool {
    const id = type_id orelse return false;
    if (id >= type_list.len) return false;
    return switch (type_list[id]) {
        .prim => |primitive| primitive == .never,
        else => false,
    };
}

fn unionNodes(
    parent: []exprs.NodeId,
    rank: []u8,
    concrete: []?exprs.TypeId,
    classes: []Class,
    type_list: []const types.Type,
    a: exprs.NodeId,
    b: exprs.NodeId,
) void {
    if (a >= parent.len or b >= parent.len) return;
    const root_a = findRoot(parent, a);
    const root_b = findRoot(parent, b);
    if (root_a == root_b) return;

    // `never` is the bottom type. It participates in an equality edge as a
    // diverging operand, but must not erase a reachable type from the other
    // operand. Keep the per-node bottom marker for the result pass below.
    const merged_concrete = if (isNeverTypeId(type_list, concrete[root_a]))
        concrete[root_b] orelse concrete[root_a]
    else
        concrete[root_a] orelse concrete[root_b];
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

fn findFnReturnType(b: *const bodies.Bodies, body_node: exprs.NodeId) ?types.Type {
    for (b.bodies) |bk| {
        switch (bk) {
            .fn_ => |fb| {
                if (fb.body == body_node) {
                    return fb.ret;
                }
            },
            else => {},
        }
    }
    return null;
}

fn findFnRetTypeId(b: *const bodies.Bodies, body_node: exprs.NodeId) ?exprs.TypeId {
    const result = findFnReturnType(b, body_node) orelse return null;
    return findTypeIndex(b, result);
}
fn resolvedTypeAt(
    b: *const bodies.Bodies,
    result_types: []const ?exprs.TypeId,
    node: exprs.NodeId,
) ?types.Type {
    if (node < result_types.len) {
        if (result_types[node]) |type_id| {
            if (type_id < b.types.len) return b.types[type_id];
        }
    }
    if (node < b.exprs.len) {
        if (b.exprs[node].ty) |type_id| {
            if (type_id < b.types.len) return b.types[type_id];
        }
    }
    return null;
}

fn corePointerPointee(ty: types.Type) ?types.Type {
    return switch (ty) {
        .raw_ptr => |pointer| pointer.pointee,
        .reference => |reference| reference.pointee,
        else => null,
    };
}

/// Resolve an omitted core generic from solved operand/result types. This
/// deliberately has no primitive fallback: an omitted argument is valid only
/// when the surrounding constraints provide a real type.
fn coreTypeArgumentFromSolved(
    b: *const bodies.Bodies,
    result_types: []const ?exprs.TypeId,
    node: exprs.NodeId,
    call: exprs.CoreCall,
) ?types.Type {
    if (call.generic_args.len != 0) return null;
    const result_ty = resolvedTypeAt(b, result_types, node);
    switch (call.function) {
        .default_value, .convert_from => return result_ty,
        .cmp_min, .cmp_max => {
            if (result_ty) |known| return known;
            if (call.args.len > 0) {
                if (resolvedTypeAt(b, result_types, call.args[0])) |known| return known;
            }
            if (call.args.len > 1) return resolvedTypeAt(b, result_types, call.args[1]);
            return null;
        },
        .mem_size_of_val => {
            if (call.args.len == 0) return null;
            const argument = resolvedTypeAt(b, result_types, call.args[0]) orelse return null;
            return switch (argument) {
                .reference => |reference| reference.pointee,
                .slice, .array => argument,
                else => null,
            };
        },
        .ptr_copy_nonoverlapping, .ptr_write_bytes => {
            if (call.args.len == 0) return null;
            const argument = resolvedTypeAt(b, result_types, call.args[0]) orelse return null;
            return corePointerPointee(argument);
        },
        .ptr_read_unaligned => {
            if (result_ty) |known| return known;
            if (call.args.len == 0) return null;
            const argument = resolvedTypeAt(b, result_types, call.args[0]) orelse return null;
            return corePointerPointee(argument);
        },
        .slice_from_raw_parts, .slice_from_raw_parts_mut => {
            if (result_ty) |known| {
                if (known == .slice) return known.slice.elem;
            }
            if (call.args.len == 0) return null;
            const argument = resolvedTypeAt(b, result_types, call.args[0]) orelse return null;
            return corePointerPointee(argument);
        },
        else => return null,
    }
}

fn finalizeCoreCallTypeArguments(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    result_types: []const ?exprs.TypeId,
) !void {
    for (b.exprs, 0..) |expression, node| {
        if (expression.kind != .core_call) continue;
        const call = &@constCast(b.exprs)[node].kind.core_call;
        if (call.generic_args.len != 0) continue;
        if (coreTypeArgumentFromSolved(b, result_types, @intCast(node), call.*)) |argument| {
            call.generic_args = try alloc.dupe(types.Type, &.{argument});
        }
    }
}

/// Run unification solver on pre-computed constraint Gen over `b`.
pub fn solveWithGen(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    g: *const Gen,
) !Inferred {
    if (g.invalid_casts.items.len > 0) return error.InvalidCast;
    const num_exprs = b.exprs.len;
    if (num_exprs == 0) {
        // Zero exprs: still hand over any recorded instantiations (rare no-body case).
        const result_types = try alloc.alloc(?exprs.TypeId, 0);
        errdefer alloc.free(result_types);
        return .{
            .types = result_types,
            .instantiations = try cloneInstantiationMap(alloc, g.instantiations),
        };
    }

    const parent = try alloc.alloc(exprs.NodeId, num_exprs);
    defer alloc.free(parent);
    const rank = try alloc.alloc(u8, num_exprs);
    defer alloc.free(rank);
    const concrete = try alloc.alloc(?exprs.TypeId, num_exprs);
    defer alloc.free(concrete);
    const bottom = try alloc.alloc(bool, num_exprs);
    defer alloc.free(bottom);
    const classes = try alloc.alloc(Class, num_exprs);
    defer alloc.free(classes);

    for (0..num_exprs) |i| {
        parent[i] = @intCast(i);
        rank[i] = 0;
        concrete[i] = b.exprs[i].ty;
        bottom[i] = isNeverTypeId(b.types, concrete[i]);
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
            if (isNeverTypeId(b.types, p.ty)) bottom[p.node] = true;
        }
    }

    // Unify equivalence edges.
    for (g.edges.items) |e| {
        switch (e) {
            .eq => |eq_edge| {
                unionNodes(
                    parent,
                    rank,
                    concrete,
                    classes,
                    b.types,
                    eq_edge.a,
                    eq_edge.b,
                );
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
    errdefer alloc.free(result_types);
    const never_type_id = primTypeId(b, .never);
    for (0..num_exprs) |i| {
        const root = findRoot(parent, @intCast(i));
        result_types[i] = if (bottom[i]) never_type_id orelse concrete[root] else concrete[root];
    }

    // Core generic arguments may become knowable only after unification has
    // applied a return-type or assignment constraint.
    try finalizeCoreCallTypeArguments(alloc, b, result_types);

    for (b.exprs, 0..) |expression, node| {
        const cast = switch (expression.kind) {
            .cast => |value| value,
            else => continue,
        };
        if (cast.target >= b.types.len) {
            return error.InvalidCast;
        }
        const target_is_placeholder = isInferPlaceholderType(b.types[cast.target]);
        if (std.meta.activeTag(cast.source_type) != .unsupported and !target_is_placeholder) {
            continue;
        }

        const source_type_id: ?exprs.TypeId = if (std.meta.activeTag(cast.source_type) == .unsupported)
            if (cast.operand < result_types.len) result_types[cast.operand] else null
        else
            findTypeIndex(b, cast.source_type);
        const resolved_source_id = source_type_id orelse blk: {
            if (cast.operand < b.exprs.len) {
                const operand_type = b.exprs[cast.operand].ty orelse return error.InvalidCast;
                break :blk operand_type;
            }
            return error.InvalidCast;
        };

        const resolved_target_id: ?exprs.TypeId = if (!target_is_placeholder)
            cast.target
        else blk: {
            const candidate = if (node < result_types.len)
                result_types[node]
            else
                null;
            if (candidate) |candidate_id| {
                if (candidate_id < b.types.len and
                    !isInferPlaceholderType(b.types[candidate_id]) and
                    isConcreteDerivedType(b.types[candidate_id]))
                {
                    break :blk candidate_id;
                }
            }
            if (node < b.exprs.len) {
                if (b.exprs[node].ty) |candidate_id| {
                    if (candidate_id < b.types.len and
                        !isInferPlaceholderType(b.types[candidate_id]) and
                        isConcreteDerivedType(b.types[candidate_id]))
                    {
                        break :blk candidate_id;
                    }
                }
            }
            break :blk null;
        };
        const final_target_id = resolved_target_id orelse return error.InvalidCast;
        if (resolved_source_id >= b.types.len or final_target_id >= b.types.len) {
            return error.InvalidCast;
        }
        const source_type = if (std.meta.activeTag(cast.source_type) == .unsupported)
            b.types[resolved_source_id]
        else
            cast.source_type;
        const target_type = b.types[final_target_id];
        if (target_is_placeholder) {
            @constCast(b.types)[cast.target] = target_type;
        }
        @constCast(b.exprs)[node].kind.cast.source_type = source_type;
        if (!isValidCast(cast.kind, source_type, target_type, source_type)) {
            return error.InvalidCast;
        }
    }
    return .{
        .types = result_types,
        .instantiations = try cloneInstantiationMap(alloc, g.instantiations),
    };
}

/// Generate constraints and run full unification solver with defaults on `b`.
pub fn solve(alloc: std.mem.Allocator, b: *const bodies.Bodies) !Inferred {
    return solveWithGraph(alloc, b, null);
}

pub fn solveWithGraph(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    cg: ?*const graph.CrateGraph,
) !Inferred {
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
const CastInferenceFixture = struct {
    b: bodies.Bodies,
    graph_store: graph.CrateGraph,
    cast_id: exprs.NodeId,
    expected_source: types.Type,
    expected_kind: exprs.ConversionKind,
};

fn pendingCastSourceTypeForTest() types.Type {
    return .{ .unsupported = .{
        .reason = .iterators,
        .message = "cast source type pending inference",
        .span = test_span,
    } };
}

fn makeCastInferenceFixture(
    alloc: std.mem.Allocator,
    source_primitive: types.Prim,
    target_primitive: types.Prim,
    indexed_source: bool,
    conversion_kind: exprs.ConversionKind,
) !CastInferenceFixture {
    var graph_store = graph.CrateGraph.init(alloc);
    errdefer graph_store.deinit();
    const function_name = try alloc.dupe(u8, "primitive_cast");
    const function_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = function_name,
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    std.debug.assert(function_id == 0);
    const value_name = try alloc.dupe(u8, if (indexed_source) "bytes" else "value");
    const value_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = value_name,
        .span = test_span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    std.debug.assert(value_id == 1);

    const type_count: usize = if (indexed_source) 3 else 2;
    const types_store = try alloc.alloc(types.Type, type_count);
    const source_type: types.Type = .{ .prim = source_primitive };
    types_store[1] = .{ .prim = target_primitive };
    var expected_source = source_type;
    var parameter_type = source_type;
    if (indexed_source) {
        const slice = try alloc.create(types.Slice);
        slice.* = .{ .const_ = true, .elem = source_type };
        parameter_type = .{ .slice = slice };
        types_store[0] = parameter_type;
        types_store[2] = source_type;
        expected_source = types_store[2];
    } else {
        types_store[0] = source_type;
    }

    const parameter_name: []const u8 = if (indexed_source) "bytes" else "value";
    const params = try alloc.alloc(items.Param, 1);
    params[0] = .{ .name = parameter_name, .ty = parameter_type, .span = test_span };

    const expression_count: usize = if (indexed_source) 5 else 3;
    const exprs_store = try alloc.alloc(exprs.Expr, expression_count);
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .path = .{ .def = value_id, .generic_args = &.{} } },
    };
    var operand_id: exprs.NodeId = 0;
    var cast_id: exprs.NodeId = 1;
    var block_id: exprs.NodeId = 2;
    if (indexed_source) {
        exprs_store[1] = .{
            .id = 1,
            .span = test_span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "0",
                .value = 0,
                .base = .dec,
                .ty_suffix = null,
            } } },
        };
        exprs_store[2] = .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .index = .{ .base = 0, .index = 1 } },
        };
        operand_id = 2;
        cast_id = 3;
        block_id = 4;
    }
    exprs_store[cast_id] = .{
        .id = cast_id,
        .span = test_span,
        .ty = 1,
        .kind = .{ .cast = .{
            .kind = conversion_kind,
            .operand = operand_id,
            .source_type = pendingCastSourceTypeForTest(),
            .target = 1,
        } },
    };
    exprs_store[block_id] = .{
        .id = block_id,
        .span = test_span,
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
        .span = test_span,
        .ty = null,
        .kind = .{ .expr = cast_id },
    };
    const bodies_store = try alloc.alloc(bodies.BodyKind, 1);
    bodies_store[0] = .{ .fn_ = .{
        .params = params,
        .ret = .{ .prim = .unit },
        .body = block_id,
    } };

    return .{
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_store,
        },
        .graph_store = graph_store,
        .cast_id = cast_id,
        .expected_source = expected_source,
        .expected_kind = conversion_kind,
    };
}

fn expectAcceptedCastInference(
    alloc: std.mem.Allocator,
    fixture: *CastInferenceFixture,
) !void {
    var generated = try genWithGraph(alloc, &fixture.b, &fixture.graph_store);
    defer generated.deinit(alloc);
    const cast = fixture.b.exprs[fixture.cast_id].kind.cast;
    try std.testing.expectEqual(fixture.expected_source, cast.source_type);
    try std.testing.expectEqual(fixture.expected_kind, cast.kind);
    try std.testing.expectEqual(@as(usize, 0), generated.invalid_casts.items.len);

    var inferred = try solveWithGen(alloc, &fixture.b, &generated);
    defer inferred.deinit(alloc);
    try std.testing.expectEqual(@as(?exprs.TypeId, 1), inferred.getType(fixture.cast_id));
}

test "primitive_from accepts unsigned identity conversion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try makeCastInferenceFixture(
        arena_state.allocator(),
        .u64,
        .u64,
        false,
        .primitive_from,
    );
    defer fixture.graph_store.deinit();
    try expectAcceptedCastInference(arena_state.allocator(), &fixture);
}

test "primitive_from accepts unsigned widening conversion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try makeCastInferenceFixture(
        arena_state.allocator(),
        .u64,
        .u128,
        false,
        .primitive_from,
    );
    defer fixture.graph_store.deinit();
    try expectAcceptedCastInference(arena_state.allocator(), &fixture);
}

test "primitive_from accepts an index-derived u8 source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try makeCastInferenceFixture(
        arena_state.allocator(),
        .u8,
        .u64,
        true,
        .primitive_from,
    );
    defer fixture.graph_store.deinit();
    try expectAcceptedCastInference(arena_state.allocator(), &fixture);
}

test "primitive_from rejects unsigned narrowing conversion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try makeCastInferenceFixture(
        arena_state.allocator(),
        .u64,
        .u8,
        false,
        .primitive_from,
    );
    defer fixture.graph_store.deinit();

    var generated = try genWithGraph(
        arena_state.allocator(),
        &fixture.b,
        &fixture.graph_store,
    );
    defer generated.deinit(arena_state.allocator());
    const cast = fixture.b.exprs[fixture.cast_id].kind.cast;
    try std.testing.expectEqual(fixture.expected_source, cast.source_type);
    try std.testing.expectEqual(fixture.expected_kind, cast.kind);
    try std.testing.expectEqual(@as(usize, 1), generated.invalid_casts.items.len);
    try std.testing.expectError(
        error.InvalidCast,
        solveWithGen(arena_state.allocator(), &fixture.b, &generated),
    );
}

test "explicit u128 as u64 remains accepted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try makeCastInferenceFixture(
        arena_state.allocator(),
        .u128,
        .u64,
        false,
        .as_,
    );
    defer fixture.graph_store.deinit();
    try expectAcceptedCastInference(arena_state.allocator(), &fixture);
}

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

fn checkSolveWithGraphAllocationFailures(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
) !void {
    var inferred = try solveWithGraph(alloc, b, null);
    defer inferred.deinit(alloc);
    try std.testing.expect(inferred.getInstantiation(2) != null);
}

test "solveWithGraph propagates allocation failures" {
    const a = std.testing.allocator;

    const types_store = try a.alloc(types.Type, 1);
    defer a.free(types_store);
    types_store[0] = .{ .prim = .u32 };

    const param = try testPrimPath(a, "T");
    defer a.free(param.path.segments);
    const id_fn_params = try a.alloc(items.Param, 1);
    defer a.free(id_fn_params);
    id_fn_params[0] = .{ .name = "x", .ty = param, .span = test_span };

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
    const caller_params = try a.dupe(items.Param, &.{});
    defer a.free(caller_params);
    bodies_store[0] = .{ .fn_ = .{ .params = caller_params, .ret = .{ .prim = .u32 }, .body = 0 } };
    bodies_store[1] = .{ .fn_ = .{ .params = id_fn_params, .ret = param, .body = 0 } };

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = stmts_store,
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };

    try std.testing.checkAllAllocationFailures(
        a,
        checkSolveWithGraphAllocationFailures,
        .{&b},
    );
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

test "typed call let binding informs method receiver inference" {
    const alloc = std.testing.allocator;
    const slice_payload: types.Slice = .{
        .const_ = true,
        .elem = .{ .prim = .u8 },
    };
    const slice_ty: types.Type = .{ .slice = &slice_payload };
    const types_store = [_]types.Type{
        slice_ty,
        .{ .prim = .u8 },
        .{ .prim = .usize },
        .{ .prim = .unit },
    };
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = test_span,
            .ty = null,
            .kind = .{ .block = .{
                .statements = &.{0},
                .tail = null,
                .labelled = null,
            } },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = 0,
            .kind = .{ .call = .{
                .call_kind = .{ .free = 99 },
                .args = &.{},
            } },
        },
        .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .path = .{
                .def = 0,
                .generic_args = &.{},
            } },
        },
        .{
            .id = 3,
            .span = test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 2,
                .receiver_mode = .shared,
                .method = 1,
                .args = &.{},
            } },
        },
    };
    const pats_store = [_]exprs.Pattern{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .binding = .{
            .name = "data",
            .mode = .{ .value = {} },
            .mutable = false,
        } },
    }};
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .let = .{
            .pattern = 0,
            .init = 1,
            .ty = null,
        } },
    }};
    const methods = [_]bodies.StructMethod{.{
        .name = "as_bytes",
        .ret = slice_ty,
        .body = 0,
    }};
    const bodies_store = [_]bodies.BodyKind{
        .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .body = 0,
        } },
        .{ .struct_ = .{ .methods = &methods } },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &stmts_store,
        .pats = &pats_store,
        .types = &types_store,
        .bodies = &bodies_store,
    };

    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{
        .alloc = alloc,
        .b = &b,
        .g = &generated,
    };
    defer ctx.deinit();

    try walkStmt(&ctx, 0, 0);
    try std.testing.expectEqual(slice_ty, ctx.local_types.get(0).?);
    try walkExpr(&ctx, 3, 0);

    var receiver_pinned = false;
    var method_result_pinned = false;
    for (generated.pins.items) |pin| {
        if (pin.node == 2 and pin.ty == 0) receiver_pinned = true;
        if (pin.node == 3 and pin.ty == 0) method_result_pinned = true;
    }
    try std.testing.expect(receiver_pinned);
    try std.testing.expect(method_result_pinned);
}

test "assertion markers walk valid equality conditions only" {
    const alloc = std.testing.allocator;
    const exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = test_span,
            .ty = null,
            .kind = .{ .unsupported = .{
                .reason = "assertion:1",
                .suggested_version = .v3,
            } },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = null,
            .kind = .{ .binary = .{
                .op = .eq,
                .overflow = .checked,
                .lhs = 2,
                .rhs = 3,
            } },
        },
        .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "1",
                .value = 1,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 3,
            .span = test_span,
            .ty = null,
            .kind = .{ .literal = .{ .int = .{
                .text = "2",
                .value = 2,
                .base = .dec,
                .ty_suffix = null,
            } } },
        },
        .{
            .id = 4,
            .span = test_span,
            .ty = null,
            .kind = .{ .unsupported = .{
                .reason = "assertion:not-a-node",
                .suggested_version = .v3,
            } },
        },
        .{
            .id = 5,
            .span = test_span,
            .ty = null,
            .kind = .{ .unsupported = .{
                .reason = "assertion:99",
                .suggested_version = .v3,
            } },
        },
        .{
            .id = 6,
            .span = test_span,
            .ty = null,
            .kind = .{ .unsupported = .{
                .reason = "ordinary unsupported",
                .suggested_version = .v3,
            } },
        },
    };
    const types_store = [_]types.Type{
        .{ .prim = .bool },
        .{ .prim = .i32 },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };

    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{
        .alloc = alloc,
        .b = &b,
        .g = &generated,
    };
    defer ctx.deinit();

    try walkExpr(&ctx, 0, 0);
    try std.testing.expectEqual(Class.integer, generated.classes.get(2).?);
    try std.testing.expectEqual(Class.integer, generated.classes.get(3).?);
    try std.testing.expectEqual(@as(usize, 2), generated.classes.count());
    try std.testing.expectEqual(@as(usize, 1), generated.edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), generated.pins.items.len);
    try std.testing.expectEqual(@as(exprs.NodeId, 1), generated.pins.items[0].node);
    try std.testing.expectEqual(@as(exprs.TypeId, 0), generated.pins.items[0].ty);

    try walkExpr(&ctx, 4, 0);
    try walkExpr(&ctx, 5, 0);
    try walkExpr(&ctx, 6, 0);
    try std.testing.expectEqual(@as(usize, 2), generated.classes.count());
    try std.testing.expectEqual(@as(usize, 1), generated.edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), generated.pins.items.len);
}

test "source analysis infers binary and length cast sources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const function_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "numeric_cast_sources"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const a_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "a"),
        .span = test_span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const b_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "b"),
        .span = test_span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bytes_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = try alloc.dupe(u8, "bytes"),
        .span = test_span,
        .visibility = .private,
        .parent = function_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const len_def = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "len"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    const bytes_slice = try alloc.create(types.Slice);
    bytes_slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const types_store = [_]types.Type{
        .{ .prim = .u64 },
        .{ .prim = .u128 },
        .{ .slice = bytes_slice },
        .{ .prim = .u8 },
        .{ .prim = .usize },
    };
    const params = try alloc.alloc(items.Param, 3);
    params[0] = .{ .name = "a", .ty = types_store[0], .span = test_span };
    params[1] = .{ .name = "b", .ty = types_store[0], .span = test_span };
    params[2] = .{ .name = "bytes", .ty = types_store[2], .span = test_span };

    const exprs_store = try alloc.alloc(exprs.Expr, 13);
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = 0,
        .kind = .{ .path = .{ .def = a_def, .generic_args = &.{} } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = test_span,
        .ty = 0,
        .kind = .{ .path = .{ .def = b_def, .generic_args = &.{} } },
    };
    // These call-shaped operands stand for the two `u128::from` results.
    exprs_store[2] = .{
        .id = 2,
        .span = test_span,
        .ty = 1,
        .kind = .{ .call = .{
            .call_kind = .{ .associated = 100 },
            .args = &.{0},
        } },
    };
    exprs_store[3] = .{
        .id = 3,
        .span = test_span,
        .ty = 1,
        .kind = .{ .call = .{
            .call_kind = .{ .associated = 101 },
            .args = &.{1},
        } },
    };
    exprs_store[4] = .{
        .id = 4,
        .span = test_span,
        .ty = 1,
        .kind = .{ .binary = .{
            .op = .mul,
            .overflow = .checked,
            .lhs = 2,
            .rhs = 3,
        } },
    };
    exprs_store[5] = .{
        .id = 5,
        .span = test_span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{
            .text = "64",
            .value = 64,
            .base = .dec,
            .ty_suffix = null,
        } } },
    };
    exprs_store[6] = .{
        .id = 6,
        .span = test_span,
        .ty = null,
        .kind = .{ .binary = .{
            .op = .shr,
            .overflow = .checked,
            .lhs = 4,
            .rhs = 5,
        } },
    };
    exprs_store[7] = .{
        .id = 7,
        .span = test_span,
        .ty = null,
        .kind = .{ .binary = .{
            .op = .bit_xor,
            .overflow = .checked,
            .lhs = 6,
            .rhs = 4,
        } },
    };
    exprs_store[8] = .{
        .id = 8,
        .span = test_span,
        .ty = 0,
        .kind = .{ .cast = .{
            .operand = 7,
            .source_type = types.Type{ .unsupported = .{
                .reason = .iterators,
                .message = "cast source type pending inference",
                .span = test_span,
            } },
            .target = 0,
        } },
    };
    exprs_store[9] = .{
        .id = 9,
        .span = test_span,
        .ty = 2,
        .kind = .{ .path = .{ .def = bytes_def, .generic_args = &.{} } },
    };
    exprs_store[10] = .{
        .id = 10,
        .span = test_span,
        .ty = null,
        .kind = .{ .method_call = .{
            .receiver = 9,
            .receiver_mode = .shared,
            .method = len_def,
            .args = &.{},
        } },
    };
    exprs_store[11] = .{
        .id = 11,
        .span = test_span,
        .ty = 0,
        .kind = .{ .cast = .{
            .operand = 10,
            .source_type = types.Type{ .unsupported = .{
                .reason = .iterators,
                .message = "cast source type pending inference",
                .span = test_span,
            } },
            .target = 0,
        } },
    };
    exprs_store[12] = .{
        .id = 12,
        .span = test_span,
        .ty = null,
        .kind = .{ .block = .{
            .statements = &.{ 0, 1 },
            .tail = null,
            .labelled = null,
        } },
    };
    const stmts_store = [_]exprs.Statement{
        .{
            .id = 0,
            .span = test_span,
            .ty = null,
            .kind = .{ .expr = 8 },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = null,
            .kind = .{ .expr = 11 },
        },
    };
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = params,
            .ret = types_store[0],
            .body = 12,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &stmts_store,
        .pats = &.{},
        .types = &types_store,
        .bodies = &bodies_store,
    };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{
        .alloc = alloc,
        .b = &b,
        .g = &generated,
        .cg = &graph_store,
    };
    defer ctx.deinit();
    try std.testing.expectEqual(types_store[1], getKnownType(&ctx, 7).?);
    try std.testing.expectEqual(types_store[4], getKnownType(&ctx, 10).?);

    var inferred = try solveWithGraph(alloc, &b, &graph_store);

    defer inferred.deinit(alloc);

    try std.testing.expectEqual(@as(?exprs.TypeId, 1), inferred.getType(7));
    try std.testing.expectEqual(@as(?exprs.TypeId, 4), inferred.getType(10));
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(8));
    try std.testing.expectEqual(@as(?exprs.TypeId, 0), inferred.getType(11));
    try std.testing.expectEqual(
        types.Type{ .prim = .u128 },
        exprs_store[8].kind.cast.source_type,
    );
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        exprs_store[11].kind.cast.source_type,
    );
    try std.testing.expectEqual(
        types.Type{ .prim = .u128 },
        types_store[inferred.getType(7).?],
    );
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        types_store[inferred.getType(10).?],
    );
}

test "array reference casts unsize without strengthening mutability" {
    const array: types.Array = .{
        .elem = .{ .prim = .u8 },
        .len = .{ .literal = 4 },
    };
    const shared_source: types.Ref = .{ .mut = false, .pointee = .{ .array = &array } };
    const mutable_source: types.Ref = .{ .mut = true, .pointee = .{ .array = &array } };
    const shared_target: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const mutable_target: types.Slice = .{ .const_ = false, .elem = .{ .prim = .u8 } };
    const nested_shared_target: types.Ref = .{
        .mut = false,
        .pointee = .{ .slice = &shared_target },
    };

    try std.testing.expect(isValidCast(
        .as_,
        .{ .reference = &mutable_source },
        .{ .slice = &shared_target },
        .{ .reference = &mutable_source },
    ));
    try std.testing.expect(isValidCast(
        .as_,
        .{ .reference = &mutable_source },
        .{ .slice = &mutable_target },
        .{ .reference = &mutable_source },
    ));
    try std.testing.expect(!isValidCast(
        .as_,
        .{ .reference = &shared_source },
        .{ .slice = &mutable_target },
        .{ .reference = &shared_source },
    ));
    try std.testing.expect(!isValidCast(
        .as_,
        .{ .reference = &shared_source },
        .{ .reference = &nested_shared_target },
        .{ .reference = &shared_source },
    ));
}

test "assignment expression has unit type" {
    const types_store = [_]types.Type{
        .{ .prim = .i32 },
        .{ .prim = .unit },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = test_span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 10, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 11, .generic_args = &.{} } },
        },
        .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .assign = .{ .target = 0, .op = .plain, .value = 1, .overflow = .checked } },
        },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };
    var generated: Gen = .{};
    defer generated.deinit(std.testing.allocator);
    var ctx: Ctx = .{
        .alloc = std.testing.allocator,
        .b = &b,
        .g = &generated,
    };
    defer ctx.deinit();

    try walkExpr(&ctx, 2, 2);
    try std.testing.expectEqual(types_store[1], getKnownType(&ctx, 2).?);
    var saw_unit_pin = false;
    for (generated.pins.items) |pin| {
        if (pin.node == 2 and pin.ty == 1) saw_unit_pin = true;
    }
    try std.testing.expect(saw_unit_pin);
    for (generated.edges.items) |edge| {
        if (edge == .eq) try std.testing.expect(edge.eq.a != 2 and edge.eq.b != 2);
    }
}

test "solver finalizes omitted pointer core generic from solved types" {
    var raw_pointer: types.RawPtr = .{ .mut = false, .pointee = .{ .prim = .u64 } };
    const types_store = [_]types.Type{
        .{ .raw_ptr = &raw_pointer },
        .{ .prim = .u64 },
    };
    var exprs_store = [_]exprs.Expr{
        .{
            .id = 0,
            .span = test_span,
            .ty = 0,
            .kind = .{ .path = .{ .def = 10, .generic_args = &.{} } },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = 1,
            .kind = .{ .core_call = .{
                .function = .ptr_read_unaligned,
                .generic_args = &.{},
                .args = &.{0},
            } },
        },
    };
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_store,
        .bodies = &.{},
    };
    var solved = [_]?exprs.TypeId{ 0, 1 };
    try std.testing.expectEqual(
        types_store[1],
        coreTypeArgumentFromSolved(&b, &solved, 1, exprs_store[1].kind.core_call).?,
    );
    try finalizeCoreCallTypeArguments(std.testing.allocator, &b, &solved);
    defer std.testing.allocator.free(exprs_store[1].kind.core_call.generic_args);
    try std.testing.expectEqual(@as(usize, 1), exprs_store[1].kind.core_call.generic_args.len);
    try std.testing.expectEqual(
        types_store[1],
        exprs_store[1].kind.core_call.generic_args[0],
    );
}

test "core transmute function item exposes source and result types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var exprs_store = [_]exprs.Expr{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .core_function = .{
            .function = .mem_transmute,
            .generic_args = &.{ .{ .prim = .u32 }, .{ .prim = .u64 } },
        } },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{ .alloc = alloc, .b = &b, .g = &generated };
    defer ctx.deinit();
    try walkExpr(&ctx, 0, 0);
    const known = getKnownType(&ctx, 0).?;
    try std.testing.expect(known == .fn_ptr);
    try std.testing.expectEqual(@as(usize, 1), known.fn_ptr.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, known.fn_ptr.params[0]);
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, known.fn_ptr.ret);
}

test "external Cow variant derives owned payload type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const owner: types.ExternalNominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .slice = slice }},
    };
    const pattern: exprs.ExternalVariantPattern = .{
        .owner = owner,
        .variant = "Owned",
        .fields = &.{.{
            .field = "0",
            .pat = null,
            .shorthand = true,
        }},
    };
    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{ .alloc = alloc, .b = &b, .g = &generated };
    defer ctx.deinit();
    const payload = externalVariantFieldType(&ctx, pattern, null, "0").?;
    try std.testing.expect(payload == .external_nominal);
    try std.testing.expectEqualStrings("Vec", payload.external_nominal.path[2]);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, payload.external_nominal.args[0]);
}

test "I/O method result requires matching generic bound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const owner_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "read"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const bound: types.Bound = .{ .path = .{
        .segments = &.{
            .{ .name = "std", .id = null },
            .{ .name = "io", .id = null },
            .{ .name = "Read", .id = null },
        },
    } };
    const generic_param: types.GenericParam = .{ .type_ = .{
        .name = "R",
        .bounds = &.{bound},
    } };
    const generics: types.Generics = .{
        .params = &.{generic_param},
        .where_clauses = &.{},
    };
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .generics = generics,
            .body = 0,
        },
    }};
    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &bodies_store,
    };
    const receiver: types.Type = .{ .path = .{
        .segments = &.{.{ .name = "R", .id = null }},
    } };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{
        .alloc = alloc,
        .b = &b,
        .g = &generated,
        .cg = &graph_store,
        .current_fn = owner_id,
    };
    defer ctx.deinit();
    const result = knownIoMethodResultType(&ctx, receiver, "read_exact").?;
    try std.testing.expect(result == .result);
    try std.testing.expectEqual(types.Type{ .prim = .unit }, result.result.ok);
    try std.testing.expectEqual(types.Type{
        .external_nominal = .{ .path = &.{ "std", "io", "Error" } },
    }, result.result.err);
    try std.testing.expect(knownIoMethodResultType(&ctx, receiver, "write_all") == null);
}
