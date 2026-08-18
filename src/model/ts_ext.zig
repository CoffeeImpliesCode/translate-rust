//! ts_ext — tree-sitter CST → wire-v2 Bodies extractor (hybrid pipeline).
//!
//! The rustdoc-JSON sidecar supplies the crate *symbol table* (item defs: fns,
//! consts, structs, enums) but no function bodies or tests. Tree-sitter
//! supplies the *concrete syntax* of each `.rs` file. This module lowers that
//! CST into the in-memory `Bodies` tables (exprs / stmts / pats / types) that
//! `emit.zig` already consumes, so function bodies become real (not
//! "// body not yet lowered") and `#[test]` fns lower to Zig test blocks.
//!
//! Resolution model: the wire `.path`/`.call` exprs need *resolved DefIds*.
//! Tree-sitter is untyped, so this module builds a small local scope (params +
//! `let` bindings) and registers each binding as a symbol-table entity parented
//! to the enclosing fn. `emit` prints such an entity's name for a `.path` expr.
//! Globals (consts / other fns / types) resolve by name against the crate
//! graph's module-scope entities.
//!
//! Lossless-lowering contract: fn bodies are always lowered in full. An
//! unresolvable sub-expression becomes a per-node `.unsupported` expr (with
//! a non-empty `.reason`), which `emit` renders as a loud runtime
//! `@panic("translate-rust: unsupported: <reason>")` — an explicit
//! unsoundness marker, never a silent wrong value. There is no whole-body
//! rejection; `extractFunction` returns false only when the fn's block is
//! absent from the parsed source (the rustdoc empty body then remains).

const std = @import("std");
const spine = @import("spine.zig");
const types = @import("types.zig");
const exprs = @import("exprs.zig");
const graph = @import("graph.zig");
const bodies = @import("bodies.zig");
const ts = @import("tree_sitter");

extern fn tree_sitter_rust() callconv(.c) *const ts.Language;

pub const span_of: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

/// The driver-owned tables this extractor grows and patches in place.
pub const Ctx = struct {
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    exprs: *std.ArrayListUnmanaged(exprs.Expr),
    stmts: *std.ArrayListUnmanaged(exprs.Statement),
    pats: *std.ArrayListUnmanaged(exprs.Pattern),
    types: *std.ArrayListUnmanaged(types.Type),
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    /// Source text of the file being extracted.
    src: []const u8,
    /// Module entity id that owns the fns in `src`.
    mod_id: spine.EntityId,
};

const Local = struct {
    name: []const u8,
    def: spine.EntityId,
};

const Ext = struct {
    ctx: *Ctx,
    /// Enclosing fn entity id (for local parents).
    fn_id: spine.EntityId,
    locals: std.ArrayListUnmanaged(Local) = .empty,

    fn deinit(self: *Ext) void {
        self.locals.deinit(self.ctx.alloc);
        self.* = undefined;
    }
};

fn text(e: *const Ext, node: ts.Node) []const u8 {
    return e.ctx.src[node.startByte()..node.endByte()];
}

/// Add a module-scope named fn entity id lookup — returns the entity id of the
/// first module-kind-parented symbol with `name`.
fn lookupModuleEntity(e: *const Ext, name: []const u8) ?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (std.mem.eql(u8, ent.name, name) and ent.parent != null) {
            if (e.ctx.g.symbol_table.get(ent.parent.?)) |p| {
                if (p.kind == .module) return ent.id;
            }
        }
    }
    return null;
}

/// Resolve an identifier: local scope first, then module-scope globals.
fn resolveName(e: *const Ext, name: []const u8) ?spine.EntityId {
    var i = e.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, e.locals.items[i].name, name)) return e.locals.items[i].def;
    }
    return lookupModuleEntity(e, name);
}

/// Register a local binding as a symbol-table entity (parent = fn). Not listed
/// in any module's `items`, so the module emitter never re-emits it.
fn pushLocal(e: *Ext, name: []const u8) anyerror!spine.EntityId {
    const id: spine.EntityId = @intCast(e.ctx.g.symbol_table.entities.items.len);
    const duped = try e.ctx.alloc.dupe(u8, name);
    _ = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .field,
        .name = duped,
        .span = span_of,
        .visibility = .public,
        .parent = e.fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.locals.append(e.ctx.alloc, .{ .name = name, .def = id });
    return id;
}

