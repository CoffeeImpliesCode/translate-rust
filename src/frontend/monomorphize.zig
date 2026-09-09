//! translate_rust.model.monomorphize — generic instantiation collection & suffix mangling.
//! See notes/design/data-model/items-types.md §3 (Generics & monomorphization).
//!
//! P5: walks the bodies' expression/type graphs and the crate-graph item
//! signatures, deduplicates every concrete `Instantiation` of a generic
//! entity into an `InstantiationTable`, and derives a deterministic Zig-safe
//! name suffix (e.g. `_u32`, `_u8_slice`, `_bool`) for each so the emitter
//! can produce distinct monomorphized rustons (never duplicate symbols).
//!
//! C-free, pure Zig: imports only graph, bodies, types, spine. 0 dynamic
//! allocations on hot paths (compares & mangles inline; only suffix buffers
//! allocate).

const std = @import("std");

const ir = @import("translate_rust.ir");
const spine = ir.spine;
const types = ir.types;
const graph = ir.graph;
const bodies = ir.bodies;
const exprs = ir.exprs;

// ── §1 Deep structural equality ─────────────────────────────────────────────

/// Structural equality of two `types.Type` values. Paths retain every segment
/// and resolution id so associated projections from distinct generic roots do
/// not collapse into the same instantiation.
pub fn typeEquals(a: types.Type, b: types.Type) bool {
    return switch (a) {
        .path => |ap| switch (b) {
            .path => |bp| pathEquals(ap, bp),
            else => false,
        },
        .external_nominal => |ae| switch (b) {
            .external_nominal => |be| {
                if (ae.path.len != be.path.len or ae.args.len != be.args.len) return false;
                for (ae.path, be.path) |left, right| {
                    if (!std.mem.eql(u8, left, right)) return false;
                }
                return typesSliceEqual(ae.args, be.args);
            },
            else => false,
        },
        .prim => |ap| switch (b) {
            .prim => |bp| ap == bp,
            else => false,
        },
        .reference => |ap| switch (b) {
            .reference => |bp| ap.mut == bp.mut and typeEquals(ap.pointee, bp.pointee),
            else => false,
        },
        .raw_ptr => |ap| switch (b) {
            .raw_ptr => |bp| ap.mut == bp.mut and typeEquals(ap.pointee, bp.pointee),
            else => false,
        },
        .slice => |ap| switch (b) {
            .slice => |bp| ap.const_ == bp.const_ and typeEquals(ap.elem, bp.elem),
            else => false,
        },
        .array => |ap| switch (b) {
            .array => |bp| arrayLenEquals(ap.len, bp.len) and typeEquals(ap.elem, bp.elem),
            else => false,
        },
        .tuple => |ap| switch (b) {
            .tuple => |bp| slicesEqual(types.Type, typeEquals, ap, bp),
            else => false,
        },
        .fn_ptr => |ap| switch (b) {
            .fn_ptr => |bp| slicesEqual(types.Type, typeEquals, ap.params, bp.params) and typeEquals(ap.ret, bp.ret),
            else => false,
        },
        .generic_inst => |ap| switch (b) {
            .generic_inst => |bp| ap.decl == bp.decl and genericArgsEquals(ap.args, bp.args),
            else => false,
        },
        .option => |ap| switch (b) {
            .option => |bp| typeEquals(ap.*, bp.*),
            else => false,
        },
        .result => |ap| switch (b) {
            .result => |bp| ap.is_error_unionable == bp.is_error_unionable and typeEquals(ap.ok, bp.ok) and typeEquals(ap.err, bp.err),
            else => false,
        },
        .boxed => |ap| switch (b) {
            .boxed => |bp| typeEquals(ap.*, bp.*),
            else => false,
        },
        .@"opaque" => |left| if (b == .@"opaque") opaqueEquals(left, b.@"opaque") else false,
        .dyn_trait => |left| if (b == .dyn_trait) boundsEqual(left, b.dyn_trait) else false,
        .unsupported => |ap| switch (b) {
            .unsupported => |bp| ap.reason == bp.reason and std.mem.eql(u8, ap.message, bp.message),
            else => false,
        },
    };
}

fn pathEquals(a: types.Path, b: types.Path) bool {
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.id != right.id) return false;
    }
    return true;
}

fn opaqueEquals(left: types.Opaque, right: types.Opaque) bool {
    if (!boundsEqual(left.bounds, right.bounds)) return false;
    const concrete = left.concrete orelse return right.concrete == null;
    return typeEquals(concrete.*, (right.concrete orelse return false).*);
}

fn boundsEqual(left: []const types.Bound, right: []const types.Bound) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.optional != b.optional or !pathEquals(a.path, b.path)) return false;
        if (!typesSliceEqual(a.args, b.args)) return false;
        if (a.associated_types.len != b.associated_types.len) return false;
        for (a.associated_types, b.associated_types) |a_binding, b_binding| {
            if (!std.mem.eql(u8, a_binding.name, b_binding.name)) return false;
            if (!typeEquals(a_binding.ty, b_binding.ty)) return false;
        }
    }
    return true;
}

