//! infer — constraint generation & unification solver for P3.
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

const InstantiationContext = struct {
    pub fn hash(_: InstantiationContext, node: exprs.NodeId) u64 {
        const little = std.mem.nativeToLittle(exprs.NodeId, node);
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&little));
    }

    pub fn eql(_: InstantiationContext, a: exprs.NodeId, b: exprs.NodeId) bool {
        return a == b;
    }
};

/// Fixed-endian node hashing keeps inferred-record ordering portable.
pub const InstantiationMap = std.HashMapUnmanaged(
    exprs.NodeId,
    types.Instantiation,
    InstantiationContext,
    std.hash_map.default_max_load_percentage,
);

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
    instantiations: InstantiationMap = .empty,
    invalid_casts: std.ArrayListUnmanaged(exprs.NodeId) = .empty,
    derived_types: std.ArrayListUnmanaged(types.Type) = .empty,
    derived_pins: std.ArrayListUnmanaged(DerivedPin) = .empty,
    derived_pattern_pins: std.ArrayListUnmanaged(DerivedPin) = .empty,
    /// Source-owned partial tuple rows survive expression type repointing.
    source_tuple_rows: std.AutoHashMapUnmanaged(exprs.NodeId, exprs.TypeId) = .empty,
    source_completion_pending: bool = false,
    /// An array or `vec!` literal that no position named and whose elements
    /// carried only a literal class, so the walk could not publish a row for
    /// it. The solver's own Defaults Phase names those elements on the
    /// solved-state replay, and the container row follows the element it reads.
    /// Which container it was does not matter — the replay walks the whole
    /// graph either way — so this is one bit rather than a list, and a crate
    /// with a thousand such literals still records one.
    derived_container_pending: bool = false,
    derived_error: bool = false,
    /// The full frontend completes these casts after method resolution.
    /// Standalone solvers leave this false and finish refusals immediately.
    defer_pending_casts: bool = false,

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.pins.deinit(alloc);
        self.edges.deinit(alloc);
        self.classes.deinit(alloc);
        deinitInstantiationMap(alloc, &self.instantiations);
        self.invalid_casts.deinit(alloc);
        self.derived_types.deinit(alloc);
        self.derived_pins.deinit(alloc);
        self.derived_pattern_pins.deinit(alloc);
        self.source_tuple_rows.deinit(alloc);
        self.* = undefined;
    }
};