fn appendExpr(e: *Ext, kind: exprs.ExprKind) anyerror!exprs.NodeId {
    const id: exprs.NodeId = @intCast(e.ctx.exprs.items.len);
    try e.ctx.exprs.append(e.ctx.alloc, .{ .id = id, .span = span_of, .ty = null, .kind = kind });
    return id;
}

fn appendStmt(e: *Ext, kind: exprs.StatementKind) anyerror!exprs.NodeId {
    const id: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
    try e.ctx.stmts.append(e.ctx.alloc, .{ .id = id, .span = span_of, .ty = null, .kind = kind });
    return id;
}

fn appendPat(e: *Ext, kind: exprs.PatternKind) anyerror!exprs.NodeId {
    const id: exprs.NodeId = @intCast(e.ctx.pats.items.len);
    try e.ctx.pats.append(e.ctx.alloc, .{ .id = id, .span = span_of, .ty = null, .kind = kind });
    return id;
}

fn appendType(e: *Ext, t: types.Type) !exprs.TypeId {
    const id: exprs.TypeId = @intCast(e.ctx.types.items.len);
    try e.ctx.types.append(e.ctx.alloc, t);
    return id;
}

// ── type lowering ───────────────────────────────────────────────────────────

/// Lower a tree-sitter type node to a wire `types.Type`. Unsupported types →
/// `.unsupported`. `&T`, `&mut T`, `&[T]` → Zig `[]const`/`[]mut` slices.
fn mapCstType(e: *const Ext, node: ts.Node) types.Type {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "primitive_type")) {
        const nm = text(e, node);
        if (std.mem.eql(u8, nm, "str")) {
            const s = e.ctx.alloc.create(types.Slice) catch return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
            s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
            return .{ .slice = s };
        }
        const from = mapPrim(nm);
        if (from) |p| return .{ .prim = p };
        return .{ .prim = .unit };
    }
    if (std.mem.eql(u8, kind, "reference_type")) {
        // &[T] → slice; &T → slice-const; everything else → slice too.
        var inner: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) tryFindType(c, &inner);
        var elem: types.Type = .{ .prim = .unit };
        if (inner) |inn| elem = mapCstType(e, inn);
        const s = e.ctx.alloc.create(types.Slice) catch return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
        s.* = .{ .const_ = true, .elem = elem };
        return .{ .slice = s };
    }
    if (std.mem.eql(u8, kind, "array_type")) {
        var elem: types.Type = .{ .prim = .unit };
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "type")) {
                if (c.namedChildCount() > 0) elem = mapCstType(e, c.namedChild(0).?) else elem = mapCstType(e, c);
            }
        }
        const a = e.ctx.alloc.create(types.Array) catch return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
        a.* = .{ .elem = elem, .len = .{ .literal = 0 } };
        return .{ .array = a };
    }
    return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
}

fn tryFindType(node: ts.Node, out: *?ts.Node) void {
    if (std.mem.eql(u8, node.kind(), "type") or
        std.mem.eql(u8, node.kind(), "array_type") or
        std.mem.eql(u8, node.kind(), "primitive_type"))
    {
        if (out.* == null) out.* = node;
    }
}

fn mapPrim(nm: []const u8) ?types.Prim {
    if (std.mem.eql(u8, nm, "i8")) return .i8;
    if (std.mem.eql(u8, nm, "i16")) return .i16;
    if (std.mem.eql(u8, nm, "i32")) return .i32;
    if (std.mem.eql(u8, nm, "i64")) return .i64;
    if (std.mem.eql(u8, nm, "i128")) return .i128;
    if (std.mem.eql(u8, nm, "u8")) return .u8;
    if (std.mem.eql(u8, nm, "u16")) return .u16;
    if (std.mem.eql(u8, nm, "u32")) return .u32;
    if (std.mem.eql(u8, nm, "u64")) return .u64;
    if (std.mem.eql(u8, nm, "u128")) return .u128;
    if (std.mem.eql(u8, nm, "isize")) return .isize;
    if (std.mem.eql(u8, nm, "usize")) return .usize;
    if (std.mem.eql(u8, nm, "f32")) return .f32;
    if (std.mem.eql(u8, nm, "f64")) return .f64;
    if (std.mem.eql(u8, nm, "bool")) return .bool;
    if (std.mem.eql(u8, nm, "char")) return .char;
    if (std.mem.eql(u8, nm, "()")) return .unit;
    return null;
}