fn arrayLenEquals(a: types.ArrayLen, b: types.ArrayLen) bool {
    return switch (a) {
        .literal => |av| switch (b) {
            .literal => |bv| av == bv,
            else => false,
        },
        .generic => |av| switch (b) {
            .generic => |bv| av == bv,
            else => false,
        },
        .expression => |av| switch (b) {
            .expression => |bv| av == bv,
            else => false,
        },
    };
}

fn slicesEqual(comptime T: type, comptime eq: fn (T, T) bool, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |av, i| {
        if (!eq(av, b[i])) return false;
    }
    return true;
}

fn typesSliceEqual(a: []const types.Type, b: []const types.Type) bool {
    return slicesEqual(types.Type, typeEquals, a, b);
}

pub fn genericArgsEquals(a: types.GenericArgs, b: types.GenericArgs) bool {
    return typesSliceEqual(a.params, b.params);
}

// ── §2 Name suffix mangling ─────────────────────────────────────────────────

// Zig identifier-safe character predicate: keep [A-Za-z0-9_], map everything
// else to `_` and squash runs so the suffix is always a valid identifier.
fn sanitizeChar(c: u8, out: *std.ArrayListUnmanaged(u8)) void {
    const ok = (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
    if (ok) {
        out.appendAssumeCapacity(c);
    } else {
        out.appendAssumeCapacity('_');
    }
}

fn hasValidTypeTag(ty: types.Type) bool {
    const union_info = @typeInfo(types.Type).@"union";
    const tag = blk: {
        @setRuntimeSafety(false);
        break :blk std.meta.activeTag(ty);
    };
    return @intFromEnum(tag) < union_info.fields.len;
}

fn appendMangled(alloc: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), ty: types.Type) std.mem.Allocator.Error!void {
    if (!hasValidTypeTag(ty)) {
        try w.appendSlice(alloc, "unsupported");
        return;
    }
    switch (ty) {
        .path => |p| try appendMangledPath(alloc, w, p),
        .external_nominal => |external| {
            try w.appendSlice(alloc, "ext");
            for (external.path) |segment| {
                try w.append(alloc, '_');
                try appendMangledName(alloc, w, segment);
            }
            for (external.args) |arg| {
                try w.append(alloc, '_');
                try appendMangled(alloc, w, arg);
            }
        },
        .prim => |p| try w.appendSlice(alloc, @tagName(p)),
        .reference => |r| {
            try appendMangled(alloc, w, r.pointee);
            try w.appendSlice(alloc, if (r.mut) "_mutref" else "_ref");
        },
        .raw_ptr => |r| {
            try appendMangled(alloc, w, r.pointee);
            try w.appendSlice(alloc, if (r.mut) "_mutptr" else "_ptr");
        },
        .slice => |s| {
            try appendMangled(alloc, w, s.elem);
            try w.appendSlice(alloc, if (s.const_) "_slice" else "_mut_slice");
        },
        .array => |a| {
            try appendMangled(alloc, w, a.elem);
            try w.appendSlice(alloc, "_arr_");
            switch (a.len) {
                .literal => |n| try appendInt(alloc, w, n),
                .generic => |gidx| {
                    try w.append(alloc, 'g');
                    try appendInt(alloc, w, gidx);
                },
                .expression => |id| {
                    try w.append(alloc, 'e');
                    try appendInt(alloc, w, id);
                },
            }
        },
        .tuple => |t| {
            try w.appendSlice(alloc, "t");
            for (t) |e| {
                try w.append(alloc, '_');
                try appendMangled(alloc, w, e);
            }
        },
        .fn_ptr => |f| {
            try w.appendSlice(alloc, "fnptrt");
            for (f.params) |pa| {
                try w.append(alloc, '_');
                try appendMangled(alloc, w, pa);
            }
            try w.appendSlice(alloc, "_ret_");
            try appendMangled(alloc, w, f.ret);
        },
        .generic_inst => |g| {
            var id_buf: [24]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "g{d}", .{g.decl}) catch "g0";
            try appendMangledName(alloc, w, id_str);
            for (g.args.params) |a| {
                try w.append(alloc, '_');
                try appendMangled(alloc, w, a);
            }
        },
        .option => |o| {
            try appendMangled(alloc, w, o.*);
            try w.appendSlice(alloc, "_opt");
        },
        .result => |r| {
            try w.appendSlice(alloc, "rt_");
            try appendMangled(alloc, w, r.ok);
            try w.appendSlice(alloc, "_e_");
            try appendMangled(alloc, w, r.err);
        },
        .boxed => |bx| {
            try appendMangled(alloc, w, bx.*);
            try w.appendSlice(alloc, "_box");
        },
        .@"opaque" => |opaque_type| {
            try w.appendSlice(alloc, "opaque");
            try appendMangledBounds(alloc, w, opaque_type.bounds);
            if (opaque_type.concrete) |concrete| {
                try w.appendSlice(alloc, "_concrete_");
                try appendMangled(alloc, w, concrete.*);
            }
        },
        .dyn_trait => |bounds| {
            try w.appendSlice(alloc, "dyn");
            try appendMangledBounds(alloc, w, bounds);
        },
        else => try w.appendSlice(alloc, "unsupported"),
    }
}