/// Result of type inference: dense array of inferred concrete TypeIds and instantiation records.
pub const Inferred = struct {
    types: []?exprs.TypeId,
    instantiations: InstantiationMap = .empty,

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
    if (types.isTypeParam(param_ty, param_names)) |idx| {
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
                if (!segmentsAreSameEntity(left, right)) return false;
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

const PatternSource = struct {
    initializer: exprs.NodeId,
    root: exprs.NodeId,
    leaf: exprs.NodeId,
};

const PatternSourceRoot = struct {
    initializer: exprs.NodeId,
    root: exprs.NodeId,
};

const Ctx = struct {
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    g: *Gen,
    cg: ?*const graph.CrateGraph = null,
    def_map: std.AutoHashMapUnmanaged(exprs.DefId, exprs.NodeId) = .empty,
    /// Concrete signature types for local parameters, keyed by their resolved
    /// field entity. This keeps a path argument's type available before the
    /// unification result has been applied to the expression table.
    local_types: std.AutoHashMapUnmanaged(exprs.DefId, types.Type) = .empty,
    known_nodes: std.AutoHashMapUnmanaged(exprs.NodeId, types.Type) = .empty,
    pattern_sources: std.AutoHashMapUnmanaged(exprs.DefId, PatternSource) = .empty,
    pattern_source_root: ?PatternSourceRoot = null,
    solved_types: ?[]const ?exprs.TypeId = null,
    /// Return types expected by enclosing expression tails.  Abstract
    /// associated calls need this context before a concrete impl is selected.
    expected_types: std.AutoHashMapUnmanaged(exprs.NodeId, types.Type) = .empty,
    /// Type an explicit `let name: T = ..` annotation pinned on an
    /// initialiser. The pin table records it too, but that table also carries
    /// every inferred constraint; a rule that asks "what did the source WRITE
    /// here" asks this one.
    annotated_inits: std.AutoHashMapUnmanaged(exprs.NodeId, exprs.TypeId) = .empty,
    current_fn: ?exprs.DefId = null,
    type_expression_depth: usize = 0,
    /// Innermost value-producing loop, for constraining `break value`.
    loop_result: ?exprs.NodeId = null,
    local_defs: []exprs.DefId = &.{},
    local_claimed: []bool = &.{},

    fn clearLocals(self: *Ctx) void {
        if (self.local_defs.len > 0) self.alloc.free(self.local_defs);
        if (self.local_claimed.len > 0) self.alloc.free(self.local_claimed);
        self.local_defs = &.{};
        self.local_claimed = &.{};
        self.local_types.clearRetainingCapacity();
        self.pattern_sources.clearRetainingCapacity();
        self.pattern_source_root = null;
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
        self.pattern_sources.deinit(self.alloc);
        self.expected_types.deinit(self.alloc);
        self.annotated_inits.deinit(self.alloc);
        self.def_map.deinit(self.alloc);
        self.* = undefined;
    }

    fn recordDerivedType(self: *Ctx, node: exprs.NodeId, ty: types.Type) void {
        if (ty == .unsupported or containsInferPlaceholder(ty)) return;
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
                if (!segmentsAreSameEntity(left, right)) return false;
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

/// Whether two path segments that BOTH record the entity they resolved to
/// name that same entity.
///
/// One recorded id is enough to prove identity; two recorded ids that differ
/// prove the types are different even though their spellings agree. A
/// segment with no id records nothing, so the name comparison the caller
/// already made is all there is — which is what keeps an unresolved `Self` or
/// a type parameter matching whatever it was written next to.
///
/// This is the rule that keeps siphasher's two private `struct Hasher`
/// declarations apart: they are one name and two entities, and an
/// instantiation that matched one against the other would bind a method call
/// to the wrong module's body without leaving a trace.
fn segmentsAreSameEntity(left: types.PathSegment, right: types.PathSegment) bool {
    if (left.id) |left_id| {
        if (right.id) |right_id| return left_id == right_id;
    }
    return true;
}

fn boundsEqual(left: []const types.Bound, right: []const types.Bound) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_bound, right_bound| {
        if (left_bound.optional != right_bound.optional) return false;
        if (left_bound.path.segments.len != right_bound.path.segments.len) return false;
        for (left_bound.path.segments, right_bound.path.segments) |left_segment, right_segment| {
            if (!std.mem.eql(u8, left_segment.name, right_segment.name)) return false;
            if (!segmentsAreSameEntity(left_segment, right_segment)) return false;
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
///
/// The inference placeholder is a third thing again: it is neither a decision
/// the source wrote nor a refusal, but the absence of any statement about the
/// slot, so a row carrying one is still open. The `.external_nominal` prong
/// below only inspects the arguments and never the path, which is right for
/// `core::marker::PhantomData<S>` and wrong for `["_"]`: read as concrete, a
/// partial tuple row looks finished, the solver skips refining it, and the
/// placeholder reaches the table where validation refuses its root.
fn isConcreteDerivedType(t: types.Type) bool {
    if (isInferPlaceholderType(t)) return false;
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

    // The Defaults Phase in `solveWithGen` resolves an unconstrained integer
    // class through `primTypeId(b, .i32)`, and that lookup only SEARCHES
    // `b.types` — it never interns. A crate whose source never names `i32`
    // therefore has no TypeId to hand the class, the phase silently does
    // nothing, and every unconstrained integer expression keeps `ty = null`.
    // Interning here makes the default reachable for exactly the crates that
    // can use it, and leaves a crate with no unannotated integer or float
    // literal with the type table it had before.
    try internDefaultClassType(alloc, type_list, &g.classes, .integer, .i32);
    try internDefaultClassType(alloc, type_list, &g.classes, .float, .f64);

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

/// Append `.{ .prim = prim }` to `type_list` when a literal of class `class`
/// exists and the list does not already name that primitive.
///
/// Interning is conditional on the class map so that a crate with no
/// unannotated literal of this class keeps the type table it had, rather than
/// carrying a default it can never select.
fn internDefaultClassType(
    alloc: std.mem.Allocator,
    type_list: *std.ArrayListUnmanaged(types.Type),
    classes: *const std.AutoHashMapUnmanaged(exprs.NodeId, Class),
    class: Class,
    prim: types.Prim,
) !void {
    var needed = false;
    var it = classes.iterator();
    while (it.next()) |entry| {
        const candidate = entry.value_ptr.*;
        if (candidate == class) {
            needed = true;
            break;
        }
    }
    if (!needed) return;
    const target: types.Type = .{ .prim = prim };
    if (findTypeIndexInSlice(type_list.items, target) != null) return;
    try type_list.append(alloc, target);
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

/// What a node has actually said it is, or null when it has not said anything
/// yet.
///
/// `getKnownType` answers a private source row that still holds the inference
/// placeholder with that row, and a row with a hole in it is a question rather
/// than an answer: `isUnnamedElement`, `refineSourceTupleRow`,
/// `containerAlreadyNamed` and `pinKnownType` all read one as no statement at
/// all. A comparison that took such a row for an answer never asked the
/// operand beside it, so the hole survived to the type table, where
/// `validateExternalNominal` refuses a single-segment `_` as
/// `IncompleteGenericMetadata`. A crate whose table carries no placeholder is
/// unaffected: the branch this guards is unreachable for one.
fn declaredPeerType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    const known = getKnownType(ctx, node) orelse return null;
    if (containsInferPlaceholder(known)) return null;
    return known;
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

/// Whether a container element's only evidence is the literal class the walk
/// recorded for it. The walk can neither name such an element nor say anything
/// about the container holding it, and the solver's Defaults Phase turns that
/// class into a primitive — so this is exactly the evidence a solved-state
/// replay can finish with. An element with no class at all has nothing
/// pending: the replay would read the same absent type and name the same absent
/// container, and a crate full of those must not pay for a second walk.
/// The replay's own answer is read straight off `solved_types` rather than
/// through `getKnownType`, which would answer the same thing while publishing
/// a row of its own into the middle of a decision that only asks a question.
fn elementAwaitsSolverDefault(ctx: *Ctx, element: exprs.NodeId) bool {
    if (element >= ctx.b.exprs.len) return false;
    if (ctx.g.classes.get(element) == null) return false;
    const solved = ctx.solved_types orelse return true;
    if (element >= solved.len) return true;
    const id = solved[element] orelse return true;
    if (id >= ctx.b.types.len) return true;
    const ty = ctx.b.types[id];
    return ty == .unsupported or containsInferPlaceholder(ty);
}

/// Note that the walk left a container untyped because its elements carried
/// only a literal class, so `materializeSolvedSourceTypes` replays the walk with
/// the solver's own answers in hand.
fn markPendingContainer(ctx: *Ctx) void {
    ctx.g.derived_container_pending = true;
}

/// Whether the walk has already said what this container IS. Three records
/// say so, and the expression table does not: `pinKnownType` reaches the solver
/// through a recorded pin or a deferred derived row, and a deferred row leaves
/// `b.exprs[node].ty` null until `materializeDerivedTypes` publishes it. So the
/// published answer is read from the records that hold it — a pin recorded for
/// the node, a concrete derived row under it, or the known row itself.
/// Reading them is a lookup; asking `getKnownType` would not be, because it
/// publishes a row of its own on the way to the answer.
/// A placeholder published as that row is not an answer. It is a hole, and
/// finishing a hole is what the solved-state replay exists for, so this guard
/// deliberately lets the mark through for one.
fn containerAlreadyNamed(ctx: *Ctx, node: exprs.NodeId) bool {
    for (ctx.g.pins.items) |pin| {
        if (pin.node != node) continue;
        // A pin is an answer only where the row it names is one. The shared
        // `_` row is a pin target like any other, and naming it says nothing.
        return pin.ty < ctx.b.types.len and !containsInferPlaceholder(ctx.b.types[pin.ty]);
    }
    for (ctx.g.derived_pins.items) |pin| {
        if (pin.node == node) return false;
    }
    if (ctx.known_nodes.get(node)) |known| {
        return known != .unsupported and !containsInferPlaceholder(known);
    }
    return false;
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
            } else if (lhs_known == null or lhs_known.? != .reference) {
                // Rust auto-derefs a reference lhs, so the result takes the
                // pointee type and the lhs edge above was deliberately not
                // emitted. Folding the unconstrained rhs INTO the result
                // would then contradict that: the literal's own default
                // (i32, now that `materializeDerivedTypes` interns it) would
                // become the result's type, where a cast around the whole
                // expression records the pointee. The same guard the shift
                // arm below already applies is the one that keeps
                // `&u8 - 1` a `u8` result.
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
            // PartialEq/PartialOrd may compare different concrete types
            // (Vec<u8> against [u8; N], String against &str). Preserve both
            // known operand types. Only an operand that has not said what it is
            // takes context from its peer, including payloads inside
            // constructors such as Ok. A row that still carries the inference
            // placeholder has NOT said what it is: it is a private source row
            // whose slot is still a question, and this module reads a hole that
            // way everywhere else (`isUnnamedElement`, `refineSourceTupleRow`,
            // `containerAlreadyNamed`). Asking its concrete peer instead is what
            // lets `assert_eq!((None, 3), u8::from_radix_10_checked(b"255"))`
            // state `Option<u8>` and `usize` for the two slots the `_` stood
            // in for.
            if (declaredPeerType(ctx, bin.lhs)) |lhs_ty| {
                if (declaredPeerType(ctx, bin.rhs) == null) {
                    try constrainExpectedType(ctx, bin.rhs, lhs_ty);
                }
            } else if (declaredPeerType(ctx, bin.rhs)) |rhs_ty| {
                try constrainExpectedType(ctx, bin.lhs, rhs_ty);
            }
            // Scalar classes still share their integer/float constraints.
            if (lhs_known == null or rhs_known == null or lhs_known.? == .prim or rhs_known.? == .prim) {
                try addEq(ctx, bin.lhs, bin.rhs);
            }
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

/// The enum a `match`'s PATTERNS say its scrutinee is, carrying no payload.
///
/// This is the one place a scrutinee's type can arrive before the scrutinee
/// expression itself has one, and it is the other direction of
/// `variantPayloadType` — that one reads a payload out of a type the rest of
/// the pass already knows; this one asks what the patterns around the value say
/// it is. A conversion written `.into()` names its target nowhere in its own
/// spelling, so when the surrounding patterns are the only other statement
/// about it, they are the evidence.
///
/// Every arm's patterns must agree on one owner, because a `match` whose arms
/// name two different enums is matching on something other than the scrutinee's
/// type and so proves nothing about it. A pattern that says nothing about an
/// enum — a wildcard, a binding, a range — is no objection either way.
fn patternOwnerNominal(ctx: *Ctx, m: exprs.MatchExpr) ?types.ExternalNominal {
    var owner: ?types.ExternalNominal = null;
    for (m.arms) |arm| {
        for (arm.patterns) |pattern_id| {
            if (pattern_id >= ctx.b.pats.len) continue;
            const seen = switch (ctx.b.pats[pattern_id].kind) {
                .external_variant => |value| value.owner,
                else => continue,
            };
            if (owner) |known| {
                if (!resolve_methods.externalPathIs(known.path, seen.path)) return null;
                continue;
            }
            owner = seen;
        }
    }
    return owner;
}

/// The target a `match`'s patterns and the crate's `From` impls jointly force a
/// `.into()` scrutinee to have, or null when they do not.
///
/// The two halves each supply what the other lacks. The PATTERNS fix the owner
/// — matching `Cow::Borrowed(..)` and `Cow::Owned(..)` says the scrutinee is a
/// `Cow`, which is not something the expression says about itself. The crate's
/// `impl` blocks then fix the payload: the one `impl From<PercentDecode<'a>>
/// for Cow<'a, [u8]>` is the only way a `PercentDecode` becomes a `Cow`, and its
/// own `self_ty` says which `B` that is. Neither half is a guess about the
/// other, and `uniqueFromImplTargetForOwner` returns null when the crate offers
/// more than one, which is exactly the case Rust would also call ambiguous.
///
/// Only the scrutinee's own type is derived. The arms' RESULT type is a
/// separate question and is never applied here — in
/// `match self.clone().into() { Cow::Borrowed(b) => .., Cow::Owned(b) => .. }`
/// inside a `-> Result<Cow<str>, Utf8Error>` function, the scrutinee is a
/// `Cow<[u8]>` while every arm is that `Result`, and handing the scrutinee the
/// arm type would overwrite a real value with one it does not have.
fn matchDirectedIntoTarget(ctx: *Ctx, m: exprs.MatchExpr) ?types.Type {
    if (m.scrutinee >= ctx.b.exprs.len) return null;
    // A scrutinee that already has a type is not this pass's question.
    if (getKnownType(ctx, m.scrutinee) != null) return null;
    const call = switch (ctx.b.exprs[m.scrutinee].kind) {
        .method_call => |value| value,
        else => return null,
    };
    const name = getMethodName(ctx, call.method) orelse return null;
    if (!std.mem.eql(u8, name, "into")) return null;
    const owner = patternOwnerNominal(ctx, m) orelse return null;
    const source = getKnownType(ctx, call.receiver) orelse return null;
    const cg = ctx.cg orelse return null;
    return resolve_methods.uniqueFromImplTargetForOwner(cg, ctx.b, source, owner.path);
}

/// Walk a `match` expression: unify the body expressions of all arms with match node.
fn walkMatch(ctx: *Ctx, node: exprs.NodeId, m: exprs.MatchExpr, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(node < ctx.b.exprs.len);
    std.debug.assert(m.scrutinee < ctx.b.exprs.len);
    // A `match` is judged by the type every arm produces, so a position that
    // demands a type of the match demands one of each arm too. Rust propagates
    // the expectation inward exactly this way, and it is the only way an
    // `.into()` written inside an arm learns what it is converting into: the
    // arm body is not the enclosing block's tail, so nothing else names a
    // target for it.
    //
    // The scrutinee is NOT one of them, and deliberately so. It is the value
    // BEING matched, not one of the values the match PRODUCES — in
    // `match self.into() { Cow::Borrowed(b) => .., Cow::Owned(b) => .. }` it
    // is a `Cow<[u8]>` while every arm is a `Result<Cow<str>, Utf8Error>` —
    // so handing it the arms' type would overwrite a real value with a type it
    // does not have. What DOES fix the scrutinee is the patterns it is matched
    // against, and for a `.into()` scrutinee that is a real derivation rather
    // than a guess: the patterns name the OWNER, and the crate's `From` impls
    // fix the payload. See `matchDirectedIntoTarget`.
    const expected = contextualTypeAt(ctx, node, fn_body);
    if (expected) |expected_ty| {
        try ctx.expected_types.put(ctx.alloc, node, expected_ty);
    }
    try walkExpr(ctx, m.scrutinee, fn_body);
    // After the walk, not before: `self.clone()` has no type until something
    // descends into it, and that clone is the conversion's SOURCE. Constraining
    // afterwards also needs no second walk — `constrainExpectedType` pins the
    // node directly, which is exactly what the walk would have done had it
    // known the target when it got there.
    if (matchDirectedIntoTarget(ctx, m)) |scrutinee_target| {
        try constrainExpectedType(ctx, m.scrutinee, scrutinee_target);
    }
    const scrutinee_ty = getKnownType(ctx, m.scrutinee);
    for (m.arms) |arm| {
        for (arm.patterns) |pattern| try bindMatchPatternKnownType(ctx, pattern, scrutinee_ty);
        if (arm.guard) |guard| try walkExpr(ctx, guard, fn_body);
        try addEq(ctx, node, arm.body);
        if (expected) |expected_ty| try constrainExpectedType(ctx, arm.body, expected_ty);
        try walkExpr(ctx, arm.body, fn_body);
    }
}

/// The `Option<T>` a prelude `Some` CONSTRUCTOR builds.
///
/// The synthetic `core::option::Option` declares its `Some` field with its own
/// uninstantiated parameter, so an arm that matches a constructor in place
/// would otherwise bind `value` to that bare `T` — a name nothing in the
/// function's scope declares, which every row that then carries it turns into
/// an unresolved type path. The constructor says what it built: `Some(x)` is
/// an `Option` whose payload is `x`, so read the payload there.
///
/// Only `Option` is read this way. `Ok(x)` and `Err(e)` each name one of two
/// parameters and say nothing about the other, so a `Result` constructor
/// leaves the pair half-determined and the declaration is no better a source
/// — those scrutinees arrive from a call whose own return type already names
/// both. The payload is pinned on the field node too, so the value the
/// constructor carries has the identity the arm binding now reports.
///
/// The result is recorded ON THE CONSTRUCTOR NODE, not only handed to a match:
/// anything that reads the node — a binding that takes it, a backend choosing
/// a representation for it — reads the node, and a type derived only for a
/// match pattern never reaches it.
fn preludeVariantType(
    ctx: *Ctx,
    node: exprs.NodeId,
) std.mem.Allocator.Error!?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    const variant = switch (ctx.b.exprs[node].kind) {
        .enum_variant => |value| value,
        else => return null,
    };
    const cg = ctx.cg orelse return null;
    const owner = cg.symbol_table.get(variant.def) orelse return null;
    const enum_id = if (owner.kind == .variant) owner.parent orelse return null else owner.id;
    const enum_entity = cg.symbol_table.get(enum_id) orelse return null;
    if (enum_entity.kind != .enum_) return null;
    const module_id = enum_entity.parent orelse return null;
    const module = cg.symbol_table.get(module_id) orelse return null;
    if (module.kind != .module) return null;
    const root_id = module.parent orelse return null;
    const root = cg.symbol_table.get(root_id) orelse return null;
    if (root.kind != .module) return null;
    if (!std.mem.eql(u8, enum_entity.name, "Option") or
        !std.mem.eql(u8, module.name, "option") or
        !std.mem.eql(u8, root.name, "core"))
    {
        return null;
    }
    if (variant.tuple_fields.len != 1) return null;
    const payload = getKnownType(ctx, variant.tuple_fields[0]) orelse return null;
    try pinKnownType(ctx, variant.tuple_fields[0], payload);
    const option = makeExternalNominalType(
        ctx,
        &.{ "core", "option", "Option" },
        &.{payload},
    ) orelse return null;
    try pinKnownType(ctx, node, option);
    return option;
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
            _ = try bindPattern(ctx, field_pattern, init, field_ty);
        } else if (field.shorthand) {
            if (ctx.claimLocal(field.field)) |def| {
                if (init) |init_node| try ctx.def_map.put(ctx.alloc, def, init_node);
                if (field_ty) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
            }
        }
    }
}

fn patternContainsLeaf(b: *const bodies.Bodies, root: exprs.NodeId, leaf: exprs.NodeId, remaining: usize) bool {
    if (root == leaf) return true;
    if (remaining == 0 or root >= b.pats.len) return false;
    return switch (b.pats[root].kind) {
        .tuple => |tuple| for (tuple.elements) |child| {
            if (patternContainsLeaf(b, child, leaf, remaining - 1)) break true;
        } else false,
        .reference => |reference| patternContainsLeaf(b, reference.inner, leaf, remaining - 1),
        else => false,
    };
}

/// Only a tuple or reference root projects a leaf whose source element
/// `def_map` cannot reach on its own. A struct or enum root names fields the
/// capture walk already types, so it registers no source slot at all.
fn patternProjectsSourceLeaf(ctx: *Ctx, root: exprs.NodeId) bool {
    if (root >= ctx.b.pats.len) return false;
    return switch (ctx.b.pats[root].kind) {
        .tuple, .reference => true,
        else => false,
    };
}

fn linkPatternSource(ctx: *Ctx, occurrence: exprs.NodeId, source: PatternSource, remaining: usize) std.mem.Allocator.Error!void {
    if (remaining == 0 or source.root >= ctx.b.pats.len or source.initializer >= ctx.b.exprs.len) return;
    // Registration only records a leaf reached through a tuple or reference
    // pattern, so `root` is a strict ancestor here and the descent below is
    // what proves which source element produces this occurrence.
    if (source.root == source.leaf) return;
    switch (ctx.b.pats[source.root].kind) {
        .tuple => |tuple| for (tuple.elements, 0..) |child, index| {
            if (!patternContainsLeaf(ctx.b, child, source.leaf, remaining - 1)) continue;
            try linkTupleSourceSlot(ctx, occurrence, source.initializer, index, child, source.leaf, remaining - 1, false);
            return;
        },
        .reference => |reference| {
            var initializer = source.initializer;
            if (ctx.b.exprs[initializer].kind == .unary and ctx.b.exprs[initializer].kind.unary.op == .ref) {
                initializer = ctx.b.exprs[initializer].kind.unary.operand;
            }
            try linkPatternSource(ctx, occurrence, .{ .initializer = initializer, .root = reference.inner, .leaf = source.leaf }, remaining - 1);
        },
        else => {},
    }
}

/// A tuple leaf and every source branch producing that leaf share identity.
/// The Option carrier proves the standard operation; a same-spelled local
/// method is not enough. These are equality edges, not fabricated types: the
/// edge lands on the source SLOT a descent reaches, and only once the element
/// pattern in that slot is the leaf itself — a nested pattern keeps
/// descending, because only the leaf's own slot is where its value comes from.
fn linkTupleSourceSlot(ctx: *Ctx, occurrence: exprs.NodeId, source: exprs.NodeId, index: usize, pattern_root: exprs.NodeId, leaf: exprs.NodeId, remaining: usize, option_payload: bool) std.mem.Allocator.Error!void {
    if (remaining == 0 or source >= ctx.b.exprs.len) return;
    const expression = ctx.b.exprs[source];
    switch (expression.kind) {
        .path => |path| {
            const initializer = ctx.def_map.get(path.def) orelse return;
            if (initializer != source) try linkTupleSourceSlot(ctx, occurrence, initializer, index, pattern_root, leaf, remaining - 1, option_payload);
        },
        .block => |block| if (block.tail) |tail| {
            try linkTupleSourceSlot(ctx, occurrence, tail, index, pattern_root, leaf, remaining - 1, option_payload);
        },
        .unary => |unary| if (unary.op == .ref or unary.op == .deref) {
            try linkTupleSourceSlot(ctx, occurrence, unary.operand, index, pattern_root, leaf, remaining - 1, option_payload);
        },
        .array => |literal| {
            if (option_payload or literal.repeat != null or index >= literal.elements.len) return;
            const row_id = ctx.g.source_tuple_rows.get(source) orelse expression.ty orelse return;
            if (row_id >= ctx.b.types.len or ctx.b.types[row_id] != .tuple) return;
            // The element pattern this descent reached IS the leaf, so the
            // slot under `index` is where the leaf's value comes from and the
            // claim is an equality edge and nothing else. `let (sign, offset)
            // = ....unwrap_or((Sign::Plus, 0))` binds two locals to two
            // positions of one value, and without the edge a slot no source
            // annotation filled holds nothing but the integer class its
            // literal carries: the solver defaults the `0` to `i32`, and the
            // row says something no Rust program would say about an offset the
            // surrounding code uses as an index. The row keeps its own
            // per-slot types either way — an edge carries identity, and
            // identity is what the slot was missing.
            //
            // A NESTED pattern (`let ((a, b), c) = ..`) has not reached its own
            // slot yet, and the descent below is what proves which one it is.
            if (pattern_root == leaf) {
                try addEq(ctx, occurrence, literal.elements[index]);
                return;
            }
            try linkPatternSource(ctx, occurrence, .{ .initializer = literal.elements[index], .root = pattern_root, .leaf = leaf }, remaining - 1);
        },
        .method_call => |method| {
            const name = getMethodName(ctx, method.method) orelse return;
            const receiver = getKnownType(ctx, method.receiver) orelse return;
            if (optionPayloadType(receiver) == null) return;
            if (!option_payload and std.mem.eql(u8, name, "unwrap_or") and method.args.len == 1) {
                try linkTupleSourceSlot(ctx, occurrence, method.args[0], index, pattern_root, leaf, remaining - 1, false);
                try linkTupleSourceSlot(ctx, occurrence, method.receiver, index, pattern_root, leaf, remaining - 1, true);
            } else if (option_payload and method.args.len == 1 and
                (std.mem.eql(u8, name, "map") or std.mem.eql(u8, name, "and_then")))
            {
                const closure_id = method.args[0];
                if (closure_id >= ctx.b.exprs.len or ctx.b.exprs[closure_id].kind != .closure) return;
                const tail = ctx.b.exprs[closure_id].kind.closure.body.tail orelse return;
                try linkTupleSourceSlot(ctx, occurrence, tail, index, pattern_root, leaf, remaining - 1, std.mem.eql(u8, name, "and_then"));
            }
        },
        .external_variant => |variant| {
            if (!option_payload or !std.mem.eql(u8, variant.variant, "Some") or variant.tuple_fields.len != 1) return;
            const carrier: types.Type = .{ .external_nominal = variant.owner };
            if (optionPayloadType(carrier) == null) return;
            try linkTupleSourceSlot(ctx, occurrence, variant.tuple_fields[0], index, pattern_root, leaf, remaining - 1, false);
        },
        .enum_variant => |variant| {
            if (!option_payload or !std.mem.eql(u8, variant.variant, "Some") or variant.tuple_fields.len != 1) return;
            const carrier = getKnownType(ctx, source) orelse return;
            if (optionPayloadType(carrier) == null) return;
            try linkTupleSourceSlot(ctx, occurrence, variant.tuple_fields[0], index, pattern_root, leaf, remaining - 1, false);
        },
        else => {},
    }
}

fn bindPattern(
    ctx: *Ctx,
    pattern_id: exprs.NodeId,
    init: ?exprs.NodeId,
    known_ty: ?types.Type,
) std.mem.Allocator.Error!?exprs.DefId {
    if (pattern_id >= ctx.b.pats.len) return null;
    const previous_source = ctx.pattern_source_root;
    if (previous_source == null) {
        if (init) |initializer| ctx.pattern_source_root = .{ .initializer = initializer, .root = pattern_id };
    }
    defer ctx.pattern_source_root = previous_source;
    const pattern_type: ?types.Type = if (known_ty) |ty| switch (ctx.b.pats[pattern_id].kind) {
        .binding => |binding| if (binding.mode == .value)
            ty
        else
            makeReferenceType(ctx, ty, binding.mode == .mut_ref) orelse return error.OutOfMemory,
        else => ty,
    } else null;
    if (pattern_type) |ty| {
        if (ty != .unsupported and !containsInferPlaceholder(ty)) {
            try ctx.g.derived_pattern_pins.append(ctx.alloc, .{ .node = pattern_id, .ty = ty });
        }
    }
    switch (ctx.b.pats[pattern_id].kind) {
        .binding => |binding| {
            const def_id = ctx.claimLocal(binding.name) orelse blk: {
                if (ctx.cg == null) break :blk @as(?exprs.DefId, @intCast(pattern_id));
                break :blk null;
            };
            if (def_id) |def| {
                if (init) |init_node| try ctx.def_map.put(ctx.alloc, def, init_node);
                if (ctx.pattern_source_root) |source| {
                    // A pattern that IS its own root already carries the
                    // initializer in `def_map`, and `walkPath` equates that
                    // occurrence directly; only a leaf projected THROUGH a
                    // tuple or reference pattern needs the source walk, and
                    // only such a leaf must allocate a second map entry.
                    if (source.root != pattern_id and patternProjectsSourceLeaf(ctx, source.root)) {
                        try ctx.pattern_sources.put(ctx.alloc, def, .{ .initializer = source.initializer, .root = source.root, .leaf = pattern_id });
                    }
                }
                if (pattern_type) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
            }
            return def_id;
        },
        .tuple => |tuple| {
            for (tuple.elements, 0..) |element, index| {
                const element_ty: ?types.Type = if (known_ty) |ty| switch (ty) {
                    .tuple => |elements| if (index < elements.len) elements[index] else null,
                    else => null,
                } else null;
                // A destructured binding owns its tuple element type; it must
                // not be equated with the whole tuple initializer.
                _ = try bindPattern(ctx, element, null, element_ty);
            }
            return null;
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
            for (slice.elements) |element| _ = try bindPattern(ctx, element, init, element_ty);
            if (slice.rest) |rest| _ = try bindPattern(ctx, rest, init, known_ty);
            return null;
        },
        .struct_pat => |struct_pat| {
            const payload_ty = variantPayloadType(ctx, .{ .struct_pat = struct_pat }, known_ty);
            // A nested local variant reads its own declared fields, not fields
            // on the enum value passed down by the enclosing Result pattern.
            if (ctx.cg) |cg| {
                if (cg.symbol_table.get(struct_pat.def)) |variant| {
                    if (variant.kind == .variant and payload_ty == null) {
                        if (variant.parent) |parent| {
                            if (parent < ctx.b.bodies.len and ctx.b.bodies[parent] == .enum_ and
                                ctx.b.bodies[parent].enum_.generic_params.len == 0)
                            {
                                try bindMatchPattern(ctx, pattern_id);
                                return null;
                            }
                        }
                    }
                }
            }
            for (struct_pat.fields) |field| {
                const field_ty = if (payload_ty != null and field.field.len > 0 and
                    std.mem.eql(u8, field.field, "0"))
                    payload_ty
                else if (known_ty) |ty|
                    fieldTypeForBase(ctx, ty, field.field)
                else
                    null;
                if (field.pat) |field_pattern| {
                    // A capture owns the projected field, not the whole
                    // initializer; equating them would turn a scalar into
                    // the enclosing struct in the unification solver.
                    _ = try bindPattern(ctx, field_pattern, null, field_ty);
                } else if (field.shorthand) {
                    const def_id = ctx.claimLocal(field.field);
                    if (def_id) |def| {
                        if (field_ty) |ty| try ctx.local_types.put(ctx.alloc, def, ty);
                    }
                }
            }
            return null;
        },
        .external_variant => |external_variant| {
            try bindExternalVariantPattern(ctx, external_variant, init, known_ty);
            return null;
        },
        .reference => |reference| {
            const inner_ty = if (known_ty) |ty| dereferencedType(ty) orelse ty else null;
            _ = try bindPattern(ctx, reference.inner, init, inner_ty);
            return null;
        },
        .@"or" => |or_pattern| {
            for (or_pattern.alternatives) |alternative| {
                _ = try bindPattern(ctx, alternative, init, known_ty);
            }
            return null;
        },
        .unsupported => return null,
        .wildcard, .literal, .path, .range => return null,
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
        .binding => {
            _ = try bindPattern(ctx, pattern_id, null, ty);
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
            _ = try bindPattern(ctx, pattern_id, null, known_ty);
        },
        .struct_pat => {
            if (variantPayloadType(ctx, ctx.b.pats[pattern_id].kind, known_ty) != null) {
                _ = try bindPattern(ctx, pattern_id, null, known_ty);
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
                if (ls.ty) |ty| {
                    try ctx.annotated_inits.put(ctx.alloc, init, ty);
                    try addPin(ctx, init, ty);
                }
                try walkExpr(ctx, init, fn_body);
                const known_ty = annotatedOrKnownType(ctx, ls.ty, init);
                _ = try bindPattern(ctx, ls.pattern, init, known_ty);
            } else {
                _ = try bindPattern(ctx, ls.pattern, null, null);
            }
        },
        .let_else => |le| {
            try walkExpr(ctx, le.init, fn_body);
            const known_ty = annotatedOrKnownType(ctx, null, le.init);
            _ = try bindPattern(ctx, le.pattern, le.init, known_ty);
            try walkBlock(ctx, le.else_block, fn_body, null);
        },
        .expr => |n| try walkExpr(ctx, n, fn_body),
        .item => {},
    }
}

/// True when a declared return type carries no concrete type and therefore
/// cannot constrain anything. `-> impl Trait` is exactly this: the frontend
/// models it as an opaque placeholder that `materializeOpaqueFunctionReturns`
/// later fills in from the tail's own type. Pinning that placeholder onto the
/// tail would overwrite the real type with itself, leaving both the
/// materialization pass and the backend staring at an unresolved opaque.
fn returnTypeNamesNoType(t: types.Type) bool {
    return t == .@"opaque" and t.@"opaque".concrete == null;
}

/// Walk a block expression's statements and optional tail expression.
fn walkBlock(ctx: *Ctx, blk: exprs.BlockExpr, fn_body: exprs.NodeId, blk_node: ?exprs.NodeId) std.mem.Allocator.Error!void {
    std.debug.assert(fn_body < ctx.b.exprs.len);
    for (blk.statements) |s| try walkStmt(ctx, s, fn_body);
    if (blk.tail) |t| {
        if (blk_node) |bn| try addEq(ctx, bn, t);
        // A block's value IS its tail's value, so whatever an enclosing position
        // demands of the BLOCK it demands of the tail too. This is what carries
        // a `Result` down through a `match` arm that is itself a nested `match`
        // and on into the `Ok(..)`/`Err(..)` the inner one selects: the demand
        // is stated once, at the outer position, and Rust propagates it the
        // whole way in. Without it the inner match is asked for a type nothing
        // around it supplies, and an `.into()` in one of ITS arms has no target
        // at all.
        //
        // Recorded rather than constrained, because the tail has not been walked
        // yet and a conversion in it asks `contextualTypeAt` for what its
        // position demands while it is being walked.
        if (blk_node) |bn| {
            if (getKnownType(ctx, bn)) |demanded| {
                try ctx.expected_types.put(ctx.alloc, t, demanded);
            }
        }
        try walkExpr(ctx, t, fn_body);
        // The function body's own tail yields the declared return type, so pin
        // it the same way a `return` statement is pinned. Nested blocks yield
        // their own type and must stay unconstrained.
        if (blk_node != null and blk_node.? == fn_body) {
            if (findFnReturnType(ctx.b, fn_body)) |ret_ty| {
                if (!returnTypeNamesNoType(ret_ty)) {
                    try constrainExpectedType(ctx, t, ret_ty);
                }
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
        _ = try bindPattern(ctx, param, null, if (index == 0) param_ty else null);
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
    map: *InstantiationMap,
) void {
    var it = map.iterator();
    while (it.next()) |entry| alloc.free(entry.value_ptr.args.params);
    map.deinit(alloc);
    map.* = .empty;
}

/// Deep-clone an instantiation map into a new map (each value args dup'd).
fn cloneInstantiationMap(
    alloc: std.mem.Allocator,
    source: InstantiationMap,
) std.mem.Allocator.Error!InstantiationMap {
    var out: InstantiationMap = .empty;
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

/// The number of type parameters the declaration `def` binds in its OWN right.
///
/// Inherited parameters are deliberately not counted. An `impl<S> Hasher<S>`
/// method binds `S`, but an instantiation names the DECLARATION its
/// parameters appear in: `Hasher<S>` at `Sip24Rounds` is the struct's row, and
/// `(new_with_keys, [Sip24Rounds])` names an instantiation no declaration can
/// have — which is what `validateInstantiations` says when it counts the
/// entity's own parameters and finds none. This is the same count `ts_ext`'s
/// `calleeTypeParamCount` refuses a `.generic_inst` on, read from the same
/// table.
fn declaredTypeParamCount(ctx: *Ctx, def: exprs.DefId) usize {
    if (def >= ctx.b.bodies.len) return 0;
    return switch (ctx.b.bodies[def]) {
        .fn_ => |fb| fb.generic_params.len,
        .struct_ => |sb| sb.generic_params.len,
        .enum_ => |eb| eb.generic_params.len,
        else => 0,
    };
}

/// Collect the generic type-parameter names a declaration binds.
///
/// A declaration's type parameters are the ones it declares in its own right,
/// and — when it declares none — the ones the DECLARATION it is nested in
/// declares. A method inside `impl<S: Sip> Hasher<S>` binds `S` without ever
/// spelling it: `fn new_with_keys(k0: u64, k1: u64) -> Hasher<S>` is
/// `Hasher<S>` instantiated at whatever the impl was instantiated at, and a
/// method inside `struct Cell<T>` binds `T` the same way. That is the whole
/// rule, and both arms below read it the same way: what a callable binds is
/// what its scope DECLARES, never what its signature happens to mention.
///
/// Scanning a signature for type NAMES is not a weaker way of asking that
/// question. It asks a different one, and it is wrong in both directions. It
/// recovers nothing that is inherited — `Hasher<S>` names `S`, but a type
/// parameter has no row of its own in the type table, so by the time a call
/// reaches here the name reads as a concrete local type and contributes
/// nothing. And it invents what is not: `struct SipHasher24 { hasher:
/// Hasher<Sip24Rounds> }` declares no parameters at all, yet `Sip24Rounds` is
/// contributed by the field, the struct literal takes the generic path with a
/// phantom one-parameter list, and the row `(SipHasher24, [Sip24Rounds])`
/// names an instantiation no declaration can have. `instantiateGenericDef`
/// then takes the path this function exists to keep it off.
///
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
            } else if (try enclosingGenericParamNames(ctx, def)) |inherited| {
                // Copied out and released here: what the caller owns is the
                // slice this function hands back, not the scope walk's.
                defer alloc.free(inherited);
                try buf.appendSlice(alloc, inherited);
            }
        },
        .struct_ => |sb| try buf.appendSlice(alloc, sb.generic_params),
        .const_ => |cb| try collectTypeParamNamesFromType(alloc, ctx.b, &buf, cb.ty),
        .type_alias => |ta| try collectTypeParamNamesFromType(alloc, ctx.b, &buf, ta.target),
        else => return error.Unsupported,
    }
    const names = try buf.toOwnedSlice(alloc);
    return names;
}

/// What a `Cow` variant carries, given the `Cow<B>` its node names.
///
/// `B` is the BORROWED payload, and the two variants are the two halves Rust
/// spells on it: `Borrowed` holds a `&B` and `Owned` holds whatever `B::Owned`
/// is — a `String` for text, a `Vec<T>` for bytes. Nothing else in the tree
/// says which of the two a variant node is, so this is asked here from the
/// owner's own path and the variant's own name, and a `Cow` whose payload is
/// neither text nor a slice — a `_` a turbofish left open, say — answers
/// nothing rather than inventing one of the two.
fn cowVariantPayloadType(
    ctx: *Ctx,
    owner: types.ExternalNominal,
    variant: []const u8,
) ?types.Type {
    if (owner.path.len != 3) return null;
    if (!std.mem.eql(u8, owner.path[1], "borrow") or
        !std.mem.eql(u8, owner.path[2], "Cow"))
    {
        return null;
    }
    if (!std.mem.eql(u8, owner.path[0], "alloc") and
        !std.mem.eql(u8, owner.path[0], "std"))
    {
        return null;
    }
    const borrowed = owner.args[0];
    if (std.mem.eql(u8, variant, "Borrowed")) {
        if (types.isStr(borrowed)) return makeReferenceType(ctx, borrowed, false);
        const slice = switch (borrowed) {
            .slice => |value| value,
            else => return null,
        };
        return makeReferenceType(ctx, .{ .slice = slice }, false);
    }
    if (!std.mem.eql(u8, variant, "Owned")) return null;
    if (types.isStr(borrowed)) {
        return makeExternalNominalType(ctx, &.{ "alloc", "string", "String" }, &.{});
    }
    const slice = switch (borrowed) {
        .slice => |value| value,
        else => return null,
    };
    return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{slice.elem});
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
    // `str::len` counts the bytes of borrowed text, so a `&str` is a length
    // receiver exactly as the `&[u8]` it used to be read as was. It reaches the
    // nominal arm on its own now that it is a `reference` to the `str`
    // PRIMITIVE rather than a `[]const u8`, and that arm names the owners and
    // the iterators, none of which `str` is.
    if (types.isStr(ty)) return true;
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

/// What `base[index]` yields: one ELEMENT for a plain index, a RUN of them for
/// a range — which is a sequence again, not an element.
///
/// `initial_bytes[..unchanged_bytes_len].to_owned()` is the shape that makes
/// this load-bearing. Typed as its element, the index is a `u8`, and a `u8` has
/// no `to_owned` that produces a `Vec`, so the conversion is unreachable and
/// the whole chain behind it falls over for a reason that has nothing to do
/// with ownership.
///
/// EVERY range kind yields a slice, over an array exactly as over a slice.
/// `[T; N][..]` is not the whole array handed back: indexing an array delegates
/// to `<[T]>`, and `<[T] as Index<RangeFull>>::Output` is `[T]` — unsized. So
/// `bytes[..].to_owned()` is a `Vec<u8>` while `bytes.to_owned()` is a
/// `[u8; N]`, and the difference between those two is the difference between
/// this branch and the plain-index branch above, NOT something to be decided
/// here. An array keeps its storage when a CONSTRUCTION demands an array — an
/// array literal adapted to a demanded slice — which is a different mechanism
/// with a different answer, and not `Index<RangeFull>::Output`.
fn indexedResultType(ctx: *Ctx, base_type: types.Type, index_node: exprs.NodeId) ?types.Type {
    const is_range = index_node < ctx.b.exprs.len and
        ctx.b.exprs[index_node].kind == .range;
    if (!is_range) return indexedElementType(base_type);

    var base = base_type;
    for (0..128) |_| {
        switch (base) {
            .reference => |reference| base = reference.pointee,
            .boxed => |boxed| base = boxed.*,
            else => break,
        }
    }
    switch (base) {
        // `makeSliceType` takes MUTABILITY, and a slice already carries the
        // opposite sense, so the base's `const_` has to be flipped rather than
        // passed straight through — reading `[]const T` as mutable would hand
        // back `[]T` and lose the borrow the range preserves.
        .slice => |slice| return makeSliceType(ctx, slice.elem, !slice.const_),
        else => {
            const element = indexedElementType(base) orelse return null;
            return makeSliceType(ctx, element, false);
        },
    }
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

/// The type a local `type` alias stands for, or null when the path names no
/// alias body this pass can read. The terminal segment carries the EntityId
/// the path resolved to and a `type_alias` body names its own target, so a
/// chain of aliases resolves the same way the CST layer resolves a single one.
fn aliasTargetType(ctx: *Ctx, path: types.Path) ?types.Type {
    if (path.segments.len == 0) return null;
    const alias_id = path.segments[path.segments.len - 1].id orelse return null;
    if (alias_id >= ctx.b.bodies.len) return null;
    if (ctx.cg) |cg| {
        const entity = cg.symbol_table.get(alias_id) orelse return null;
        if (entity.kind != .type_alias) return null;
    }
    return switch (ctx.b.bodies[alias_id]) {
        .type_alias => |alias| alias.target,
        else => null,
    };
}

/// The primitive a type names, or null when it names none. A `.path` is a
/// local `type` alias and stands for the very value its alias body names, so
/// `type Chunk = u32;` has to answer for `u32`: the CST layer records the
/// alias path as the declared type wherever the alias is spelled, and an
/// answer that stopped at the name would leave `u32` arithmetic written
/// through that name looking like arithmetic on no primitive at all. The hop
/// bound matches the method resolver's scalar check, so a chain that loops
/// ends the same way in both.
fn aliasResolvedPrim(ctx: *Ctx, ty: types.Type) ?types.Prim {
    var current = ty;
    var hops: usize = 0;
    while (hops < 128) : (hops += 1) {
        switch (current) {
            .path => current = aliasTargetType(ctx, current.path) orelse return null,
            .@"opaque" => |opaque_type| {
                current = (opaque_type.concrete orelse return null).*;
            },
            .prim => |primitive| return primitive,
            else => return null,
        }
    }
    return null;
}

/// Whether `op` over a value of `prim` yields that same primitive. `!` is
/// defined for `bool` and for every integer, `~` for every integer, and `-`
/// for integers and floats; none of them changes the type of what it read,
/// which is the whole reason a position stating what one of them IS is also
/// stating what its operand is. `&` and `*` are absent — a borrow and a deref
/// each produce a different type, or none this pass can name.
fn unaryPreservesPrim(op: exprs.UnaryOp, prim: types.Prim) bool {
    const integer = isIntegerType(.{ .prim = prim });
    return switch (op) {
        .negate => integer or prim == .f32 or prim == .f64,
        .bit_not => integer,
        .logical_not => integer or prim == .bool,
        .ref, .deref => false,
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
        else if (isStdIoResult(external) and external.args.len == 1)
            // `std::io::Result<T>` IS `core::result::Result<T, io::Error>`
            // under another name, and it is spelled with its OWN path — so the
            // `BufReader::new(..)` every fallible I/O call answers with carries
            // an arm the row above cannot match. Its `Err` is the one error
            // below, which is what makes the `?` that unwraps it and the
            // `.unwrap()` that consumes it hand back the SAME type instead of
            // two spellings of one error that each read as the other's payload.
            if (error_payload) std_io_error_type else external.args[0]
        else
            null,
        else => null,
    };
}

fn unwrapTryType(ty: types.Type) ?types.Type {
    if (optionPayloadType(ty)) |payload| return payload;
    return resultPayloadType(ty, false);
}

/// The arm a `Result`/`Option` method hands back: the same arm whether the
/// method panics with a message or not.
///
/// `expect` is `unwrap` with a message argument and `expect_err` is `unwrap_err`
/// with one, and each returns exactly the arm its unwrapping twin does — the
/// message decides nothing about the type. `resolve_methods` already dispatches
/// the pair that way (`result_expect` takes the `Ok` arm, `result_expect_err`
/// the `Err` arm, admitted on every `Result`), so answering the same question
/// here is what keeps the frontend's type and the resolver's dispatch from
/// disagreeing about which arm a call names.
///
/// A receiver that is not a `Result` or an `Option` answers nothing for any of
/// the four, so a crate's own `expect` on some other type is left alone exactly
/// as its own `unwrap` is today.
fn knownTryArmMethodType(receiver_ty: types.Type, method_name: []const u8) ?types.Type {
    if (std.mem.eql(u8, method_name, "unwrap")) return unwrapTryType(receiver_ty);
    if (std.mem.eql(u8, method_name, "expect")) return unwrapTryType(receiver_ty);
    if (std.mem.eql(u8, method_name, "unwrap_err")) return resultPayloadType(receiver_ty, true);
    if (std.mem.eql(u8, method_name, "expect_err")) return resultPayloadType(receiver_ty, true);
    // `unwrap_or(default)` hands back the arm it OPENS, whatever the default
    // evaluates to: the default decides which value is produced, never what the
    // result is. Only `Option` has `unwrap_or_else`; a `Result` reaches the same
    // arm through `unwrap_or` alone, which is why the closure form asks the
    // option and the value form asks both.
    if (std.mem.eql(u8, method_name, "unwrap_or") or
        std.mem.eql(u8, method_name, "unwrap_or_else"))
    {
        if (optionPayloadType(receiver_ty)) |payload| return payload;
        if (std.mem.eql(u8, method_name, "unwrap_or")) {
            return resultPayloadType(receiver_ty, false);
        }
    }
    return null;
}

fn makeRawPtrType(ctx: *Ctx, elem: types.Type, mutable: bool) ?types.Type {
    const pointer = ctx.alloc.create(types.RawPtr) catch return null;
    pointer.* = .{ .mut = mutable, .pointee = elem };
    return .{ .raw_ptr = pointer };
}

/// `&T`, for any pointee — and `str` is a pointee like any other.
///
/// Rust's unsized `str` is NOT `[]const u8`. It is the primitive a borrow of
/// text points at, and `&str` is the reference to it. `impl ToOwned for str {
/// type Owned = String }` and `impl ToOwned for [T] { type Owned = Vec<T> }`
/// are therefore different traits for different pointees, and only the
/// spelling of the borrow says which one a call reaches. Collapsing `str` into
/// a byte slice here erased exactly that distinction, so the whole IR held one
/// shape for both borrowed text and borrowed bytes.
///
/// The backend lowers a `reference` to a `str` pointee to the same Zig
/// `[]const u8`, so the ABI is unchanged; the two stay separate types here.
fn makeReferenceType(ctx: *Ctx, elem: types.Type, mutable: bool) ?types.Type {
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
            break :blk types.substType(
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

/// The element of a chunked-slice carrier. `chunks` and `chunks_exact`
/// differ only in the carrier they name — both yield `&[T]` — so one matcher
/// serves both. The root stays `core`: `std::slice` is a re-export of the
/// same type, and inference only ever names the `core` path.
fn sliceChunkedElement(comptime name: []const u8, ty: types.Type) ?types.Type {
    return switch (ty) {
        .external_nominal => |external| blk: {
            if (external.path.len != 3 or external.args.len != 1) break :blk null;
            if (!std.mem.eql(u8, external.path[0], "core") or
                !std.mem.eql(u8, external.path[1], "slice") or
                !std.mem.eql(u8, external.path[2], name))
            {
                break :blk null;
            }
            break :blk external.args[0];
        },
        else => null,
    };
}

fn sliceChunkedType(comptime name: []const u8, ctx: *Ctx, elem: types.Type) ?types.Type {
    const args = ctx.alloc.alloc(types.Type, 1) catch return null;
    args[0] = elem;
    return .{ .external_nominal = .{
        .path = &.{ "core", "slice", name },
        .args = args,
    } };
}

fn chunksExactElement(ty: types.Type) ?types.Type {
    return sliceChunkedElement("ChunksExact", ty);
}

fn chunksExactType(ctx: *Ctx, elem: types.Type) ?types.Type {
    return sliceChunkedType("ChunksExact", ctx, elem);
}

/// `Chunks<T>` is the carrier `chunks(n)` returns. Unlike `ChunksExact`, it has
/// no remainder, so nothing narrows its element.
fn chunksElement(ty: types.Type) ?types.Type {
    return sliceChunkedElement("Chunks", ty);
}

fn chunksType(ctx: *Ctx, elem: types.Type) ?types.Type {
    return sliceChunkedType("Chunks", ctx, elem);
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

/// What `slice::split_first` hands back: `Option<(&T, &[T])>`, the first
/// element and the rest of the slice, both borrowed from the receiver.
///
/// Both borrows are SHARED whatever the receiver is. The method takes `&self`,
/// so it hands out a shared element even when it is reached through a `&mut`
/// slice; `split_first_mut` is a different method with a different signature,
/// and reading this one as mutable would invent an exclusivity the source
/// never asked for. The rest keeps the receiver's own slice type, so a
/// `&mut [T]` receiver still yields a `&[T]` here — exactly what the runtime
/// helper's `?struct { *const Elem, []const Elem }` can represent.
fn splitFirstType(ctx: *Ctx, receiver_ty: types.Type) ?types.Type {
    const element = sliceElementForMethod(receiver_ty) orelse return null;
    const first = makeReferenceType(ctx, element, false) orelse return null;
    const rest = makeSliceType(ctx, element, false) orelse return null;
    const tuple = ctx.alloc.alloc(types.Type, 2) catch return null;
    tuple[0] = first;
    tuple[1] = rest;
    return makeExternalNominalType(
        ctx,
        &.{ "core", "option", "Option" },
        &.{.{ .tuple = tuple }},
    );
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
    // `x.clone()` has the type of `x` for every `T: Clone`, and that is the
    // WHOLE of `Clone` — the trait says the result is `Self`, so there is no
    // receiver-specific rule to consult and none should be invented. One rule
    // here is also what lets a chain like `self.clone().into()` carry a source
    // type for its conversion: the `.into()` reads the type of what precedes
    // it, and without this the clone is where the chain stops.
    //
    // A reference or a box is excluded because `x.clone()` on `x: &T` resolves
    // to `T::clone`, which yields a `T` — not the reference. Those receivers
    // fall through to the rules below rather than claiming the wrong type.
    if (std.mem.eql(u8, method_name, "clone")) {
        switch (receiver_ty) {
            .reference, .boxed, .@"opaque" => {},
            else => return receiver_ty,
        }
    }
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
            // `String::as_bytes(&self) -> &[u8]` names the OWNED bytes, and
            // `String::as_str(&self) -> &str` names them as text. The second
            // is not the first written another way: `&[u8]` and `&str` are
            // different borrows of different pointees, and only the second one
            // can answer `.to_owned()` with a `String`.
            if (std.mem.eql(u8, method_name, "as_bytes") or
                std.mem.eql(u8, method_name, "as_ref"))
            {
                return makeSliceType(ctx, .{ .prim = .u8 }, false);
            }
            if (std.mem.eql(u8, method_name, "as_str")) {
                return makeReferenceType(ctx, types.str_type, false);
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
                // `String::extend` is `Extend<A> for String`, and every `A`
                // it is implemented for yields items the string appends — so
                // the result is `()` whatever the iterator produces, and the
                // backend reads the iterator off the argument, not the return.
                std.mem.eql(u8, method_name, "extend") or
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
            // `Cow::as_bytes` reads whichever representation the value holds,
            // so it hands back a borrow either way: `Cow<str>` reaches the
            // runtime's `[]const u8`, and `Cow<[T]>` reaches `[]const T`. It
            // is not the borrow `as_ref` gives — that one answers with the
            // payload itself, and for `Cow<str>` that is a `&str` rather than
            // the raw bytes it is made of.
            if (std.mem.eql(u8, method_name, "as_bytes")) {
                if (types.isStr(payload)) return makeSliceType(ctx, .{ .prim = .u8 }, false);
                return switch (payload) {
                    .slice => |slice| makeSliceType(ctx, slice.elem, false),
                    else => payload,
                };
            }
            // `into_owned` is the consuming half: it moves and hands back
            // `B::Owned`. `to_owned` is NOT that operation — a `Cow` is `Clone`,
            // so the blanket `impl<T: Clone> ToOwned for T { type Owned = T }`
            // applies to it and the result is a `Cow` of the SAME payload, read
            // through `&self`. Typing `to_owned` as the owned payload would
            // make a call that only borrows consume its receiver.
            // `value` is the Cow's own nominal, so handing it back is handing
            // back the same `Cow<B>` — which is what a clone of one is.
            if (std.mem.eql(u8, method_name, "to_owned")) return .{ .external_nominal = value };
            if (std.mem.eql(u8, method_name, "into_owned")) {
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

        // `str` is the unsized primitive, so it names no owner of its own and
        // `impl ToOwned for str { type Owned = String }` is the operation that
        // makes one: a copy of the borrowed bytes into a fresh `String`. It is
        // deliberately NOT the slice rule below, and now it does not even
        // reach it: a `&str` receiver peels to the `str` PRIMITIVE here, while
        // a `&[u8]` receiver peels to a slice and is answered by the `Vec<u8>`
        // that `impl ToOwned for [T]` names. The two spellings are different
        // Rust borrows and they own differently.
        if (types.isStr(.{ .external_nominal = value })) {
            if (std.mem.eql(u8, method_name, "to_owned")) {
                return makeExternalNominalType(ctx, &.{ "alloc", "string", "String" }, &.{});
            }
        }
        // `String::from_utf8` hands back a `FromUtf8Error` when the bytes it
        // consumed are not UTF-8, and that error owns the bytes AND retains
        // why they failed. `utf8_error` is the half that says why, and it is
        // the very `core::str::Utf8Error` a direct `str::from_utf8` produces —
        // so the two paths hand the same value back and the caller's `Err`
        // arm has one type either way.
        const is_from_utf8_error = value.path.len == 3 and
            (std.mem.eql(u8, value.path[0], "alloc") or
                std.mem.eql(u8, value.path[0], "std")) and
            std.mem.eql(u8, value.path[1], "string") and
            std.mem.eql(u8, value.path[2], "FromUtf8Error") and
            value.args.len == 0;
        if (is_from_utf8_error and std.mem.eql(u8, method_name, "utf8_error")) {
            return makeExternalNominalType(ctx, &.{ "core", "str", "Utf8Error" }, &.{});
        }
    }

    // `to_vec` and `to_owned` answer DIFFERENTLY on an array, and Rust is
    // explicit about why. `to_vec` unsizes: `[T; N]` coerces to `[T]` and then
    // `impl<T: Clone> ToOwned for [T] { type Owned = Vec<T> }` yields a `Vec<T>`,
    // so both a slice and an array produce one. `to_owned` does NOT unsize — an
    // array is `Clone` in its own right (`impl<T: Clone, const N: usize> Clone
    // for [T; N]`), so the blanket `impl<T: Clone> ToOwned for T { type Owned =
    // T }` is what applies and `[T; N].to_owned()` is the SAME array. Typing
    // it as a `Vec` would hand the call a different Rust type than the source
    // declares.
    if (std.mem.eql(u8, method_name, "to_vec")) {
        if (sliceElementForMethod(receiver_ty)) |element| {
            return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{element});
        }
    }
    if (std.mem.eql(u8, method_name, "to_owned")) {
        switch (peelToSliceOrArray(receiver_ty) orelse return null) {
            .slice => |slice| {
                return makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{slice.elem});
            },
            .array => |array| return .{ .array = array },
            else => return null,
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

/// The slice or array a receiver really is, behind its references and boxes, or
/// null when it names something else.
///
/// `str` is deliberately not a slice here. It is a distinct unsized primitive
/// whose `ToOwned` is a `String`, and treating it as `[]const u8` would type
/// `&str::to_owned` as a `Vec<u8>` — a different Rust owner than the one the
/// source declared.
fn peelToSliceOrArray(ty: types.Type) ?types.Type {
    var current = ty;
    for (0..128) |_| {
        switch (current) {
            .slice, .array => return current,
            .reference => |reference| current = reference.pointee,
            .boxed => |boxed| current = boxed.*,
            else => return null,
        }
    }
    return null;
}

/// The type this position DEMANDS of its expression, however the demand is
/// spelled, or null when nothing demands anything here.
///
/// Three sources, in Rust's own order of authority: an explicit annotation, an
/// expectation an enclosing position already recorded for this node, and the
/// declared return of a function whose body tail this node is.
///
/// A declared return that spells itself `Self` is the fourth case and the one
/// that matters for conversions. The `from` of `impl From<A> for B` is written
/// `-> Self`, and its arms are full of `value.into()` calls whose target is
/// that very `B` — the impl's self type, which the enclosing declaration does
/// name even though the function's own signature does not.
fn contextualTypeAt(ctx: *Ctx, node: exprs.NodeId, fn_body: ?exprs.NodeId) ?types.Type {
    if (annotatedType(ctx, node)) |annotated| return annotated;
    if (ctx.expected_types.get(node)) |expected| return expected;
    const body = fn_body orelse return null;
    const tail = expectedTypeForTail(ctx, node, body) orelse return null;
    if (returnTypeNamesNoType(tail)) return null;
    if (!typeSpellsSelf(tail)) return tail;
    const self_ty = currentImplSelfType(ctx) orelse return null;
    if (returnTypeNamesNoType(self_ty)) return null;
    return self_ty;
}

/// Whether a declared type is the `Self` of its own declaration, which names
/// the enclosing impl rather than any type a table can hold.
fn typeSpellsSelf(t: types.Type) bool {
    return t == .path and t.path.segments.len == 1 and
        std.mem.eql(u8, t.path.segments[0].name, "Self");
}

/// The result of a concrete `x.into()`, which is the type it is converted INTO.
///
/// `.into()` is written against `Into<U> for T where U: From<T>`, so its
/// receiver names only the source: `&str` reaches a `String` AND a `Cow<str>`,
/// `String` reaches a `Cow<str>` AND a `Vec<u8>`, and none of them is a default
/// Rust would pick on its own. The target is therefore read off the position
/// (`contextualTypeAt`) and never invented — a call nothing constrains stays
/// untyped, which leaves the resolver free to refuse it with a reason instead
/// of emitting one of the conversions at random.
///
/// The pair is checked before the target is returned, and both checks are the
/// resolver's own predicates — `lookupStdIntoMethod` for std's ownership impls,
/// `userFromImplMethod` for one this crate wrote — so the type recorded here and
/// the dispatch `resolveMethods` admits afterwards cannot disagree about which
/// `(source, target)` pairs are conversions at all.
fn knownStdIntoType(
    ctx: *Ctx,
    node: exprs.NodeId,
    receiver_ty: types.Type,
    method_name: []const u8,
    fn_body: ?exprs.NodeId,
) ?types.Type {
    if (!std.mem.eql(u8, method_name, "into")) return null;
    const target = contextualTypeAt(ctx, node, fn_body) orelse return null;
    // Two things can make a pair a conversion: std's own ownership impls, or
    // an `impl From<A> for B` this crate wrote. Both questions are asked of
    // the resolver's own predicates so that the type recorded here and the
    // dispatch admitted after it cannot disagree about which pairs exist.
    const cg = ctx.cg orelse return null;
    if (resolve_methods.lookupStdIntoMethod(receiver_ty, target) == null and
        resolve_methods.userFromImplMethod(cg, ctx.b, receiver_ty, target) == null)
    {
        return null;
    }
    return target;
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

/// The type an `impl Trait` receiver's own bound declares under `name`.
///
/// `fn generate_iter(len: usize) -> impl Iterator<Item = (usize, usize)>`
/// returns an OPAQUE whose `Iterator` bound carries the binding in
/// `associated_types`. That list is the only place the source writes the
/// element type down: the concrete carrier the frontend may have recovered
/// alongside the opaque describes the ADAPTER, not what it yields, and a
/// receiver that is not an opaque at all — a slice, a `Vec`, a local struct —
/// declares no bound, so it reads as "nothing declared here" and the caller
/// keeps looking or gives up as before.
pub fn declaredBoundType(ty: types.Type, name: []const u8) ?types.Type {
    var current = ty;
    while (true) {
        switch (current) {
            .reference => |reference| current = reference.pointee,
            .raw_ptr => |raw_ptr| current = raw_ptr.pointee,
            .boxed => |boxed| current = boxed.*,
            .@"opaque" => |opaque_type| {
                for (opaque_type.bounds) |bound| {
                    for (bound.associated_types) |binding| {
                        if (std.mem.eql(u8, binding.name, name)) return binding.ty;
                    }
                }
                return null;
            },
            else => return null,
        }
    }
}

/// The associated type an `impl Iterator for Self` block declares, for a
/// receiver that is a nominal the graph knows.
///
/// `declaredBoundType` answers only for a receiver that CARRIES its bounds — an
/// `impl Trait`, an opaque — because those keep the bindings on the type itself.
/// A concrete nominal keeps them nowhere on the type: `type Item = &'a str;` is
/// written on the impl, and nothing inside `PercentEncode`'s nominal says so.
/// Reading it there is the whole of what lets `iter.next()` have a type at all.
///
/// The trait is proved by its FULL path, never by the leaf name `Iterator`: a
/// crate that declares its own `Iterator` writes the same word here and must
/// not answer for core's. `std::io` re-exports core's, so both spellings reach
/// the same predicate.
const core_iter_iterator: []const []const u8 = &.{ "core", "iter", "Iterator" };

/// Whether a `Self` path in an `impl` header and a receiver's nominal are the
/// SAME type declaration.
///
/// The impl answers for its own `Self`, and that is a declaration rather than a
/// word. Two modules may each declare their own `Iter`, and
/// `impl Iterator for a::Iter` says nothing about `b::Iter`; comparing the leaf
/// name alone let whichever impl the scan reached first answer for both, and
/// every `next()` on the other one then carried the wrong element type.
///
/// A terminal entity id IS that declaration, so two ids have to be the same
/// one. An id on one side and a bare name on the other is a comparison this
/// pass cannot make at all: the bare side names a type nothing has resolved
/// yet, so it is not evidence of the same declaration and does not stand in for
/// one. Only a pair of fully unresolved names falls back to the spelling, which
/// is the case a canonical std path produces — there is no local entity on
/// either side to compare.
/// Two ids are compared before anything about the spelling, and the spelling
/// is not compared at all when they agree. The SAME declaration is written
/// with and without its qualifier: `impl Iterator for crate::enc::Iter`
/// declares the type a receiver `Iter` in that module already names, so
/// requiring equal segment counts first refused a pair whose terminal ids
/// were the same one.
fn sameNominalDeclaration(left: types.Path, right: types.Path) bool {
    if (left.segments.len == 0 or right.segments.len == 0) return false;
    const left_id = left.segments[left.segments.len - 1].id;
    const right_id = right.segments[right.segments.len - 1].id;
    if (left_id != null and right_id != null) return left_id.? == right_id.?;
    if (left_id != null or right_id != null) return false;
    if (left.segments.len != right.segments.len) return false;
    for (left.segments, right.segments) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name)) return false;
    }
    return true;
}

fn implAssociatedType(ctx: *Ctx, ty: types.Type, name: []const u8) ?types.Type {
    const cg = ctx.cg orelse return null;
    const nominal = switch (ty) {
        .path => |path| path,
        else => return null,
    };
    if (nominal.segments.len == 0) return null;
    for (cg.symbol_table.entities.items) |entity| {
        if (entity.kind != .impl_) continue;
        if (entity.id >= ctx.b.bodies.len) continue;
        const implementation = switch (ctx.b.bodies[entity.id]) {
            .impl_ => |body| body,
            else => continue,
        };
        const trait_path = implementation.trait_path orelse continue;
        // The trait is proved by its FULL path through the same canonical
        // predicate `bodies.genericBound` uses, never by a leaf name: a crate
        // that declares its own `Iterator` would otherwise answer with its own
        // element type and every conversion built on it would be wrong.
        if (!bodies.boundPathMatches(cg, entity.id, trait_path, core_iter_iterator)) continue;
        const self_ty = switch (implementation.self_ty) {
            .path => |path| path,
            else => continue,
        };
        if (!sameNominalDeclaration(self_ty, nominal)) continue;
        // `type Item = &'a str;` inside the impl is a TYPE ALIAS on that impl's
        // OWN item list — which is how Rust spells the association, and where
        // the frontend puts it. It is NOT an associated-type binding on the
        // trait (`trait_associated_types`), which stays EMPTY for an impl that
        // declares the item in its body rather than in the impl header. Reading
        // only the binding therefore finds nothing at all, which is exactly why
        // `iter.next()` stayed untyped.
        //
        // So the declaration is read from where it is written, and the trait
        // binding is kept as the fallback for an impl that does use the
        // `Iterator<Item = T>` spelling.
        for (implementation.assoc_items) |assoc| {
            if (assoc >= ctx.b.bodies.len) continue;
            const child = cg.symbol_table.get(assoc) orelse continue;
            if (!std.mem.eql(u8, child.name, name)) continue;
            const alias = switch (ctx.b.bodies[assoc]) {
                .type_alias => |body| body,
                else => continue,
            };
            return alias.target;
        }
        for (implementation.trait_associated_types) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.ty;
        }
    }
    return null;
}

fn iteratorItemType(ctx: *Ctx, ty: types.Type) ?types.Type {
    // `impl Iterator<Item = T>` states the element outright. The carrier
    // reconstruction below can only rediscover it for the adapters it
    // models, so the declared binding is asked first and stands on its own.
    if (declaredBoundType(ty, "Item")) |declared| return declared;
    // A concrete NOMINAL carries no bounds of its own, so the binding has to be
    // read off the impl that declared it: `impl<'a> Iterator for PercentEncode<'a>
    // { type Item = &'a str; }` is the only place that element type is written.
    if (implAssociatedType(ctx, ty, "Item")) |declared| return declared;
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
            // `Chunks<T>` and `ChunksExact<T>` hand out the chunked slice
            // itself — `&[T]`, never its element — so a chain rooted at
            // `.chunks(n)` carries a slice item that indexes into it. The
            // two carriers differ only in the tail `remainder()` keeps, which
            // says nothing about what `next()` yields.
            if (external.args.len == 1 and
                (publicIteratorPath(external, "slice", "Chunks") or
                    publicIteratorPath(external, "slice", "ChunksExact")))
            {
                const chunk = makeSliceType(ctx, external.args[0], false) orelse return null;
                return makeReferenceType(ctx, chunk, false);
            }
            if ((publicIteratorPath(external, "iter", "StepBy") or
                publicIteratorPath(external, "iter", "Skip") or
                publicIteratorPath(external, "iter", "Rev")) and
                external.args.len == 1)
            {
                return iteratorItemType(ctx, external.args[0]);
            }
            if (publicIteratorPath(external, "iter", "Copied") and external.args.len == 1) {
                const item = iteratorItemType(ctx, external.args[0]) orelse return null;
                return switch (item) {
                    .reference => |reference| reference.pointee,
                    else => null,
                };
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
    if (std.mem.eql(u8, method_name, "copied")) {
        const item = iteratorItemType(ctx, receiver) orelse return null;
        if (item != .reference) return null;
        return makeExternalNominalType(ctx, &.{ "core", "iter", "Copied" }, &.{receiver});
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
    // `next` yields `Option<Item>`. It is the one method every iterator answers
    // with the element type the source declares ONCE, on its impl, and repeats
    // nowhere at the use site — so a caller that cannot read that binding has
    // nothing else to work from.
    //
    // This is what a `Some(x)` arm binds `x` to. Without it the binding stays
    // whatever placeholder stands in for the element, and every conversion
    // chained off it is unresolvable for a reason that has nothing to do with
    // the conversion: in percent's `From<PercentEncode> for Cow`, `first.into()`
    // fails not because the conversion is wrong but because `first` was never
    // known to be a `&str`.
    if (std.mem.eql(u8, method_name, "next")) {
        const element = iteratorItemType(ctx, receiver) orelse return null;
        return makeExternalNominalType(ctx, &.{ "core", "option", "Option" }, &.{element});
    }
    if (std.mem.eql(u8, method_name, "zip")) {
        if (args.len == 0) return null;
        const other = getKnownType(ctx, args[0]) orelse return null;
        return makeExternalNominalType(ctx, &.{ "core", "iter", "Zip" }, &.{ receiver, other });
    }

    return null;
}

/// The container `collect::<B>()` hands back, or null when the call names none.
///
/// Rust's signature is `fn collect<B: FromIterator<Self::Item>>(self) -> B`,
/// so the target is whatever the source says `B` is, in this order:
///
///  1. the turbofish, which is the caller's own binding for it;
///  2. an explicit annotation on the binding the call initialises;
///  3. the type the call's POSITION expects — the enclosing function's
///     return type for a call in tail position.
///
/// `bindTurbofishCollectedElement` has already filled the one half a turbofish
/// may leave open — `Vec<_>` takes its element from the receiver's `Item` — so
/// the argument read here is the finished target. What is still standing is a
/// placeholder no bound says anything about, and that is not a type: the
/// positional rules below answer for it instead.
///
/// The positional rules are why `xs.map(..).collect()` is a `Vec<u8>` in a
/// function declared `-> Result<Vec<u8>, u8>` and not a `Vec<Result<u8, u8>>`
/// of the items it happens to yield. Rust reads the same target off the same
/// position, and the items say only what the container is FILLED with.
///
/// The receiver has to be an `Iterator` this pass can read an `Item` off. A
/// method called `collect` on anything else is a different method whose result
/// this signature says nothing about, so it is left alone.
fn knownCollectTargetType(
    ctx: *Ctx,
    node: exprs.NodeId,
    expected: ?types.Type,
) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    const call = switch (ctx.b.exprs[node].kind) {
        .method_call => |value| value,
        else => return null,
    };
    const receiver_ty = getKnownType(ctx, call.receiver) orelse return null;
    if (iteratorItemType(ctx, receiver_ty) == null) return null;
    switch (call.generic_args.len) {
        0 => {},
        1 => {
            const named = call.generic_args[0];
            if (!containsInferPlaceholder(named)) return named;
        },
        // `collect` takes no type arguments but its one, so more than one is
        // not a call this signature describes.
        else => return null,
    }
    const contextual = annotatedType(ctx, node) orelse expected orelse return null;
    return if (isCollectTargetType(ctx, contextual)) contextual else null;
}

/// The type an explicit annotation wrote on `node`, or null when none did.
///
/// The statement walk records it before it walks the initialiser, so a
/// `collect` under the binding reads the annotation that names its target.
fn annotatedType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    const type_id = ctx.annotated_inits.get(node) orelse return null;
    if (type_id >= ctx.b.types.len) return null;
    return ctx.b.types[type_id];
}

/// Whether `ty` is a shape `collect::<B>()` can hand back.
///
/// This is the whitelist of containers Rust's own `FromIterator` impls cover,
/// not a guess at one: an expected type outside it is left alone, so the call
/// stays untyped and the resolver keeps refusing the operator over it instead
/// of typing it against something no collection can produce.
fn isCollectTargetType(ctx: *Ctx, ty: types.Type) bool {
    return switch (ty) {
        .external_nominal => |external| isFromIteratorContainer(external.path),
        // `Result<C, E>` and `Option<C>` collect by running the same
        // `FromIterator` and stopping on the first failure, so the container
        // is the arm the payload sits in, not the arm itself.
        .result => |res| isCollectTargetType(ctx, res.ok),
        .option => |inner| isCollectTargetType(ctx, inner.*),
        .path => |path| if (path.segments.len == 1)
            isEnclosingGenericParam(ctx, path.segments[0].name)
        else
            false,
        .generic_inst => |inst| blk: {
            const cg = ctx.cg orelse break :blk false;
            const entity = cg.symbol_table.get(inst.decl) orelse break :blk false;
            break :blk isEnclosingGenericParam(ctx, entity.name);
        },
        else => false,
    };
}

/// Whether a `core`/`std`/`alloc` path names a container Rust collects into.
fn isFromIteratorContainer(path: []const []const u8) bool {
    if (path.len < 2) return false;
    const name = path[path.len - 1];
    const named = std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Vec") or
        std.mem.eql(u8, name, "BTreeMap") or
        std.mem.eql(u8, name, "BTreeSet") or
        std.mem.eql(u8, name, "HashMap") or
        std.mem.eql(u8, name, "HashSet") or
        std.mem.eql(u8, name, "Result") or
        std.mem.eql(u8, name, "Option");
    if (!named) return false;
    const root = path[0];
    return std.mem.eql(u8, root, "core") or
        std.mem.eql(u8, root, "std") or
        std.mem.eql(u8, root, "alloc");
}

/// Whether `name` spells a type parameter of the function being walked.
///
/// A `C: FromIterator<Item>` parameter IS the un-instantiated target of a
/// `collect`, and what it becomes is the instantiation's business: the same
/// `char` items collect into a `String` and into a `Vec<char>`. Only a
/// parameter the ENCLOSING function declares can be that; a crate-local
/// nominal in the same position is not a `FromIterator` and stays out.
fn isEnclosingGenericParam(ctx: *Ctx, name: []const u8) bool {
    if (name.len == 0) return false;
    const def = ctx.current_fn orelse return false;
    if (def >= ctx.b.bodies.len) return false;
    const params = switch (ctx.b.bodies[def]) {
        .fn_ => |function| function.generic_params,
        else => return false,
    };
    for (params) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}
/// The container an iterator chain's `collect` hands back, read off the
/// position the chain sits in.
///
/// The method form already reads its target this way (`knownCollectTargetType`),
/// and a chain lowered as one expression node has the same annotation and the
/// same expected return type in front of it. Rust reads the target off that
/// position too, so `xs.map(..).collect()` under a `Result<Vec<u8>, u8>`
/// binding is that `Result` and not a `Vec` of the items the chain happens to
/// yield: the items say only what the container is FILLED with.
fn collectTargetFromContext(ctx: *Ctx, node: ?exprs.NodeId) ?types.Type {
    const at_node = node orelse return null;
    const contextual = annotatedType(ctx, at_node) orelse
        ctx.expected_types.get(at_node) orelse
        return null;
    if (!isCollectTargetType(ctx, contextual)) return null;
    return contextual;
}

fn knownIteratorChainType(
    ctx: *Ctx,
    node: ?exprs.NodeId,
    chain: exprs.IteratorChainExpr,
) ?types.Type {
    if (chain.terminal == .sum) return iteratorChainElementType(ctx, chain);
    if (chain.terminal == .collect_vec) {
        if (collectTargetFromContext(ctx, node)) |target| return target;
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

/// The receiver a declared type stands for, as the resolver reads it.
///
/// A nominal that RECORDS its declaration keeps it: a name-only lookup would
/// see the spelling and nothing else, and siphasher declares
/// `struct Hasher<S>` once per module — one name, two declarations — so the
/// name is not the identity. Everything else keeps this module's own rule
/// that a receiver's type is never inferred from its spelling: a `path`
/// whose terminal segment records no entity names nothing here, exactly as
/// before.
fn canonicalReceiver(ctx: *const Ctx, ty: types.Type) ?resolve_methods.SourceReceiver {
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
    if (resolve_methods.nominalDeclarationId(cg, base) != null) {
        return resolve_methods.declaredReceiver(cg, base);
    }
    return switch (base) {
        .prim => |primitive| .{ .name = @tagName(primitive) },
        .path => |path| blk: {
            if (path.segments.len == 0) break :blk null;
            const terminal = path.segments[path.segments.len - 1];
            const def = terminal.id orelse break :blk null;
            const entity = cg.symbol_table.get(def) orelse break :blk null;
            break :blk .{ .name = entity.name };
        },
        .generic_inst => |instance| blk: {
            const entity = cg.symbol_table.get(instance.decl) orelse break :blk null;
            break :blk .{ .name = entity.name };
        },
        .external_nominal => |external| if (external.path.len > 0)
            .{ .name = external.path[external.path.len - 1] }
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

/// The declared return type of the method a call names, whether the call still
/// holds a `method_ref` (whose trait signature carries it) or `resolveMethods`
/// already rewrote the entity to the concrete `fn_`.
fn methodDeclaredReturnType(ctx: *Ctx, def: exprs.DefId) ?types.Type {
    if (def < ctx.b.bodies.len) {
        switch (ctx.b.bodies[def]) {
            .fn_ => |fn_body| return fn_body.ret,
            else => {},
        }
    }
    return traitAssociatedReturnType(ctx, def);
}

/// The trait method signature a turbofish binds against: the declared return
/// and the ordered type parameters the call supplies arguments for.
const TraitMethodSignature = struct {
    ret: types.Type,
    /// Borrowed from the body table, which the frontend arena owns.
    generic_params: []const []const u8,
};

/// The signature of the trait method that provides `method_name`, or null
/// when this crate declares no such trait.
///
/// This is the second half of what a method call's callee can carry, for the
/// shape that carries nothing: body lowering synthesizes one `method_ref` per
/// call site and parents it to the enclosing callable or module
/// (`pushMethodRef`), leaving its body slot `.none`. There is no `fn_` to read
/// a return type or a parameter list from, and `traitAssociatedReturnType`
/// cannot reach one either, because it reads the trait off the parent and the
/// parent is a function. A turbofish on such a call then binds to nothing, and
/// `xs.encode_hex::<String>()` — whose `ToHex::encode_hex` declares
/// `fn encode_hex<T>(&self) -> T`, the bare parameter — stays untyped however
/// the rest of the tree is read.
///
/// The trait is found the way Rust finds the method: by the name the call
/// spells, among the traits this crate declares, narrowed to those whose
/// method takes as many type parameters as the turbofish supplies. The arity
/// is what keeps `ToHex::encode_hex` from answering for a same-named method
/// elsewhere, and two DIFFERENT traits answering means the call is ambiguous
/// in Rust too — so neither of them wins here.
fn traitDeclaredMethod(
    ctx: *const Ctx,
    method_name: []const u8,
    arg_count: usize,
) ?TraitMethodSignature {
    if (arg_count == 0 or method_name.len == 0) return null;
    const cg = ctx.cg orelse return null;
    var found: ?TraitMethodSignature = null;
    var owner: ?spine.EntityId = null;
    for (cg.symbol_table.entities.items, 0..) |entity, index| {
        if (entity.kind != .trait_ or index >= ctx.b.bodies.len) continue;
        const trait_body = switch (ctx.b.bodies[index]) {
            .trait_ => |body| body,
            else => continue,
        };
        for (trait_body.methods) |declared| {
            if (!std.mem.eql(u8, declared.name, method_name)) continue;
            if (declared.generic_params.len != arg_count) continue;
            if (owner) |first| {
                if (first != index) return null;
            }
            owner = @intCast(index);
            found = .{ .ret = declared.ret, .generic_params = declared.generic_params };
        }
    }
    return found;
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
        // A signature this module can COMPLETE is asked to complete itself
        // before the expectation is consulted at all. `impl<I: Integer>
        // FromRadix10Checked for I` declares `(Option<I>, usize)`, which is not
        // concrete in the callee — but the call records the RECEIVER as its one
        // type argument, so `u8::from_radix_10_checked(..)` binds that `I` to
        // `u8` and the call produces the `(Option<u8>, usize)` the source
        // compares it against. Reading the expectation first returned it (or
        // nothing at all) and never got that far, which is what left a `_`
        // placeholder where a whole tuple belonged.
        var completed: ?types.Type = null;
        if (callGenericArguments(ctx, node, def)) |generic_args| {
            const names = getGenericParamNames(ctx, def) catch null;
            if (names) |param_names| {
                defer ctx.alloc.free(param_names);
                const substituted = types.substType(
                    ctx.alloc,
                    declared,
                    param_names,
                    generic_args,
                ) catch null;
                if (substituted) |resolved| {
                    if (isConcreteDerivedType(resolved)) completed = resolved;
                }
            }
        }
        if (completed) |resolved| return resolved;
        if (!isConcreteDerivedType(declared)) {
            if (ctx.expected_types.get(node)) |expected| {
                // A placeholder is not an expectation, it is the record of
                // there being none: `assert_eq!(a, b)` states `_` for the side
                // nothing else types, and handing that back is what put the hole
                // where a whole tuple belonged. A signature this module could
                // complete and did not has said nothing worth keeping.
                if (!isInferPlaceholderType(expected)) return expected;
                return null;
            }
            return null;
        }
        return declared;
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
    const receiver = canonicalReceiver(ctx, receiver_ty) orelse return null;
    const method_def = switch (resolve_methods.lookupSourceMethodFor(cg, ctx.b, receiver, method_name)) {
        .inherent, .trait_ => |definition| definition,
        .ambiguous, .missing => return null,
    };
    return knownSourceMethodReturnType(ctx, receiver_ty, method_def);
}

fn knownSourceMethodReturnType(ctx: *Ctx, receiver_ty: types.Type, method_def: spine.EntityId) ?types.Type {
    const cg = ctx.cg orelse return null;
    if (method_def >= ctx.b.bodies.len) return null;

    const function = switch (ctx.b.bodies[method_def]) {
        .fn_ => |fn_body| fn_body,
        else => return null,
    };
    const return_type = function.ret;

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
    if (generic_args.len == 0) {
        if (types.typeContainsParam(return_type, function.generic_params)) return null;
        return if (isConcreteDerivedType(return_type) or types.mentionsSelf(return_type))
            return_type
        else
            null;
    }

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
            .type_ => |type_param| type_names.append(ctx.alloc, type_param.name) catch {
                ctx.g.derived_error = true;
                return null;
            },
            else => {},
        }
    }
    if (!types.typeContainsParam(return_type, type_names.items)) {
        return if (types.typeContainsParam(return_type, function.generic_params))
            null
        else
            return_type;
    }
    if (type_names.items.len != generic_args.len) return null;
    const substituted = types.substType(ctx.alloc, return_type, type_names.items, generic_args) catch {
        ctx.g.derived_error = true;
        return null;
    };
    if (types.typeContainsParam(substituted, function.generic_params) or
        (!isConcreteDerivedType(substituted) and !types.mentionsSelf(substituted)))
    {
        types.freeSubstitutedType(ctx.alloc, return_type, substituted, type_names.items, generic_args);
        return null;
    }
    // Successful derived types live in the frontend arena; the driver
    // materializes them with the other inferred signature types.
    return substituted;
}
/// `std::io::Error`, the error every fallible standard I/O method here produces
/// and the arm `std::io::Result<T>` carries. One constant for both spellings,
/// so the `?` that unwraps a `fill_buf` and the `.unwrap()` that consumes one
/// do not hand back two types that each read as the other's payload.
const std_io_error_type: types.Type = .{ .external_nominal = .{
    .path = &.{ "std", "io", "Error" },
} };

/// Whether a nominal is `std::io::Result<T>`, the alias every fallible standard
/// I/O method in a crate is written with and a different path from the
/// `core::result::Result` the same type is spelled `Result` for.
fn isStdIoResult(external: types.ExternalNominal) bool {
    return external.path.len == 3 and
        std.mem.eql(u8, external.path[0], "std") and
        std.mem.eql(u8, external.path[1], "io") and
        std.mem.eql(u8, external.path[2], "Result");
}

/// What a standard I/O method hands back. `consume` is the one that hands back
/// nothing at all, and `fill_buf` the only one that hands back a borrow of the
/// reader's own buffer rather than a result over `()`.
const IoMethodResult = enum { unit, fallible_unit, borrowed_bytes };

/// The `std::io` trait whose bound a canonical I/O method name requires, beside
/// the shape of the value that method produces.
const IoMethod = struct {
    trait: []const []const u8,
    result: IoMethodResult,
};

/// The `std::io` trait whose bound a canonical I/O method name requires, or null
/// for every other name.
///
/// This is the one place that answer is given, and both of its readers read it
/// here: the result type below, and the buffer constraint further down. They
/// therefore cannot disagree about which calls are the standard ones, and a
/// method is not one of these until it is named here — which is where whoever
/// adds one will find it.
///
/// Pure, and it answers a question about a name alone. The receiver's bound is
/// the caller's to prove, and proving it is a symbol-table walk this must not
/// repeat merely to be reused.
fn stdIoMethod(method_name: []const u8) ?IoMethod {
    if (std.mem.eql(u8, method_name, "read_exact")) {
        return .{ .trait = &.{ "std", "io", "Read" }, .result = .fallible_unit };
    }
    if (std.mem.eql(u8, method_name, "write_all")) {
        return .{ .trait = &.{ "std", "io", "Write" }, .result = .fallible_unit };
    }
    // `BufRead` is a SUPERTRAIT of `Read`, so an `R: BufRead` proves both and
    // the two rows above cannot answer for these names. They carry their own
    // trait instead of a longer path for the same method, which is what keeps
    // `fill_buf`'s result from being read as a `Read` one.
    if (std.mem.eql(u8, method_name, "fill_buf")) {
        return .{ .trait = &.{ "std", "io", "BufRead" }, .result = .borrowed_bytes };
    }
    if (std.mem.eql(u8, method_name, "consume")) {
        return .{ .trait = &.{ "std", "io", "BufRead" }, .result = .unit };
    }
    return null;
}

fn stdIoMethodTrait(method_name: []const u8) ?[]const []const u8 {
    const method = stdIoMethod(method_name) orelse return null;
    return method.trait;
}

/// Infer the standard I/O result only when the receiver's generic parameter
/// carries the corresponding non-optional trait bound.
fn knownIoMethodResultType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
) ?types.Type {
    const method = stdIoMethod(method_name) orelse return null;
    const cg = ctx.cg orelse return null;
    const owner = ctx.current_fn orelse return null;
    if (bodies.genericBound(cg, ctx.b, owner, receiver_ty, method.trait) == null) return null;
    if (method.result == .unit) return .{ .prim = .unit };
    // `BufRead::fill_buf(&mut self) -> io::Result<&[u8]>` lends out the bytes it
    // has already buffered. The borrow is SHARED — the reader writes through
    // `&mut self`, not through the slice it returns, and a mutable one would make
    // `h.write_slice(buf)` read a different program from the one written.
    const ok: types.Type = if (method.result == .borrowed_bytes)
        makeSliceType(ctx, .{ .prim = .u8 }, false) orelse return null
    else
        .{ .prim = .unit };
    const result = ctx.alloc.create(types.Result) catch {
        ctx.g.derived_error = true;
        return null;
    };
    result.* = .{
        .ok = ok,
        .err = std_io_error_type,
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
    const target = types.substType(ctx.alloc, bound.args[0], &.{"Self"}, &.{receiver_ty}) catch {
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

/// The type a method on a BOUNDED generic receiver produces, or null when it
/// carries none.
///
/// Every answer here is the resolver's own proof rather than a name this file
/// happens to know, because a bound method is reached through the receiver's
/// ACTUAL bounds: `boundTraitMethod` walks them and their supertraits, which is
/// the only way to reach a sealed trait — itoa's `Integer: private::Sealed`,
/// whose `fn write(self, buf: &mut Self::Buffer) -> &str` no list of names here
/// could ever contain. `hasCheckedNumericBound` and `hasHasherPrimitiveBound`
/// answer the two families whose declared signature says only `Self` and `()`.
/// Asking the resolver keeps the type recorded here and the dispatch
/// `resolveMethods` admits afterwards from disagreeing about which calls are
/// bound methods at all.
fn knownBoundTraitMethodType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
    method_def: exprs.DefId,
) ?types.Type {
    const cg = ctx.cg orelse return null;
    const owner = genericMethodOwner(ctx, method_def) orelse return null;
    // The conversion traits keep their own table, and it runs FIRST: their
    // signature is `fn as_ref(&self) -> &T`, where `T` is the TRAIT's
    // parameter, so the declared signature alone would leave it unbound where
    // the bound's own argument is what fills it.
    if (knownBoundMethodReturnType(ctx, receiver_ty, method_name, method_def)) |declared| {
        return declared;
    }
    // `checked_add`, `checked_sub` and `checked_mul` all hand back
    // `Option<Self>` — `None` IS the overflow. The proof is the resolver's
    // because the canonical `num_traits::ops::checked::Checked*` path and its
    // public re-export are one declaration written two ways, and a crate's own
    // `checked_add` shares the name without sharing either.
    if (resolve_methods.hasCheckedNumericBound(cg, ctx.b, owner, receiver_ty, method_name)) {
        const integer = types.peelCarrier(receiver_ty) orelse receiver_ty;
        return makeOptionType(ctx, integer);
    }
    // The hashing family is answered BEFORE the generic signature path, and by
    // the resolver's own exact answer rather than by a name list: `Hasher::
    // finish` is `u64` and `Hash::hash` is `()`, while the PRIMItIVE writers
    // (`write_u16` and the rest) write the value's own bytes and hand nothing
    // back. A crate's own `write` on a receiver that is not a `Hasher` stays
    // unanswered, which is why the proof and the return type are one call:
    // answering by name alone would type siphasher's `H.write(..)` and any
    // unrelated `write` identically.
    if (resolve_methods.boundHashMethodReturnType(cg, ctx.b, owner, receiver_ty, method_name)) |hash_result| {
        return hash_result;
    }
    // Anything else is answered from the trait's own DECLARED signature, with
    // `Self` filled in from the receiver. `write` on itoa's sealed `Integer` is
    // exactly this: a return of `&str` that is already concrete without any
    // substitution at all, while a signature that does name `Self` gets the
    // receiver written into it.
    const bound = resolve_methods.boundTraitMethod(cg, ctx.b, owner, receiver_ty, method_name) orelse
        return null;
    return substituteSelfLeaves(ctx, receiver_ty, bound.signature.ret) orelse bound.signature.ret;
}

/// The arm of the `Option`/`Result` chain a call sits in: `first`, `map` and
/// `and_then`.
///
/// The known path and the walk path both ask this, so the type derived from a
/// chain's SHAPE and the record pinned onto its node cannot disagree — and the
/// chain a source writes as one expression
/// (`text.first().and_then(..).map(..).unwrap_or(..)`) is four nodes, each of
/// which the next receiver reads.
fn knownOptionChainType(
    ctx: *Ctx,
    receiver_ty: types.Type,
    method_name: []const u8,
    args: []const exprs.NodeId,
) ?types.Type {
    if (std.mem.eql(u8, method_name, "first")) {
        // `<[T]>::first(&self) -> Option<&T>` hands back a BORROW of the
        // element, and that borrow is the answer rather than an optimisation of
        // it: the `.and_then(|&byte| ..)` that follows destructures with a `&`,
        // and an `Option<T>` here would be a pattern against a value the slice
        // never had. An ITERATOR's `first` yields its item BY VALUE, so the two
        // receivers are two different answers and only the slice one borrows.
        if (sliceElementForMethod(receiver_ty)) |element| {
            const borrowed = makeReferenceType(ctx, element, false) orelse return null;
            return makeOptionLike(ctx, receiver_ty, borrowed) orelse
                makeOptionType(ctx, borrowed);
        }
        if (iteratorItemType(ctx, receiver_ty)) |item| {
            return makeOptionLike(ctx, receiver_ty, item) orelse
                makeOptionType(ctx, item);
        }
        return null;
    }
    const is_map = std.mem.eql(u8, method_name, "map");
    if (!is_map and !std.mem.eql(u8, method_name, "and_then")) return null;
    // `and_then` takes the arm the receiver OPENS, not a new one, so it needs
    // one to hand the closure; a `Result` is not one Rust defines it on.
    const opened = optionPayloadType(receiver_ty) != null or
        (is_map and resultPayloadType(receiver_ty, false) != null);
    if (!opened) return null;
    if (args.len == 0) return null;
    const mapped = closureReturnType(ctx, args[0]) orelse return null;
    if (optionPayloadType(receiver_ty) != null) {
        if (!is_map) return mapped;
        return makeOptionLike(ctx, receiver_ty, mapped);
    }
    if (!is_map) return null;
    const err = resultPayloadType(receiver_ty, true) orelse return null;
    return makeResultLike(ctx, receiver_ty, mapped, err);
}

/// `std::io::Result<T>` as the `Result` it is an alias for, carrying the very
/// error identity the fallible I/O methods produce.
///
/// Reading both arms off the alias is enough for `resultPayloadType`, but not
/// for the dispatch that follows: a method on an EXTERNAL nominal the resolver
/// has no entry for is refused, and `.unwrap()` on `std::io::Result<T>` is
/// refused for the want of one. So the receiver's own record is rewritten to
/// the `Result` the name aliases — a normalization of a type the source already
/// wrote, not a name-based shim for a method that does not exist.
fn normalizedIoResultType(ctx: *Ctx, ty: types.Type) ?types.Type {
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return null,
    };
    if (!isStdIoResult(external) or external.args.len != 1) return null;
    const result = ctx.alloc.create(types.Result) catch {
        ctx.g.derived_error = true;
        return null;
    };
    result.* = .{
        .ok = external.args[0],
        .err = std_io_error_type,
        .is_error_unionable = false,
    };
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
fn knownCoreCallType(ctx: *Ctx, node: exprs.NodeId, call: exprs.CoreCall) ?types.Type {
    switch (call.function) {
        .default_value, .convert_from => {
            if (call.generic_args.len != 1) return null;
            return call.generic_args[0];
        },
        // `T::from_le_bytes(bytes)` is the DECODE and its result is the integer
        // its one type argument names; `value.to_le_bytes()` is the ENCODE and
        // its result is `[size_of::<T>()]u8`, whose width is the integer's own.
        // Neither is a `mem_transmute`: that copies the value's bytes and is the
        // right answer only on a little-endian target, while these two are
        // little-endian on every target or the hash they feed is a different
        // hash. So they are one function each rather than a transmute in either
        // direction, and the pair is why the width has to come from the type
        // argument rather than from whatever the call happens to receive.
        .prim_from_le_bytes => {
            if (call.generic_args.len != 1) return null;
            return call.generic_args[0];
        },
        .prim_to_le_bytes => {
            if (call.generic_args.len != 1) return null;
            return integerByteArrayType(ctx, node, call.generic_args[0]);
        },
        // The semantic result retains `MaybeUninit<T>` even though the backend
        // uses T's byte layout. A source repeat belongs to its surrounding
        // array node, never to this constructor's result type.
        .maybe_uninit_uninit => {
            if (call.generic_args.len != 1) return null;
            return .{ .external_nominal = .{
                .path = &.{ "core", "mem", "MaybeUninit" },
                .args = call.generic_args,
            } };
        },
        // `fill_bytes_via_next` fills its destination in place and hands nothing
        // back, and the `Hasher::write_uN` default bodies write the value's own
        // bytes and hand nothing back either. Both are `()`, and both are only
        // reached once no source impl of the same name answered for them.
        .rng_fill_bytes_via_next, .hash_write_primitive => return .{ .prim = .unit },
        // `I::ZERO` / `I::ONE` and `I::MIN_VALUE` / `I::MAX_VALUE` are the
        // bound OF the type the one type argument is, so the result is that type
        // — but only when it is one. `isConcreteDerivedType` is the same
        // predicate the call's own return is judged by, and it is strict in the
        // way that matters here: a `_` placeholder reads as concrete to a walk
        // that only inspects arguments, and a sentinel in this slot is a value
        // the caller would go on to use. An enclosing type parameter is the one
        // non-concrete type that still answers, because the bound it carries is
        // the same bound these names are declared against. There is no literal to
        // fall back to either: `I::MIN` names the bound, it does not write a
        // number down.
        .numeric_zero, .numeric_one, .numeric_min_value, .numeric_max_value => {
            if (call.generic_args.len != 1) return null;
            const integer = call.generic_args[0];
            if (isConcreteDerivedType(integer)) return integer;
            if (integer == .path and integer.path.segments.len == 1 and
                isEnclosingGenericParam(ctx, integer.path.segments[0].name))
            {
                return integer;
            }
            return null;
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
            // The ARGUMENT is bytes and the RESULT is borrowed text, and this
            // is the call that turns one into the other:
            // `pub const fn from_utf8(v: &[u8]) -> Result<&str, Utf8Error>`.
            // Handing back the same `[]const u8` the argument already had would
            // type `str::from_utf8(bytes)?.len()` as a byte count by accident
            // rather than by a decision, and would leave the `Ok` payload a
            // type no `.to_owned()` can answer for.
            const string = makeReferenceType(ctx, types.str_type, false) orelse return null;
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
/// `[u8; N]`, the byte image of an integer, in whichever of the two forms this
/// translator can state it.
///
/// A FIXED-WIDTH integer gets the literal length that width always has. A
/// pointer-sized one — `usize`, `isize` — gets the `[u8; @sizeOf(T)]` whose
/// length is an EXPRESSION, because its width is the TARGET's: a literal would
/// be right for the host that ran the translation and wrong for every target
/// that is not it. That is the same reason those two have a core function of
/// their own instead of sharing the native-endian one, and it is why the record
/// the lowering layer already wrote on `node` is read back rather than a second
/// one built: the length is that `mem_size_of` call, and inventing a second node
/// for it would leave an unreferenced expression in the table. A node carrying
/// no such record answers nothing, and the call keeps whatever type it was
/// lowered with.
fn integerByteArrayType(
    ctx: *Ctx,
    node: exprs.NodeId,
    ty: types.Type,
) ?types.Type {
    const primitive = switch (ty) {
        .prim => |value| value,
        // Rust's method call auto-derefs its receiver, so a `&u64` names the
        // same integer a `u64` does.
        .reference => |reference| switch (reference.pointee) {
            .prim => |value| value,
            else => return null,
        },
        else => return null,
    };
    const width: u64 = switch (primitive) {
        .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32 => 4,
        .i64, .u64 => 8,
        .i128, .u128 => 16,
        .usize, .isize => return recordedArrayType(ctx, node),
        // A float, a `char` and a `bool` have no byte image these methods
        // produce, so there is no width to state for them at all.
        else => return null,
    };
    const array = ctx.alloc.create(types.Array) catch {
        ctx.g.derived_error = true;
        return null;
    };
    array.* = .{ .elem = .{ .prim = .u8 }, .len = .{ .literal = width } };
    return .{ .array = array };
}

/// The array a node was already given, when that record is an array at all.
///
/// This is how a pointer-sized integer's byte image reaches its own type: the
/// lowering layer built `[u8; @sizeOf(T)]` and recorded it here, and a width
/// only the target knows cannot be written down a second time.
fn recordedArrayType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    const type_id = ctx.b.exprs[node].ty orelse return null;
    if (type_id >= ctx.b.types.len) return null;
    const recorded = ctx.b.types[type_id];
    if (recorded != .array) return null;
    return recorded;
}

/// The number a constant array length names, when the length is written as a
/// `const` whose initializer is a plain integer literal.
///
/// `[T; N]` and `[T; 40]` are one Rust type, and the declaration that gives `N`
/// its value is a row of this crate's own table. Reading the number from there
/// is therefore a value the source wrote, not one inferred from how the length
/// is used — the difference between restoring what `const I128_MAX_LEN: usize
/// = 40;` says and guessing that a length means whatever makes a cast work.
fn constArrayLengthValue(ctx: *Ctx, len: types.ArrayLen) ?u64 {
    const node = switch (len) {
        .expression => |value| value,
        else => return null,
    };
    if (node >= ctx.b.exprs.len) return null;
    const path = switch (ctx.b.exprs[node].kind) {
        .path => |value| value,
        else => return null,
    };
    if (path.generic_args.len != 0) return null;
    if (path.def >= ctx.b.bodies.len) return null;
    const constant = switch (ctx.b.bodies[path.def]) {
        .const_ => |value| value,
        else => return null,
    };
    if (constant.init >= ctx.b.exprs.len) return null;
    const value: i128 = switch (ctx.b.exprs[constant.init].kind) {
        .literal => |literal| switch (literal) {
            .int => |int| int.value,
            else => return null,
        },
        else => return null,
    };
    if (value < 0) return null;
    const wide: u128 = @intCast(value);
    if (wide > std.math.maxInt(u64)) return null;
    return @intCast(wide);
}

fn resolveChildTypes(
    ctx: *Ctx,
    children: []const types.Type,
    depth: usize,
) ?[]const types.Type {
    var copy: ?[]types.Type = null;
    for (children, 0..) |child, index| {
        const resolved = resolveConstArrayLengths(ctx, child, depth) orelse continue;
        if (copy == null) {
            copy = ctx.alloc.dupe(types.Type, children) catch {
                ctx.g.derived_error = true;
                return null;
            };
        }
        copy.?[index] = resolved;
    }
    return copy;
}

/// The same type with every constant array length replaced by the number that
/// constant carries, or null when there is none to replace.
///
/// `typeEqual` compares an array length by payload, so a destination spelled
/// with the constant and an operand spelled with its value are two unrelated
/// pointee types. Neither spelling is wrong and neither is a better answer —
/// they are the one type the declaration says they are, so the whole chain is
/// rebuilt once and published instead of leaving every reader to compare the
/// two writings. A type with nothing to resolve allocates nothing and hands
/// back null, so the common case leaves every shared node untouched.
fn resolveConstArrayLengths(ctx: *Ctx, ty: types.Type, depth: usize) ?types.Type {
    if (depth >= types.traversal_depth_max) return null;
    const next = depth + 1;
    return switch (ty) {
        .array => |array| blk: {
            const length: ?types.ArrayLen = if (constArrayLengthValue(ctx, array.len)) |value|
                types.ArrayLen{ .literal = value }
            else
                null;
            const elem = resolveConstArrayLengths(ctx, array.elem, next);
            if (length == null and elem == null) break :blk null;
            const rebuilt = ctx.alloc.create(types.Array) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = .{ .elem = elem orelse array.elem, .len = length orelse array.len };
            break :blk .{ .array = rebuilt };
        },
        .reference => |reference| blk: {
            const pointee = resolveConstArrayLengths(ctx, reference.pointee, next) orelse break :blk null;
            const rebuilt = ctx.alloc.create(types.Ref) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = .{ .mut = reference.mut, .pointee = pointee };
            break :blk .{ .reference = rebuilt };
        },
        .raw_ptr => |pointer| blk: {
            const pointee = resolveConstArrayLengths(ctx, pointer.pointee, next) orelse break :blk null;
            const rebuilt = ctx.alloc.create(types.RawPtr) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = .{ .mut = pointer.mut, .pointee = pointee };
            break :blk .{ .raw_ptr = rebuilt };
        },
        .slice => |slice| blk: {
            const elem = resolveConstArrayLengths(ctx, slice.elem, next) orelse break :blk null;
            const rebuilt = ctx.alloc.create(types.Slice) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = .{ .const_ = slice.const_, .elem = elem };
            break :blk .{ .slice = rebuilt };
        },
        .tuple => |elements| if (resolveChildTypes(ctx, elements, next)) |copy|
            .{ .tuple = copy }
        else
            null,
        // `Type.external_nominal` holds an `ExternalNominal` by value, and one
        // is two slices, so the rebuilt owner is built where the union needs
        // it. Nothing is allocated here beyond the argument copy the mapper
        // already made, and only when an argument actually resolved.
        .external_nominal => |external| blk: {
            const copy = resolveChildTypes(ctx, external.args, next) orelse break :blk null;
            break :blk .{ .external_nominal = .{
                .path = external.path,
                .args = copy,
            } };
        },
        .generic_inst => |instance| blk: {
            const copy = resolveChildTypes(ctx, instance.args.params, next) orelse break :blk null;
            break :blk .{ .generic_inst = .{
                .decl = instance.decl,
                .args = .{ .params = copy },
            } };
        },
        .fn_ptr => |function| blk: {
            const params = resolveChildTypes(ctx, function.params, next);
            const ret = resolveConstArrayLengths(ctx, function.ret, next);
            if (params == null and ret == null) break :blk null;
            const rebuilt = ctx.alloc.create(types.FnPtr) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = .{
                .params = params orelse function.params,
                .ret = ret orelse function.ret,
            };
            break :blk .{ .fn_ptr = rebuilt };
        },
        .option => |value| blk: {
            const inner = resolveConstArrayLengths(ctx, value.*, next) orelse break :blk null;
            const rebuilt = ctx.alloc.create(types.Type) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = inner;
            break :blk .{ .option = rebuilt };
        },
        .result => |result| blk: {
            const ok = resolveConstArrayLengths(ctx, result.ok, next);
            const err = resolveConstArrayLengths(ctx, result.err, next);
            if (ok == null and err == null) break :blk null;
            const rebuilt = ctx.alloc.create(types.Result) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = .{
                .ok = ok orelse result.ok,
                .err = err orelse result.err,
                .is_error_unionable = result.is_error_unionable,
            };
            break :blk .{ .result = rebuilt };
        },
        .boxed => |value| blk: {
            const inner = resolveConstArrayLengths(ctx, value.*, next) orelse break :blk null;
            const rebuilt = ctx.alloc.create(types.Type) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            rebuilt.* = inner;
            break :blk .{ .boxed = rebuilt };
        },
        .@"opaque" => |opaque_type| blk: {
            const concrete = opaque_type.concrete orelse break :blk null;
            const inner = resolveConstArrayLengths(ctx, concrete.*, next) orelse break :blk null;
            const holder = ctx.alloc.create(types.Type) catch {
                ctx.g.derived_error = true;
                break :blk null;
            };
            holder.* = inner;
            break :blk .{ .@"opaque" = .{
                .bounds = opaque_type.bounds,
                .concrete = holder,
            } };
        },
        .path, .prim, .dyn_trait, .unsupported => null,
    };
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
    // `Vec::from(sequence)` records its target as `alloc::vec::Vec` with an EMPTY
    // payload, because nothing in the argument NAMES the element type — only
    // the argument sequence does, and only once that is typed. An unfilled
    // payload is not a smaller answer, it is an invalid one: `ir.validate`
    // rejects a nominal whose argument list is missing, so the whole crate fails
    // on a call whose type is in fact fully determined. `finalizeCoreCallTypeArguments`
    // cannot repair it, because it completes an EMPTY argument list and this
    // one has length.
    if (call.function == .convert_from) {
        try completeConvertTarget(ctx, node, call);
    }
    if (getKnownType(ctx, node)) |result| try pinKnownType(ctx, node, result);
    switch (call.function) {
        .cmp_min, .cmp_max => if (coreTypeArgument(ctx, call.*)) |argument| {
            for (call.args) |arg| try constrainExpectedType(ctx, arg, argument);
        },
        .string_from_utf8 => {
            // The canonical signature consumes Vec<u8>; its byte element
            // constrains unsuffixed integers before the solver defaults them.
            if (call.args.len != 1) return;
            const bytes = makeExternalNominalType(
                ctx,
                &.{ "alloc", "vec", "Vec" },
                &.{.{ .prim = .u8 }},
            ) orelse return;
            try constrainExpectedType(ctx, call.args[0], bytes);
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
        // The decode reads the integer's OWN image, so what the argument is
        // read AT is an array of `u8` of that integer's width — not the slice a
        // source wrote over it, and not a bare `&[u8]`. Stating nothing leaves
        // the literal's elements to the `i32` default, and the width is the one
        // thing that says which integer this call produces.
        .prim_from_le_bytes => {
            if (call.args.len != 1 or call.generic_args.len != 1) return;
            if (integerByteArrayType(ctx, node, call.generic_args[0])) |bytes| {
                try constrainExpectedType(ctx, call.args[0], bytes);
            }
        },
        // The encode is the mirror: the value IS the integer, so the demand is
        // that integer and nothing about its bytes.
        .prim_to_le_bytes => {
            if (call.args.len != 1 or call.generic_args.len != 1) return;
            try constrainExpectedType(ctx, call.args[0], call.generic_args[0]);
        },
        // The default `Hasher` writer's second argument is the integer it is
        // about to write, and it writes that value's OWN bytes — so saying which
        // integer here is what makes `write_u16` a 16-bit write.
        .hash_write_primitive => {
            if (call.args.len != 2 or call.generic_args.len != 1) return;
            try constrainExpectedType(ctx, call.args[1], call.generic_args[0]);
        },
        // `fill_bytes_via_next` writes THROUGH its destination, so the borrow it
        // takes is a mutable byte slice. A shared one would be a different
        // program, and a destination nothing types would let an unconstrained
        // literal decide the element.
        .rng_fill_bytes_via_next => {
            if (call.args.len != 2) return;
            if (makeSliceType(ctx, .{ .prim = .u8 }, true)) |destination| {
                try constrainExpectedType(ctx, call.args[1], destination);
            }
        },
        else => {},
    }
}

/// Fill in an unfilled `Vec` conversion target from the argument sequence's
/// element type, rewriting the recorded target as well as the call's result.
///
/// BOTH are rewritten, not just the result type, because the backend lowers the
/// copy from the target's payload — `r2z.alloc.vec_from_slice(T, gpa, sequence)`
/// — rather than from the expression's type. Leaving `generic_args[0]` unfilled
/// would keep the arity error alive even with the call typed.
///
/// The completed type is recorded through the derived-type channel rather than
/// pinned directly, so `materializeDerivedTypes` interns the row before
/// `ir.validate` reads it; that is the same path every type inference derives
/// rather than finds, and it dedupes, so two conversions producing the same
/// `Vec<T>` share one row.
///
/// `sliceElementForMethod` resolves the element of a slice, array, reference,
/// box, `Vec<T>`, `String`, or `Cow`. Reusing it avoids a conversion rule for
/// each element type.
fn completeConvertTarget(
    ctx: *Ctx,
    node: exprs.NodeId,
    call: *exprs.CoreCall,
) std.mem.Allocator.Error!void {
    if (call.generic_args.len != 1) return;
    const external = switch (call.generic_args[0]) {
        .external_nominal => |value| value,
        else => return,
    };
    // Only an UNFILLED target is this call's problem. A target that already
    // carries its payload was written by something that knew the element, and a
    // target that is not the `alloc` owner this pass can complete is left for
    // its own admission rather than guessed at here.
    if (external.args.len != 0) return;
    if (external.path.len != 3) return;
    if (!std.mem.eql(u8, external.path[1], "vec")) return;
    if (!std.mem.eql(u8, external.path[2], "Vec")) return;
    if (!std.mem.eql(u8, external.path[0], "alloc") and
        !std.mem.eql(u8, external.path[0], "std")) return;
    if (call.args.len != 1) return;
    const argument_ty = getKnownType(ctx, call.args[0]) orelse return;
    const element = sliceElementForMethod(argument_ty) orelse return;
    const completed_args = try ctx.alloc.alloc(types.Type, 1);
    completed_args[0] = element;
    const completed: types.Type = .{ .external_nominal = .{
        .path = external.path,
        .args = completed_args,
    } };
    ctx.recordDerivedType(node, completed);
    // Anything already cached for this node was the INCOMPLETE type, so the
    // entry has to go — or every later reader in this same solve would keep
    // seeing a `Vec` with no payload, and the pin would be right while the value
    // every consumer actually reads was not.
    _ = ctx.known_nodes.remove(node);
    call.generic_args = try ctx.alloc.dupe(types.Type, &.{completed});
}
/// Derive a concrete Type for an argument expression node where possible.
/// A solved aggregate may fill holes only if every source-named component
/// and qualifier agrees. Replacing the private field value, rather than
/// mutating shared child pointers, keeps other literals and scopes isolated.
fn sourceTypeAcceptsSolved(source: types.Type, solved: types.Type) bool {
    return sourceTypeAcceptsSolvedDepth(source, solved, 0);
}

/// Bounded by the same `traversal_depth_max` every other structural type walk
/// here uses. Exhausting it means agreement is not PROVEN, so the slot stays a
/// hole: a private row is completed, never invented.
fn sourceTypeAcceptsSolvedDepth(source: types.Type, solved: types.Type, depth: usize) bool {
    if (isUnnamedElement(source)) return solved != .unsupported and !containsInferPlaceholder(solved);
    if (!containsInferPlaceholder(source)) return typeEqual(source, solved);
    if (std.meta.activeTag(source) != std.meta.activeTag(solved)) return false;
    if (depth >= types.traversal_depth_max) return false;
    const next = depth + 1;
    return switch (source) {
        .reference => |reference| reference.mut == solved.reference.mut and sourceTypeAcceptsSolvedDepth(reference.pointee, solved.reference.pointee, next),
        .raw_ptr => |pointer| pointer.mut == solved.raw_ptr.mut and sourceTypeAcceptsSolvedDepth(pointer.pointee, solved.raw_ptr.pointee, next),
        .slice => |slice| slice.const_ == solved.slice.const_ and sourceTypeAcceptsSolvedDepth(slice.elem, solved.slice.elem, next),
        .array => |array| std.meta.eql(array.len, solved.array.len) and sourceTypeAcceptsSolvedDepth(array.elem, solved.array.elem, next),
        .tuple => |fields| blk: {
            if (fields.len != solved.tuple.len) break :blk false;
            for (fields, solved.tuple) |left, right| if (!sourceTypeAcceptsSolvedDepth(left, right, next)) break :blk false;
            break :blk true;
        },
        .option => |inner| sourceTypeAcceptsSolvedDepth(inner.*, solved.option.*, next),
        .result => |result| result.is_error_unionable == solved.result.is_error_unionable and
            sourceTypeAcceptsSolvedDepth(result.ok, solved.result.ok, next) and sourceTypeAcceptsSolvedDepth(result.err, solved.result.err, next),
        .boxed => |inner| sourceTypeAcceptsSolvedDepth(inner.*, solved.boxed.*, next),
        .fn_ptr => |function| blk: {
            if (function.params.len != solved.fn_ptr.params.len) break :blk false;
            for (function.params, solved.fn_ptr.params) |left, right| if (!sourceTypeAcceptsSolvedDepth(left, right, next)) break :blk false;
            break :blk sourceTypeAcceptsSolvedDepth(function.ret, solved.fn_ptr.ret, next);
        },
        .generic_inst => |generic| blk: {
            if (generic.decl != solved.generic_inst.decl or generic.args.params.len != solved.generic_inst.args.params.len) break :blk false;
            for (generic.args.params, solved.generic_inst.args.params) |left, right| if (!sourceTypeAcceptsSolvedDepth(left, right, next)) break :blk false;
            break :blk true;
        },
        .external_nominal => |nominal| blk: {
            if (nominal.path.len != solved.external_nominal.path.len or nominal.args.len != solved.external_nominal.args.len) break :blk false;
            for (nominal.path, solved.external_nominal.path) |left, right| if (!std.mem.eql(u8, left, right)) break :blk false;
            for (nominal.args, solved.external_nominal.args) |left, right| if (!sourceTypeAcceptsSolvedDepth(left, right, next)) break :blk false;
            break :blk true;
        },
        .@"opaque", .dyn_trait, .prim, .path, .unsupported => false,
    };
}

fn sourceSolvedElementType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    if (ctx.solved_types) |solved| {
        if (node < solved.len) {
            if (solved[node]) |id| {
                if (id < ctx.b.types.len) {
                    const ty = ctx.b.types[id];
                    if (ty != .unsupported and !containsInferPlaceholder(ty)) return ty;
                }
            }
        }
    }
    const known = getKnownType(ctx, node) orelse return null;
    if (known == .unsupported or containsInferPlaceholder(known)) return null;
    return known;
}

fn refineSourceTupleRow(ctx: *Ctx, node: exprs.NodeId, literal: exprs.ArrayExpr) void {
    const row_id = ctx.g.source_tuple_rows.get(node) orelse return;
    if (row_id >= ctx.b.types.len or ctx.b.types[row_id] != .tuple or literal.repeat != null) return;
    const fields = ctx.b.types[row_id].tuple;
    if (fields.len != literal.elements.len) return;
    for (literal.elements, 0..) |element, index| {
        if (!isUnnamedElement(fields[index]) and !containsInferPlaceholder(fields[index])) continue;
        const candidate = sourceSolvedElementType(ctx, element) orelse continue;
        if (!sourceTypeAcceptsSolved(fields[index], candidate)) continue;
        // The row, not this expression's current TypeId, owns the private slot.
        @constCast(fields)[index] = candidate;
    }
}

fn knownSourceArrayType(ctx: *Ctx, node: exprs.NodeId, literal: exprs.ArrayExpr) ?types.Type {
    if (ctx.g.source_tuple_rows.get(node)) |row_id| {
        refineSourceTupleRow(ctx, node, literal);
        if (row_id < ctx.b.types.len) return ctx.b.types[row_id];
    }
    if (ctx.b.exprs[node].ty) |id| {
        if (id < ctx.b.types.len and (ctx.b.types[id] == .array or ctx.b.types[id] == .tuple)) return ctx.b.types[id];
    }
    if (literal.elements.len == 0) return null;
    const element = sourceSolvedElementType(ctx, literal.elements[0]) orelse return null;
    for (literal.elements[1..]) |child| {
        const candidate = sourceSolvedElementType(ctx, child) orelse return null;
        if (!typeEqual(element, candidate)) return null;
    }
    const array = ctx.alloc.create(types.Array) catch {
        ctx.g.derived_error = true;
        return null;
    };
    array.* = .{ .elem = element, .len = .{ .literal = literal.repeat orelse @as(u64, @intCast(literal.elements.len)) } };
    const aggregate: types.Type = .{ .array = array };
    ctx.known_nodes.put(ctx.alloc, node, aggregate) catch {
        ctx.alloc.destroy(array);
        ctx.g.derived_error = true;
        return null;
    };
    return aggregate;
}

fn knownSourceEnumVariantType(ctx: *Ctx, node: exprs.NodeId, variant: exprs.EnumVariant) ?types.Type {
    const cg = ctx.cg orelse return null;
    const entity = cg.symbol_table.get(variant.def) orelse return null;
    const owner = if (entity.kind == .variant) entity.parent orelse return null else entity.id;
    if (owner >= ctx.b.bodies.len or ctx.b.bodies[owner] != .enum_) return null;
    // An open generic enum needs its own source argument/expected type;
    // another use's instantiation is not evidence for this variant.
    if (ctx.b.bodies[owner].enum_.generic_params.len != 0) return null;
    return nominalTypeForDefinition(ctx, node, owner);
}

fn getKnownType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    if (ctx.known_nodes.get(node)) |known| {
        if (known != .unsupported and !containsInferPlaceholder(known)) return known;
    }
    if (ctx.solved_types) |solved| {
        if (node < solved.len) {
            if (solved[node]) |id| {
                if (id < ctx.b.types.len and ctx.b.types[id] != .unsupported and !containsInferPlaceholder(ctx.b.types[id])) return ctx.b.types[id];
            }
        }
    }
    const e = ctx.b.exprs[node];
    switch (e.kind) {
        .array => |literal| return knownSourceArrayType(ctx, node, literal),
        .block => |block| {
            // The block owns the identity of its tail before solving equality
            // edges. A later borrow must see that identity, not constrain the
            // block and its owning locals to the borrowed view's pointee.
            if (block.tail) |tail| {
                if (getKnownType(ctx, tail)) |known| return known;
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .enum_variant => |variant| {
            if (knownSourceEnumVariantType(ctx, node, variant)) |known| return known;
            if (e.ty) |id| {
                if (id < ctx.b.types.len) return ctx.b.types[id];
            }
            return null;
        },
        .core_call => |call| {
            const known = knownCoreCallType(ctx, node, call) orelse return null;
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
                if (containsInferPlaceholder(local_ty)) return null;
                if (local_ty == .path and local_ty.path.segments.len == 1 and
                    std.mem.eql(u8, local_ty.path.segments[0].name, "Self"))
                {
                    if (currentImplSelfType(ctx)) |self_ty| return self_ty;
                }
                // `&Self` is the receiver every trait method whose signature
                // borrows itself carries, and it is this same BARE `Self` one
                // layer down that a projection is read through: `self.tail` in
                // `impl Hasher for SeaHasher { fn finish(&self) -> u64 { ..
                // self.tail.to_le_bytes() .. } }`. Left as `&Self`, the field
                // has no struct to be read off, and everything that hangs off
                // that receiver loses what its own declaration says — here the
                // `u64` width a `to_le_bytes` is nothing without.
                if (local_ty == .reference and typeSpellsSelf(local_ty.reference.pointee)) {
                    if (currentImplSelfType(ctx)) |self_ty| {
                        if (makeReferenceType(ctx, self_ty, local_ty.reference.mut)) |borrow| {
                            return borrow;
                        }
                    }
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
                    if (knownTryArmMethodType(receiver_ty, method_name)) |payload| return payload;
                    if (knownAllocMethodType(ctx, receiver_ty, method_name)) |alloc_result| {
                        return alloc_result;
                    }
                    if (knownStdIntoType(
                        ctx,
                        node,
                        receiver_ty,
                        method_name,
                        null,
                    )) |into_result| {
                        return into_result;
                    }
                    if (knownBoundTraitMethodType(
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
                    // `collect` is the one iterator method whose result the
                    // turbofish names, so it is asked of the node rather than
                    // of the receiver: the receiver types what the container
                    // is FILLED with, and the call's own argument is what it
                    // IS. Read from the table, because
                    // `bindTurbofishCollectedElement` rewrites that argument
                    // in place before the value copied out of the table here
                    // is ever used.
                    if (std.mem.eql(u8, method_name, "collect")) {
                        if (knownCollectTargetType(ctx, node, null)) |collect_target| {
                            return collect_target;
                        }
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
                } else if (std.mem.eql(u8, method_name, "split_first")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (splitFirstType(ctx, receiver_ty)) |first_ty| return first_ty;
                    }
                } else if (std.mem.eql(u8, method_name, "chunks")) {
                    if (getKnownType(ctx, method.receiver)) |receiver_ty| {
                        if (sliceElementForMethod(receiver_ty)) |element| {
                            return chunksType(ctx, element);
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
                } else if (std.mem.eql(u8, method_name, "to_le_bytes")) {
                    // `value.to_le_bytes()` produces the integer's OWN image, so
                    // the array's length IS the width this receiver declares.
                    // A pointer-sized one keeps the target's own answer, which
                    // the lowering layer recorded as a symbolic length rather
                    // than a number this module could have guessed.
                    if (getKnownType(ctx, method.receiver)) |recv_ty| {
                        if (integerByteArrayType(ctx, node, recv_ty)) |bytes| {
                            return bytes;
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
                        return substituteSelfLeaves(ctx, receiver_ty, return_type) orelse return_type;
                    }
                }
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .field => |field| {
            if (getKnownType(ctx, field.base)) |base_ty| {
                if (fieldTypeForBase(ctx, base_ty, field.field)) |field_ty| {
                    // A slot the source never named is not what the projection
                    // holds — it is what the projection is still waiting to be
                    // told. Reporting it back pins the hole onto the node, and
                    // because a hole is never interned on its own it reaches
                    // the solver through the derived channel, which is applied
                    // after every recorded pin. `u8_id(first.0)` therefore
                    // ends up solved back to `_` after the parameter stated
                    // `u8`, and the tuple row the literal owns keeps its
                    // placeholder for good.
                    if (!isUnnamedElement(field_ty)) return field_ty;
                }
            }
            if (e.ty) |tid| {
                if (tid < ctx.b.types.len) return ctx.b.types[tid];
            }
        },
        .index => |index| {
            if (getKnownType(ctx, index.base)) |base_type| {
                if (indexedResultType(ctx, base_type, index.index)) |result_type| return result_type;
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
            // `!x` is a `bool` over a bool and the same integer over an
            // integer, so an operand nothing has typed yet leaves the
            // negation unnamed too. Naming it `bool` anyway is a guess that
            // outruns the walk: it makes the node look typed, and a position
            // that states what this expression IS — `mask[i] &= !(1 << n)` —
            // then finds a type to agree with and states nothing, so the
            // literal underneath keeps the `i32` an unconstrained integer
            // defaults to.
            .logical_not => if (getKnownType(ctx, unary.operand)) |op_ty| blk: {
                if (aliasResolvedPrim(ctx, op_ty)) |primitive| {
                    if (unaryPreservesPrim(.logical_not, primitive)) break :blk op_ty;
                }
                break :blk types.Type{ .prim = .bool };
            } else null,
            .ref => |mode| if (getKnownType(ctx, unary.operand)) |pointee|
                makeReferenceType(ctx, pointee, mode == .mutable)
            else
                null,
        },
        .iterator_chain => |chain| return knownIteratorChainType(ctx, node, chain),
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
            .string => {
                if (e.ty) |id| {
                    if (id < ctx.b.types.len and !containsInferPlaceholder(ctx.b.types[id])) return ctx.b.types[id];
                }
                return null;
            },
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

/// True for the type table's stand-in for a Rust `_` inference placeholder.
/// The placeholder is a real, resolvable entry rather than a hole: solving
/// rewrites the entry in place once surrounding constraints name a concrete
/// type. Lowering therefore keeps an `_` destination and defers the decision
/// to this module, instead of rejecting the construct while the placeholder
/// is still standing in for the type.
pub fn isInferPlaceholderType(ty: types.Type) bool {
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

/// `x as *mut _` is the pointer `x` already is: the wildcard stands for the
/// operand's own pointee and for nothing else. Reading it off the destination
/// instead states the destination as its own source, and the statement is
/// false the moment the operand is typed — `&mut data as *mut _ as *mut u8`
/// records `*mut u8` as the source of a `*mut u32` value and the second pass,
/// which is the one that knows the operand, refuses the cast as a source that
/// disagrees with it. An operand that is not yet a pointer, or whose pointee is
/// itself a placeholder, resolves nothing: the wildcard stays standing and the
/// solved-type pass completes it from the operand it has since typed.
fn resolveWildcardRawPointerSource(
    ctx: *Ctx,
    source: types.Type,
    target: types.Type,
    operand_source: types.Type,
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
    const pointee: types.Type = switch (operand_source) {
        .reference => |reference| reference.pointee,
        .raw_ptr => |raw| raw.pointee,
        else => return null,
    };
    if (isInferPlaceholderType(pointee)) return null;
    const resolved = ctx.alloc.create(types.RawPtr) catch {
        ctx.g.derived_error = true;
        return null;
    };
    resolved.* = .{
        .mut = source_raw.mut,
        .pointee = pointee,
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

/// `&[T]` and `&mut [T]` are modelled as a slice, and a `*const [T]` /
/// `*mut [T]` destination is a raw pointer to that same unsized slice: both
/// carry the element AND the length, so the cast re-labels one as the other
/// and keeps both. Only the fat destination can stand for a slice — a thin
/// `*const u8` has nowhere to keep the length — and the mutability still has
/// to hold: a shared slice cannot become a mutable pointer, while a mutable
/// one can become either.
fn sliceToRawPointerCompatible(
    source_slice: *const types.Slice,
    target_raw: *const types.RawPtr,
) bool {
    if (target_raw.mut and source_slice.const_) return false;
    const target_slice = switch (target_raw.pointee) {
        .slice => |value| value,
        else => return false,
    };
    return typeEqual(source_slice.elem, target_slice.elem);
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
                .slice => |source_slice| sliceToRawPointerCompatible(source_slice, target_ptr),
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
    if (chunksElement(iterable_ty) orelse chunksExactElement(iterable_ty)) |element| {
        return makeSliceType(ctx, element, false);
    }
    switch (iterable_ty) {
        .external_nominal => return iteratorItemType(ctx, iterable_ty),
        .reference => |reference| switch (reference.pointee) {
            .array => |array| return makeReferenceType(ctx, array.elem, reference.mut),
            .slice => |slice| return makeReferenceType(ctx, slice.elem, reference.mut),
            .external_nominal => |external| {
                const is_vec = external.path.len == 3 and
                    (std.mem.eql(u8, external.path[0], "alloc") or
                        std.mem.eql(u8, external.path[0], "std")) and
                    std.mem.eql(u8, external.path[1], "vec") and
                    std.mem.eql(u8, external.path[2], "Vec") and
                    external.args.len == 1;
                if (is_vec) return makeReferenceType(ctx, external.args[0], reference.mut);
            },
            else => {},
        },
        // `for x in xs` walks the elements; only `xs.iter()` hands out a
        // borrow, and that receiver arrives here as the iterator carrier
        // instead. A mutable slice is the one case that still yields `&mut T`.
        .slice => |slice| return if (slice.const_)
            slice.elem
        else
            makeReferenceType(ctx, slice.elem, true),
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
        .slice => return loopCarrierElementType(ctx, iterable) orelse
            rangeExpressionItemType(ctx, iterable),
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
            const iterator_ty = knownIteratorChainType(ctx, null, chain) orelse return null;
            return iteratorItemType(ctx, iterator_ty);
        },
    }
}

/// The item a range expression yields, or null when `node` is not a range.
///
/// `unwrapIterable` labels `for x in a..b` with the slice kind and the range
/// expression itself, so the carrier reading finds no slice to read an
/// element off and the binding falls back to the default integer type:
/// `for round in 0u8..2` binds a `usize`, and every use of it is then a type
/// error against the `u8` the source wrote.
fn rangeExpressionItemType(ctx: *Ctx, node: exprs.NodeId) ?types.Type {
    if (node >= ctx.b.exprs.len) return null;
    const range = switch (ctx.b.exprs[node].kind) {
        .range => |value| value,
        else => return null,
    };
    const range_ty = getKnownType(ctx, node) orelse return null;
    return iteratorItemType(ctx, range_ty) orelse getKnownType(ctx, range.start);
}

/// The loop counter and the range it walks are ONE value in Rust, and the
/// body is what says which one: `for i in 0..127 { low_bits_of_byte(i) }`
/// names `u8` at the call, because `low_bits_of_byte` declares `byte: u8`.
/// Nothing above settles it. The range carries no type of its own at this
/// point — `rangeExpressionItemType` needs one and finds none — so both its
/// endpoints fall through to the unconstrained-integer default while the
/// counter the body's own calls pinned reads as something else. They are one
/// value, so the two answers cannot both stand.
///
/// So the edge is drawn after the body, from the range's start to the first
/// expression that mentions the binding: `def_map` recorded that node when
/// `walkPath` walked it, and the body's own calls have already pinned it. One
/// edge, not a pin — the type is already decided on the body's side, and a pin
/// here would be a second statement of it instead of the single class both
/// names then read from. The endpoint is the start and not the end because
/// `walkExpr` has already tied those together, and it is the start because
/// that is what a backend reads the loop's item type off.
///
/// A binding the body never mentions has no occurrence to draw the edge to and
/// needs none: nothing said what it is, so the default that reached the range
/// also reaches the counter, and the two agree. A `for` over anything but a
/// range has no endpoints to unify, which is the `.range` arm's own gate.
fn unifyRangeBinding(
    ctx: *Ctx,
    iterable: exprs.NodeId,
    binding: ?exprs.DefId,
) std.mem.Allocator.Error!void {
    const def = binding orelse return;
    if (iterable >= ctx.b.exprs.len) return;
    const range = switch (ctx.b.exprs[iterable].kind) {
        .range => |value| value,
        else => return,
    };
    const occurrence = ctx.def_map.get(def) orelse return;
    if (occurrence >= ctx.b.exprs.len or range.start >= ctx.b.exprs.len) return;
    try addEq(ctx, range.start, occurrence);
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
/// How deep a tail chain is followed. Each step moves strictly inward through
/// one construct's own tail, so the cap is only here for a table that points at
/// itself.
const tail_chain_depth_max: usize = 128;

/// Whether `node` is the value the function body ultimately produces.
///
/// Tail position is not only the outermost statement. A body that is an `if`
/// returns whichever branch ran, so `else { None }` is as much the function's
/// value as a bare `None` tail would be — and a value only one branch reaches
/// is exactly the one that had no type before. Every construct that passes
/// control onward carries its own tail into the next one: a block, an
/// `if`/`else`, an `if let`, a `match` arm, a `loop`. A position is a return
/// position when the chain reaches it, so all six readers of that question
/// answer it the same way.
fn isBodyTail(
    ctx: *Ctx,
    body: exprs.NodeId,
    node: exprs.NodeId,
    depth: usize,
) bool {
    if (depth >= tail_chain_depth_max) return false;
    if (body >= ctx.b.exprs.len) return false;
    if (body == node) return true;
    return switch (ctx.b.exprs[body].kind) {
        .block => |block| if (block.tail) |tail|
            isBodyTail(ctx, tail, node, depth + 1)
        else
            false,
        .if_else => |if_expr| {
            if (if_expr.then_.tail) |tail| {
                if (isBodyTail(ctx, tail, node, depth + 1)) return true;
            }
            return isElseBodyTail(ctx, if_expr.@"else", node, depth + 1);
        },
        .if_let => |if_let| {
            if (if_let.then_.tail) |tail| {
                if (isBodyTail(ctx, tail, node, depth + 1)) return true;
            }
            return isElseBodyTail(ctx, if_let.@"else", node, depth + 1);
        },
        .match => |match_expr| {
            for (match_expr.arms) |arm| {
                if (isBodyTail(ctx, arm.body, node, depth + 1)) return true;
            }
            return false;
        },
        // A `loop` is deliberately NOT followed. `loop { .. }` in tail position
        // evaluates to `()` in Rust, whatever its body ends with; it is the
        // `break` that carries a value out, and this walk follows expressions
        // rather than the path control takes. Treating a loop's tail as the
        // function's value would claim return position for a statement that is
        // not returned, so the case is left to a pass that can follow the break.
        else => false,
    };
}

fn isElseBodyTail(
    ctx: *Ctx,
    branch: exprs.ElseBranch,
    node: exprs.NodeId,
    depth: usize,
) bool {
    if (depth >= tail_chain_depth_max) return false;
    return switch (branch) {
        .none => false,
        .block => |block| if (block.tail) |tail|
            isBodyTail(ctx, tail, node, depth + 1)
        else
            false,
        .chain => |chain| isBodyTail(ctx, chain, node, depth + 1),
    };
}

/// Recover the declared return type for an expression in the body's tail chain.
/// This supplies the expected type for abstract associated calls whose
/// declaration still contains `Self` or an associated projection, and it is
/// what types a variant that carries no type of its own — `None` has no
/// payload to read one from, and its declared option is the only thing that
/// says what it is.
fn expectedTypeForTail(
    ctx: *Ctx,
    node: exprs.NodeId,
    fn_body: exprs.NodeId,
) ?types.Type {
    if (fn_body >= ctx.b.exprs.len) return null;
    const body_expr = ctx.b.exprs[fn_body];
    if (body_expr.kind != .block) return null;
    const tail = body_expr.kind.block.tail orelse return null;
    if (!isBodyTail(ctx, tail, node, 0)) return null;
    return findFnReturnType(ctx.b, fn_body);
}

/// Recover the expected generic result for a call in the body's tail chain.
/// The limit is the chain, not the position: using a function's return type for
/// an arbitrary nested call would bind unrelated call sites to the same record,
/// and a call no branch of the body can reach is exactly such a site.
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
///
/// A callable is checked against the parameters it DECLARES, which is not the
/// same list `getGenericParamNames` substitutes with. A method inside
/// `impl<S> Hasher<S>` binds `S` and names no parameter of its own, so a
/// turbofish that happens to be one argument long is a receiver witness rather
/// than an instantiation of that function; recording it would be the row
/// `validateInstantiations` rejects. This is the only thing the result gates —
/// the caller's single use of it is the `addInstantiation` it guards.
fn explicitArgsMatchSignature(
    ctx: *Ctx,
    def: exprs.DefId,
    args: []const types.Type,
) std.mem.Allocator.Error!bool {
    if (def >= ctx.b.bodies.len) return true;
    switch (ctx.b.bodies[def]) {
        .none => return true,
        .fn_, .struct_ => return declaredTypeParamCount(ctx, def) == args.len,
        .const_, .type_alias => {
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

/// How far a demand for an index result travels back through nested indexes to
/// the literal it reads. Each step moves strictly outward from the position
/// that stated the demand, so the cap is only here for a table that points at
/// itself.
const index_base_walk_depth_max: usize = 32;

/// Carry the type an index PRODUCES back into what it reads.
///
/// A range index (`x[a..b]`) yields a view over the base's elements and a plain
/// one (`x[i]`) yields a single element, so what a position states for the
/// index is a statement about the base's element — and it says nothing at all
/// until it reaches the base. `&[][..]` writes no element type anywhere: an
/// empty literal has no sibling to read one from, and its `0..` says only
/// where the view starts. The borrow's own `&[u8]` is the one statement of
/// what the empty slice holds, and this is what hands it down.
///
/// Only a base that is still unresolved is asked. A base the source already
/// typed says what it is, and pinning a demand onto it would invent a coercion
/// the source never wrote.
fn constrainIndexedBase(
    ctx: *Ctx,
    index: exprs.IndexExpr,
    result: types.Type,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (depth >= index_base_walk_depth_max) return;
    if (index.base >= ctx.b.exprs.len) return;
    // The bounds of a sequence index are `Range<usize>` in Rust, and the DEMAND
    // belongs on the endpoints — they are the indices. A range node is the view
    // those two bounds make, and `getKnownType` builds its `Range<usize>` from
    // them, so constraining the node itself stated a type the source never
    // wrote and left the view with a bare scalar record. This mirrors what the
    // `.index` walk arm already does for the same expression.
    const is_range = index.index < ctx.b.exprs.len and
        ctx.b.exprs[index.index].kind == .range;
    if (is_range) {
        const range = ctx.b.exprs[index.index].kind.range;
        try constrainExpectedType(ctx, range.start, .{ .prim = .usize });
        if (range.end) |end| try constrainExpectedType(ctx, end, .{ .prim = .usize });
    }
    var element = result;
    if (is_range) {
        element = indexedElementType(result) orelse return;
    }
    try constrainIndexedBaseElements(ctx, index.base, element, depth + 1);
}

/// State what the ELEMENTS of an index's base are, and nothing else.
///
/// The base of `x[i]` and of `x[a..b]` is a place, not a value a position is
/// converting, so a base that already carries a type of its own keeps it: an
/// owned length, a slice's `const` and a nominal element are all statements
/// the source made. `&mut rows[1][..]` asks a `rows` that already reads
/// `[[u8; 2]; 2]` for a `u8`, and asking it to become `[]const u8` is what
/// dropped a dimension per level out of it.
///
/// A base still carrying nothing is the other half of the same rule. The
/// `[]const u8` demanded of it is a real coercion — Rust unsizes an array into
/// the slice a borrow or an index names — and `constrainExpectedType` spends a
/// demanded slice on the literal underneath through `literalElementIdentity`,
/// which rebuilds the element from the literal's own spines rather than
/// storing the demanded slice in its place. One level out costs one level
/// back, at the lengths the source wrote. A nested index is that same crossing
/// one more time, which is why the element is rewrapped there rather than
/// passed bare.
///
/// A genuinely empty `[]`, a `[0; 4]` whose `0` no use has fixed, and an
/// element nothing named yet all arrive here unresolved too — which is the
/// only place a demand belongs.
fn constrainIndexedBaseElements(
    ctx: *Ctx,
    base: exprs.NodeId,
    element: types.Type,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (depth >= index_base_walk_depth_max) return;
    if (base >= ctx.b.exprs.len) return;
    if (getKnownType(ctx, base)) |known| {
        try nameUnnamedElement(ctx, base, known, element);
        return;
    }
    const base_ty = makeSliceType(ctx, element, false) orelse return;
    switch (ctx.b.exprs[base].kind) {
        .array => try constrainExpectedType(ctx, base, base_ty),
        // A nested index is another place, and its own type ends the walk
        // wherever it has one; where it has none the demand crosses it as the
        // slice its base's elements are, one more level of the same crossing.
        .index => |nested| try constrainIndexedBase(ctx, nested, base_ty, depth + 1),
        .path => try constrainBorrowedLocalInitializer(ctx, base, base_ty),
        else => {},
    }
}

/// Name an element a base's own type leaves as a hole, leaving everything else
/// about it — an array's length, a slice's `const` — as the source wrote it.
///
/// A base whose type this module recorded is a decision it made, and a
/// decision is not a hole; the fill is for a type the table handed over with
/// nothing under its element, where nothing has been recorded to contradict.
fn nameUnnamedElement(
    ctx: *Ctx,
    base: exprs.NodeId,
    known: types.Type,
    element: types.Type,
) std.mem.Allocator.Error!void {
    if (ctx.known_nodes.get(base) != null) return;
    const named: ?types.Type = switch (known) {
        .array => |array| if (isUnnamedElement(array.elem)) rebuilt: {
            const copy = try ctx.alloc.create(types.Array);
            copy.* = .{ .elem = element, .len = array.len };
            break :rebuilt .{ .array = copy };
        } else null,
        .slice => |slice| if (isUnnamedElement(slice.elem)) rebuilt: {
            const copy = try ctx.alloc.create(types.Slice);
            copy.* = .{ .const_ = slice.const_, .elem = element };
            break :rebuilt .{ .slice = copy };
        } else null,
        else => null,
    };
    if (named) |replacement| try pinKnownType(ctx, base, replacement);
}

/// Whether an element identity is still standing for whatever the constraints
/// around it will name: an `unsupported` hole, or a `_` placeholder.
fn isUnnamedElement(ty: types.Type) bool {
    return ty == .unsupported or isInferPlaceholderType(ty);
}

/// The element type an array literal holds, given the element type a position
/// demands of it.
///
/// The literal's own nesting and lengths are the source's — `[[0; 2]; 2]` is
/// two arrays of two whatever a position asks of it — so a demand is spent AT
/// the literal rather than replacing the shape it wrote. A child that is
/// itself an array literal holds its own array, and the demanded element
/// (`[]E`, say) is only what that child coerces to; the child's own `[M]E` is
/// what the literal actually holds, so the demand crosses into the child
/// instead of stopping at it — one level further in, because the child's
/// elements are what `[]E` names — until it reaches a level whose elements are
/// not arrays, which is the only level that keeps the demanded element.
///
/// Reconstructing the element here is what keeps a binding's shape whole when
/// the demand arrived one level out per nested index. Recording the demanded
/// slice as the element instead leaves the child the source wrote as an array
/// unaccounted for one level above it, which is how a dimension is lost.
fn literalElementIdentity(
    ctx: *Ctx,
    literal: exprs.ArrayExpr,
    demanded: types.Type,
) std.mem.Allocator.Error!types.Type {
    if (literal.elements.len == 0) return demanded;
    const child = literal.elements[0];
    if (child >= ctx.b.exprs.len) return demanded;
    const child_literal = switch (ctx.b.exprs[child].kind) {
        .array => |array| array,
        else => return demanded,
    };
    // A child the source already typed says what it is, and the literal's
    // element is that child whatever the demand called it.
    if (getKnownType(ctx, child)) |known| {
        if (known == .array) return known;
    }
    const inner = indexedElementType(demanded) orelse return demanded;
    const element = try literalElementIdentity(ctx, child_literal, inner);
    const child_len: u64 = child_literal.repeat orelse
        @as(u64, @intCast(child_literal.elements.len));
    const array = try ctx.alloc.create(types.Array);
    array.* = .{
        .elem = element,
        .len = .{ .literal = child_len },
    };
    return .{ .array = array };
}

fn constrainExpectedType(
    ctx: *Ctx,
    node: exprs.NodeId,
    expected: types.Type,
) std.mem.Allocator.Error!void {
    if (node >= ctx.b.exprs.len) return;
    if (getKnownType(ctx, node)) |known| {
        if (known == .prim and known.prim == .never) return;
        // Deref coercion changes the borrowed view, not the owner's identity.
        // Propagating `&str` into `&String` would pin the local initializer
        // to `str` and erase the frame's allocation and release obligation.
        const demanded = switch (expected) {
            .reference => |reference| reference.pointee,
            else => expected,
        };
        if (types.isStr(demanded)) {
            if (externalNominalBase(known)) |external| {
                if (external.args.len == 0 and external.path.len == 3 and
                    (std.mem.eql(u8, external.path[0], "alloc") or
                        std.mem.eql(u8, external.path[0], "std")) and
                    std.mem.eql(u8, external.path[1], "string") and
                    std.mem.eql(u8, external.path[2], "String"))
                {
                    try ctx.expected_types.put(ctx.alloc, node, expected);
                    return;
                }
            }
        }
    }
    var target = expected;
    if (ctx.b.exprs[node].kind == .array and expected == .slice) {
        const literal = ctx.b.exprs[node].kind.array;
        // The literal's element is what the source's own nesting makes it,
        // not the slice a position demanded of that element: `[[0; 2]; 2]`
        // adapts to a demanded `[][]u8` as `[2][2]u8`, one level of slice
        // spent per level of array the literal wrote.
        const literal_len: u64 = literal.repeat orelse
            @as(u64, @intCast(literal.elements.len));
        const array = try ctx.alloc.create(types.Array);
        array.* = .{
            .elem = try literalElementIdentity(ctx, literal, expected.slice.elem),
            .len = .{ .literal = literal_len },
        };
        target = .{ .array = array };
    }
    // Recorded as well as applied. Pinning fixes THIS node's type, but a node
    // that is itself a composite — a nested `match`, a block — gets walked
    // afterwards, and its own inference has to be able to ask what its position
    // expects of it. `contextualTypeAt` reads this table for exactly that, so a
    // conversion inside such a node can reach the expectation stated outside
    // it. Without the record the demand stops at the node it was stated for, and
    // everything beneath has to invent a target it cannot see.
    //
    // `target` is recorded rather than `expected`, because an array literal
    // adapted to a demanded slice IS the array, and the node's own type is what
    // a later reader should find.
    try ctx.expected_types.put(ctx.alloc, node, target);
    try pinKnownType(ctx, node, target);
    switch (ctx.b.exprs[node].kind) {
        .path => |path| {
            // An alias to a borrowed literal needs its pointee demand too;
            // equating only the whole reference would default its child.
            if (ctx.def_map.get(path.def)) |initializer| {
                if (initializer != node) try constrainExpectedType(ctx, initializer, target);
            }
        },
        .block => |block| {
            if (block.tail) |tail| try constrainExpectedType(ctx, tail, target);
        },
        .vec_lit => |vector| {
            const external = externalNominalBase(target) orelse return;
            if (external.path.len != 3 or external.args.len != 1 or
                (!std.mem.eql(u8, external.path[0], "alloc") and
                    !std.mem.eql(u8, external.path[0], "std")) or
                !std.mem.eql(u8, external.path[1], "vec") or
                !std.mem.eql(u8, external.path[2], "Vec")) return;
            for (vector.elements) |element| {
                try constrainExpectedType(ctx, element, external.args[0]);
            }
        },
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
        // `base[..]` is a view over the base, not a value read out of it, so
        // what a position states for the index is a statement about what the
        // base holds. That is the whole way `&[][..]` learns it is bytes: the
        // empty literal underneath names no element and has no sibling that
        // does, so the demand has to travel back down to it.
        .index => |index| {
            try constrainIndexedBase(ctx, index, target, 0);
        },
        // A range IS its endpoints — `a..b` names one integer type — so a
        // position that says what the range is says what both ends are. The
        // walk tied the two together with an `eq` edge already; this is the
        // identity the node itself never had. Only an integer demand reaches
        // the ends: a sequence index range is `usize`, and nothing else here
        // states what a range holds.
        .range => |range| {
            if (isIntegerType(target)) {
                try constrainExpectedType(ctx, range.start, target);
                if (range.end) |end| try constrainExpectedType(ctx, end, target);
            }
        },
        // `t.0` IS the element it reads, so a position that says what the
        // projection is says what that element is. The walk already tied the
        // two together with an `eq` edge, and an edge can only carry identity;
        // what it cannot carry is the demand, and for a tuple literal whose
        // slot the source left open this projection is the only place the
        // demand is ever stated. `u8_id(first.0)` names the parameter's `u8`
        // here, at the projection, and nothing in `(7, true)` names it.
        .field => |field| {
            const slot = std.fmt.parseInt(usize, field.field, 10) catch null;
            if (slot) |index| {
                if (tupleLiteralField(ctx, field.base, index)) |element| {
                    try constrainExpectedType(ctx, element, target);
                }
            }
        },
        .unary => |unary| {
            if (unary.op == .ref) {
                switch (target) {
                    .reference => |reference| {
                        try constrainExpectedType(ctx, unary.operand, reference.pointee);
                        try constrainBorrowedLocalInitializer(ctx, unary.operand, reference.pointee);
                    },
                    .slice => {
                        // `&[]` borrows the literal itself and `&[][..]`
                        // borrows a view of it. The demand the position states
                        // is the same one either way, so a range index is
                        // handed it beside the array literal, and what it does
                        // with it is `constrainIndexedBase`'s.
                        if (unary.operand < ctx.b.exprs.len) {
                            switch (ctx.b.exprs[unary.operand].kind) {
                                .array, .index => try constrainExpectedType(ctx, unary.operand, target),
                                else => {},
                            }
                        }
                        // `&mut [T]` lowers to a mutable slice, not a reference,
                        // so a borrowed binding reaches this arm too.
                        try constrainBorrowedLocalInitializer(ctx, unary.operand, target);
                    },
                    else => {},
                }
            } else {
                // `!x`, `~x` and `-x` produce the type they read, so a
                // position that names what the negation IS names what it
                // read. `mask[i] &= !(1 << n)` is written this way: the
                // demand reaches the shift, the shift reaches the `1`, and
                // the `1` keeps `Chunk`'s `u32` instead of the `i32` an
                // unconstrained integer literal would default to.
                if (aliasResolvedPrim(ctx, target)) |prim| {
                    if (unaryPreservesPrim(unary.op, prim)) {
                        try constrainExpectedType(ctx, unary.operand, target);
                    }
                }
            }
        },
        .enum_variant => |variant| switch (target) {
            // `Ok(v)` is `Result<typeof v, E>`, so a known `Result` type is
            // what gives the payload its type: the variant node itself says
            // nothing about `v`. The first tuple field is the `Ok` payload
            // and the second the `Err` one, matching the lowering of both
            // variants onto the same pair of positions.
            .result => |result| {
                if (variant.tuple_fields.len > 0) {
                    try constrainExpectedType(ctx, variant.tuple_fields[0], result.ok);
                }
                if (variant.tuple_fields.len > 1) {
                    try constrainExpectedType(ctx, variant.tuple_fields[1], result.err);
                }
            },
            // `Some(v)` is `Option<typeof v>` for the same reason and by the
            // same rule, and the `.external_variant` arm below already reads
            // an `Option` target that way. Without this prong a demand for
            // `Option<u8>` reached `Some(255)` and stopped there: the
            // constructor was pinned but the `255` it carries fell through to
            // the `i32` an unconstrained integer literal defaults to, so the
            // row said `Option<u8>` over an `i32`.
            .option => |inner| {
                if (variant.tuple_fields.len > 0) {
                    try constrainExpectedType(ctx, variant.tuple_fields[0], inner.*);
                }
            },
            else => {},
        },
        // `Some(x)` is `Option<T>` and `Ok(x)`/`Err(e)` are `Result<T, E>`
        // wherever the value stands, so a position that says what the option or
        // the result holds is what says what the payload holds: the variant
        // node itself says nothing about it. A variant carrying no field —
        // `None` — takes the whole declared type and pushes nothing, and that
        // declared type is the only thing that ever said what it is.
        .external_variant => |variant| {
            const payload: ?types.Type = switch (target) {
                .option => |inner| if (std.mem.eql(u8, variant.variant, "Some"))
                    inner.*
                else
                    null,
                .result => |result| if (std.mem.eql(u8, variant.variant, "Ok"))
                    result.ok
                else if (std.mem.eql(u8, variant.variant, "Err"))
                    result.err
                else
                    null,
                else => null,
            };
            const field: ?exprs.NodeId = if (variant.tuple_fields.len == 1)
                variant.tuple_fields[0]
            else if (variant.named_fields.len == 1)
                variant.named_fields[0].value
            else
                null;
            if (payload) |payload_ty| {
                if (field) |field_node| try constrainExpectedType(ctx, field_node, payload_ty);
            }
        },
        else => {},
    }
}

/// Follow a borrow of a local binding back to that binding's initializer.
/// `let mut out = [0; 4];` declares no element type, and in Rust the element
/// type arrives from the use: a parameter declared `&mut [u8]` coerces the
/// array to a slice and thereby fixes `out` to `[u8; 4]`. Without this step
/// the array literal stays untyped, its `0` element falls back to the `i32`
/// default, and the backend later rejects the repeat literal for having no
/// element type identity. `pointee` is the borrowed type itself: a mutable
/// slice for `&mut [T]`, a reference's pointee for `&[T; N]`.
fn constrainBorrowedLocalInitializer(
    ctx: *Ctx,
    node: exprs.NodeId,
    pointee: types.Type,
) std.mem.Allocator.Error!void {
    switch (pointee) {
        .slice, .array => {},
        else => return,
    }
    if (node >= ctx.b.exprs.len) return;
    const path = switch (ctx.b.exprs[node].kind) {
        .path => |path| path,
        else => return,
    };
    const init_node = ctx.def_map.get(path.def) orelse return;
    if (init_node == node or init_node >= ctx.b.exprs.len) return;
    switch (ctx.b.exprs[init_node].kind) {
        .array => {},
        else => return,
    }
    try constrainExpectedType(ctx, init_node, pointee);
    // The binding holds the array, not the slice it was borrowed as, so record
    // the array shape the literal just resolved to. A later `&out` then types
    // from that instead of defaulting again.
    const init_ty = getKnownType(ctx, init_node) orelse return;
    if (init_ty == .array) try ctx.local_types.put(ctx.alloc, path.def, init_ty);
}

/// The bounds under which a byte sink lives. Both name `u8` for a slice, an
/// array and a vector, and their `&mut W` / `&W` / `Box<W>` forms delegate to
/// those, so a value that reaches either bound is a value of bytes however the
/// source spelled it. `std` is the only root asked for, the same spelling
/// `knownIoMethodResultType` uses; the lookup resolves the name through the
/// callee's own `use`, so a crate's own `Read` is never matched here.
const io_sink_bounds: [2][]const []const u8 = .{
    &.{ "std", "io", "Write" },
    &.{ "std", "io", "Read" },
};

/// How far a sink constraint walks back through borrows, bindings and indexes
/// to the container it came from. Each step moves strictly outward from the
/// literal, so the cap is only here for a table that points at itself.
const io_sink_walk_depth_max: usize = 32;

/// Rust takes a byte sink's element type from the bound, not from the call
/// site. `let mut buf = [0; 1];` names no element at all, and the only `T` for
/// which `&mut [T]` is a `Write` is `u8`: trait selection answers first, so
/// the unconstrained-integer fallback never gets the chance to say `i32`.
/// Nothing here reads a literal's text — the bound is what says what these
/// bytes are, and a literal whose element something else already named keeps
/// that element.
fn constrainIoSinkArguments(
    ctx: *Ctx,
    def: exprs.DefId,
    args: []const exprs.NodeId,
) std.mem.Allocator.Error!void {
    const cg = ctx.cg orelse return;
    if (def >= ctx.b.bodies.len) return;
    const function = switch (ctx.b.bodies[def]) {
        .fn_ => |body| body,
        else => return,
    };
    if (args.len != function.params.len) return;
    for (args, function.params) |arg, param| {
        if (!declaresIoSinkBound(cg, ctx.b, def, param.ty)) continue;
        try constrainIoSinkElement(ctx, arg, 0);
    }
}

/// Whether a parameter names a type parameter the callee bounds by `Write` or
/// `Read`. The reference and box layers around that parameter are peeled by the
/// same lookup that resolves a receiver's bound, so `&mut W` with `W: Write`
/// and a plain `W` are one question, not two.
fn declaresIoSinkBound(
    cg: *const graph.CrateGraph,
    b: *const bodies.Bodies,
    def: exprs.DefId,
    param: types.Type,
) bool {
    for (io_sink_bounds) |trait_path| {
        if (bodies.genericBound(cg, b, def, param, trait_path) != null) return true;
    }
    return false;
}

/// The same question asked of a METHOD call, where the bound is on the
/// receiver and there is no parameter to ask. `fn unsigned<R>(r: &mut R) where
/// R: ?Sized + io::Read` puts `std::io::Read` on `R`, so `r.read_exact(&mut
/// buf)` inherits that bound the way it inherits every other method of the
/// trait — through the receiver — while the buffer it fills is one of the
/// call's own arguments rather than a parameter the callee hands back.
///
/// The receiver bound alone does not say a buffer is there. `Read::
/// read_vectored` takes `&mut [IoSliceMut]`, `Read::read_to_string` takes
/// `&mut String` and `Write::write_fmt` takes `&mut Arguments` — all of them
/// borrowed arguments of a `std::io` receiver, none of them bytes. So the name
/// is read first, out of the same `stdIoMethodTrait` that gives this very call
/// its result type: one name, the one trait that name requires, and the one
/// buffer it takes. Asking for the bound the name asks for is also what keeps a
/// crate's own `read_exact`, or an inherent method of the same name, out — it
/// carries no `std::io` bound to be found.
fn constrainIoSinkMethodArguments(
    ctx: *Ctx,
    method_name: []const u8,
    receiver_ty: ?types.Type,
    args: []const exprs.NodeId,
) std.mem.Allocator.Error!void {
    const trait_path = stdIoMethodTrait(method_name) orelse return;
    const cg = ctx.cg orelse return;
    const owner = ctx.current_fn orelse return;
    const receiver = receiver_ty orelse return;
    if (bodies.genericBound(cg, ctx.b, owner, receiver, trait_path) == null) return;
    // Both of those methods take exactly the one buffer and nothing else, so an
    // arity that does not match is not a call this describes.
    if (args.len != 1) return;
    if (!borrowedArgument(ctx, args[0])) return;
    try constrainIoSinkElement(ctx, args[0], 0);
}

/// Whether the expression at `node` is a borrow, which is the only shape a
/// byte sink is handed over in — `read_exact` takes `&mut [u8]`, `write_all`
/// takes `&[u8]`, and neither takes a buffer by value.
fn borrowedArgument(ctx: *Ctx, node: exprs.NodeId) bool {
    if (node >= ctx.b.exprs.len) return false;
    return switch (ctx.b.exprs[node].kind) {
        .unary => |unary| unary.op == .ref,
        else => false,
    };
}

/// Push the byte element back to the container the source actually built, and
/// pin every node the walk passed through so the backend reads a type at each
/// one.
///
/// A sink names no array of its own: the source writes
/// `let mut buf = [0; 1]; let mut writable = &mut buf[..];`, so the bound has
/// to reach through the borrow, the binding and the index to reach the literal
/// that nothing else types. Each step answers with the type its own node now
/// has, which is what the step above it pins.
fn constrainIoSinkElement(
    ctx: *Ctx,
    node: exprs.NodeId,
    depth: usize,
) std.mem.Allocator.Error!void {
    if (depth >= io_sink_walk_depth_max) return;
    if (node >= ctx.b.exprs.len) return;
    switch (ctx.b.exprs[node].kind) {
        .unary => |unary| {
            const mode = switch (unary.op) {
                .ref => |value| value,
                else => return,
            };
            try constrainIoSinkElement(ctx, unary.operand, depth + 1);
            const pointee = getKnownType(ctx, unary.operand) orelse return;
            const borrowed = makeReferenceType(ctx, pointee, mode == .mutable) orelse return;
            try pinKnownType(ctx, node, borrowed);
        },
        .path => |path| {
            const init = ctx.def_map.get(path.def) orelse return;
            if (init == node) return;
            try constrainIoSinkElement(ctx, init, depth + 1);
            const init_ty = getKnownType(ctx, init) orelse return;
            try ctx.local_types.put(ctx.alloc, path.def, init_ty);
            try pinKnownType(ctx, node, init_ty);
        },
        .index => |index| {
            try constrainIoSinkElement(ctx, index.base, depth + 1);
            const base_ty = getKnownType(ctx, index.base) orelse return;
            const selected = indexedResultType(ctx, base_ty, index.index) orelse return;
            try pinKnownType(ctx, node, selected);
        },
        .array => {
            // The literal is the end of the walk, and demanding the slice
            // `[u8]` of it is the one step that already fixes an array's
            // element and pins the array shape. A literal that already has a
            // type of its own has nothing to take from the bound.
            if (ctx.known_nodes.get(node) != null) return;
            const bytes = makeSliceType(ctx, .{ .prim = .u8 }, false) orelse return;
            try constrainExpectedType(ctx, node, bytes);
        },
        .vec_lit => {
            if (ctx.known_nodes.get(node) != null) return;
            const bytes = makeExternalNominalType(
                ctx,
                &.{ "alloc", "vec", "Vec" },
                &.{.{ .prim = .u8 }},
            ) orelse return;
            try constrainExpectedType(ctx, node, bytes);
        },
        else => {},
    }
}

/// Record what each argument position DEMANDS of the expression written there.
///
/// A call is where Rust hands a callee's own parameter type to whatever stands
/// in that position, and for a conversion written as `.into()` it is the only
/// place the target is ever named: `decode_utf8_lossy(bytes.into())` says
/// `Cow<'_, [u8]>` in the signature and nowhere else, and `bytes.into()` would
/// otherwise have no way to learn what it is converting into.
///
/// Only the DECLARED type is recorded. Nothing is pinned and no inference runs
/// from it here, so a callee whose parameter still names one of its own type
/// parameters, or one the frontend recovered no concrete for, records nothing
/// and its arguments are walked exactly as before. The arity has to line up:
/// a call with fewer arguments than parameters, or more, has no one-to-one
/// correspondence to read, and guessing one would type an expression against a
/// parameter it was never passed to.
/// The type-parameter names the scopes ENCLOSING `def` bind: its impl, its
/// trait, and the struct or enum either hangs off.
///
/// A method declared inside `impl MaxNumDigits for I` binds no generic parameter
/// of its own and still has one: `I` belongs to the impl, so
/// `fn max_num_digits(radix: I)` declares a generic parameter in a signature
/// carrying no `generics` of its own. That is what makes the callee's own
/// `generics` a false negative for exactly the declarations that need this most,
/// and why a signature scan cannot stand in for it — `I` is already interned in
/// the type table by the time a call reaches here, so it reads as a concrete
/// type. Naming it as a type parameter here is what stops that argument from
/// being told to be an `I` no matter what concrete type the receiver has.
///
/// Caller owns the returned slice.
fn enclosingGenericParamNames(ctx: *Ctx, def: exprs.DefId) std.mem.Allocator.Error!?[][]const u8 {
    const cg = ctx.cg orelse return null;
    var entity = cg.symbol_table.get(def) orelse return null;
    var collected: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer collected.deinit(ctx.alloc);
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const parent_id = entity.parent orelse break;
        const parent = cg.symbol_table.get(parent_id) orelse break;
        entity = parent;
        if (parent_id >= ctx.b.bodies.len) continue;
        switch (ctx.b.bodies[parent_id]) {
            .struct_ => |structure| for (structure.generic_params) |name| {
                try collected.append(ctx.alloc, name);
            },
            .enum_ => |enumeration| for (enumeration.generic_params) |name| {
                try collected.append(ctx.alloc, name);
            },
            .trait_ => |declaration| {
                for (declaration.generic_params) |name| try collected.append(ctx.alloc, name);
                if (declaration.generics) |generics| for (generics.params) |param| switch (param) {
                    .type_ => |type_param| try collected.append(ctx.alloc, type_param.name),
                    else => {},
                };
            },
            .impl_ => |implementation| if (implementation.generics) |generics| for (generics.params) |param| switch (param) {
                .type_ => |type_param| try collected.append(ctx.alloc, type_param.name),
                else => {},
            },
            else => {},
        }
    }
    if (collected.items.len == 0) {
        collected.deinit(ctx.alloc);
        return null;
    }
    return try collected.toOwnedSlice(ctx.alloc);
}

fn recordArgumentExpectations(
    ctx: *Ctx,
    def: exprs.DefId,
    args: []const exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (def >= ctx.b.bodies.len) return;
    const function = switch (ctx.b.bodies[def]) {
        .fn_ => |declaration| declaration,
        else => return,
    };
    if (function.params.len != args.len) return;
    // Naming the callee's type parameters is what tells a parameter type that
    // is still generic from one that is concrete, and a callee with no generic
    // parameters at all cannot have one. Reading that off the body the
    // parameters are already in skips the duplicate-and-free that asking the
    // graph for them costs on every call expression in the crate.
    const declares_generics = blk: {
        const generics = function.generics orelse break :blk false;
        break :blk generics.params.len > 0 or generics.where_clauses.len > 0;
    };
    const param_names: []const []const u8 = if (declares_generics)
        (getGenericParamNames(ctx, def) catch return)
    else
        &.{};
    defer {
        if (declares_generics) ctx.alloc.free(param_names);
    }
    // A parameter whose type names a type parameter of the callee's ENCLOSING
    // scope is still generic, however concrete that name reads in the type
    // table: `i32::max_num_digits(10)` passes a `usize`, and the `I` the
    // parameter is written with is the impl's, not the callee's. Recording it as
    // an expectation is what hands the argument a type no concrete one can
    // satisfy.
    const enclosing_names = try enclosingGenericParamNames(ctx, def);
    defer if (enclosing_names) |names| ctx.alloc.free(names);
    for (args, function.params) |arg, param| {
        if (arg >= ctx.b.exprs.len) continue;
        if (returnTypeNamesNoType(param.ty)) continue;
        if (param_names.len > 0 and types.typeContainsParam(param.ty, param_names)) continue;
        if (enclosing_names) |names| {
            if (types.typeContainsParam(param.ty, names)) continue;
        }
        try ctx.expected_types.put(ctx.alloc, arg, param.ty);
    }
}

fn constrainConcreteArguments(
    ctx: *Ctx,
    def: exprs.DefId,
    definition: bodies.BodyKind,
    args: []const exprs.NodeId,
    fields: []const exprs.FieldInit,
) std.mem.Allocator.Error!void {
    switch (definition) {
        .fn_ => |function| {
            if (args.len != function.params.len) return;
            // The same rule `recordArgumentExpectations` states, on the same
            // ground: a parameter naming the enclosing scope's type parameter
            // constrains nothing concrete, and `constrainExpectedType` would
            // spend a demand on an `I` that no argument can satisfy.
            const enclosing_names = try enclosingGenericParamNames(ctx, def);
            defer if (enclosing_names) |names| ctx.alloc.free(names);
            for (args, function.params) |arg, param| {
                if (returnTypeNamesNoType(param.ty)) continue;
                if (enclosing_names) |names| {
                    if (types.typeContainsParam(param.ty, names)) continue;
                }
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
    const def = callDefinition(c);
    // Before the arguments are walked, not after: an argument that is itself
    // `.into()` reads what its position demands while it is being walked.
    try recordArgumentExpectations(ctx, def, c.args);
    for (c.args) |a| try walkExpr(ctx, a, fn_body);
    // After the arguments are walked, so a sink that an argument's own literal
    // already typed is left exactly as that literal typed it.
    try constrainIoSinkArguments(ctx, def, c.args);
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
    if (expected_type) |expected| {
        try pinKnownType(ctx, node, expected);
        return;
    }
    // Rust gives a call the callee's declared return type wherever it appears,
    // so a call in argument or comparison position carries that type even
    // though no enclosing signature propagates one to it. That declared type
    // is the only source the other operand of a comparison has, so leaving
    // the node untyped there leaves the whole comparison untyped.
    try pinDeclaredReturnType(ctx, node, def);
}

/// Pin a callee's declared return type onto its call node. A declared type
/// that still names a type parameter, or an `impl Trait` the frontend models
/// as an unresolved opaque, carries no information at this call site: it is
/// valid only in the callee's own generic context, and pinning it would
/// overwrite a real type with a placeholder. Such a declaration is skipped,
/// exactly as `returnTypeNamesNoType` skips it for a function's own tail.
fn pinDeclaredReturnType(
    ctx: *Ctx,
    node: exprs.NodeId,
    def: exprs.DefId,
) std.mem.Allocator.Error!void {
    if (def >= ctx.b.bodies.len) return;
    const function = switch (ctx.b.bodies[def]) {
        .fn_ => |declaration| declaration,
        else => return,
    };
    const declared = findFnReturnType(ctx.b, function.body) orelse function.ret;
    if (returnTypeNamesNoType(declared)) return;
    if (!isConcreteType(declared)) return;
    const param_names = getGenericParamNames(ctx, def) catch return;
    defer ctx.alloc.free(param_names);
    if (param_names.len > 0 and types.typeContainsParam(declared, param_names)) return;
    try pinKnownType(ctx, node, declared);
}

/// Walk a struct literal: recurse into field values and, when the struct is
/// generic, unify field expression types with instantiated field types.
fn handleStructLit(ctx: *Ctx, node: exprs.NodeId, s: exprs.StructLit) std.mem.Allocator.Error!void {
    for (s.fields) |f| try walkExpr(ctx, f.value, node);
    if (s.base) |b0| try walkExpr(ctx, b0, node);
    try constrainWildcardFieldCasts(ctx, s.def, s.fields);
    try instantiateGenericDef(
        ctx,
        node,
        s.def,
        explicitArgsForNode(ctx, node),
        &.{},
        s.fields,
    );
}

/// Pin a struct-literal field's declared type onto a wildcard `as _` written
/// as that field's value. Rust types a field initializer against the field's
/// own declaration, so the declaration is the wildcard's destination; without
/// it, `Buf { off: n as _ }` names the cast nowhere and stays unresolvable.
///
/// Only a fully concrete declared type qualifies. A field whose type still
/// names a type parameter (`Box<T>`'s `T`) is not resolved until the generic
/// arguments are, so pinning it would put a symbolic path on the cast instead
/// of a type the backend can emit, and the wildcard must stay pending.
fn constrainWildcardFieldCasts(
    ctx: *Ctx,
    def: exprs.DefId,
    fields: []const exprs.FieldInit,
) std.mem.Allocator.Error!void {
    if (fields.len == 0 or def >= ctx.b.bodies.len) return;
    const structure = switch (ctx.b.bodies[def]) {
        .struct_ => |structure| structure,
        else => return,
    };
    const param_names = getGenericParamNames(ctx, def) catch |err| switch (err) {
        error.Unsupported => return,
        else => |allocator_error| return allocator_error,
    };
    defer ctx.alloc.free(param_names);
    for (fields) |field| {
        if (field.value >= ctx.b.exprs.len) continue;
        const cast = switch (ctx.b.exprs[field.value].kind) {
            .cast => |cast| cast,
            else => continue,
        };
        if (cast.target >= ctx.b.types.len) continue;
        if (!isInferPlaceholderType(ctx.b.types[cast.target])) continue;
        for (structure.fields) |declared| {
            if (!std.mem.eql(u8, declared.name, field.field)) continue;
            if (types.typeContainsParam(declared.ty, param_names)) break;
            try constrainExpectedType(ctx, field.value, declared.ty);
            break;
        }
    }
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
        try constrainConcreteArguments(ctx, def, ctx.b.bodies[def], args, fields);
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
                const actual_ty = getKnownType(ctx, arg_node);
                if (actual_ty) |actual| {
                    if (!matchGenericType(param.ty, actual, param_names, inferred_args)) {
                        valid = false;
                        break;
                    }
                    continue;
                }
                // A parameter naming no type parameter is already concrete, so
                // it still fixes an argument inference has not typed. That is
                // how `&mut [u8]` gives `let mut out = [0; 4];` its element type
                // through a generic callee such as
                // `fn f<T: AsRef<[u8]>>(.., ..: &mut [u8])`. An argument whose
                // parameter does name a type parameter stays unmatchable: the
                // type argument it would bind is still unknown.
                if (types.typeContainsParam(param.ty, param_names)) {
                    valid = false;
                    break;
                }
                try constrainExpectedType(ctx, arg_node, param.ty);
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

    // A record names an INSTANTIATION of a declaration, and a declaration
    // instantiates only through the parameters it declares in its own right.
    // `impl<S: Sip> Hasher<S> { fn new_with_keys(k0: u64, k1: u64) -> Hasher<S> }`
    // declares none: `Hasher<S>` is the struct's, and `Sip24Rounds` says
    // nothing about how many parameters `new_with_keys` takes. Writing the row
    // anyway records an instantiation no declaration can have — the metadata
    // `validateInstantiations` refuses, counted on the same entity's own
    // `generic_params`. The substitution below still runs, because that is
    // what the call PRODUCES: the inherited parameters are exactly what
    // determines the returned type.
    if (declaredTypeParamCount(ctx, def) == concrete_args.len) {
        try addInstantiation(ctx, node, .{
            .generic_id = def,
            .args = .{ .params = concrete_args },
            .zig_suffix = "",
        });
    }

    // Pin the instantiated return type when it resolves to an existing type.
    if (ret_ty) |return_ty| {
        if (try substitutedTypeId(ctx, return_ty, param_names, concrete_args)) |tid| {
            try addPin(ctx, node, tid);
        } else if (types.typeContainsParam(return_ty, param_names)) {
            // A generic return that nothing in the crate had interned yet is
            // still fully DETERMINED here — every parameter is bound above, so
            // substitution names one exact type. Dropping it for want of a table
            // row leaves the call untyped for a reason that has nothing to do
            // with the call, and that is the shape a seeded std constructor
            // always lands in: nothing in the source spells `Cursor<[u8; 3]>`,
            // so the only thing that can produce it is this substitution.
            //
            // Recording is the same channel `materializeDerivedTypes` already
            // uses for a type inference DERIVES rather than finds, so the row
            // lands in the table before the backend reads it. It is not a pin
            // shortcut: `recordDerivedType` dedupes against both the table and
            // the types already recorded, so this only ever ADDS the one row
            // that was missing and re-derives nothing.
            const derived = try types.substType(ctx.alloc, return_ty, param_names, concrete_args);
            ctx.recordDerivedType(node, derived);
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
    if (types.isTypeParam(t, param_names)) |idx| {
        if (idx < args.len) {
            const concrete = args[idx];
            if (findTypeIndex(ctx.b, concrete)) |cid| return cid;
        }
        return null;
    }
    // When the type has no generic-parameter references, it is already concrete.
    if (!types.typeContainsParam(t, param_names)) {
        return findTypeIndex(ctx.b, t);
    }
    // Otherwise substitute, look up, and release only owned temporary nodes.
    const subst = try types.substType(ctx.alloc, t, param_names, args);
    const found = findTypeIndex(ctx.b, subst);
    types.freeSubstitutedType(ctx.alloc, t, subst, param_names, args);
    return found;
}

/// Record `known` as this node's type even when the node already has one.
///
/// `pinKnownType` is deliberately conservative: a concrete type already on a
/// node is never displaced by a later answer. A receiver normalized from an
/// ALIAS is not a later answer — it is the very value the node already carries,
/// written under the record that name stands for — so it replaces the record
/// instead of losing to it. The pin, or the derived-type row a type not yet in
/// the table takes, is recorded after the one it supersedes, which is the order
/// `solved.apply` replays.
fn setKnownType(ctx: *Ctx, node: exprs.NodeId, known: types.Type) std.mem.Allocator.Error!void {
    if (known == .unsupported or containsInferPlaceholder(known)) return;
    const entry = try ctx.known_nodes.getOrPut(ctx.alloc, node);
    entry.value_ptr.* = known;
    if (findTypeIndex(ctx.b, known)) |type_id| {
        try addPin(ctx, node, type_id);
    } else {
        ctx.recordDerivedType(node, known);
    }
}

fn pinKnownType(ctx: *Ctx, node: exprs.NodeId, known: types.Type) std.mem.Allocator.Error!void {
    // Open shapes may guide child constraints but are not authoritative pins.
    if (known == .unsupported or containsInferPlaceholder(known)) return;
    const entry = try ctx.known_nodes.getOrPut(ctx.alloc, node);
    const already_known = entry.found_existing;
    if (!already_known or
        (entry.value_ptr.* == .generic_inst and known != .generic_inst) or
        (isInferPlaceholderType(entry.value_ptr.*) and !isInferPlaceholderType(known)))
    {
        entry.value_ptr.* = known;
    }
    // The pins a node accumulates are applied in the order they were recorded,
    // and a type that is not in the table yet reaches the solver through the
    // derived channel, which `materializeDerivedTypes` appends after every
    // recorded pin. So the guard above, which has just refused a placeholder
    // as this node's type, has to refuse it as this node's pin too: recorded,
    // it would be the last word for the node and would undo the concrete type
    // a surrounding position stated for it, and interning it would leave a
    // type nothing can carry in the crate's table. A node already known to be
    // something concrete learns nothing new from a hole.
    if (already_known and
        isInferPlaceholderType(known) and
        !isInferPlaceholderType(entry.value_ptr.*))
    {
        return;
    }
    if (findTypeIndex(ctx.b, known)) |type_id| {
        try addPin(ctx, node, type_id);
    } else {
        ctx.recordDerivedType(node, known);
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
    if (ctx.pattern_sources.get(p.def)) |source| {
        try linkPatternSource(ctx, node, source, ctx.b.exprs.len + ctx.b.pats.len + 1);
    }
    if (ctx.local_types.get(p.def)) |local_ty| {
        if (local_ty != .unsupported and !containsInferPlaceholder(local_ty)) try pinKnownType(ctx, node, local_ty);
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

/// Carry the target's declared type into a plain assignment's value.
///
/// `x = v` states that `v` IS `x`'s type, and Rust carries that statement
/// inward. `state.bytes = &[][..]` names no element anywhere in the source —
/// an empty literal has no sibling to read one from — so the field's own
/// `&[u16]` is the only thing in the expression that says what the empty slice
/// holds. The `eq` edge settles the value's own row but stops there: it joins
/// two nodes without reaching anything underneath them.
///
/// Only a value that carries no type of its own is asked, for the same reason
/// `constrainCompoundAssignment` asks in that order. A value the source
/// already typed has said what it is, and pushing the target's type onto one
/// the source coerced — a `&mut [T]` written into a `&[T]`, a `[T; N]` into a
/// `&[T]` — would replace the borrow qualifier it was written with.
fn constrainAssignedValue(
    ctx: *Ctx,
    target: exprs.NodeId,
    value: exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (getKnownType(ctx, value) != null) return;
    // A target that names nothing concrete — a cfg-gated declaration, an
    // `as _` destination, a not-yet-materialized `impl Trait` return — has no
    // type to state, and the equality edge is the only answer left.
    const target_ty = getKnownType(ctx, target) orelse return;
    if (target_ty == .unsupported) return;
    if (isInferPlaceholderType(target_ty)) return;
    if (returnTypeNamesNoType(target_ty)) return;
    try constrainExpectedType(ctx, value, target_ty);
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

fn tupleLiteralField(ctx: *Ctx, base: exprs.NodeId, index: usize) ?exprs.NodeId {
    return tupleLiteralFieldDepth(ctx, base, index, ctx.b.exprs.len);
}

fn tupleLiteralFieldDepth(ctx: *Ctx, base: exprs.NodeId, index: usize, fuel: usize) ?exprs.NodeId {
    var current = base;
    var remaining = fuel;
    while (remaining != 0) {
        remaining -= 1;
        if (current >= ctx.b.exprs.len) return null;
        switch (ctx.b.exprs[current].kind) {
            .path => |path| current = ctx.def_map.get(path.def) orelse return null,
            .field => |field| {
                const outer = std.fmt.parseInt(usize, field.field, 10) catch return null;
                current = tupleLiteralFieldDepth(ctx, field.base, outer, remaining) orelse return null;
            },
            .unary => |unary| {
                if (unary.op != .ref and unary.op != .deref) return null;
                current = unary.operand;
            },
            .array => |literal| {
                const ty = getKnownType(ctx, current) orelse return null;
                if (ty != .tuple or index >= literal.elements.len) return null;
                return literal.elements[index];
            },
            else => return null,
        }
    }
    return null;
}

/// Recursively walk an expression node in the graph.
/// Fold a cast's target, then put the folded type on its canonical row and
/// repoint every id that named the old one.
///
/// Folding REWRITES the row it lands on, and that is what makes two rows which
/// were genuinely different at extraction equal afterwards. itoa declares
/// `I64_MAX_LEN` and `U64_MAX_LEN` with the same value, each cast carries its own
/// length expression, and three rows are the right answer until all three fold to
/// `.literal(20)` — at which point one type occupies three rows and `deepEqual`
/// is true for all of them. Re-interning is what puts it back on one row.
///
/// Repointing is not optional. `ts_ext` sets `expr.ty` and `cast.target` to the
/// SAME id at extraction, so a fold that moves the target and leaves `expr.ty`
/// holding the old one reproduces the split one level down rather than removing
/// it.
fn foldCastTarget(ctx: *Ctx, node: exprs.NodeId) std.mem.Allocator.Error!void {
    const cast = &@constCast(ctx.b.exprs)[node].kind.cast;
    if (cast.target >= ctx.b.types.len) return;
    const folded = resolveConstArrayLengths(ctx, ctx.b.types[cast.target], 0) orelse return;
    // The canonical row is found BEFORE the folded type is written over the one
    // being folded: afterwards that row deep-equals it by construction and would
    // always win, which is the same row we are trying to leave.
    var canonical: ?exprs.TypeId = null;
    for (ctx.b.types, 0..) |row, index| {
        if (index == cast.target) continue;
        if (types.deepEqual(row, folded)) {
            canonical = @intCast(index);
            break;
        }
    }
    @constCast(ctx.b.types)[cast.target] = folded;
    const repointed = canonical orelse return;
    cast.target = repointed;
    @constCast(ctx.b.exprs)[node].ty = repointed;
}

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
            _ = try bindPattern(ctx, il.pattern, null, getKnownType(ctx, il.scrutinee));
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
                _ = try bindPattern(ctx, capture, null, getKnownType(ctx, w.cond));
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
            const binding = try bindPattern(ctx, f.pattern, null, element_ty);
            try walkBlock(ctx, f.body, fn_body, null);
            try unifyRangeBinding(ctx, f.iterable, binding);
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
            // `Some(x)` is an `Option` where it stands, not only where a
            // `match` reads one off it, so the identity is recorded here and
            // every reader of the node gets it.
            _ = try preludeVariantType(ctx, node);
            if (knownSourceEnumVariantType(ctx, node, ev)) |known| try pinKnownType(ctx, node, known);
            // The same demand the external variants answer: a body that returns
            // a value from this position says what that value is, and a variant
            // is no more exempt from it than a call is. A crate's own enum gets
            // the question asked of it the same way `Option` and `Result` do.
            if (expectedTypeForTail(ctx, node, fn_body)) |expected| {
                try constrainExpectedType(ctx, node, expected);
            }
        },
        .external_variant => |variant| {
            for (variant.tuple_fields) |field| try walkExpr(ctx, field, fn_body);
            for (variant.named_fields) |field| try walkExpr(ctx, field.value, fn_body);
            if (expectedTypeForTail(ctx, node, fn_body)) |expected| {
                try constrainExpectedType(ctx, node, expected);
            } else if (getKnownType(ctx, node)) |known| {
                try pinKnownType(ctx, node, known);
            }
            // `Cow::Owned(..)` CONSTRUCTS `B::Owned` and `Cow::Borrowed(..)`
            // constructs a borrow of `B`, and the variant node itself says only
            // which of the two by name — the payload it carries is named
            // nowhere else. `std::borrow::Cow::<str>::Owned(String::from(..))`
            // is the shape that needs it: the turbofish names `Cow<str>`, the
            // variant names the owned half, and `String` is what the payload
            // has to be for either to be a `Cow` at all. Stating it here rather
            // than from the position leaves the callee's own `B` — which is a
            // `_` for a turbofish that only fixed the borrowed half — out of
            // the payload's type.
            if (variant.owner.args.len == 1) {
                if (cowVariantPayloadType(ctx, variant.owner, variant.variant)) |payload| {
                    const field: ?exprs.NodeId = if (variant.tuple_fields.len == 1)
                        variant.tuple_fields[0]
                    else if (variant.named_fields.len == 1)
                        variant.named_fields[0].value
                    else
                        null;
                    if (field) |field_node| try constrainExpectedType(ctx, field_node, payload);
                }
            }
        },
        .field => |f| {
            try walkExpr(ctx, f.base, fn_body);
            if (std.fmt.parseInt(usize, f.field, 10) catch null) |index| {
                if (tupleLiteralField(ctx, f.base, index)) |element| try addEq(ctx, node, element);
            }
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        },
        .index => |ix| {
            try walkExpr(ctx, ix.base, fn_body);
            if (getKnownType(ctx, ix.base)) |base| {
                if (peelToSliceOrArray(base) != null and ix.index < ctx.b.exprs.len) {
                    switch (ctx.b.exprs[ix.index].kind) {
                        .range => |range| {
                            try constrainExpectedType(ctx, range.start, .{ .prim = .usize });
                            if (range.end) |end| try constrainExpectedType(ctx, end, .{ .prim = .usize });
                        },
                        else => try constrainExpectedType(ctx, ix.index, .{ .prim = .usize }),
                    }
                }
            }
            try walkExpr(ctx, ix.index, fn_body);
            // A range used as a sequence index is the VIEW those bounds make
            // over the base's element, not a `Range<usize>` value: `u[..1]` is
            // a window onto `u`, and the node the source wrote is that window.
            // `getKnownType` alone answers `core::ops::Range<T>`, which is the
            // right answer for a range used AS a value and the wrong one for the
            // view an index names, so the index position states it here.
            if (ix.index < ctx.b.exprs.len and ctx.b.exprs[ix.index].kind == .range) {
                if (getKnownType(ctx, ix.base)) |base_ty| {
                    if (indexedElementType(base_ty)) |elem| {
                        if (makeSliceType(ctx, elem, false)) |view| {
                            try pinKnownType(ctx, ix.index, view);
                        }
                    }
                }
            }
            if (getKnownType(ctx, node)) |known| try pinKnownType(ctx, node, known);
        },
        .cast => |cast| {
            if (cast.target < ctx.b.types.len) try walkTypeExpressions(ctx, ctx.b.types[cast.target], fn_body);
            try walkTypeExpressions(ctx, cast.source_type, fn_body);
            try walkExpr(ctx, cast.operand, fn_body);
            var source = getKnownType(ctx, cast.operand);
            var source_type = cast.source_type;
            // `&mut self.bytes as *mut [MaybeUninit<u8>; I128_MAX_LEN]` is a
            // cast between one type written two ways: the operand reads the
            // field, whose length the field binding already restored to the
            // number `const I128_MAX_LEN: usize = 40;` carries, and the
            // destination still spells that same length as the constant's own
            // expression. `typeEqual` compares the two writings as different
            // payloads, so the destination is published with its length
            // resolved and the operand judged by the same rule. Nothing here
            // accepts a cast: both sides now state the one type the
            // declaration says they are, and `isValidCast` reads them exactly
            // as it reads any other pair.
            try foldCastTarget(ctx, node);
            if (source) |known_source| {
                if (resolveConstArrayLengths(ctx, known_source, 0)) |resolved| source = resolved;
            }
            if (resolveConstArrayLengths(ctx, source_type, 0)) |resolved| {
                source_type = resolved;
                @constCast(ctx.b.exprs)[node].kind.cast.source_type = resolved;
            }
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
                if (resolveWildcardRawPointerSource(ctx, source_type, target, source_for_target)) |resolved| {
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
                .plain => {
                    try addEq(ctx, a.target, a.value);
                    try constrainAssignedValue(ctx, a.target, a.value);
                },
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
                    if (!returnTypeNamesNoType(ret_ty)) {
                        try constrainExpectedType(ctx, v, ret_ty);
                    }
                }
            }
        },
        .closure => |closure| try walkClosure(ctx, closure, fn_body),
        .iterator_chain => |chain| {
            try walkIteratorChain(ctx, chain, fn_body);
            // A `collect` in tail position takes its target from the
            // function's declared return type, the same way the call form
            // does in `handleCall`. A chain is the call form once the
            // frontend has folded it into one node, so it needs the same
            // record or it falls back to a `Vec` of its own items.
            if (expectedTypeForTail(ctx, node, fn_body)) |expected| {
                try ctx.expected_types.put(ctx.alloc, node, expected);
            }
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
        .array => |a| {
            for (a.elements) |el| try walkExpr(ctx, el, fn_body);
            refineSourceTupleRow(ctx, node, a);
            // A position that says what this literal IS wins over the sibling
            // rule below, and a tuple is where that matters most. A Rust tuple
            // `(0, Some(0))` reaches the IR as an array of two elements with no
            // repeat, exactly as `[0, 0]` does, so nothing in the node says the
            // elements are unrelated — but the declared `(usize, Option<usize>)`
            // hands them to each position, and forcing the `Some` to be whatever
            // the `0` is would invent a type the source never wrote.
            // An `impl Trait` return names no type this literal can be coerced
            // to, so it says nothing here and the sibling rule below still runs
            // — the same guard the `return` arm and `.into()` target apply
            // before they use a declared return as an expectation.
            if (expectedTypeForTail(ctx, node, fn_body)) |expected| {
                if (!returnTypeNamesNoType(expected)) {
                    try constrainExpectedType(ctx, node, expected);
                    return;
                }
            }
            if (e.ty) |type_id| {
                if (type_id < ctx.b.types.len and ctx.b.types[type_id] == .tuple) {
                    const fields = ctx.b.types[type_id].tuple;
                    // A slot the literal never named is still standing for
                    // whatever the constraints around it will say, and
                    // `isConcreteDerivedType` is what says so: constraining
                    // the element to it would pin the placeholder itself as
                    // the element's type, which is not a type anything can
                    // carry.
                    for (a.elements, 0..) |element, index| {
                        if (index < fields.len and isConcreteDerivedType(fields[index])) {
                            try constrainExpectedType(ctx, element, fields[index]);
                        }
                    }
                    return;
                }
            }
            // An array literal has ONE element type, and Rust fixes the
            // elements that name none from the ones that do: in
            // `[CONTINUATION_BIT, 1]` the sibling says `u8`, so the bare `1` is
            // a `u8`. Walking the elements leaves that one free, the solver
            // defaults it to `i32`, and then the array has no element type at
            // all — so the `let` holding it has none either, and every later
            // borrow of that binding has no pointee to hand on.
            //
            // The same door `.range` opens below for `a..b`: the sibling is
            // what says so, not a default.
            var element_type: ?types.Type = null;
            for (a.elements) |el| {
                element_type = getKnownType(ctx, el) orelse continue;
                for (a.elements) |other| {
                    if (other == el) continue;
                    try constrainExpectedType(ctx, other, element_type.?);
                }
                break;
            }
            // The array is itself a value once its element type is known.
            // Constraining the elements is not enough on its own: with both
            // elements typed and the literal still carrying no identity, the
            // `let` that binds it binds nothing, and everything downstream —
            // the slice range, the borrow, the path — has nothing to carry on.
            // `pinKnownType` interns the row through the ordinary derived-type
            // path when the table has not seen it yet, which is the same road
            // every other derived type takes; nothing here is a default.
            if (element_type) |elem| {
                if (ctx.b.exprs[node].ty == null) {
                    const array = try ctx.alloc.create(types.Array);
                    array.* = .{
                        .elem = elem,
                        .len = .{ .literal = a.repeat orelse @as(u64, @intCast(a.elements.len)) },
                    };
                    try pinKnownType(ctx, node, .{ .array = array });
                }
            }
            // `[0, 1, 2]` is the case no rule above can reach: no element
            // names a type, so the sibling loop has nothing to carry and the
            // container never becomes a value. The elements are not untyped —
            // each holds the integer class, which the solver's Defaults Phase
            // turns into a primitive — so the walk can finish this literal on
            // the solved-state replay `materializeSolvedSourceTypes` performs.
            // The mark is what asks for that replay, and it asks for it only
            // when the block above published nothing: `b.exprs[node].ty` is null
            // for a container this walk just named through a deferred pin, so
            // that table alone would ask a crate which is already answered to
            // pay for the replay.
            if (ctx.b.exprs[node].ty == null and !containerAlreadyNamed(ctx, node)) {
                for (a.elements) |el| {
                    if (elementAwaitsSolverDefault(ctx, el)) {
                        markPendingContainer(ctx);
                        break;
                    }
                }
            }
        },
        .vec_lit => |vec| {
            for (vec.elements) |el| try walkExpr(ctx, el, fn_body);
            // `vec![e; n]` counts in `usize` whatever `e` is, and `n` is an
            // ordinary expression evaluated after the element: walking it is
            // what reaches its own children. The `usize` demand is recorded
            // rather than forced, as the `.index` arm records it for its own
            // index, so a count that already carries a type keeps it.
            if (vec.repeat) |repeat| switch (repeat) {
                .literal => {},
                .expression => |count| {
                    try walkExpr(ctx, count, fn_body);
                    try constrainExpectedType(ctx, count, .{ .prim = .usize });
                },
            };
            // What the vector IS is said in one of two places, and the
            // stronger claim comes first. A declared binding states the element
            // type outright — `let values: Vec<(String, u8)> = vec![(..); n]` —
            // and outranks an element the extractor could not type, so the
            // position is read before the element is. Only a position that
            // demands nothing concrete leaves the element to answer, and that
            // answer is the same `Vec<T>` the `.array` arm above pins for an
            // array literal: `vec!` cannot carry it from extraction, because the
            // node is appended with `ty = null`. No special case for tuples, and
            // no `Vec<_>` for an element nothing typed: an untyped element
            // simply leaves the node untyped, which is what it already was.
            //
            // The element stays first in the source sense: the count is walked
            // and typed above, and the vector is named from the element or from
            // the declaration — never from the count.
            if (ctx.b.exprs[node].ty == null) {
                if (contextualTypeAt(ctx, node, fn_body)) |demanded| {
                    if (demanded == .external_nominal) try pinKnownType(ctx, node, demanded);
                }
            }
            if (ctx.b.exprs[node].ty == null and vec.elements.len > 0) {
                if (getKnownType(ctx, vec.elements[0])) |elem| {
                    if (makeExternalNominalType(ctx, &.{ "alloc", "vec", "Vec" }, &.{elem})) |vector| {
                        try pinKnownType(ctx, node, vector);
                    }
                }
            }
            // Same door the `.array` arm opens above, for the same reason:
            // `vec![0, 1]` holds elements the walk can only class, and the
            // vector takes its type from the element the solver named. An
            // elementless `Vec::new()` has no such element and is left alone.
            if (ctx.b.exprs[node].ty == null and !containerAlreadyNamed(ctx, node)) {
                for (vec.elements) |el| {
                    if (elementAwaitsSolverDefault(ctx, el)) {
                        markPendingContainer(ctx);
                        break;
                    }
                }
            }
        },
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
    const receiver = canonicalReceiver(ctx, known_receiver) orelse return;
    const method_def =
        resolve_methods.lookupInherentMethodFor(cg, ctx.b, receiver, method_name) orelse return;
    if (method_def >= ctx.b.bodies.len) return;
    const function = switch (ctx.b.bodies[method_def]) {
        .fn_ => |fn_body| fn_body,
        else => return,
    };
    const params = function.params;
    const offset: usize = if (params.len == args.len + 1) 1 else 0;
    if (params.len != args.len + offset) return;
    // A parameter still written as one of the callee's OWN type parameters is
    // not a demand about the argument: `short_write<T>(&mut self, _x: T, ..)`
    // called as `self.short_write(i, ..)` asks to BIND `T` from `i`. Stating
    // the demand instead writes the callee's unbound parameter name into the
    // caller's expression type, and the caller — a method that declares no `T`
    // — has no name for it. `recordArgumentExpectations` already reads the
    // callee's parameters this way; this loop has to agree with it.
    const declares_generics = blk: {
        const generics = function.generics orelse break :blk false;
        break :blk generics.params.len > 0 or generics.where_clauses.len > 0;
    };
    const param_names: []const []const u8 = if (declares_generics)
        (getGenericParamNames(ctx, method_def) catch return)
    else
        &.{};
    defer {
        if (declares_generics) ctx.alloc.free(param_names);
    }
    for (args, params[offset..]) |arg, param| {
        if (arg >= ctx.b.exprs.len) continue;
        if (returnTypeNamesNoType(param.ty)) continue;
        if (param_names.len > 0 and types.typeContainsParam(param.ty, param_names)) continue;
        try constrainExpectedType(ctx, arg, param.ty);
    }
}

/// Constrain the argument of a STANDARD method against the parameter its own
/// signature declares, for the methods whose parameter type is not a type
/// parameter and so is not reached by the inherent-method path above.
///
/// `String::push_str(&mut self, string: &str)` appends borrowed TEXT. Its
/// argument is a position that says what an expression in it has to be, and a
/// `"..."` written there carries no type of its own, so the demand is stated
/// here rather than left for something downstream to guess. It is borrowed
/// text and not borrowed bytes: only the second one can be `to_owned()` into
/// the `String` this very call is building.
///
/// The receiver decides. A crate's own `String`, a `Vec<u8>`, and a slice
/// borrow each reach a different runtime type, and a `push_str` this table
/// does not admit must not have its argument typed as if it were the owned
/// string's.
fn constrainStandardMethodArguments(
    ctx: *Ctx,
    method_name: []const u8,
    receiver_ty: ?types.Type,
    args: []const exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (!std.mem.eql(u8, method_name, "push_str")) return;
    const external = externalNominalBase(receiver_ty orelse return) orelse return;
    const is_owned_string = external.args.len == 0 and external.path.len == 3 and
        (std.mem.eql(u8, external.path[0], "alloc") or
            std.mem.eql(u8, external.path[0], "std")) and
        std.mem.eql(u8, external.path[1], "string") and
        std.mem.eql(u8, external.path[2], "String");
    if (!is_owned_string) return;
    if (args.len != 1) return;
    const borrowed_str = makeReferenceType(ctx, types.str_type, false) orelse return;
    try constrainExpectedType(ctx, args[0], borrowed_str);
}

/// Pin the result type a method call's own turbofish declares.
///
/// `xs.collect::<Vec<u8>>()` and `s.parse::<u32>()` name the result type at the
/// call site. Substituting those arguments into the method's declared return
/// type is what makes the call typed at all: the declared return is the bare
/// parameter, so nothing else can resolve it. Returns true when a type was
/// pinned, which is the caller's signal to stop — a turbofish outranks every
/// receiver-shaped rule, because that is what Rust does. Returns false when
/// there is no turbofish, or when substitution cannot produce a concrete
/// type, leaving the ordinary inference rules to run.
///
/// The call is read from the expression table, not from the copy the walker
/// holds: `bindTurbofishCollectedElement` rewrites a `collect` turbofish in
/// place, and a copy taken before that rewrite would substitute a placeholder
/// the walk has already replaced with the element the receiver's `Item` names.
fn pinTurbofishResultType(ctx: *Ctx, node: exprs.NodeId) std.mem.Allocator.Error!bool {
    if (node >= ctx.b.exprs.len) return false;
    const m = switch (ctx.b.exprs[node].kind) {
        .method_call => |value| value,
        else => return false,
    };
    if (m.generic_args.len == 0) return false;
    // The signature the substitution runs on, and the names it binds. A
    // concrete `fn_` carries both; a bodiless call-site `method_ref` carries
    // neither, and the trait that declares the method carries both from its
    // own signature. `getGenericParamNames` hands back a caller-freed
    // duplicate while a trait signature is read straight out of the body
    // table, so only the first is owned here.
    var declared: types.Type = undefined;
    var owned_names: []const []const u8 = &.{};
    var param_names: []const []const u8 = &.{};
    if (methodDeclaredReturnType(ctx, m.method)) |fn_return| {
        declared = fn_return;
        param_names = getGenericParamNames(ctx, m.method) catch return false;
        owned_names = param_names;
    } else if (getMethodName(ctx, m.method)) |method_name| {
        const signature = traitDeclaredMethod(
            ctx,
            method_name,
            m.generic_args.len,
        ) orelse return false;
        declared = signature.ret;
        param_names = signature.generic_params;
    } else return false;
    defer ctx.alloc.free(owned_names);
    if (param_names.len == 0 or param_names.len != m.generic_args.len) return false;
    // The declared return has to actually mention a parameter: a turbofish on
    // a method that returns something concrete says nothing new, and the
    // receiver-shaped rules below already reach that type.
    if (!types.typeContainsParam(declared, param_names)) return false;
    const substituted = types.substType(ctx.alloc, declared, param_names, m.generic_args) catch
        return false;
    if (!isConcreteDerivedType(substituted)) {
        types.freeSubstitutedType(ctx.alloc, declared, substituted, param_names, m.generic_args);
        return false;
    }
    try pinKnownType(ctx, node, substituted);
    // `pinKnownType` records the type on the solver's derived list, which the
    // driver reads; the arena owns the substitution, so nothing is freed here.
    return true;
}

/// True when any bound argument or associated-type binding still carries a
/// Rust `_`. Trait-object and opaque bounds hide placeholders one level down.
fn placeholderInBounds(bounds: []const types.Bound, depth: usize) bool {
    if (depth >= types.traversal_depth_max) return true;
    const next = depth + 1;
    for (bounds) |bound| {
        for (bound.args) |arg| if (containsInferPlaceholderDepth(arg, next)) return true;
        for (bound.associated_types) |binding| if (containsInferPlaceholderDepth(binding.ty, next)) return true;
    }
    return false;
}

/// True when `ty` still carries a Rust `_` somewhere inside it.
fn containsInferPlaceholder(ty: types.Type) bool {
    return containsInferPlaceholderDepth(ty, 0);
}

/// The walk is bounded by the same `traversal_depth_max` as every other
/// structural type traversal here. Exhausting it does not establish that the
/// type is finished, so it reports the hole still standing: an unfinished type
/// is never published, and an unfinished row is never counted as completed.
fn containsInferPlaceholderDepth(ty: types.Type, depth: usize) bool {
    if (isInferPlaceholderType(ty)) return true;
    if (depth >= types.traversal_depth_max) return true;
    const next = depth + 1;
    return switch (ty) {
        .external_nominal => |external| for (external.args) |arg| {
            if (containsInferPlaceholderDepth(arg, next)) break true;
        } else false,
        .generic_inst => |generic| for (generic.args.params) |arg| {
            if (containsInferPlaceholderDepth(arg, next)) break true;
        } else false,
        .tuple => |elements| for (elements) |arg| {
            if (containsInferPlaceholderDepth(arg, next)) break true;
        } else false,
        .reference => |reference| containsInferPlaceholderDepth(reference.pointee, next),
        .raw_ptr => |pointer| containsInferPlaceholderDepth(pointer.pointee, next),
        .slice => |slice| containsInferPlaceholderDepth(slice.elem, next),
        .array => |array| containsInferPlaceholderDepth(array.elem, next),
        .fn_ptr => |function| blk: {
            for (function.params) |param| if (containsInferPlaceholderDepth(param, next)) break :blk true;
            break :blk containsInferPlaceholderDepth(function.ret, next);
        },
        .option => |inner| containsInferPlaceholderDepth(inner.*, next),
        .result => |result| containsInferPlaceholderDepth(result.ok, next) or containsInferPlaceholderDepth(result.err, next),
        .boxed => |inner| containsInferPlaceholderDepth(inner.*, next),
        .@"opaque" => |opaque_type| placeholderInBounds(opaque_type.bounds, next) or
            if (opaque_type.concrete) |concrete| containsInferPlaceholderDepth(concrete.*, next) else false,
        .dyn_trait => |bounds| placeholderInBounds(bounds, next),
        .prim, .path, .unsupported => false,
    };
}

/// A `Vec` as the frontend spells it: `alloc::vec::Vec` with exactly one type
/// argument, the element it collects.
fn isCollectedElementContainer(ty: types.Type) bool {
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return false,
    };
    if (external.args.len != 1 or external.path.len != 3) return false;
    if (!std.mem.eql(u8, external.path[0], "alloc") and
        !std.mem.eql(u8, external.path[0], "std"))
    {
        return false;
    }
    return std.mem.eql(u8, external.path[1], "vec") and
        std.mem.eql(u8, external.path[2], "Vec");
}

/// Replace the `_` in `collect::<Vec<_>>()` with the element the receiver
/// declares, or return null when there is nothing to replace.
///
/// Only the collected element is bound, and only from a type the source
/// wrote down. `Result<Vec<_>, _>` leaves TWO placeholders and they are not
/// the same type: the `Vec`'s is `Self::Item`, while the `Result`'s is the
/// `FromIterator` error, which no bound on the receiver says anything about.
/// So the walk descends through the container spine and stops at the `Vec`
/// argument, leaving every other placeholder standing.
fn bindCollectedElementPlaceholder(
    alloc: std.mem.Allocator,
    ty: types.Type,
    item: types.Type,
) ?types.Type {
    if (isCollectedElementContainer(ty)) {
        const external = ty.external_nominal;
        if (!containsInferPlaceholder(external.args[0])) return null;
        const bound = alloc.alloc(types.Type, 1) catch return null;
        bound[0] = item;
        return .{ .external_nominal = .{
            .path = external.path,
            .args = bound,
        } };
    }
    if (!containsInferPlaceholder(ty)) return null;
    return switch (ty) {
        .external_nominal => |external| blk: {
            const args = alloc.alloc(types.Type, external.args.len) catch break :blk null;
            for (external.args, 0..) |arg, i| {
                args[i] = bindCollectedElementPlaceholder(alloc, arg, item) orelse arg;
            }
            break :blk types.Type{ .external_nominal = .{
                .path = external.path,
                .args = args,
            } };
        },
        .generic_inst => |generic| blk: {
            const params = alloc.alloc(types.Type, generic.args.params.len) catch break :blk null;
            for (generic.args.params, 0..) |arg, i| {
                params[i] = bindCollectedElementPlaceholder(alloc, arg, item) orelse arg;
            }
            break :blk types.Type{ .generic_inst = .{
                .decl = generic.decl,
                .args = .{ .params = params },
            } };
        },
        .tuple => |elements| blk: {
            const rebuilt = alloc.alloc(types.Type, elements.len) catch break :blk null;
            for (elements, 0..) |arg, i| {
                rebuilt[i] = bindCollectedElementPlaceholder(alloc, arg, item) orelse arg;
            }
            break :blk types.Type{ .tuple = rebuilt };
        },
        .option => |inner| blk: {
            const bound = bindCollectedElementPlaceholder(alloc, inner.*, item) orelse
                break :blk null;
            const rebuilt = alloc.create(types.Type) catch break :blk null;
            rebuilt.* = bound;
            break :blk types.Type{ .option = rebuilt };
        },
        else => null,
    };
}

/// Bind an open turbofish element to the `Item` the receiver's own bound
/// declares, in the IR the rest of the frontend reads.
///
/// `generate_iter(5).collect::<Vec<_>>()` names its container and leaves the
/// element to inference. The element is not free: the receiver is
/// `impl Iterator<Item = (usize, usize)>` and that bound says what it yields.
/// A receiver that declares no Item binds nothing, and the placeholder is
/// left standing for the resolver to refuse — this never guesses.
///
/// The receiver has to be WALKED before this runs. A receiver this pass has
/// not descended into has no type of its own yet, so the `Item` this reads
/// off it is not there to read; the placeholder would survive a walk that
/// could have completed it, and the call would stay untyped for the rest of
/// the frontend. Every caller therefore walks the receiver first.
fn bindTurbofishCollectedElement(ctx: *Ctx, node: exprs.NodeId, receiver: exprs.NodeId) void {
    if (node >= ctx.b.exprs.len or receiver >= ctx.b.exprs.len) return;
    const call = &@constCast(ctx.b.exprs)[node].kind.method_call;
    if (call.generic_args.len == 0) return;
    const receiver_ty = getKnownType(ctx, receiver) orelse return;
    const item = declaredBoundType(receiver_ty, "Item") orelse return;
    for (@constCast(call.generic_args)) |*argument| {
        argument.* = bindCollectedElementPlaceholder(ctx.alloc, argument.*, item) orelse
            argument.*;
    }
}

/// A declared `-> Self` is a statement about the CALLEE's own type. Pinning it
/// onto a call node carries that statement into the CALLER, where `Self` names
/// nothing: the caller has no impl in scope to resolve it against, and every
/// later reader sees a segment called `Self` pointing at an entity called
/// something else. `CONTROLS.add(b' ')` on a module constant is the shape that
/// leaks — thirty-three chained calls, each carrying the callee's `Self` into a
/// context that cannot mean it. The receiver is the one thing at the call site
/// that answers it, so every `Self` leaf becomes the receiver's own base type
/// here, at the producer, where the answer exists.
///
/// The rewrite itself is the IR's, so one rule serves every caller that has to
/// carry a `Self` spelling out of the impl that gave it meaning, and a
/// signature keeps its own shape around the leaf. Null says the declared type
/// names no `Self` anywhere, and the caller keeps what it already had.
fn substituteSelfLeaves(ctx: *Ctx, receiver: types.Type, declared: types.Type) ?types.Type {
    if (!types.mentionsSelf(declared)) return null;
    const self_type = types.peelCarrier(receiver) orelse return null;
    // Every failure the IR's rewrite reports answers null here, which means
    // "keep the declared type" — the spelling the frontend already had, and the
    // one this whole call chain existed to improve on rather than to guarantee
    // under memory pressure or past the traversal bound. It cannot mean "half
    // replaced": the IR's rewrite returns an error rather than a null for every
    // failure, so nothing partial arrives here.
    return types.replaceSelfLeaves(ctx.alloc, self_type, declared) catch null;
}

fn walkMethodCall(ctx: *Ctx, node: exprs.NodeId, m: exprs.MethodCall, fn_body: exprs.NodeId) std.mem.Allocator.Error!void {
    const m_name = getMethodName(ctx, m.method) orelse {
        try walkExpr(ctx, m.receiver, fn_body);
        for (m.args) |a| try walkExpr(ctx, a, fn_body);
        bindTurbofishCollectedElement(ctx, node, m.receiver);
        _ = try pinTurbofishResultType(ctx, node);
        return;
    };
    try walkExpr(ctx, m.receiver, fn_body);
    // The receiver is walked FIRST: the `Item` an open `collect` turbofish is
    // completed from is that receiver's own bound, and a receiver this pass
    // has not descended into has no type to read it off.
    bindTurbofishCollectedElement(ctx, node, m.receiver);
    const receiver_ty = getKnownType(ctx, m.receiver);
    // The receiver's OWN record is what the dispatch reads, so an alias spelled
    // the long way is normalized HERE rather than only in the arms this module
    // reads off it. `BufReader::new(data).unwrap()` is the shape: the receiver
    // is `std::io::Result<BufReader<R>>`, and a method on that external
    // nominal is refused for the want of an entry rather than for want of a
    // type. Recorded after the receiver's own walk, so this pin is the later
    // word for the node.
    if (receiver_ty) |known_receiver| {
        if (normalizedIoResultType(ctx, known_receiver)) |normalized| {
            try setKnownType(ctx, m.receiver, normalized);
        }
    }
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
    try constrainStandardMethodArguments(ctx, m_name, receiver_ty, m.args);
    // After the arguments are walked, for the same reason the free-call path is:
    // a buffer an argument's own literal already typed is left as that literal
    // typed it, and one nothing else typed is fixed here.
    try constrainIoSinkMethodArguments(ctx, m_name, receiver_ty, m.args);
    // An explicit turbofish is the caller's own binding for the method's type
    // parameters, so it decides the result type here — ahead of every
    // receiver-shaped rule below, exactly as `recv.m::<u32>()` wins over what
    // `recv` alone would imply. With no turbofish this is a no-op and the
    // existing rules run unchanged.
    if (try pinTurbofishResultType(ctx, node)) return;
    // A source declaration outranks receiver-shaped standard rules even when
    // its generic return cannot yet be completed. Ambiguous source dispatch
    // likewise cannot acquire a guessed standard return type.
    if (receiver_ty) |known_receiver| {
        if (ctx.cg) |cg| {
            if (canonicalReceiver(ctx, known_receiver)) |receiver| {
                switch (resolve_methods.lookupSourceMethodFor(cg, ctx.b, receiver, m_name)) {
                    .inherent, .trait_ => |definition| {
                        if (knownSourceMethodReturnType(ctx, known_receiver, definition)) |declared| {
                            const result = substituteSelfLeaves(ctx, known_receiver, declared) orelse declared;
                            try pinKnownType(ctx, node, result);
                        }
                        return;
                    },
                    .ambiguous => return,
                    .missing => {},
                }
            }
        }
    }
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
        if (knownTryArmMethodType(known_receiver, m_name)) |payload| {
            try pinKnownType(ctx, node, payload);
            return;
        }
        if (knownAllocMethodType(ctx, known_receiver, m_name)) |alloc_result| {
            try pinKnownType(ctx, node, alloc_result);
            return;
        }
        if (knownStdIntoType(ctx, node, known_receiver, m_name, fn_body)) |into_result| {
            try pinKnownType(ctx, node, into_result);
            return;
        }
        if (knownBoundTraitMethodType(ctx, known_receiver, m_name, m.method)) |bound_result| {
            try pinKnownType(ctx, node, bound_result);
            return;
        }
        // `first`, `map` and `and_then` are answered from the chain's SHAPE
        // rather than from a receiver table, and the next call in the chain
        // reads this node's record. Without the pin the chain is typed in
        // `getKnownType` and reaches the backend with nothing on the node the
        // consumer reads, which is how `text.first().and_then(..)` lost the
        // `Option<&u8>` the `&byte` pattern needs.
        if (knownOptionChainType(ctx, known_receiver, m_name, m.args)) |chain_result| {
            try pinKnownType(ctx, node, chain_result);
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
    // The terminal `collect` is typed from its target: its own turbofish,
    // completed by `bindTurbofishCollectedElement` from the receiver's
    // `Item`, or else the position the call sits in. It runs after the
    // adapter rules because a receiver that is not an `Iterator` has no
    // `Item` to fill a turbofish with, and those rules are what decide that.
    if (std.mem.eql(u8, m_name, "collect")) {
        if (knownCollectTargetType(ctx, node, expectedTypeForTail(ctx, node, fn_body))) |collect_target| {
            try pinKnownType(ctx, node, collect_target);
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
        std.mem.eql(u8, m_name, "split_first") or
        std.mem.eql(u8, m_name, "chunks") or
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
}

/// Walk the lossless code model of every `.fn_` body in `b` and generate
/// authoritative type pins and unification edges.
pub fn gen(alloc: std.mem.Allocator, b: *const bodies.Bodies) std.mem.Allocator.Error!Gen {
    return genWithGraph(alloc, b, null);
}

pub fn genWithGraph(alloc: std.mem.Allocator, b: *const bodies.Bodies, cg: ?*const graph.CrateGraph) std.mem.Allocator.Error!Gen {
    return genWithSolvedSources(alloc, b, cg, null, null);
}

fn genWithSolvedSources(
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    cg: ?*const graph.CrateGraph,
    solved_types: ?[]const ?exprs.TypeId,
    source_rows: ?*const std.AutoHashMapUnmanaged(exprs.NodeId, exprs.TypeId),
) std.mem.Allocator.Error!Gen {
    var g: Gen = .{};
    errdefer g.deinit(alloc);
    // Rescan first, then inherit. A row this expression carries NOW is one the
    // previous pass could not see: the first solve may have landed a
    // placeholder-bearing tuple on a literal that was untyped when the ledger
    // was seeded. The inherited ledger is laid over the scan so a row the
    // scan no longer admits is not dropped — it was earned by an earlier walk
    // and the replay is here to finish it, not to forget it.
    for (b.exprs, 0..) |expression, node| {
        if (expression.kind != .array or expression.kind.array.repeat != null) continue;
        const id = expression.ty orelse continue;
        if (id >= b.types.len or b.types[id] != .tuple or !containsInferPlaceholder(b.types[id])) continue;
        try g.source_tuple_rows.put(alloc, @intCast(node), id);
    }
    if (source_rows) |rows| {
        var iterator = rows.iterator();
        while (iterator.next()) |entry| try g.source_tuple_rows.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    var ctx: Ctx = .{ .alloc = alloc, .b = b, .g = &g, .cg = cg, .solved_types = solved_types };
    defer ctx.deinit();
    for (b.bodies, 0..) |kind, fn_index| {
        switch (kind) {
            .fn_ => |function| {
                ctx.def_map.clearRetainingCapacity();
                try ctx.prepareLocals(@intCast(fn_index), function.params);
                if (function.body < b.exprs.len) {
                    if (b.exprs[function.body].kind == .block) {
                        try walkBlock(&ctx, b.exprs[function.body].kind.block, function.body, function.body);
                    } else {
                        try walkExpr(&ctx, function.body, function.body);
                    }
                }
            },
            .none, .const_, .struct_, .enum_, .trait_, .impl_, .type_alias => {},
        }
    }
    if (g.derived_error) return error.OutOfMemory;
    g.source_completion_pending = g.source_tuple_rows.count() != 0 or
        g.derived_container_pending;
    return g;
}

/// Publish structural types which become knowable only after child solving.
/// The generator's own records decide whether any exist: a source tuple row
/// still carrying a `_`, and a container whose elements held only a literal
/// class. Both are finished by one replay of the walk with the solver's own
/// answers read as known types, and neither asks for a replay when there is
/// nothing to finish.
/// Keep the original generator's source ledger until table adoption is final.
/// Nested type storage retains the Bodies allocator lifetime; only temporary
/// generators and the replaced Inferred result are released by this operation.
pub fn materializeSolvedSourceTypes(
    alloc: std.mem.Allocator,
    b: *bodies.Bodies,
    type_list: *std.ArrayListUnmanaged(types.Type),
    g: *Gen,
    inferred: *Inferred,
    cg: ?*const graph.CrateGraph,
) !void {
    if (!g.source_completion_pending) return;
    // `materializeDerivedTypes` appends to the caller's list, which can move
    // the buffer this body table views. Rebind on every exit, including the
    // error exit between that append and the assignment below, so a failure
    // never leaves the caller holding a freed type slice.
    defer b.types = type_list.items;
    var completed_gen = try genWithSolvedSources(alloc, b, cg, inferred.types, &g.source_tuple_rows);
    defer completed_gen.deinit(alloc);
    completed_gen.defer_pending_casts = g.defer_pending_casts;
    try materializeDerivedTypes(alloc, type_list, @constCast(b.pats), &completed_gen);
    b.types = type_list.items;
    const completed = try solveWithGen(alloc, b, &completed_gen);
    inferred.deinit(alloc);
    inferred.* = completed;
    inferred.apply(@constCast(b.exprs));
    // The replay is over: what it could still not name is the only thing a
    // further replay would be asked for. Both are re-read from the generator
    // that just walked, never assumed cleared.
    g.source_completion_pending = completed_gen.derived_container_pending;
    var rows = g.source_tuple_rows.iterator();
    while (rows.next()) |entry| {
        const id = entry.value_ptr.*;
        if (id >= b.types.len or containsInferPlaceholder(b.types[id])) {
            g.source_completion_pending = true;
            break;
        }
    }
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

/// Reason published for a cast whose operand carries no type at all, so the
/// solver has no source type to check the destination against. `ir.validate`
/// carries this text out to the caller, which is what turns an opaque
/// `error.InvalidCast` into a diagnosis naming the construct.
const unresolved_cast_operand_reason = "unresolved cast operand type";

/// Replace a cast with a named refusal on the non-fatal channel.
///
/// The cast is not a wrong cast, it is an unresolved one: the frontend never
/// typed the operand and never recorded a source type, so `isValidCast` has
/// nothing to rule on and any verdict it returned would be a guess. Naming the
/// expression is both safer than guessing and more useful than aborting the
/// whole crate with an error that does not say which expression was at fault.
fn markUntypedCastOperand(e: *exprs.Expr) void {
    e.kind = .{ .unsupported = .{
        .reason = unresolved_cast_operand_reason,
        .suggested_version = .v1,
    } };
}

/// Complete casts whose operands acquire a genuine type during dispatch.
/// Call after adopting the resolver's final tables and before validation.
/// No new type is synthesized: wildcard destinations must already have a
/// concrete canonical expression type in the existing table.
pub fn completePendingCasts(b: *const bodies.Bodies) error{InvalidCast}!void {
    for (@constCast(b.exprs)) |*expression| {
        const cast = switch (expression.kind) {
            .cast => |value| value,
            else => continue,
        };
        if (cast.source_type != .unsupported) continue;
        if (cast.operand >= b.exprs.len or cast.target >= b.types.len) return error.InvalidCast;
        const source_id = b.exprs[cast.operand].ty orelse {
            markUntypedCastOperand(expression);
            continue;
        };
        if (source_id >= b.types.len) return error.InvalidCast;
        const source = b.types[source_id];
        if (source == .unsupported or isInferPlaceholderType(source)) {
            markUntypedCastOperand(expression);
            continue;
        }
        const target_id = if (isInferPlaceholderType(b.types[cast.target]))
            expression.ty orelse return error.InvalidCast
        else
            cast.target;
        if (target_id >= b.types.len) return error.InvalidCast;
        const target = b.types[target_id];
        if (isInferPlaceholderType(target) or !isValidCast(cast.kind, source, target, source)) {
            return error.InvalidCast;
        }
        expression.kind.cast.source_type = source;
        expression.kind.cast.target = target_id;
        expression.ty = target_id;
    }
}

/// Bring a settled cast's recorded source type back onto the type its operand
/// finally carries. The record was written during the walk, from the operand as
/// it stood then, and a solved pass can land a different type on that operand:
/// an element the Defaults Phase named, or a container the solved-state replay
/// completed. The IR requires the two to agree, so the writing side is what
/// repairs it. The rewrite happens only when `isValidCast` accepts the pair it
/// would create; a cast the operand's final type does not justify keeps the
/// record it had and is refused by the same code that refused it before.
fn reconcileSettledCastSource(
    b: *const bodies.Bodies,
    node: exprs.NodeId,
    cast: exprs.CastExpr,
    result_types: []const ?exprs.TypeId,
) void {
    if (node >= b.exprs.len or cast.operand >= b.exprs.len or cast.target >= b.types.len) return;
    const final_source_id = (if (cast.operand < result_types.len)
        result_types[cast.operand]
    else
        null) orelse b.exprs[cast.operand].ty orelse return;
    if (final_source_id >= b.types.len) return;
    const final_source = b.types[final_source_id];
    if (typeEqual(cast.source_type, final_source)) return;
    if (final_source == .unsupported or containsInferPlaceholder(final_source)) return;
    const target = b.types[cast.target];
    if (!isValidCast(cast.kind, final_source, target, final_source)) return;
    @constCast(b.exprs)[node].kind.cast.source_type = final_source;
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
        concrete[i] = if (b.exprs[i].ty) |id|
            if (id < b.types.len and !containsInferPlaceholder(b.types[id])) id else null
        else
            null;
        bottom[i] = isNeverTypeId(b.types, concrete[i]);
        classes[i] = .none;
    }

    // Apply literal classes.
    var class_it = g.classes.iterator();
    while (class_it.next()) |entry| {
        const n = entry.key_ptr.*;
        if (n < num_exprs) classes[n] = entry.value_ptr.*;
    }

    // Apply pinned authoritative types. Pins are applied in the order they were
    // recorded, so the last one recorded for a node is the one that survives —
    // which is right for two real types and wrong for a placeholder, because a
    // placeholder is not a statement that this node IS that type but the
    // absence of any statement about it. A hole never displaces a concrete
    // type, whichever of the two reached this node first.
    for (g.pins.items) |p| {
        if (p.node >= num_exprs) continue;
        if (p.ty >= b.types.len or containsInferPlaceholder(b.types[p.ty])) continue;
        concrete[p.node] = p.ty;
        if (isNeverTypeId(b.types, p.ty)) bottom[p.node] = true;
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
    // Complete every private source row, including rows whose expression was
    // repointed by return-context or alias inference. Lexical generic fields
    // are source decisions, so only actual holes receive solved child types.
    var source_rows = g.source_tuple_rows.iterator();
    while (source_rows.next()) |entry| {
        const node = entry.key_ptr.*;
        const row_id = entry.value_ptr.*;
        if (node >= b.exprs.len or row_id >= b.types.len or b.types[row_id] != .tuple) continue;
        const literal = switch (b.exprs[node].kind) {
            .array => |value| value,
            else => continue,
        };
        if (literal.repeat != null) continue;
        const fields = b.types[row_id].tuple;
        if (fields.len != literal.elements.len) continue;
        for (literal.elements, 0..) |element, index| {
            if ((!isUnnamedElement(fields[index]) and !containsInferPlaceholder(fields[index])) or element >= result_types.len) continue;
            const solved = result_types[element] orelse continue;
            if (solved >= b.types.len) continue;
            const candidate = b.types[solved];
            if (candidate == .unsupported or containsInferPlaceholder(candidate)) continue;
            if (!sourceTypeAcceptsSolved(fields[index], candidate)) continue;
            @constCast(fields)[index] = candidate;
        }
    }

    // Core generic arguments may become knowable only after unification has
    // applied a return-type or assignment constraint.
    try finalizeCoreCallTypeArguments(alloc, b, result_types);

    // Every `as _` in a crate lowers to one shared `_` entry in the type
    // table, so the first wildcard resolved here rewrites the very slot the
    // next one still points at. A cast aimed at such a slot is a wildcard
    // that has already been given a destination, not a cast whose
    // destination was always concrete, and it must still resolve from its
    // own solved type rather than inherit the first one's.
    const resolved_wildcards = try alloc.alloc(bool, b.types.len);
    defer alloc.free(resolved_wildcards);
    @memset(resolved_wildcards, false);

    for (b.exprs, 0..) |expression, node| {
        const cast = switch (expression.kind) {
            .cast => |value| value,
            else => continue,
        };
        if (cast.target >= b.types.len) {
            return error.InvalidCast;
        }
        const target_is_placeholder = isInferPlaceholderType(b.types[cast.target]);
        const target_is_resolved_wildcard = !target_is_placeholder and
            resolved_wildcards[cast.target];
        const source_type_is_unsupported = std.meta.activeTag(cast.source_type) == .unsupported;
        if (!source_type_is_unsupported and
            !target_is_placeholder and !target_is_resolved_wildcard)
        {
            // The walk already settled this cast: a concrete source and a
            // destination it resolved. Its record can still be stale if the
            // solver landed a different type on the operand, so it is brought
            // back onto that type before the cast is left alone — and only
            // where the pair that rewrite creates is one `isValidCast` accepts.
            reconcileSettledCastSource(b, @intCast(node), cast, result_types);
            continue;
        }

        const source_type_id: ?exprs.TypeId = if (source_type_is_unsupported)
            if (cast.operand < result_types.len) result_types[cast.operand] else null
        else
            findTypeIndex(b, cast.source_type);
        if (source_type_is_unsupported and source_type_id == null and
            cast.operand < b.exprs.len and b.exprs[cast.operand].ty == null)
        {
            // Preserve every original cast field for the full compiler's
            // post-dispatch completion step; no placeholder is validated.
            if (g.defer_pending_casts) continue;
            // Recorded source type still pending, nothing the solver produced
            // for the operand, and no type ever interned on it. There is no
            // source type here, so this cast is unresolved rather than wrong.
            // Say so by name instead of aborting the crate with an error that
            // does not identify the expression.
            markUntypedCastOperand(&@constCast(b.exprs)[node]);
            continue;
        }
        const resolved_source_id = source_type_id orelse blk: {
            if (cast.operand < b.exprs.len) {
                const operand_type = b.exprs[cast.operand].ty orelse return error.InvalidCast;
                break :blk operand_type;
            }
            return error.InvalidCast;
        };

        const resolved_target_id: ?exprs.TypeId = if (!target_is_placeholder and
            !target_is_resolved_wildcard)
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
        const source_type = if (source_type_is_unsupported)
            b.types[resolved_source_id]
        else
            cast.source_type;
        const target_type = b.types[final_target_id];
        if (target_is_placeholder or target_is_resolved_wildcard) {
            // Rewrite the placeholder slot so anything else still pointing at
            // it sees a concrete type, and repoint the cast at its own
            // resolved entry. `Inferred.apply` writes that same entry into
            // the cast's `ty`, so the IR keeps `ty == target`. The slot is
            // written once: a second `as _` sharing it must not overwrite the
            // destination the first one already published there.
            if (!target_is_resolved_wildcard) {
                @constCast(b.types)[cast.target] = target_type;
                resolved_wildcards[cast.target] = true;
            }
            @constCast(b.exprs)[node].kind.cast.target = final_target_id;
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
    // 1: id<T>(x: T) -> T (generic callee). The `<T>` is what `generic_params`
    // records, and a callee's parameters are read from there — never from the
    // names its signature happens to spell.
    const id_generic_params = try a.dupe([]const u8, &.{"T"});
    defer a.free(id_generic_params);
    bodies_store[1] = .{ .fn_ = .{
        .params = id_fn_params,
        .ret = param,
        .generic_params = id_generic_params,
        .body = 0,
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
    const id_generic_params = try a.dupe([]const u8, &.{"T"});
    defer a.free(id_generic_params);
    bodies_store[1] = .{ .fn_ = .{
        .params = id_fn_params,
        .ret = param,
        .generic_params = id_generic_params,
        .body = 0,
    } };

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

/// The declaration a struct literal instantiates is the struct's own, so
/// whether the row exists at all is a question about the DECLARATION and not
/// about the struct literal.
const struct_lit_struct: exprs.DefId = 1;

/// Expr 1 is the `5u32` written for `x`, expr 2 the `Pair { x: 5u32 }` itself.
const struct_lit_value_node: exprs.NodeId = 1;
const struct_lit_node: exprs.NodeId = 2;

/// The type rows this fixture interns, in the order it interns them. The
/// nominal path is what `nominalTypeForDefinition` scans for when the struct
/// declares nothing, so it has to be a row of its own rather than a name the
/// symbol table could be asked for.
const struct_lit_value_type: exprs.TypeId = 0;
const struct_lit_parameter_type: exprs.TypeId = 1;
const struct_lit_nominal_type: exprs.TypeId = 2;

const StructLitFixture = struct {
    exprs_store: []exprs.Expr,
    statements: []exprs.NodeId,
    stmts_store: []exprs.Statement,
    types_store: []types.Type,
    fields: []items.Field,
    bodies_store: []bodies.BodyKind,
    parameter_segments: []types.PathSegment,
    nominal_segments: []types.PathSegment,
    b: bodies.Bodies,

    fn deinit(self: *StructLitFixture, alloc: std.mem.Allocator) void {
        alloc.free(self.nominal_segments);
        alloc.free(self.parameter_segments);
        alloc.free(self.fields);
        alloc.free(self.bodies_store);
        alloc.free(self.types_store);
        alloc.free(self.stmts_store);
        alloc.free(self.statements);
        alloc.free(self.exprs_store);
        self.* = undefined;
    }
};

/// `struct Pair<..> { x: T, y: T }` and the `Pair { x: 5u32 }` written for it.
///
/// `generic_params` is the only input that differs between the two halves of
/// the test: the fields, their `T`, the type table and the literal are the same
/// either way, so whatever separates a recorded row from an absent one is the
/// declaration and nothing else. A field NAMES a type without declaring it —
/// `struct SipHasher24 { hasher: Hasher<Sip24Rounds> }` declares no parameter
/// at all and names one in every field — and reading that as a parameter list is
/// what wrote the row `(SipHasher24, [Sip24Rounds])`, an instantiation no
/// declaration can have.
fn buildStructLitFixture(
    alloc: std.mem.Allocator,
    generic_params: []const []const u8,
) !StructLitFixture {
    const parameter_segments = try alloc.dupe(types.PathSegment, &.{.{ .name = "T", .id = null }});
    errdefer alloc.free(parameter_segments);
    const nominal_segments = try alloc.dupe(types.PathSegment, &.{.{ .name = "Pair", .id = struct_lit_struct }});
    errdefer alloc.free(nominal_segments);
    const fields = try alloc.alloc(items.Field, 2);
    errdefer alloc.free(fields);
    const field_names = [_][]const u8{ "x", "y" };
    for (fields, field_names) |*field, name| {
        field.* = .{
            .name = name,
            .ty = .{ .path = .{ .segments = parameter_segments } },
            .visibility = .public,
            .span = test_span,
        };
    }

    const types_store = try alloc.alloc(types.Type, 3);
    errdefer alloc.free(types_store);
    types_store[struct_lit_value_type] = .{ .prim = .u32 };
    types_store[struct_lit_parameter_type] = .{ .path = .{ .segments = parameter_segments } };
    types_store[struct_lit_nominal_type] = .{ .path = .{ .segments = nominal_segments } };

    const exprs_store = try alloc.alloc(exprs.Expr, 3);
    errdefer alloc.free(exprs_store);
    // A block's `statements` are indices into the STMT table, in order, not
    // expression-table node ids: `walkBlock` hands each one to `walkStmt`,
    // which reads `b.stmts` with it and returns when the index is past the
    // table. An expression id there walks nothing at all, so the struct
    // literal was never reached and no instantiation was ever recorded —
    // which is what this fixture's first half read as a missing row rather
    // than as a literal the walk skipped.
    const statements = try alloc.alloc(exprs.NodeId, 1);
    errdefer alloc.free(statements);
    statements[0] = 0;
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .block = .{ .statements = statements, .tail = null, .labelled = null } },
    };
    exprs_store[struct_lit_value_node] = .{
        .id = struct_lit_value_node,
        .span = test_span,
        .ty = null,
        .kind = .{ .literal = .{ .int = .{ .text = "5u32", .value = 5, .base = .dec, .ty_suffix = "u32" } } },
    };
    exprs_store[struct_lit_node] = .{
        .id = struct_lit_node,
        .span = test_span,
        .ty = null,
        .kind = .{ .struct_lit = .{
            .def = struct_lit_struct,
            .fields = &.{.{ .field = "x", .value = struct_lit_value_node, .shorthand = false }},
            .base = null,
        } },
    };

    const stmts_store = try alloc.alloc(exprs.Statement, 1);
    errdefer alloc.free(stmts_store);
    stmts_store[0] = .{ .id = 0, .span = test_span, .ty = null, .kind = .{ .expr = struct_lit_node } };

    const bodies_store = try alloc.alloc(bodies.BodyKind, 2);
    errdefer alloc.free(bodies_store);
    bodies_store[0] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u32 },
        .body = 0,
    } };
    bodies_store[struct_lit_struct] = .{ .struct_ = .{
        .generic_params = generic_params,
        .trait_bounds = &.{},
        .layout = .named,
        .fields = fields,
        .methods = &.{},
    } };

    return .{
        .exprs_store = exprs_store,
        .statements = statements,
        .stmts_store = stmts_store,
        .types_store = types_store,
        .fields = fields,
        .bodies_store = bodies_store,
        .parameter_segments = parameter_segments,
        .nominal_segments = nominal_segments,
        .b = .{
            .exprs = exprs_store,
            .stmts = stmts_store,
            .pats = &.{},
            .types = types_store,
            .bodies = bodies_store,
        },
    };
}

test "generic struct literal records instantiation" {
    const a = std.testing.allocator;

    // `struct Pair<T>` declares `T`, the `x: 5u32` field binds it at `u32`, and
    // the row names an instantiation that declaration can have.
    var declared = try buildStructLitFixture(a, &.{"T"});
    defer declared.deinit(a);
    var declared_inferred = try solve(a, &declared.b);
    defer declared_inferred.deinit(a);

    const inst = declared_inferred.getInstantiation(struct_lit_node);
    try std.testing.expect(inst != null);
    try std.testing.expectEqual(struct_lit_struct, inst.?.generic_id);
    try std.testing.expectEqual(@as(usize, 1), inst.?.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, inst.?.args.params[0]);

    // `struct Pair` declares nothing. Its fields still name `T` and the literal
    // is the same one, so there is no declaration to instantiate and no row to
    // record. The literal is not left open for that: the non-generic path pins
    // the struct's own nominal type, which is what the literal IS.
    var undeclared = try buildStructLitFixture(a, &.{});
    defer undeclared.deinit(a);
    var undeclared_inferred = try solve(a, &undeclared.b);
    defer undeclared_inferred.deinit(a);

    try std.testing.expect(undeclared_inferred.getInstantiation(struct_lit_node) == null);
    try std.testing.expectEqual(@as(?exprs.TypeId, struct_lit_nominal_type), undeclared_inferred.getType(struct_lit_node));
}

/// `addInstantiation` duplicates the caller's args, so the source slice is
/// borrowed throughout and the map owns the copy. Sweeping every allocation
/// point covers three shapes: a fresh node key, a key that already holds a
/// record, and the exact moment between the duplicate and the map insert.
fn checkAddInstantiationAllocationFailures(alloc: std.mem.Allocator, replace_existing: bool) !void {
    const source_allocator = std.testing.allocator;
    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var constraints: Gen = .{};
    defer constraints.deinit(alloc);
    var ctx: Ctx = .{ .alloc = alloc, .b = &b, .g = &constraints };

    const prior_args = try source_allocator.dupe(types.Type, &.{.{ .prim = .i64 }});
    defer source_allocator.free(prior_args);
    const next_args = try source_allocator.dupe(
        types.Type,
        &.{ .{ .prim = .u32 }, .{ .prim = .bool } },
    );
    defer source_allocator.free(next_args);

    if (replace_existing) {
        addInstantiation(&ctx, 3, .{
            .generic_id = 7,
            .args = .{ .params = prior_args },
            .zig_suffix = "i64",
        }) catch |err| {
            // Seeding the prior record can itself exhaust the budget; the map
            // stays empty and the caller's storage is untouched.
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(constraints.instantiations.get(3) == null);
            try std.testing.expectEqual(types.Type{ .prim = .i64 }, prior_args[0]);
            return err;
        };
    }

    addInstantiation(&ctx, 3, .{
        .generic_id = 9,
        .args = .{ .params = next_args },
        .zig_suffix = "u32",
    }) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        // A refused recording leaves the map exactly as it stood before.
        if (replace_existing) {
            const kept = constraints.instantiations.get(3) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(exprs.DefId, 7), kept.generic_id);
            try std.testing.expectEqual(@as(usize, 1), kept.args.params.len);
            try std.testing.expectEqual(types.Type{ .prim = .i64 }, kept.args.params[0]);
            try std.testing.expectEqual(@as([]const u8, "i64"), kept.zig_suffix);
        } else {
            try std.testing.expect(constraints.instantiations.get(3) == null);
        }
        // The caller's own slice is borrowed and comes back unchanged.
        try std.testing.expectEqual(types.Type{ .prim = .u32 }, next_args[0]);
        try std.testing.expectEqual(types.Type{ .prim = .bool }, next_args[1]);
        return err;
    };

    const recorded = constraints.instantiations.get(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(exprs.DefId, 9), recorded.generic_id);
    try std.testing.expectEqual(@as(usize, 2), recorded.args.params.len);
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, recorded.args.params[0]);
    try std.testing.expectEqual(types.Type{ .prim = .bool }, recorded.args.params[1]);
    try std.testing.expectEqual(@as([]const u8, "u32"), recorded.zig_suffix);
    // The map holds the duplicate, never the caller's slice.
    try std.testing.expect(recorded.args.params.ptr != next_args.ptr);
    // A replaced record is superseded, not accumulated.
    try std.testing.expectEqual(@as(usize, 1), constraints.instantiations.count());
    try std.testing.expectEqual(types.Type{ .prim = .u32 }, next_args[0]);
    try std.testing.expectEqual(types.Type{ .prim = .bool }, next_args[1]);
}

test "addInstantiation rollback" {
    for ([_]bool{ false, true }) |replace_existing| {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            checkAddInstantiationAllocationFailures,
            .{replace_existing},
        );
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

fn nominalPathForTest(
    alloc: std.mem.Allocator,
    segments: []const struct { []const u8, ?spine.EntityId },
) !types.Path {
    const stored = try alloc.alloc(types.PathSegment, segments.len);
    for (segments, stored) |source, *target| {
        target.* = .{ .name = source[0], .id = source[1] };
    }
    return .{ .segments = stored };
}

// The same declaration is written with and without its qualifier:
// `impl Iterator for crate::enc::Iter` declares the type a receiver `Iter` in
// that module already names, and the pair was refused for having different
// segment counts before their ids were ever compared.
test "a qualified impl self type names the same declaration as a bare receiver" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const qualified = try nominalPathForTest(alloc, &.{
        .{ "crate", @as(?spine.EntityId, 1) },
        .{ "enc", null },
        .{ "Iter", @as(?spine.EntityId, 7) },
    });
    const bare = try nominalPathForTest(alloc, &.{.{ "Iter", @as(?spine.EntityId, 7) }});
    const other = try nominalPathForTest(alloc, &.{.{ "Iter", @as(?spine.EntityId, 8) }});
    const full_unresolved = try nominalPathForTest(alloc, &.{
        .{ "core", null },
        .{ "iter", null },
        .{ "Iterator", null },
    });
    const leaf_unresolved = try nominalPathForTest(alloc, &.{.{ "Iterator", null }});

    try std.testing.expect(sameNominalDeclaration(qualified, bare));
    try std.testing.expect(sameNominalDeclaration(bare, qualified));
    try std.testing.expect(!sameNominalDeclaration(qualified, other));
    // One side resolved and the other not is a comparison this pass cannot
    // make; the spelling must not stand in for the missing id.
    try std.testing.expect(!sameNominalDeclaration(qualified, leaf_unresolved));
    try std.testing.expect(!sameNominalDeclaration(leaf_unresolved, qualified));
    // Two fully unresolved paths fall back to the spelling, and that is the
    // whole spelling: a leaf alone never stands for a full path.
    try std.testing.expect(!sameNominalDeclaration(full_unresolved, leaf_unresolved));
}

// ── Contextual inference: the boundaries a consumer can see ────────────────

// `pub fn adler32<R: BufRead>(mut reader: R) -> io::Result<u32>` reads its input
// through `fill_buf` and `consume`, and the test beside it reaches the same
// reader through `BufReader::new(data).unwrap()`. All three are `std::io`
// identities the source writes, and they have to be the SAME identities the
// fallible methods produce — an error type that differs by spelling makes each
// read as the other's payload.
test "a BufRead bound types fill_buf as a shared byte slice and consume as unit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const owner_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "adler32"),
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
            .{ .name = "BufRead", .id = null },
        },
    } };
    const generics: types.Generics = .{
        .params = &.{.{ .type_ = .{ .name = "R", .bounds = &.{bound} } }},
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
    const receiver: types.Type = .{ .path = .{ .segments = &.{.{ .name = "R", .id = null }} } };
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

    const filled = knownIoMethodResultType(&ctx, receiver, "fill_buf").?;
    try std.testing.expect(filled == .result);
    // The buffer a `BufRead` lends out is SHARED. The reader is what `consume`
    // writes through, and a mutable slice here would make the `write_slice(buf)`
    // that consumes it a different program from the one written.
    try std.testing.expect(filled.result.ok == .slice);
    try std.testing.expect(filled.result.ok.slice.const_);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, filled.result.ok.slice.elem);
    try std.testing.expectEqual(std_io_error_type, filled.result.err);
    // `consume(&mut self, amt: usize)` hands nothing back at all.
    try std.testing.expectEqual(
        types.Type{ .prim = .unit },
        knownIoMethodResultType(&ctx, receiver, "consume").?,
    );
    // `BufRead` is not `Write`, so a crate's own `write_all` on the very same
    // receiver stays untyped rather than borrowing the `BufRead` answer.
    try std.testing.expect(knownIoMethodResultType(&ctx, receiver, "write_all") == null);

    // What `BufReader::new(data)` produces is `std::io::Result<BufReader<R>>` —
    // its OWN path, not `core::result::Result` — so the `.unwrap()` the source
    // writes has to read both arms off it, and the `Err` arm is the very error
    // `fill_buf` fails with rather than a second spelling of it.
    const reader_type: types.Type = .{ .prim = .u32 };
    const io_result: types.Type = .{ .external_nominal = .{
        .path = &.{ "std", "io", "Result" },
        .args = &.{reader_type},
    } };
    try std.testing.expectEqual(
        reader_type,
        knownTryArmMethodType(io_result, "unwrap").?,
    );
    try std.testing.expectEqual(
        std_io_error_type,
        knownTryArmMethodType(io_result, "unwrap_err").?,
    );
    // `unwrap_or` opens the same arm and decides which VALUE is produced rather
    // than what the result is.
    try std.testing.expectEqual(
        reader_type,
        knownTryArmMethodType(io_result, "unwrap_or").?,
    );
}

// `value.to_le_bytes()` and `T::from_le_bytes(..)` are one operation in each
// direction, and the pair is why the width has to come from the integer rather
// than from whatever the call happens to receive.
test "a little-endian byte conversion types both directions from its integer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{ .alloc = alloc, .b = &b, .g = &generated, .cg = null };
    defer ctx.deinit();

    // The encode produces the integer's OWN image, as an array of `u8` whose
    // length is that integer's width — here `u64`'s eight.
    const encoded = knownCoreCallType(&ctx, 0, .{
        .function = .prim_to_le_bytes,
        .generic_args = &.{.{ .prim = .u64 }},
        .args = &.{},
    }).?;
    try std.testing.expect(encoded == .array);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, encoded.array.elem);
    try std.testing.expect(encoded.array.len == .literal);
    try std.testing.expectEqual(@as(u64, 8), encoded.array.len.literal);
    // The decode is the mirror: it produces the integer, never an array of it.
    try std.testing.expectEqual(types.Type{ .prim = .u64 }, knownCoreCallType(&ctx, 0, .{
        .function = .prim_from_le_bytes,
        .generic_args = &.{.{ .prim = .u64 }},
        .args = &.{},
    }).?);
    // A pointer-sized integer's width is the TARGET's. A literal here would be
    // right for the host that ran the translation and wrong for every target that
    // is not it, so with no recorded `[u8; @sizeOf(T)]` to read back the answer
    // is nothing at all rather than a number.
    try std.testing.expect(knownCoreCallType(&ctx, 0, .{
        .function = .prim_to_le_bytes,
        .generic_args = &.{.{ .prim = .usize }},
        .args = &.{},
    }) == null);
    // The semantic wrapper must survive inference; only code generation
    // erases its storage layout. The repeat remains on the array node.
    try std.testing.expect(types.deepEqual(
        .{ .external_nominal = .{
            .path = &.{ "core", "mem", "MaybeUninit" },
            .args = &.{.{ .prim = .u8 }},
        } },
        knownCoreCallType(&ctx, 0, .{
            .function = .maybe_uninit_uninit,
            .generic_args = &.{.{ .prim = .u8 }},
            .args = &.{},
        }).?,
    ));
    // Both default bodies write somewhere else and hand nothing back.
    for ([_]exprs.CoreFunction{ .rng_fill_bytes_via_next, .hash_write_primitive }) |function| {
        try std.testing.expectEqual(
            types.Type{ .prim = .unit },
            knownCoreCallType(&ctx, 0, .{
                .function = function,
                .generic_args = &.{.{ .prim = .u64 }},
                .args = &.{0},
            }).?,
        );
    }
}

// `I::ZERO`, `I::ONE`, `I::MIN_VALUE` and `I::MAX_VALUE` all name the bound of
// the type their one argument is, so all four hand that type back.
test "a numeric bound names the type it bounds and never a placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{
            .params = &.{},
            .ret = .{ .prim = .unit },
            .generic_params = &.{"I"},
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
    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const owner_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "from_radix_10_signed"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
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

    const parameter: types.Type = .{ .path = .{ .segments = &.{.{ .name = "I", .id = null }} } };
    const placeholder: types.Type = .{ .external_nominal = .{ .path = &.{"_"} } };
    for ([_]exprs.CoreFunction{
        .numeric_zero,
        .numeric_one,
        .numeric_min_value,
        .numeric_max_value,
    }) |function| {
        // A primitive says its own width.
        try std.testing.expectEqual(types.Type{ .prim = .u8 }, knownCoreCallType(&ctx, 0, .{
            .function = function,
            .generic_args = &.{.{ .prim = .u8 }},
            .args = &.{},
        }).?);
        // A type parameter the ENCLOSING scope declared is bound by the same
        // bound these names are declared against.
        try std.testing.expectEqual(parameter, knownCoreCallType(&ctx, 0, .{
            .function = function,
            .generic_args = &.{parameter},
            .args = &.{},
        }).?);
        // A `_` is neither. It reads as concrete to a walk that only inspects
        // arguments, and a sentinel in this slot is a value the caller goes on to
        // use. There is no literal to fall back to either: `I::MIN` names the
        // bound rather than writing a number down.
        try std.testing.expect(knownCoreCallType(&ctx, 0, .{
            .function = function,
            .generic_args = &.{placeholder},
            .args = &.{},
        }) == null);
    }
}

// `impl<I: Integer> FromRadix10Checked for I { fn from_radix_10_checked(text:
// &[u8]) -> (Option<I>, usize) }` declares a return that names the IMPL's
// parameter, so nothing about the callee is concrete on its own. The call
// records the RECEIVER as its one type argument, and binding that is what turns
// `(Option<I>, usize)` into the tuple `assert_eq!((Some(255), 3), ..)` compares
// against — instead of the `_` placeholder that reached validation.
//
// `I` belongs to the impl and the method never spells it, so the binding comes
// from the scope walk OUT of the method and not from the function's own body.
// That walk needs a symbol table to walk: given a method whose parent chain
// leads nowhere, `getGenericParamNames` has no declaration to inherit from,
// substitutes nothing, and the call says nothing — which is this test's second
// half, and not a reason for the first half to be built out of one.
test "a blanket local trait impl answers its own primitive through the receiver" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Entity ids are body-table indices, and `add` mints them in call order:
    // 0 = the method, 1 = the impl that declares `I`, 2 = the module it is in.
    const method_id: spine.EntityId = 0;
    const impl_id: spine.EntityId = 1;
    const module_id: spine.EntityId = 2;
    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    try std.testing.expectEqual(method_id, try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "from_radix_10_checked"),
        .span = test_span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    }));
    try std.testing.expectEqual(impl_id, try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try alloc.dupe(u8, "FromRadix10Checked for I"),
        .span = test_span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    }));
    try std.testing.expectEqual(module_id, try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, "lib"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    }));

    const parameter = types.Type{ .path = .{ .segments = &.{.{ .name = "I", .id = null }} } };
    const option_ptr = try alloc.create(types.Type);
    option_ptr.* = parameter;
    const declared_tuple = try alloc.alloc(types.Type, 2);
    declared_tuple[0] = .{ .option = option_ptr };
    declared_tuple[1] = .{ .prim = .usize };

    // The impl declares `I`; the method declares nothing of its own. That is
    // the whole shape of a blanket impl, where `Option<I>` is written in the
    // method and `I` belongs to `impl<I> .. for I` above it.
    const impl_params = try alloc.alloc(types.GenericParam, 1);
    impl_params[0] = .{ .type_ = .{ .name = "I", .bounds = &.{} } };
    const assoc_items = try alloc.alloc(spine.EntityId, 1);
    assoc_items[0] = method_id;

    // The call node carries the receiver as its one type argument, which is the
    // only place `u8` is written down for this call. Node 1 is the callee's own
    // empty block, so the method body is not the call that carries the witness.
    const types_store = try alloc.alloc(types.Type, 1);
    types_store[0] = .{ .generic_inst = .{
        .decl = method_id,
        .args = .{ .params = &.{.{ .prim = .u8 }} },
    } };
    const exprs_store = try alloc.alloc(exprs.Expr, 2);
    exprs_store[0] = .{
        .id = 0,
        .span = test_span,
        .ty = 0,
        .kind = .{ .call = .{
            .call_kind = .{ .associated = method_id },
            .args = &.{},
        } },
    };
    exprs_store[1] = .{
        .id = 1,
        .span = test_span,
        .ty = null,
        .kind = .{ .block = .{ .statements = &.{}, .tail = null, .labelled = null } },
    };

    const bodies_store = try alloc.alloc(bodies.BodyKind, 3);
    bodies_store[method_id] = .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .tuple = declared_tuple },
        .body = 1,
    } };
    bodies_store[impl_id] = .{ .impl_ = .{
        .self_ty = parameter,
        .trait_path = .{ .segments = &.{.{ .name = "FromRadix10Checked", .id = null }} },
        .generics = .{ .params = impl_params, .where_clauses = &.{} },
        .assoc_items = assoc_items,
    } };
    bodies_store[module_id] = .none;

    const b: bodies.Bodies = .{
        .exprs = exprs_store,
        .stmts = &.{},
        .pats = &.{},
        .types = types_store,
        .bodies = bodies_store,
    };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{ .alloc = alloc, .b = &b, .g = &generated, .cg = &graph_store };
    defer ctx.deinit();

    const call = exprs.Call{ .call_kind = .{ .associated = method_id }, .args = &.{} };
    // Named rather than unwrapped: "a call that cannot be completed says
    // nothing" is a property worth asserting, so a regression in the walk that
    // stops `I` from binding has to read as a failed expectation here rather
    // than as an abort that takes the whole test binary with it.
    const resolved = knownCallReturnType(&ctx, 0, call) orelse return error.ReceiverDidNotBindTheImplsParameter;
    try std.testing.expect(resolved == .tuple);
    try std.testing.expectEqual(@as(usize, 2), resolved.tuple.len);
    try std.testing.expect(resolved.tuple[0] == .option);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, resolved.tuple[0].option.*);
    try std.testing.expectEqual(types.Type{ .prim = .usize }, resolved.tuple[1]);

    // The same call with nothing recording the receiver cannot be completed, and
    // a call that cannot be completed says NOTHING. The impl is still there and
    // still declares `I` — what is missing is the `u8` to bind it at, and
    // handing back the callee's own unbound `I` would write a parameter name
    // into the caller's expression that the caller's own function never
    // declared.
    const bare_exprs = [_]exprs.Expr{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .call = .{
            .call_kind = .{ .associated = method_id },
            .args = &.{},
        } },
    }};
    const bare: bodies.Bodies = .{
        .exprs = &bare_exprs,
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = bodies_store,
    };
    ctx.b = &bare;
    try std.testing.expect(knownCallReturnType(&ctx, 0, call) == null);
}

// `text.first().and_then(|&byte| Sign::try_from(byte)).map(|sign| (sign, 1))
// .unwrap_or((Sign::Plus, 0))` ends in a tuple the chain's own `unwrap_or`
// opens. `std::borrow::Cow::<str>::Owned(String::from(..))` puts a `String`
// inside a variant whose node says only which half of the `Cow` it is.
test "a Cow variant carries the half its own name says it does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const b: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{},
    };
    var generated: Gen = .{};
    defer generated.deinit(alloc);
    var ctx: Ctx = .{ .alloc = alloc, .b = &b, .g = &generated, .cg = null };
    defer ctx.deinit();

    // The turbofish names the BORROWED half, and the variant name is the only
    // thing that says the owned half of `Cow<str>` is a `String`.
    const text_owner: types.ExternalNominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{types.str_type},
    };
    const owned = cowVariantPayloadType(&ctx, text_owner, "Owned").?;
    try std.testing.expect(owned == .external_nominal);
    try std.testing.expectEqual(@as(usize, 3), owned.external_nominal.path.len);
    try std.testing.expectEqualStrings("String", owned.external_nominal.path[2]);
    const borrowed = cowVariantPayloadType(&ctx, text_owner, "Borrowed").?;
    try std.testing.expect(borrowed == .reference);
    try std.testing.expect(!borrowed.reference.mut);
    try std.testing.expectEqual(types.str_type, borrowed.reference.pointee);

    // The byte half owns differently: a `Vec<u8>` against a `&[u8]`.
    const bytes_slice = try alloc.create(types.Slice);
    bytes_slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const bytes_owner: types.ExternalNominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .slice = bytes_slice }},
    };
    const owned_bytes = cowVariantPayloadType(&ctx, bytes_owner, "Owned").?;
    try std.testing.expectEqual(@as(usize, 3), owned_bytes.external_nominal.path.len);
    try std.testing.expectEqualStrings("Vec", owned_bytes.external_nominal.path[2]);
    try std.testing.expectEqual(
        types.Type{ .prim = .u8 },
        owned_bytes.external_nominal.args[0],
    );
    const borrowed_bytes = cowVariantPayloadType(&ctx, bytes_owner, "Borrowed").?;
    try std.testing.expect(borrowed_bytes == .reference);
    try std.testing.expect(borrowed_bytes.reference.pointee == .slice);

    // A `Cow` whose borrowed half a turbofish left as `_` answers nothing at
    // all. Guessing one of the two payloads here is what would write the callee's
    // own unbound parameter into the caller's expression.
    const open_owner: types.ExternalNominal = .{
        .path = &.{ "alloc", "borrow", "Cow" },
        .args = &.{.{ .external_nominal = .{ .path = &.{"_"} } }},
    };
    try std.testing.expect(cowVariantPayloadType(&ctx, open_owner, "Owned") == null);
    try std.testing.expect(cowVariantPayloadType(&ctx, open_owner, "Borrowed") == null);
    // A nominal that is not a `Cow` is somebody else's variant entirely.
    const other: types.ExternalNominal = .{
        .path = &.{ "core", "option", "Option" },
        .args = &.{types.str_type},
    };
    try std.testing.expect(cowVariantPayloadType(&ctx, other, "Owned") == null);
    try std.testing.expect(cowVariantPayloadType(&ctx, other, "Borrowed") == null);
}

// `R: BufRead` reaches `fill_buf` through the bound alone, and
// `BufReader::new(data)` reaches `.unwrap()` only once its own record is the
// `Result` the `std::io::Result` alias names. Both are the records a dispatch
// reads, not the arms this module can read off them.
test "a buffered reader result normalizes its own record to the aliased Result" {
    const alloc = std.testing.allocator;
    const reader: types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "BufReader", .id = @as(?spine.EntityId, 50) },
        .{ .name = "R", .id = null },
    } } };
    const io_result_ty: types.Type = .{ .external_nominal = .{
        .path = &.{ "std", "io", "Result" },
        .args = &.{reader},
    } };
    const types_store = [_]types.Type{
        reader,
        io_result_ty,
        .{ .path = .{ .segments = &.{.{ .name = "the_reader", .id = null }} } },
    };
    // `EntityId` is a dense index into the symbol table, so the method the call
    // names is the id `add` hands back — not a number this fixture picks.
    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const owner_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "bufread"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const unwrap_entity = try graph_store.symbol_table.add(.{
        .id = 1,
        .kind = .method_ref,
        .name = try alloc.dupe(u8, "unwrap"),
        .span = test_span,
        .visibility = .public,
        .parent = owner_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    std.debug.assert(unwrap_entity == 1);
    const exprs_store = [_]exprs.Expr{
        // 0 = `BufReader::new(data)`, spelled the alias way.
        .{
            .id = 0,
            .span = test_span,
            .ty = 1,
            .kind = .{ .call = .{ .call_kind = .{ .associated = 60 }, .args = &.{} } },
        },
        // 1 = `the_reader` — the binding that call initialises.
        .{ .id = 1, .span = test_span, .ty = null, .kind = .{ .path = .{ .def = 70, .generic_args = &.{} } } },
        // 2 = `.unwrap()`.
        .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .method_call = .{
                .receiver = 1,
                .receiver_mode = .shared,
                .method = unwrap_entity,
                .args = &.{},
            } },
        },
    };
    const bodies_store = [_]bodies.BodyKind{.{
        .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0 },
    }};
    const b: bodies.Bodies = .{
        .exprs = &exprs_store,
        .stmts = &.{},
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
        .current_fn = owner_id,
    };
    defer ctx.deinit();

    // The receiver is the binding, not the call, so the binding is what has to
    // carry the alias — and the alias is what has to become the `Result`.
    try ctx.local_types.put(alloc, 70, io_result_ty);
    try walkExpr(&ctx, 2, 0);

    try std.testing.expectEqual(reader, getKnownType(&ctx, 2).?);

    // The receiver's OWN record is what the dispatch reads, so that record is
    // what this asserts: the alias became the `Result`, carrying the reader as
    // its `Ok` arm.
    const record = getKnownType(&ctx, 1) orelse return error.ReceiverRecordWentMissing;
    const normalized = switch (record) {
        .result => |result| result,
        else => return error.ReceiverRecordIsNotTheAliasedResult,
    };
    defer alloc.destroy(@constCast(normalized));
    try std.testing.expectEqual(reader, normalized.ok);
    // ONE error identity: the very `std::io::Error` the fallible I/O methods
    // produce, not a second spelling of it.
    try std.testing.expectEqual(std_io_error_type, normalized.err);
}

// The whole chain as the frontend actually runs it — `genWithGraph`,
// `materializeDerivedTypes`, `solveWithGen`, `solved.apply`, then the resolver —
// over the real shape of the source atoi writes:
//
//     let (sign, offset) = text
//         .first()
//         .and_then(|&byte| Sign::try_from(byte))
//         .map(|sign| (sign, 1))
//         .unwrap_or((Sign::Plus, 0));
//
// The boundary that matters is the one a consumer sees: every node AND every
// pattern carries a concrete type, nothing is left `unsupported`, the `&byte`
// the closure destructures is the `&u8` `first` lent out of the slice, the
// offset in the tuple is a `usize`, and `Sign::try_from(byte)` is the
// `Option<Sign>` that makes `and_then` an `Option<Sign>` rather than a hole.
test "the first and and_then and map and unwrap_or chain types end to end" {
    // The option and tuple payloads and the table built from them stay live for
    // every read below, and resolution may intern further types into a table of
    // its own. One arena owns all of it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const byte_slice: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const borrowed_byte: types.Ref = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    // The pattern row holds the whole `&u8`, so the value every assertion
    // below compares against is the reference type and not the `types.Ref`
    // payload it points at. One canonical spelling serves the fixture's own
    // table rows too, so no assertion reads a half of what it is checking.
    const borrowed_byte_ty: types.Type = .{ .reference = &borrowed_byte };
    const sign: types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "Sign", .id = @as(?spine.EntityId, 40) },
    } } };

    const first_inner = try alloc.create(types.Type);
    first_inner.* = borrowed_byte_ty;
    const first_ty: types.Type = .{ .option = first_inner };

    const sign_option = try alloc.create(types.Type);
    sign_option.* = sign;
    const sign_option_ty: types.Type = .{ .option = sign_option };

    // `(sign, 1)` — the tuple the `map` closure builds.
    const pair = try alloc.alloc(types.Type, 2);
    pair[0] = sign;
    pair[1] = .{ .prim = .usize };
    const pair_ty: types.Type = .{ .tuple = pair };

    const pair_option = try alloc.create(types.Type);
    pair_option.* = .{ .tuple = pair };
    const pair_option_ty: types.Type = .{ .option = pair_option };

    const text_ref: types.Ref = .{ .mut = false, .pointee = .{ .slice = &byte_slice } };
    const text_ty: types.Type = .{ .reference = &text_ref };

    const types_store = try alloc.alloc(types.Type, 9);
    types_store[0] = text_ty;
    types_store[1] = first_ty;
    types_store[2] = sign;
    types_store[3] = sign_option_ty;
    types_store[4] = pair_ty;
    types_store[5] = pair_option_ty;
    types_store[6] = .{ .prim = .u8 };
    types_store[7] = .{ .prim = .usize };
    types_store[8] = borrowed_byte_ty;

    // 0 `text`  1 `.first()`  2 `| &byte | ..`  3 `&byte` pattern  4 `byte`
    // 5 `Sign::try_from(byte)`  6 `| sign | ..`  7 `(sign, 1)`  8 `.and_then`
    // 9 `.map`  10 `(Sign::Plus, 0)`  11 `.unwrap_or`  12 the tuple pattern
    const exprs_store = [_]exprs.Expr{
        .{ .id = 0, .span = test_span, .ty = 0, .kind = .{ .path = .{ .def = 20, .generic_args = &.{} } } },
        .{
            .id = 1,
            .span = test_span,
            .ty = null,
            .kind = .{ .method_call = .{ .receiver = 0, .receiver_mode = .shared, .method = 2, .args = &.{} } },
        },
        .{
            .id = 2,
            .span = test_span,
            .ty = null,
            .kind = .{ .closure = .{
                .captures = &.{},
                .params = &.{0},
                .return_ty = null,
                .body = .{ .statements = &.{}, .tail = 4, .labelled = null },
                .trait = .@"fn",
            } },
        },
        .{ .id = 3, .span = test_span, .ty = null, .kind = .{ .path = .{ .def = 21, .generic_args = &.{} } } },
        .{
            .id = 4,
            .span = test_span,
            .ty = null,
            .kind = .{ .call = .{ .call_kind = .{ .associated = 1 }, .args = &.{3} } },
        },
        .{
            .id = 5,
            .span = test_span,
            .ty = null,
            .kind = .{ .closure = .{
                .captures = &.{},
                .params = &.{2},
                .return_ty = null,
                .body = .{ .statements = &.{}, .tail = 6, .labelled = null },
                .trait = .@"fn",
            } },
        },
        .{
            .id = 6,
            .span = test_span,
            .ty = 4,
            .kind = .{ .array = .{ .elements = &.{ 23, 25 }, .repeat = null } },
        },
        .{
            .id = 7,
            .span = test_span,
            .ty = null,
            .kind = .{ .method_call = .{ .receiver = 1, .receiver_mode = .shared, .method = 3, .args = &.{2} } },
        },
        .{
            .id = 8,
            .span = test_span,
            .ty = null,
            .kind = .{ .method_call = .{ .receiver = 7, .receiver_mode = .shared, .method = 4, .args = &.{5} } },
        },
        .{
            .id = 9,
            .span = test_span,
            .ty = 4,
            .kind = .{ .array = .{ .elements = &.{ 6, 25 }, .repeat = null } },
        },
        .{
            .id = 10,
            .span = test_span,
            .ty = null,
            .kind = .{ .method_call = .{ .receiver = 8, .receiver_mode = .shared, .method = 5, .args = &.{9} } },
        },
        // 11 = the block the `let` sits in: its one statement destructures the chain.
        .{ .id = 11, .span = test_span, .ty = null, .kind = .{ .block = .{
            .statements = &.{0},
            .tail = null,
            .labelled = null,
        } } },
    };
    const pats_store = [_]exprs.Pattern{
        // 0 = the `&byte` the `and_then` closure destructures.
        .{
            .id = 0,
            .span = test_span,
            .ty = 8,
            .kind = .{ .reference = .{ .mode = .shared_ref, .inner = 1 } },
        },
        .{
            .id = 1,
            .span = test_span,
            .ty = 8,
            .kind = .{ .binding = .{ .name = "byte", .mode = .{ .value = {} }, .mutable = false } },
        },
        // 2 = the `sign` the `map` closure names.
        .{
            .id = 2,
            .span = test_span,
            .ty = 2,
            .kind = .{ .binding = .{ .name = "sign", .mode = .{ .value = {} }, .mutable = false } },
        },
        // 3 = the tuple the `let` destructures: `Sign::Plus` and the offset.
        .{ .id = 3, .span = test_span, .ty = null, .kind = .{ .tuple = .{ .elements = &.{ 4, 5 }, .rest = false } } },
        .{
            .id = 4,
            .span = test_span,
            .ty = 2,
            .kind = .{ .binding = .{ .name = "sign", .mode = .{ .value = {} }, .mutable = false } },
        },
        .{
            .id = 5,
            .span = test_span,
            .ty = 7,
            .kind = .{ .binding = .{ .name = "offset", .mode = .{ .value = {} }, .mutable = false } },
        },
    };
    // `let (sign, offset) = <chain>;` — the destructuring that gives the two
    // bindings their types, which is the only thing that binds the tuple
    // pattern at all.
    const stmts_store = [_]exprs.Statement{.{
        .id = 0,
        .span = test_span,
        .ty = null,
        .kind = .{ .let = .{ .pattern = 3, .init = 10, .ty = null } },
    }};
    const bodies_store = [_]bodies.BodyKind{
        .{
            .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = .unit },
                // The fn body is the block holding the `let`; walking it
                // reaches the chain, both closures and both patterns.
                .body = 11,
                .generics = null,
            },
        },
        .{
            .fn_ = .{
                // `fn try_from(byte: u8) -> Option<Sign>` — the call the
                // `and_then` closure's return type comes from.
                .params = &.{},
                .ret = sign_option_ty,
                .body = 0,
                .generics = null,
            },
        },
    };

    var graph_store = graph.CrateGraph.init(alloc);
    defer graph_store.deinit();
    const owner_id = try graph_store.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "from_radix_10_signed_checked"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    // `EntityId` is a dense index into the symbol table, and a body row is
    // indexed by the entity that declares it — so `Sign::try_from` is declared
    // FIRST, and it is that entity the `.call` above names. The four chain
    // methods follow it, and the leaves the tuples name follow those.
    const try_from_entity = try graph_store.symbol_table.add(.{
        .id = 1,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "try_from"),
        .span = test_span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    std.debug.assert(try_from_entity == 1);
    for ([_][]const u8{ "first", "and_then", "map", "unwrap_or" }, 0..) |name, offset| {
        const method_entity = try graph_store.symbol_table.add(.{
            .id = @intCast(2 + offset),
            .kind = .method_ref,
            .name = try alloc.dupe(u8, name),
            .span = test_span,
            .visibility = .public,
            .parent = owner_id,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        std.debug.assert(method_entity == @as(exprs.DefId, @intCast(2 + offset)));
    }
    // The three leaves the tuples name: `sign` (the closure's parameter),
    // `Sign::Plus`, and the integer literal `1` / `0` that is the offset.
    for (0..3) |offset| {
        const leaf_entity = try graph_store.symbol_table.add(.{
            .id = @intCast(6 + offset),
            .kind = .fn_,
            .name = try alloc.dupe(u8, "leaf"),
            .span = test_span,
            .visibility = .public,
            .parent = owner_id,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        std.debug.assert(leaf_entity == @as(exprs.DefId, @intCast(6 + offset)));
    }

    // `Inferred.apply` writes the solved ids, so the table it writes is a
    // mutable copy of the fixture's expressions. The type table itself is only
    // BORROWED: resolution appends by rebinding `b.types` to a table it owns, so
    // this body — and no second local handle — is what the assertions below read
    // types through.
    var exprs_mut: [exprs_store.len]exprs.Expr = exprs_store;
    var pats_mut: [pats_store.len]exprs.Pattern = pats_store;
    var mutable_b: bodies.Bodies = .{
        .exprs = &exprs_mut,
        .stmts = &stmts_store,
        .pats = &pats_mut,
        .types = types_store,
        .bodies = &bodies_store,
    };

    // The derived channel is where a PATTERN's type travels, and it is
    // materialized between generating and solving — `solveWithGraph` folds
    // those two steps together and never runs it, so this spells the pass out
    // the way the header describes rather than reaching for the wrapper.
    var type_list: std.ArrayListUnmanaged(types.Type) = .empty;
    defer type_list.deinit(alloc);
    try type_list.appendSlice(alloc, types_store);
    var generated = try genWithGraph(alloc, &mutable_b, &graph_store);
    defer generated.deinit(alloc);
    try materializeDerivedTypes(alloc, &type_list, @constCast(mutable_b.pats), &generated);
    mutable_b.types = type_list.items;
    var inferred = try solveWithGen(alloc, &mutable_b, &generated);
    defer inferred.deinit(alloc);
    inferred.apply(&exprs_mut);
    _ = try resolve_methods.resolveMethods(&graph_store, &mutable_b);

    // The chain's own nodes carry the arm the next one reads. The rows are
    // addressed by POSITION: the fixture's table has no `.id = 3` row (the
    // numbering it comments on counts the `&byte` PATTERN), so every node after
    // the second closure sits one below the id its own name carries.
    try std.testing.expectEqual(first_ty, mutable_b.types[mutable_b.exprs[1].ty.?]);
    try std.testing.expectEqual(sign_option_ty, mutable_b.types[mutable_b.exprs[7].ty.?]);
    try std.testing.expectEqual(pair_option_ty, mutable_b.types[mutable_b.exprs[8].ty.?]);
    try std.testing.expectEqual(pair_ty, mutable_b.types[mutable_b.exprs[10].ty.?]);

    // `Sign::try_from(byte)` is the `Option<Sign>` the closure returns. The
    // `&byte` PATTERN is the whole `&u8` it destructures, and the `byte` it
    // binds inside it is the `u8` that borrow points at — the reference is what
    // the pattern carries, not what the name it introduces carries.
    try std.testing.expectEqual(sign_option_ty, mutable_b.types[mutable_b.exprs[4].ty.?]);
    try std.testing.expectEqual(borrowed_byte_ty, mutable_b.types[mutable_b.pats[0].ty.?]);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, mutable_b.types[mutable_b.pats[1].ty.?]);

    // The tuple the `let` destructures reaches both arms: `Sign` and the
    // `usize` offset, with the fallback's own literal typed the same way.
    try std.testing.expectEqual(pair_ty, mutable_b.types[mutable_b.pats[3].ty.?]);
    try std.testing.expectEqual(sign, mutable_b.types[mutable_b.pats[4].ty.?]);
    try std.testing.expectEqual(types.Type{ .prim = .usize }, mutable_b.types[mutable_b.pats[5].ty.?]);

    // Nothing in the chain is left standing for something no rule named.
    for (mutable_b.exprs) |e| {
        if (e.ty) |id| {
            try std.testing.expect(mutable_b.types[id] != .unsupported);
        }
    }
    for (mutable_b.pats) |p| {
        if (p.ty) |id| {
            try std.testing.expect(mutable_b.types[id] != .unsupported);
        }
    }
}