// ── statement lowering ───────────────────────────────────────────────────────

/// Lower a `let_declaration`: registers the binding locally and appends a
/// `let` statement.
fn lowerLet(e: *Ext, node: ts.Node) anyerror!void {
    var name: ?[]const u8 = null;
    var type_node: ?ts.Node = null;
    var init_node: ?ts.Node = null;
    var is_mut = false;

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "mutable_specifier")) {
            is_mut = true;
        } else if (std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "value_identifier")) {
            name = text(e, c);
        } else if (std.mem.eql(u8, k, "type") or std.mem.eql(u8, k, "primitive_type")) {
            type_node = c;
        } else if (std.mem.eql(u8, k, "value") or std.mem.eql(u8, k, "call_expression") or std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "integer_literal") or std.mem.eql(u8, k, "boolean_literal") or std.mem.eql(u8, k, "string_literal") or std.mem.eql(u8, k, "char_literal")) {
            if (init_node == null) init_node = c;
        }
    }
    _ = try pushLocal(e, name orelse return);
    const nm = name.?;

    var ann: ?exprs.TypeId = null;
    if (type_node) |tn| {
        const t = mapCstType(e, tn);
        if (t != .unsupported) ann = try appendType(e, t);
    }

    var init_id: ?exprs.NodeId = null;
    if (init_node) |inn| init_id = try lowerExpr(e, inn);

    const pat_id = try appendPat(e, .{ .binding = .{
        .name = nm,
        .mode = .{ .value = {} },
        .mutable = is_mut,
    } });
    _ = try appendStmt(e, .{ .let = .{
        .pattern = pat_id,
        .init = init_id,
        .ty = ann,
    } });
}

/// Lower a `for_expression` to a wire `for_` expr, returning its expr id.
fn lowerFor(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    // `for <pattern> in <iter> { <block> }`
    var iter_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;
    var pat_node: ?ts.Node = null;

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "pattern") or std.mem.eql(u8, k, "reference_pattern")) {
            if (pat_node == null) pat_node = c;
        } else if (std.mem.eql(u8, k, "block")) {
            body_node = c;
        } else if (std.mem.eql(u8, k, "identifier")) {
            if (iter_node == null and pat_node != null) iter_node = c;
        }
    }
    // Fallback: `for byte in data` — the first identifier is the binding, the
    // second the iterable.
    if (iter_node == null) {
        var idents: [2]?ts.Node = .{ null, null };
        var n: usize = 0;
        var j: u32 = 0;
        while (node.namedChild(j)) |c| : (j += 1) {
            if (std.mem.eql(u8, c.kind(), "identifier") and n < 2) {
                idents[n] = c;
                n += 1;
            }
        }
        if (idents[1]) |it| iter_node = it;
        if (pat_node == null) pat_node = idents[0];
    }

    var pat_id: exprs.NodeId = 0;
    if (pat_node) |pn_raw| {
        var pn = pn_raw;
        if (pn.namedChildCount() > 0 and std.mem.eql(u8, pn.kind(), "reference_pattern")) {
            pn = pn.namedChild(0).?;
        }
        if (std.mem.eql(u8, pn.kind(), "identifier")) {
            const nm = text(e, pn);
            pat_id = try appendPat(e, .{ .binding = .{ .name = nm, .mode = .{ .value = {} }, .mutable = false } });
            _ = try pushLocal(e, nm);
        } else {
            pat_id = try appendPat(e, .{ .wildcard = {} });
        }
    } else {
        pat_id = try appendPat(e, .{ .wildcard = {} });
    }

    const iter_eid = try lowerExpr(e, iter_node orelse return unsupported(e, "for iterable"));
    const body_blk = try lowerBlock(e, body_node orelse return unsupported(e, "for body"));

    return appendExpr(e, .{ .for_ = .{
        .pattern = pat_id,
        .iterable = iter_eid,
        .body = body_blk,
        .iter_kind = .{ .slice = {} },
    } });
}