fn appendMangledBounds(alloc: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), bounds: []const types.Bound) std.mem.Allocator.Error!void {
    for (bounds) |bound| {
        try w.appendSlice(alloc, if (bound.optional) "_maybe_" else "_bound_");
        try appendMangledPath(alloc, w, bound.path);
        for (bound.args) |arg| {
            try w.appendSlice(alloc, "_arg_");
            try appendMangled(alloc, w, arg);
        }
        for (bound.associated_types) |binding| {
            try w.appendSlice(alloc, "_assoc_");
            try appendMangledName(alloc, w, binding.name);
            try w.append(alloc, '_');
            try appendMangled(alloc, w, binding.ty);
        }
    }
}

/// Append decimal digits of a u64 to the writer (no allocation beyond the
/// stack buffer).
fn appendInt(alloc: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), v: u64) std.mem.Allocator.Error!void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try w.appendSlice(alloc, s);
}

fn appendMangledPath(alloc: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), p: types.Path) std.mem.Allocator.Error!void {
    if (p.segments.len == 0) {
        try w.appendSlice(alloc, "unsupported");
        return;
    }
    for (p.segments, 0..) |segment, index| {
        if (index > 0) try w.append(alloc, '_');
        try appendMangledName(alloc, w, segment.name);
    }
}

fn appendMangledName(alloc: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), name: []const u8) std.mem.Allocator.Error!void {
    // Sanitize on a scratch capacity reserve so appendAssumeCapacity is safe.
    try w.ensureUnusedCapacity(alloc, name.len);
    for (name) |c| sanitizeChar(c, w);
}

/// Synthetic one-segment path for a generic_inst whose decl is an EntityId
/// (no stored name): derive the segment from the id to keep it deterministic.
fn segmentPath(id: spine.EntityId) types.Path {
    var buf: [24]u8 = undefined;
    const name = std.fmt.bufPrint(buf[0..], "g{d}", .{id}) catch buf[0..0];
    const seg: types.PathSegment = .{ .name = name, .id = id };
    return .{ .segments = &.{seg} };
}

/// Deterministic Zig-safe suffix for a generic argument list, prefixed by `_`
/// per argument (e.g. single `u32` → `_u32`, `&[u8]` → `_u8_slice`). Empty
/// args → `""`.
pub fn mangleSuffix(alloc: std.mem.Allocator, args: types.GenericArgs) ![]const u8 {
    if (args.params.len == 0) return alloc.dupe(u8, "");
    var w: std.ArrayListUnmanaged(u8) = .empty;
    defer w.deinit(alloc);
    for (args.params) |a| {
        try w.append(alloc, '_');
        try appendMangled(alloc, &w, a);
    }
    return w.toOwnedSlice(alloc);
}

// ── §3 Instantiation table ──────────────────────────────────────────────────

/// Deduplicated list of instantiation records. Owns its buffer, each concrete
/// argument slice, and each mangled suffix slice; `deinit` frees them all.
pub const InstantiationTable = struct {
    instantiations: std.ArrayListUnmanaged(types.Instantiation) = .empty,

    pub fn deinit(self: *InstantiationTable, alloc: std.mem.Allocator) void {
        for (self.instantiations.items) |inst| {
            if (inst.args.params.len > 0) alloc.free(inst.args.params);
            if (inst.zig_suffix.len > 0) alloc.free(inst.zig_suffix);
        }
        self.instantiations.deinit(alloc);
        self.* = undefined;
    }

    pub fn count(self: *const InstantiationTable) usize {
        return self.instantiations.items.len;
    }

    pub fn get(self: *const InstantiationTable, index: usize) ?types.Instantiation {
        if (index >= self.instantiations.items.len) return null;
        return self.instantiations.items[index];
    }

    /// Return the table index of an existing `(generic_id, args)` record, or
    /// create (and mangle) it if absent.
    pub fn addOrGet(
        self: *InstantiationTable,
        alloc: std.mem.Allocator,
        generic_id: spine.EntityId,
        args: types.GenericArgs,
    ) !usize {
        for (self.instantiations.items, 0..) |inst, i| {
            if (inst.generic_id == generic_id and genericArgsEquals(inst.args, args)) return i;
        }
        const owned_args = try alloc.dupe(types.Type, args.params);
        errdefer if (owned_args.len > 0) alloc.free(owned_args);
        const suffix = try mangleSuffix(alloc, args);
        errdefer if (suffix.len > 0) alloc.free(suffix);
        try self.instantiations.append(alloc, .{
            .generic_id = generic_id,
            .args = .{ .params = owned_args },
            .zig_suffix = suffix,
        });
        return self.instantiations.items.len - 1;
    }

    /// Copy every inference record into the owned table before the inference
    /// result is released. The source map is keyed by expression node, while
    /// the public table is deduplicated by declaration and concrete args.
    pub fn mergeInferred(
        self: *InstantiationTable,
        alloc: std.mem.Allocator,
        source: std.AutoHashMapUnmanaged(exprs.NodeId, types.Instantiation),
    ) !void {
        var it = source.iterator();
        while (it.next()) |entry| {
            _ = try self.addOrGet(alloc, entry.value_ptr.generic_id, entry.value_ptr.args);
        }
    }
};

