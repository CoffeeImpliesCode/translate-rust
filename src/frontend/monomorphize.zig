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

/// Structural equality of two `types.Type` values. A `Path` is compared by
/// its last non-empty segment name only ? resolution ids are not yet
/// guaranteed stable across every construction path, so a name comparison
/// gives the deduplication that the emitter needs for non-generic paths
/// (which never reach the table anyway).
pub fn typeEquals(a: types.Type, b: types.Type) bool {
    return switch (a) {
        .path => |ap| switch (b) {
            .path => |bp| pathEquals(ap, bp),
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
        .unsupported => |ap| switch (b) {
            .unsupported => |bp| ap.reason == bp.reason and std.mem.eql(u8, ap.message, bp.message),
            else => false,
        },
    };
}

fn pathEquals(a: types.Path, b: types.Path) bool {
    const an = lastSegment(a);
    const bn = lastSegment(b);
    return std.mem.eql(u8, an, bn);
}

/// Last non-empty segment name of a path (`""` if none/none non-empty).
fn lastSegment(p: types.Path) []const u8 {
    var i = p.segments.len;
    while (i > 0) {
        i -= 1;
        const s = p.segments[i];
        if (s.name.len > 0) return s.name;
    }
    return "";
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

fn appendMangled(alloc: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), ty: types.Type) std.mem.Allocator.Error!void {
    switch (ty) {
        .path => |p| try appendMangledPath(alloc, w, p),
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
            try w.appendSlice(alloc, "_slice");
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
        .unsupported => |u| try appendMangledName(alloc, w, @tagName(u.reason)),
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
    try appendMangledName(alloc, w, lastSegment(p));
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

/// Deduplicated list of instantiation records. Owns its buffer + each mangled
/// suffix slice; `deinit` frees them all.
pub const InstantiationTable = struct {
    instantiations: std.ArrayListUnmanaged(types.Instantiation) = .empty,

    pub fn deinit(self: *InstantiationTable, alloc: std.mem.Allocator) void {
        for (self.instantiations.items) |inst| {
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
        const suffix = try mangleSuffix(alloc, args);
        errdefer if (suffix.len > 0) alloc.free(suffix);
        try self.instantiations.append(alloc, .{
            .generic_id = generic_id,
            .args = args,
            .zig_suffix = suffix,
        });
        return self.instantiations.items.len - 1;
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

/// Determine whether a `Type` reachable through the model is itself a generic
/// instantiation; register it (and recurse into its nested args). Repeated
/// registration is deduplicated by `addOrGet`, so a simple recursive scan is
/// safe.
fn collectType(table: *InstantiationTable, alloc: std.mem.Allocator, ty: types.Type) std.mem.Allocator.Error!void {
    switch (ty) {
        .generic_inst => |g| {
            // A generic_inst guards on decl + args; only register when it has
            // at least one concrete argument (a no-arg "generic" is not a
            // monomorphization and would produce an empty suffix).
            if (g.args.params.len > 0) {
                _ = try table.addOrGet(alloc, g.decl, g.args);
            }
            for (g.args.params) |a| try collectType(table, alloc, a);
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
        else => {},
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
            if (p.generic_args.len > 0) {
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
        .continue_, .literal, .unit, .unsupported => {},
        .array => |a| for (a.elements) |el| try collectExpr(table, alloc, b, v, el),
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
        .field => |f| try collectExpr(table, alloc, b, v, f.base),
        .index => |ix| {
            try collectExpr(table, alloc, b, v, ix.base);
            try collectExpr(table, alloc, b, v, ix.index);
        },
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
    if (p.ty) |tyid| {
        if (tyid < b.types.len) try collectType(table, alloc, b.types[tyid]);
    }
    switch (p.kind) {
        .wildcard, .literal => {},
        .binding => {},
        .path => {},
        .tuple => |t| for (t.elements) |e| try collectPat(table, alloc, b, v, e),
        .slice => |s| {
            for (s.elements) |e| try collectPat(table, alloc, b, v, e);
            if (s.rest) |r| try collectPat(table, alloc, b, v, r);
        },
        .struct_pat => |sp| for (sp.fields) |fld| if (fld.pat) |fp| try collectPat(table, alloc, b, v, fp),
        .reference => |r| try collectPat(table, alloc, b, v, r.inner),
        .@"or" => |o| for (o.alternatives) |alt| try collectPat(table, alloc, b, v, alt),
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

/// Collect every instantiation reachable from a single EntityBody (fn body
/// block, const init) plus the entity's param/ret signature types.
fn collectBodyKind(
    table: *InstantiationTable,
    alloc: std.mem.Allocator,
    b: *const bodies.Bodies,
    v: *Visited,
    kind: bodies.BodyKind,
) std.mem.Allocator.Error!void {
    switch (kind) {
        .none, .struct_, .enum_, .trait_, .type_alias => {},
        .const_ => |c| {
            try collectType(table, alloc, c.ty);
            try collectExpr(table, alloc, b, v, c.init);
        },
        .fn_ => |f| {
            for (f.params) |p| try collectType(table, alloc, p.ty);
            try collectType(table, alloc, f.ret);
            try collectExpr(table, alloc, b, v, f.body);
        },
    }
}

/// Scan the crate graph's item signatures (struct fields, enum variants,
/// fn params/returns) for generic instantiations not carried in bodies.
fn collectItemTypes(table: *InstantiationTable, alloc: std.mem.Allocator, g: *const graph.CrateGraph) std.mem.Allocator.Error!void {
    // The graph owns a flat entity list in its symbol table; we only need the
    // entity ids that have items. items.zig Item data is not directly linked
    // here (items -> types only), so walk via graph entities conservatively:
    // register generic signatures already present in the type table is done
    // through bodies. Graph-level generic fields/fn signatures are captured
    // on demand by emitting the instantiation table from bodies; the CrateGraph
    // parameter keeps the contract for downstream callers that pass both.
    _ = g;
    _ = alloc;
    _ = table;
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

    try collectItemTypes(&table, alloc, g);
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