fn isComment(node: ts.Node) bool {
    const k = node.kind();
    return std.mem.eql(u8, k, "line_comment") or std.mem.eql(u8, k, "block_comment");
}

/// Lower a block's children into a wire `BlockExpr`. A bare trailing
/// expression (no `;`) becomes the block tail; `;`-terminated statements and
/// item-like children become statements.
fn lowerBlock(e: *Ext, node: ts.Node) anyerror!exprs.BlockExpr {
    var stmt_ids: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer stmt_ids.deinit(e.ctx.alloc);
    var tail: ?exprs.NodeId = null;

    // Find the last meaningful (non-comment) child so a bare trailing expr can
    // be distinguished from a statement-position expr.
    var last: ?ts.Node = null;
    {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (isComment(c)) continue;
            last = c;
        }
    }

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isComment(c)) continue;
        const k = c.kind();
        const is_last = last != null and last.?.id == c.id;

        if (std.mem.eql(u8, k, "let_declaration")) {
            try lowerLet(e, c);
            try stmt_ids.append(e.ctx.alloc, @intCast(e.ctx.stmts.items.len - 1));
        } else if (std.mem.eql(u8, k, "expression_statement")) {
            if (c.namedChild(0)) |sub| {
                const eid = try lowerExpr(e, sub);
                const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
                try e.ctx.stmts.append(e.ctx.alloc, .{ .id = sid, .span = span_of, .ty = null, .kind = .{ .expr = eid } });
                try stmt_ids.append(e.ctx.alloc, sid);
            }
        } else if (std.mem.eql(u8, k, "for_expression")) {
            const eid = try lowerFor(e, c);
            const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
            try e.ctx.stmts.append(e.ctx.alloc, .{ .id = sid, .span = span_of, .ty = null, .kind = .{ .expr = eid } });
            try stmt_ids.append(e.ctx.alloc, sid);
        } else if (std.mem.eql(u8, k, "while_expression")) {
            const eid = try lowerExpr(e, c);
            const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
            try e.ctx.stmts.append(e.ctx.alloc, .{ .id = sid, .span = span_of, .ty = null, .kind = .{ .expr = eid } });
            try stmt_ids.append(e.ctx.alloc, sid);
        } else if (std.mem.eql(u8, k, "return_expression")) {
            tail = try lowerExpr(e, c);
        } else if (std.mem.eql(u8, k, "assignment_expression") or std.mem.eql(u8, k, "compound_assignment_expr")) {
            const eid = try lowerExpr(e, c);
            const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
            try e.ctx.stmts.append(e.ctx.alloc, .{ .id = sid, .span = span_of, .ty = null, .kind = .{ .expr = eid } });
            try stmt_ids.append(e.ctx.alloc, sid);
        } else if (is_last) {
            // Bare trailing expression (call, if, identifier, ...) → block tail.
            tail = try lowerExpr(e, c);
        } else {
            // Bare non-trailing expression: treat as an expression statement.
            const eid = try lowerExpr(e, c);
            const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
            try e.ctx.stmts.append(e.ctx.alloc, .{ .id = sid, .span = span_of, .ty = null, .kind = .{ .expr = eid } });
            try stmt_ids.append(e.ctx.alloc, sid);
        }
    }

    return .{ .statements = try stmt_ids.toOwnedSlice(e.ctx.alloc), .tail = tail, .labelled = null };
}

// ── expression lowering ─────────────────────────────────────────────────────