// ── §4 Collection: scan bodies + crate graph ────────────────────────────────

/// Per-table "seen" bitsets. The expr / stmt / pat tables are each dense from
/// id 0, so a single shared `[]bool` would wrongly skip an expression whose id
/// collides with an already-seen statement or pattern id. Each table tracks
/// its own visited set.
const Visited = struct {
    exprs: []bool,
    stmts: []bool,
    pats: []bool,

    fn init(alloc: std.mem.Allocator, b: *const bodies.Bodies) !Visited {
        const ve = try alloc.alloc(bool, b.exprs.len);
        errdefer alloc.free(ve);
        const vs = try alloc.alloc(bool, b.stmts.len);
        errdefer alloc.free(vs);
        const vp = try alloc.alloc(bool, b.pats.len);
        errdefer alloc.free(vp);
        @memset(ve, false);
        @memset(vs, false);
        @memset(vp, false);
        return .{ .exprs = ve, .stmts = vs, .pats = vp };
    }

    fn deinit(self: *Visited, alloc: std.mem.Allocator) void {
        alloc.free(self.exprs);
        alloc.free(self.stmts);
        alloc.free(self.pats);
        self.* = undefined;
    }
};

/// A generic-instantiation record is emitted only for concrete arguments.
/// Generic declaration signatures such as `Fletcher<T>` are traversed for
/// nested types but must not become monomorphization records: their `T` path
/// is valid only in the declaration's generic scope, not as a standalone
/// instantiation argument.
fn isConcreteType(ty: types.Type) bool {
    if (!hasValidTypeTag(ty)) return false;
    return switch (ty) {
        .path => |path| blk: {
            if (path.segments.len == 0) break :blk false;
            const first = path.segments[0];
            const lexical_root = std.mem.eql(u8, first.name, "crate") or
                std.mem.eql(u8, first.name, "self") or
                std.mem.eql(u8, first.name, "super");
            if (first.id == null and !lexical_root) break :blk false;
            const terminal = path.segments[path.segments.len - 1];
            break :blk terminal.id != null;
        },
        .external_nominal => |external| blk: {
            if (external.path.len == 0) break :blk false;
            for (external.args) |arg| {
                if (!isConcreteType(arg)) break :blk false;
            }
            break :blk true;
        },
        .prim => true,
        .reference => |reference| isConcreteType(reference.pointee),
        .raw_ptr => |raw_ptr| isConcreteType(raw_ptr.pointee),
        .slice => |slice| isConcreteType(slice.elem),
        .array => |array| switch (array.len) {
            .literal => isConcreteType(array.elem),
            .generic, .expression => false,
        },
        .tuple => |tuple| blk: {
            for (tuple) |element| {
                if (!isConcreteType(element)) break :blk false;
            }
            break :blk true;
        },
        .fn_ptr => |fn_ptr| blk: {
            for (fn_ptr.params) |param| {
                if (!isConcreteType(param)) break :blk false;
            }
            break :blk isConcreteType(fn_ptr.ret);
        },
        .generic_inst => |generic| blk: {
            if (generic.decl == std.math.maxInt(spine.EntityId)) break :blk false;
            for (generic.args.params) |arg| {
                if (!isConcreteType(arg)) break :blk false;
            }
            break :blk true;
        },
        .option => |inner| isConcreteType(inner.*),
        .result => |result| isConcreteType(result.ok) and isConcreteType(result.err),
        .boxed => |inner| isConcreteType(inner.*),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete| isConcreteType(concrete.*) else false,
        .dyn_trait => |bounds| concreteBounds(bounds),
        .unsupported => false,
    };
}

fn concreteBounds(bounds: []const types.Bound) bool {
    for (bounds) |bound| {
        if (!concreteArgs(bound.args)) return false;
        for (bound.associated_types) |binding| {
            if (!isConcreteType(binding.ty)) return false;
        }
    }
    return true;
}

fn concreteArgs(args: []const types.Type) bool {
    for (args) |arg| {
        if (!isConcreteType(arg)) return false;
    }
    return true;
}