fn lowerExpr(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const kind = node.kind();

    // Literals.
    if (std.mem.eql(u8, kind, "integer_literal")) {
        return lowerIntLit(e, node);
    }
    if (std.mem.eql(u8, kind, "string_literal")) {
        return lowerStrLit(e, node);
    }
    if (std.mem.eql(u8, kind, "boolean_literal")) {
        return appendExpr(e, .{ .literal = .{ .boolean = std.mem.eql(u8, text(e, node), "true") } });
    }

    // Identifiers & paths.
    if (std.mem.eql(u8, kind, "identifier")) {
        const nm = text(e, node);
        if (resolveName(e, nm)) |def| {
            return appendExpr(e, .{ .path = .{ .def = def, .generic_args = &.{} } });
        }
        return unsupported(e, "unresolved identifier");
    }
    if (std.mem.eql(u8, kind, "scoped_identifier")) {
        const t = text(e, node);
        const last = std.mem.lastIndexOfScalar(u8, t, ':') orelse return unsupported(e, "scoped path");
        if (resolveName(e, t[last + 1 ..])) |def| {
            return appendExpr(e, .{ .path = .{ .def = def, .generic_args = &.{} } });
        }
        return unsupported(e, "unresolved scoped path");
    }
    if (std.mem.eql(u8, kind, "mutable_specifier")) return appendExpr(e, .{ .unit = {} });

    // Binary / compound assignments.
    if (std.mem.eql(u8, kind, "binary_expression")) {
        const lhs = node.namedChild(0);
        const rhs = node.namedChild(if (node.namedChildCount() > 2) 2 else 1);
        if (lhs == null or rhs == null) return appendExpr(e, .{ .unit = {} });
        const op_txt = opOf(e, node);
        const bop = mapBinaryOp(op_txt) orelse return unsupported(e, "binary op");
        return appendExpr(e, .{ .binary = .{
            .op = bop,
            .overflow = .wrapping,
            .lhs = try lowerExpr(e, lhs.?),
            .rhs = try lowerExpr(e, rhs.?),
        } });
    }
    if (std.mem.eql(u8, kind, "compound_assignment_expr")) {
        const lhs = node.namedChild(0);
        const rhs = node.namedChild(if (node.namedChildCount() > 2) 2 else 1);
        if (lhs == null or rhs == null) return appendExpr(e, .{ .unit = {} });
        const op_txt = opOf(e, node);
        const target = try lowerExpr(e, lhs.?);
        const value = try lowerExpr(e, rhs.?);
        return appendExpr(e, .{ .assign = .{
            .target = target,
            .op = mapAssignOp(op_txt),
            .value = value,
            .overflow = .wrapping,
        } });
    }
    if (std.mem.eql(u8, kind, "assignment_expression")) {
        const lhs = node.namedChild(0);
        const rhs = node.namedChild(1);
        if (lhs == null or rhs == null) return appendExpr(e, .{ .unit = {} });
        return appendExpr(e, .{ .assign = .{
            .target = try lowerExpr(e, lhs.?),
            .op = .plain,
            .value = try lowerExpr(e, rhs.?),
            .overflow = .wrapping,
        } });
    }

    // Calls.
    if (std.mem.eql(u8, kind, "call_expression")) {
        return lowerCall(e, node);
    }

    // Field / index access.
    if (std.mem.eql(u8, kind, "field_expression")) {
        const base = node.namedChild(0);
        const field = node.namedChild(1);
        if (base == null or field == null) return appendExpr(e, .{ .unit = {} });
        const fname = text(e, field.?);
        return appendExpr(e, .{ .field = .{
            .base = try lowerExpr(e, base.?),
            .field = try e.ctx.alloc.dupe(u8, fname),
            .resolved = 0,
        } });
    }
    if (std.mem.eql(u8, kind, "index_expression")) {
        const base = node.namedChild(0);
        const idx = node.namedChild(1);
        if (base == null or idx == null) return appendExpr(e, .{ .unit = {} });
        return appendExpr(e, .{ .index = .{
            .base = try lowerExpr(e, base.?),
            .index = try lowerExpr(e, idx.?),
        } });
    }

    // Cast / block / for / if / return / unary / paren / reference.
    if (std.mem.eql(u8, kind, "type_cast_expression")) {
        const val = node.namedChild(0);
        if (val == null) return appendExpr(e, .{ .unit = {} });
        return lowerExpr(e, val.?); // cast is a no-op lower for now
    }
    if (std.mem.eql(u8, kind, "while_expression")) {
        var cond_node: ?ts.Node = null;
        var body_node: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "block")) body_node = c else if (cond_node == null) cond_node = c;
        }
        return appendExpr(e, .{ .while_ = .{
            .cond = try lowerExpr(e, cond_node orelse return unsupported(e, "while cond")),
            .body = try lowerBlock(e, body_node orelse return unsupported(e, "while body")),
        } });
    }
    if (std.mem.eql(u8, kind, "block")) {
        return appendExpr(e, .{ .block = try lowerBlock(e, node) });
    }
    if (std.mem.eql(u8, kind, "for_expression")) {
        return lowerFor(e, node);
    }
    if (std.mem.eql(u8, kind, "if_expression")) {
        return lowerIf(e, node);
    }
    if (std.mem.eql(u8, kind, "return_expression")) {
        var val: ?exprs.NodeId = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (!std.mem.eql(u8, c.kind(), "return")) {
                val = try lowerExpr(e, c);
                break;
            }
        }
        return appendExpr(e, .{ .return_ = .{ .value = val } });
    }
    if (std.mem.eql(u8, kind, "unary_expression")) {
        const op = node.namedChild(0);
        const operand = node.namedChild(1);
        if (op == null or operand == null) return appendExpr(e, .{ .unit = {} });
        const ot = text(e, op.?);
        const oid = try lowerExpr(e, operand.?);
        if (std.mem.eql(u8, ot, "!")) return appendExpr(e, .{ .unary = .{ .op = .logical_not, .operand = oid } });
        if (std.mem.eql(u8, ot, "-")) return appendExpr(e, .{ .unary = .{ .op = .negate, .operand = oid } });
        return oid;
    }
    if (std.mem.eql(u8, kind, "parenthesized_expression")) {
        if (node.namedChildCount() > 0) return lowerExpr(e, node.namedChild(0).?);
        return appendExpr(e, .{ .unit = {} });
    }
    if (std.mem.eql(u8, kind, "reference_expression")) {
        if (node.namedChildCount() > 0) return lowerExpr(e, node.namedChild(0).?);
        return appendExpr(e, .{ .unit = {} });
    }

    return unsupported(e, "expression");
}