/// Determine whether a Type reachable through the model is itself a generic
/// instantiation; register it (and recurse into its nested args). Repeated
/// registration is deduplicated by `addOrGet`, so a simple recursive scan is
/// safe.
fn collectType(table: *InstantiationTable, alloc: std.mem.Allocator, ty: types.Type) std.mem.Allocator.Error!void {
    if (!hasValidTypeTag(ty)) return;
    switch (ty) {
        .generic_inst => |g| {
            // Declaration signatures can contain `Wrapper<T>`. It is not a
            // concrete instantiation until every argument has a resolved
            // nominal identity (or is otherwise structurally concrete).
            if (g.args.params.len > 0 and concreteArgs(g.args.params)) {
                _ = try table.addOrGet(alloc, g.decl, g.args);
            }
            for (g.args.params) |a| try collectType(table, alloc, a);
        },
        .external_nominal => |external| {
            for (external.args) |arg| try collectType(table, alloc, arg);
        },
        .reference => |r| try collectType(table, alloc, r.pointee),
        .raw_ptr => |r| try collectType(table, alloc, r.pointee),
        .slice => |s| try collectType(table, alloc, s.elem),
        .array => |a| try collectType(table, alloc, a.elem),
        .tuple => |t| for (t) |e| try collectType(table, alloc, e),
        .fn_ptr => |f| {
            for (f.params) |p| try collectType(table, alloc, p);
            try collectType(table, alloc, f.ret);
        },
        .option => |o| try collectType(table, alloc, o.*),
        .result => |r| {
            try collectType(table, alloc, r.ok);
            try collectType(table, alloc, r.err);
        },
        .boxed => |bx| try collectType(table, alloc, bx.*),
        .@"opaque" => |opaque_type| {
            try collectBounds(table, alloc, opaque_type.bounds);
            if (opaque_type.concrete) |concrete| try collectType(table, alloc, concrete.*);
        },
        .dyn_trait => |bounds| try collectBounds(table, alloc, bounds),
        else => {},
    }
}

fn collectBounds(table: *InstantiationTable, alloc: std.mem.Allocator, bounds: []const types.Bound) std.mem.Allocator.Error!void {
    for (bounds) |bound| {
        for (bound.args) |arg| try collectType(table, alloc, arg);
        for (bound.associated_types) |binding| try collectType(table, alloc, binding.ty);
    }
}

/// Walk every expression node exactly once (guard against DAG sharing / any
/// cycle in the flat id graph via a visited bitset), registering each node's
/// resolved `ty` from the type table and any inline generic arguments on path
/// expressions.
fn collectExpr(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    id: exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (id >= b.exprs.len or v.exprs[id]) return;
    v.exprs[id] = true;
    const e = b.exprs[id];
    if (e.ty) |tyid| {
        if (tyid < b.types.len) try collectType(table, alloc, b.types[tyid]);
    }
    switch (e.kind) {
        .path => |p| {
            if (p.generic_args.len > 0 and concreteArgs(p.generic_args)) {
                _ = try table.addOrGet(alloc, p.def, .{ .params = p.generic_args });
            }
            for (p.generic_args) |a| try collectType(table, alloc, a);
        },
        .block => |blk| {
            for (blk.statements) |sid| try collectStmt(table, alloc, b, v, sid);
            if (blk.tail) |t| try collectExpr(table, alloc, b, v, t);
        },
        .if_else => |ie| {
            try collectExpr(table, alloc, b, v, ie.cond);
            try collectBlock(table, alloc, b, v, ie.then_);
            try collectElse(table, alloc, b, v, ie.@"else");
        },
        .if_let => |il| {
            try collectPat(table, alloc, b, v, il.pattern);
            try collectExpr(table, alloc, b, v, il.scrutinee);
            try collectBlock(table, alloc, b, v, il.then_);
            try collectElse(table, alloc, b, v, il.@"else");
        },
        .match => |m| {
            try collectExpr(table, alloc, b, v, m.scrutinee);
            for (m.arms) |arm| {
                for (arm.patterns) |pid| try collectPat(table, alloc, b, v, pid);
                if (arm.guard) |g| try collectExpr(table, alloc, b, v, g);
                try collectExpr(table, alloc, b, v, arm.body);
            }
        },
        .loop_ => |l| try collectBlock(table, alloc, b, v, l.body),
        .while_ => |wh| {
            try collectExpr(table, alloc, b, v, wh.cond);
            if (wh.capture) |cap_id| try collectPat(table, alloc, b, v, cap_id);
            try collectBlock(table, alloc, b, v, wh.body);
        },
        .for_ => |f| {
            try collectPat(table, alloc, b, v, f.pattern);
            try collectExpr(table, alloc, b, v, f.iterable);
            try collectBlock(table, alloc, b, v, f.body);
            switch (f.iter_kind) {
                .range, .slice, .enumerate => {},
                .multi => |ids| for (ids) |m| try collectExpr(table, alloc, b, v, m),
                .adapter => |ad| try collectIteratorAdapter(table, alloc, b, v, ad),
            }
        },
        .break_ => |br| if (br.value) |bval| try collectExpr(table, alloc, b, v, bval),
        .continue_, .literal, .unit, .panic_, .unsupported => {},
        .array => |a| for (a.elements) |el| try collectExpr(table, alloc, b, v, el),
        .vec_lit => |vec| for (vec.elements) |el| try collectExpr(table, alloc, b, v, el),
        .range => |range| {
            try collectExpr(table, alloc, b, v, range.start);
            if (range.end) |end| try collectExpr(table, alloc, b, v, end);
        },
        .call => |c| for (c.args) |a| try collectExpr(table, alloc, b, v, a),
        .method_call => |mc| {
            try collectExpr(table, alloc, b, v, mc.receiver);
            for (mc.args) |a| try collectExpr(table, alloc, b, v, a);
        },
        .struct_lit => |sl| {
            for (sl.fields) |fld| try collectExpr(table, alloc, b, v, fld.value);
            if (sl.base) |base| try collectExpr(table, alloc, b, v, base);
        },
        .enum_variant => |ev| {
            for (ev.tuple_fields) |tf| try collectExpr(table, alloc, b, v, tf);
            for (ev.named_fields) |nf| try collectExpr(table, alloc, b, v, nf.value);
        },
        .external_variant => |variant| {
            for (variant.tuple_fields) |field| try collectExpr(table, alloc, b, v, field);
            for (variant.named_fields) |field| try collectExpr(table, alloc, b, v, field.value);
        },
        .core_function => {},
        .core_call => |call| {
            for (call.args) |arg| try collectExpr(table, alloc, b, v, arg);
        },
        .format_write => |format_write| {
            try collectExpr(table, alloc, b, v, format_write.writer);
            for (format_write.args) |arg| {
                try collectExpr(table, alloc, b, v, arg);
            }
        },
        .field => |f| try collectExpr(table, alloc, b, v, f.base),
        .index => |ix| {
            try collectExpr(table, alloc, b, v, ix.base);
            try collectExpr(table, alloc, b, v, ix.index);
        },
        .cast => |cast| try collectExpr(table, alloc, b, v, cast.operand),
        .binary => |bin| {
            try collectExpr(table, alloc, b, v, bin.lhs);
            try collectExpr(table, alloc, b, v, bin.rhs);
        },
        .unary => |u| try collectExpr(table, alloc, b, v, u.operand),
        .assign => |asg| {
            try collectExpr(table, alloc, b, v, asg.target);
            try collectExpr(table, alloc, b, v, asg.value);
        },
        .try_ => |t| try collectExpr(table, alloc, b, v, t.inner),
        .return_ => |r| if (r.value) |rval| try collectExpr(table, alloc, b, v, rval),
        .closure => |cl| {
            for (cl.params) |pid| try collectPat(table, alloc, b, v, pid);
            if (cl.return_ty) |rt| {
                // return_ty is a TypeRef (bare type, not table index) — embed
                // it directly when present. It is carried inline in the model.
                _ = rt;
            }
            try collectBlock(table, alloc, b, v, cl.body);
        },
        .iterator_chain => |ic| {
            try collectExpr(table, alloc, b, v, ic.source);
            for (ic.adapters) |ad| try collectIterator(table, alloc, b, v, ad);
        },
    }
}

fn collectBlock(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    blk: exprs.BlockExpr,
) std.mem.Allocator.Error!void {
    for (blk.statements) |sid| try collectStmt(table, alloc, b, v, sid);
    if (blk.tail) |t| try collectExpr(table, alloc, b, v, t);
}

fn collectElse(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    br: exprs.ElseBranch,
) std.mem.Allocator.Error!void {
    switch (br) {
        .none => {},
        .block => |blk| try collectBlock(table, alloc, b, v, blk),
        .chain => |ch| try collectExpr(table, alloc, b, v, ch),
    }
}

fn collectStmt(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    id: exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (id >= b.stmts.len or v.stmts[id]) return;
    v.stmts[id] = true;
    const s = b.stmts[id];
    if (s.ty) |tyid| {
        if (tyid < b.types.len) try collectType(table, alloc, b.types[tyid]);
    }
    switch (s.kind) {
        .let => |ls| {
            try collectPat(table, alloc, b, v, ls.pattern);
            if (ls.init) |i| try collectExpr(table, alloc, b, v, i);
        },
        .let_else => |le| {
            try collectPat(table, alloc, b, v, le.pattern);
            try collectExpr(table, alloc, b, v, le.init);
            try collectBlock(table, alloc, b, v, le.else_block);
        },
        .expr => |e| try collectExpr(table, alloc, b, v, e),
        .item => {},
    }
}

fn collectPat(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    id: exprs.NodeId,
) std.mem.Allocator.Error!void {
    if (id >= b.pats.len or v.pats[id]) return;
    v.pats[id] = true;
    const p = b.pats[id];
    if (p.kind == .unsupported) return;
    if (p.ty) |tyid| {
        if (tyid < b.types.len) try collectType(table, alloc, b.types[tyid]);
    }
    switch (p.kind) {
        .wildcard, .literal => {},
        .binding => {},
        .path => {},
        .external_variant => |variant| for (variant.fields) |field| {
            if (field.pat) |pattern| try collectPat(table, alloc, b, v, pattern);
        },
        .tuple => |t| for (t.elements) |e| try collectPat(table, alloc, b, v, e),
        .slice => |s| {
            for (s.elements) |e| try collectPat(table, alloc, b, v, e);
            if (s.rest) |r| try collectPat(table, alloc, b, v, r);
        },
        .struct_pat => |sp| for (sp.fields) |fld| if (fld.pat) |fp| try collectPat(table, alloc, b, v, fp),
        .reference => |r| try collectPat(table, alloc, b, v, r.inner),
        .@"or" => |o| for (o.alternatives) |alt| try collectPat(table, alloc, b, v, alt),
        .unsupported => {},
        .range => {},
    }
}