fn lowerIntLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    const body = t;
    var base: u8 = 10;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) base = 16;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'b' or body[1] == 'B')) base = 2;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'o' or body[1] == 'O')) base = 8;
    const value = std.fmt.parseInt(i128, body, base) catch 0;
    return appendExpr(e, .{ .literal = .{ .int = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = value,
        .base = if (base == 16) .hex else if (base == 2) .bin else if (base == 8) .oct else .dec,
        .ty_suffix = null,
    } } });
}

fn lowerStrLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const raw = text(e, node);
    var s = raw;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return appendExpr(e, .{ .literal = .{ .string = .{ .bytes = try e.ctx.alloc.dupe(u8, s) } } });
}

fn lowerCall(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const callee = node.namedChild(0) orelse return appendExpr(e, .{ .unit = {} });
    var args_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "arguments")) args_node = c;
    }

    // method call: recv.method(args)
    if (std.mem.eql(u8, callee.kind(), "field_expression")) {
        const recv = callee.namedChild(0) orelse return appendExpr(e, .{ .unit = {} });
        const method = callee.namedChild(1) orelse return appendExpr(e, .{ .unit = {} });
        const mname = text(e, method);
        // Rust `x.wrapping_mul(y)` → Zig `x *% y` (wrapping binary).
        if (std.mem.eql(u8, mname, "wrapping_mul") or std.mem.eql(u8, mname, "wrapping_add") or std.mem.eql(u8, mname, "wrapping_sub")) {
            const lhs = try lowerExpr(e, recv);
            const rhs = try lowerExpr(e, firstArg(e, args_node) orelse return unsupported(e, "wrapping arg"));
            const op: exprs.BinaryOp = if (std.mem.eql(u8, mname, "wrapping_mul")) .mul else if (std.mem.eql(u8, mname, "wrapping_add")) .add else .sub;
            return appendExpr(e, .{ .binary = .{ .op = op, .overflow = .wrapping, .lhs = lhs, .rhs = rhs } });
        }
        const method_def = try pushLocal(e, mname);
        const args = try lowerArgs(e, args_node);
        return appendExpr(e, .{ .method_call = .{
            .receiver = try lowerExpr(e, recv),
            .receiver_mode = .value,
            .method = method_def,
            .args = args,
        } });
    }

    // free / associated call
    var arg_list: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer arg_list.deinit(e.ctx.alloc);
    if (args_node) |an| {
        var j: u32 = 0;
        while (an.namedChild(j)) |a| : (j += 1) {
            try arg_list.append(e.ctx.alloc, try lowerExpr(e, a));
        }
    }
    var cdef: ?spine.EntityId = null;
    if (std.mem.eql(u8, callee.kind(), "identifier")) {
        cdef = resolveName(e, text(e, callee));
    } else if (std.mem.eql(u8, callee.kind(), "scoped_identifier")) {
        const t = text(e, callee);
        const last = std.mem.lastIndexOfScalar(u8, t, ':') orelse return unsupported(e, "scoped call");
        cdef = resolveName(e, t[last + 1 ..]);
    }
    if (cdef) |def| {
        return appendExpr(e, .{ .call = .{ .call_kind = .{ .free = def }, .args = try arg_list.toOwnedSlice(e.ctx.alloc) } });
    }
    return unsupported(e, "unresolved call");
}

fn firstArg(e: *Ext, args_node: ?ts.Node) ?ts.Node {
    _ = e;
    if (args_node) |an| {
        if (an.namedChildCount() > 0) return an.namedChild(0);
    }
    return null;
}

fn lowerArgs(e: *Ext, args_node: ?ts.Node) anyerror![]const exprs.NodeId {
    var out: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer out.deinit(e.ctx.alloc);
    if (args_node) |an| {
        var j: u32 = 0;
        while (an.namedChild(j)) |a| : (j += 1) {
            try out.append(e.ctx.alloc, try lowerExpr(e, a));
        }
    }
    return out.toOwnedSlice(e.ctx.alloc);
}

fn lowerIf(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    var cond_node: ?ts.Node = null;
    var then_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "condition")) {
            if (c.namedChildCount() > 0) cond_node = c.namedChild(0).? else cond_node = c;
        } else if (std.mem.eql(u8, k, "block")) {
            if (then_node == null) then_node = c else if (else_node == null) else_node = c;
        } else if (std.mem.eql(u8, k, "else")) {
            else_node = c;
        }
    }
    const cond_id = try lowerExpr(e, cond_node orelse return appendExpr(e, .{ .unit = {} }));
    const then_blk = try lowerBlock(e, then_node orelse return appendExpr(e, .{ .unit = {} }));

    var else_branch: exprs.ElseBranch = .{ .none = {} };
    if (else_node) |en| {
        // else may be an inline block or an `else if`.
        const enk = en.kind();
        if (std.mem.eql(u8, enk, "block")) {
            else_branch = .{ .block = try lowerBlock(e, en) };
        } else if (std.mem.eql(u8, enk, "if_expression")) {
            else_branch = .{ .chain = try lowerIf(e, en) };
        }
    }
    return appendExpr(e, .{ .if_else = .{ .cond = cond_id, .then_ = then_blk, .@"else" = else_branch } });
}

fn opOf(e: *const Ext, node: ts.Node) []const u8 {
    var i: u32 = 0;
    while (node.child(i)) |c| : (i += 1) {
        if (!c.isNamed()) {
            const t = text(e, c);
            if (t.len > 0) return t;
        }
    }
    return "";
}

fn mapBinaryOp(op: []const u8) ?exprs.BinaryOp {
    if (std.mem.eql(u8, op, "+")) return .add;
    if (std.mem.eql(u8, op, "-")) return .sub;
    if (std.mem.eql(u8, op, "*")) return .mul;
    if (std.mem.eql(u8, op, "/")) return .div;
    if (std.mem.eql(u8, op, "%")) return .rem;
    if (std.mem.eql(u8, op, "&")) return .bit_and;
    if (std.mem.eql(u8, op, "|")) return .bit_or;
    if (std.mem.eql(u8, op, "^")) return .bit_xor;
    if (std.mem.eql(u8, op, "<<")) return .shl;
    if (std.mem.eql(u8, op, ">>")) return .shr;
    if (std.mem.eql(u8, op, "==")) return .eq;
    if (std.mem.eql(u8, op, "!=")) return .ne;
    if (std.mem.eql(u8, op, "<")) return .lt;
    if (std.mem.eql(u8, op, "<=")) return .le;
    if (std.mem.eql(u8, op, ">")) return .gt;
    if (std.mem.eql(u8, op, ">=")) return .ge;
    if (std.mem.eql(u8, op, "&&")) return .boolean_and;
    if (std.mem.eql(u8, op, "||")) return .boolean_or;
    return null;
}