fn collectIteratorAdapter(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    ad: exprs.IteratorChainExpr,
) std.mem.Allocator.Error!void {
    try collectExpr(table, alloc, b, v, ad.source);
    for (ad.adapters) |a| try collectIterator(table, alloc, b, v, a);
}

fn collectIterator(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    ad: exprs.IteratorAdapter,
) std.mem.Allocator.Error!void {
    switch (ad) {
        .map => |m| try collectClosure(table, alloc, b, v, m.closure),
        .filter => |f| try collectClosure(table, alloc, b, v, f.closure),
        .flat_map => |closure| try collectClosure(table, alloc, b, v, closure),
        .enumerate, .range_rev, .other => {},
        .zip => |z| try collectExpr(table, alloc, b, v, z.other),
    }
}

fn collectClosure(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    cl: exprs.ClosureExpr,
) std.mem.Allocator.Error!void {
    for (cl.params) |pid| try collectPat(table, alloc, b, v, pid);
    try collectBlock(table, alloc, b, v, cl.body);
}

/// Collect only declaration-signature types. This pass is separate from body
/// traversal so graph entities with no lowered body still contribute their
/// generic field/parameter/alias instantiations.
fn collectSignatureKind(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    kind: bodies.BodyKind,
) std.mem.Allocator.Error!void {
    switch (kind) {
        .none => {},
        .trait_ => |trait_body| {
            for (trait_body.methods) |method| {
                for (method.params) |param| try collectType(table, alloc, param.ty);
                try collectType(table, alloc, method.ret);
            }
            for (trait_body.assoc_types) |assoc| {
                if (assoc.default) |default| try collectType(table, alloc, default);
            }
            for (trait_body.assoc_consts) |assoc| try collectType(table, alloc, assoc.ty);
        },
        .impl_ => |impl_body| {
            try collectType(table, alloc, impl_body.self_ty);
            if (impl_body.generics) |generics| {
                for (generics.params) |param| {
                    switch (param) {
                        .const_ => |constant| try collectType(table, alloc, constant.ty),
                        else => {},
                    }
                }
            }
        },
        .const_ => |constant| try collectType(table, alloc, constant.ty),
        .fn_ => |function| {
            for (function.params) |param| try collectType(table, alloc, param.ty);
            try collectType(table, alloc, function.ret);
        },
        .struct_ => |structure| {
            for (structure.fields) |field| try collectType(table, alloc, field.ty);
            for (structure.methods) |method| {
                for (method.params) |param| try collectType(table, alloc, param.ty);
                try collectType(table, alloc, method.ret);
            }
        },
        .enum_ => |enumeration| {
            for (enumeration.variants) |variant| {
                switch (variant.fields) {
                    .none => {},
                    .tuple => |fields| for (fields) |field| try collectType(table, alloc, field),
                    .named => |fields| for (fields) |field| try collectType(table, alloc, field.ty),
                }
            }
        },
        .type_alias => |alias| try collectType(table, alloc, alias.target),
    }
}

/// Collect every instantiation reachable from a single EntityBody (fn body
/// block, const init) plus the entity's param/ret signature types.
fn collectBodyKind(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    kind: bodies.BodyKind,
) std.mem.Allocator.Error!void {
    try collectSignatureKind(table, alloc, kind);
    switch (kind) {
        .none, .enum_, .trait_, .impl_, .type_alias => {},
        .struct_ => {},
        .const_ => |c| try collectExpr(table, alloc, b, v, c.init),
        .fn_ => |f| try collectExpr(table, alloc, b, v, f.body),
    }
}

/// Scan graph-backed declaration signatures as a second guard for sparse body
/// tables. `BodyKind` is keyed by the same dense EntityId as the graph.
fn collectItemTypes(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
) std.mem.Allocator.Error!void {
    for (g.symbol_table.entities.items) |entity| {
        if (entity.id < b.bodies.len) {
            try collectSignatureKind(table, alloc, b.bodies[entity.id]);
        }
    }
}

/// Main entry: build a deduplicated instantiation table from all bodies and
/// crate-graph item signatures reachable from `g` / `b`.
pub fn collectInstantiations(
    alloc: std.mem.Allocator,
    g: *const graph.CrateGraph,
    b: *const bodies.Bodies,
) !InstantiationTable {
    var table: InstantiationTable = .{};
    errdefer table.deinit(alloc);

    if (b.bodies.len > 0) {
        var v = try Visited.init(alloc, b);
        defer v.deinit(alloc);

        for (b.bodies) |kind| try collectBodyKind(&table, alloc, b, &v, kind);
    }

    try collectItemTypes(&table, alloc, g, b);
    return table;
}

// ── §5 Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn primType(p: types.Prim) types.Type {
    return .{ .prim = p };
}

fn genericOf(decl: spine.EntityId, params: []const types.Type) types.Type {
    return .{ .generic_inst = .{ .decl = decl, .args = .{ .params = params } } };
}

test "mangleSuffix — primitives, slices, multiple args, empty" {
    const a = testing.allocator;

    const s1 = try mangleSuffix(a, .{ .params = &.{primType(.u32)} });
    defer a.free(s1);
    try testing.expectEqualStrings("_u32", s1);

    var s_slice: types.Slice = .{ .const_ = true, .elem = primType(.u8) };
    const s2 = try mangleSuffix(a, .{ .params = &.{.{ .slice = &s_slice }} });
    defer a.free(s2);
    try testing.expectEqualStrings("_u8_slice", s2);

    const s3 = try mangleSuffix(a, .{ .params = &.{ primType(.bool), primType(.u8) } });
    defer a.free(s3);
    try testing.expectEqualStrings("_bool_u8", s3);

    const s4 = try mangleSuffix(a, .{ .params = &.{} });
    defer a.free(s4);
    try testing.expectEqualStrings("", s4);
}

test "typeEquals and mangleSuffix retain complete associated paths" {
    const a = testing.allocator;
    const t_input: types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "T", .id = null },
        .{ .name = "InputType", .id = null },
    } } };
    const u_input: types.Type = .{ .path = .{ .segments = &.{
        .{ .name = "U", .id = null },
        .{ .name = "InputType", .id = null },
    } } };

    try testing.expect(!typeEquals(t_input, u_input));
    const suffix = try mangleSuffix(a, .{ .params = &.{t_input} });
    defer a.free(suffix);
    try testing.expectEqualStrings("_T_InputType", suffix);
}

test "InstantiationTable.addOrGet — dedup by id+args, distinct suffix" {
    const a = testing.allocator;
    var t: InstantiationTable = .{};
    defer t.deinit(a);

    const idx1 = try t.addOrGet(a, 10, .{ .params = &.{primType(.u32)} });
    const idx1b = try t.addOrGet(a, 10, .{ .params = &.{primType(.u32)} });
    const idx2 = try t.addOrGet(a, 10, .{ .params = &.{primType(.u8)} });
    const idx3 = try t.addOrGet(a, 11, .{ .params = &.{primType(.u32)} });

    try testing.expectEqual(idx1, idx1b); // duplicate returns same index
    try testing.expectEqual(@as(usize, 3), t.count());
    try testing.expect(idx1 != idx2);
    try testing.expect(idx2 != idx3);

    const inst1 = (t.get(idx1) orelse unreachable);
    const inst2 = (t.get(idx2) orelse unreachable);
    try testing.expectEqualStrings("_u32", inst1.zig_suffix);
    try testing.expectEqualStrings("_u8", inst2.zig_suffix);
    try testing.expectEqual(@as(spine.EntityId, 10), inst1.generic_id);
}

test "collectInstantiations — discovers generics from fn body exprs & types" {
    const a = testing.allocator;

    // Type table: [0] = generic_inst Foo<i32>, [1] = prim u32
    const foo_inst = genericOf(5, &.{primType(.i32)});
    const t_u32 = primType(.u32);
    const types_arr = [_]types.Type{ foo_inst, t_u32 };

    // Expr 0: object expr of type generic_inst Foo<i32> (via .ty = 0)
    const expr0: exprs.Expr = .{
        .id = 0,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .ty = 0,
        .kind = .{ .path = .{ .def = 3, .generic_args = &.{} } },
    };
    // Expr 1: block with tail expr0
    const expr1: exprs.Expr = .{
        .id = 1,
        .span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 },
        .ty = 1,
        .kind = .{ .block = .{ .statements = &.{}, .tail = 0, .labelled = null } },
    };
    const exprs_arr = [_]exprs.Expr{ expr0, expr1 };

    const bodies_kind: bodies.BodyKind = .{ .fn_ = .{
        .params = &.{},
        .ret = t_u32,
        .body = 1,
    } };
    const bodies_arr = [_]bodies.BodyKind{bodies_kind};

    const bb: bodies.Bodies = .{
        .exprs = &exprs_arr,
        .stmts = &.{},
        .pats = &.{},
        .types = &types_arr,
        .bodies = &bodies_arr,
    };
    var g = graph.CrateGraph.init(a);
    defer g.deinit();

    var t = try collectInstantiations(a, &g, &bb);
    defer t.deinit(a);

    // gen generic Foo<i32> (from expr0.ty -> types[0]) => 1 entry (dedup).
    try testing.expectEqual(@as(usize, 1), t.count());
    const inst = (t.get(0) orelse unreachable);
    try testing.expectEqual(@as(spine.EntityId, 5), inst.generic_id);
    try testing.expectEqualStrings("_i32", inst.zig_suffix);
}

test "collectInstantiations — propagates allocator failure" {
    const generic_ret = genericOf(5, &.{primType(.i32)});
    const body: bodies.BodyKind = .{ .fn_ = .{
        .params = &.{},
        .ret = generic_ret,
        .body = 0,
    } };
    const bb: bodies.Bodies = .{
        .exprs = &.{},
        .stmts = &.{},
        .pats = &.{},
        .types = &.{},
        .bodies = &.{body},
    };

    var g = graph.CrateGraph.init(testing.allocator);
    defer g.deinit();

    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.OutOfMemory,
        collectInstantiations(failing_allocator.allocator(), &g, &bb),
    );
}