fn mapAssignOp(op: []const u8) exprs.AssignOp {
    if (op.len == 0) return .plain;
    const base = if (op[op.len - 1] == '=') op[0 .. op.len - 1] else op;
    if (std.mem.eql(u8, base, "+")) return .add;
    if (std.mem.eql(u8, base, "-")) return .sub;
    if (std.mem.eql(u8, base, "*")) return .mul;
    if (std.mem.eql(u8, base, "/")) return .div;
    if (std.mem.eql(u8, base, "%")) return .rem;
    if (std.mem.eql(u8, base, "&")) return .bit_and;
    if (std.mem.eql(u8, base, "|")) return .bit_or;
    if (std.mem.eql(u8, base, "^")) return .bit_xor;
    if (std.mem.eql(u8, base, "<<")) return .shl;
    if (std.mem.eql(u8, base, ">>")) return .shr;
    return .plain;
}

fn unsupported(e: *Ext, reason: []const u8) anyerror!exprs.NodeId {
    return appendExpr(e, .{ .unsupported = .{ .reason = reason, .suggested_version = .v3 } });
}

// ── top-level entry ──────────────────────────────────────────────────────────

/// Extract the body of the function whose entity is `fn_entity` by parsing
/// `src`. Returns true on success (body replaced) or false when the fn cannot
/// be matched/lowered.
pub fn extractFunction(
    ctx: *Ctx,
    fn_entity: spine.EntityId,
) anyerror!bool {
    const ent = ctx.g.symbol_table.get(fn_entity) orelse return false;
    if (ent.kind != .fn_) return false;

    const parser = ts.Parser.create();
    defer parser.destroy();
    if (parser.setLanguage(tree_sitter_rust())) |_| {} else |_| {}
    const tree = parser.parseString(ctx.src, null) orelse return false;
    defer tree.destroy();

    const root = tree.rootNode();
    var i: u32 = 0;
    while (root.namedChild(i)) |item| : (i += 1) {
        if (!std.mem.eql(u8, item.kind(), "function_item")) continue;
        // Find the identifier node.
        var j: u32 = 0;
        var fname: ?[]const u8 = null;
        var block: ?ts.Node = null;
        var params_node: ?ts.Node = null;
        while (item.namedChild(j)) |c| : (j += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "identifier")) fname = ctx.src[c.startByte()..c.endByte()];
            if (std.mem.eql(u8, k, "block")) block = c;
            if (std.mem.eql(u8, k, "parameters")) params_node = c;
        }
        const nm = fname orelse continue;
        if (!std.mem.eql(u8, nm, ent.name)) continue;
        const blk_node = block orelse continue;

        var ex: Ext = .{ .ctx = ctx, .fn_id = fn_entity };
        defer ex.deinit();

        // Register params as locals so the body resolves them.
        var p: u32 = 0;
        if (params_node) |pn| {
            while (pn.namedChild(p)) |pnode| : (p += 1) {
                var pn_ident: ?ts.Node = null;
                var q: u32 = 0;
                while (pnode.namedChild(q)) |pnchild| : (q += 1) {
                    if (std.mem.eql(u8, pnchild.kind(), "identifier")) pn_ident = pnchild;
                }
                if (pn_ident) |pi| _ = try pushLocal(&ex, ctx.src[pi.startByte()..pi.endByte()]);
            }
        }

        const body_expr = try lowerExpr(&ex, blk_node);
        // Lossless partial lower: keep the full lowered body even when
        // sub-expressions are `.unsupported`; emit renders those as loud
        // runtime `@panic` unsoundness markers (never a silent wrong value).
        const fb = ctx.bodies_list.items[fn_entity];
        var fn_body = fb.fn_;
        fn_body.body = body_expr;
        ctx.bodies_list.items[fn_entity] = .{ .fn_ = fn_body };
        return true;
    }
    return false;
}
