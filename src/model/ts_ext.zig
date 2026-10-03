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
const expand = @import("expand.zig");
const ts = @import("tree_sitter");
const rust = @import("rust");

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

/// Look up a module-scope entity or a `use ... as Local` binding by name.
fn lookupModuleEntity(e: *const Ext, name: []const u8) ?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (std.mem.eql(u8, ent.name, name)) {
            return ent.id;
        }
    }
    // `use path as Local` binds the local spelling separately from the
    // use_ entity's diagnostic path/name.
    for (e.ctx.g.uses.items) |use| {
        if (std.mem.eql(u8, use.local_name, name)) return use.id;
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
    if (lookupModuleEntity(e, name)) |def| return def;
    return null;
}
/// Strip trait and generic decorations from an implementation/type name.
fn nominalName(name: []const u8) []const u8 {
    var out = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.lastIndexOf(u8, out, " for ")) |separator| {
        out = out[separator + 5 ..];
    }
    if (std.mem.indexOfScalar(u8, out, '<')) |generic_start| {
        out = out[0..generic_start];
    }
    return std.mem.trim(u8, out, " \t\r\n");
}

fn nominalNamesEqual(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, nominalName(lhs), nominalName(rhs));
}

/// Resolve the terminal entity of a type path used by an alias body.
fn resolveTypePath(e: *const Ext, path: types.Path) ?spine.EntityId {
    if (path.segments.len == 0) return null;
    const terminal = path.segments[path.segments.len - 1];
    if (terminal.id) |id| return id;
    return lookupModuleEntity(e, terminal.name);
}

/// Follow an imported binding to its resolved target entity.
fn resolveUseTarget(e: *const Ext, use_id: spine.EntityId) ?spine.EntityId {
    const use_ent = e.ctx.g.symbol_table.get(use_id) orelse return null;
    if (use_ent.resolved) |resolved| return resolved;
    for (e.ctx.g.uses.items) |use| {
        if (use.id != use_id) continue;
        return if (use.target != 0) use.target else null;
    }
    return null;
}

/// Return whether an entity can own inherent associated functions.
fn isNominalEntity(kind: spine.EntityKind) bool {
    return switch (kind) {
        .struct_, .enum_, .union_ => true,
        else => false,
    };
}

/// Resolve the nominal target of an alias or imported type binding.
fn resolveNominalTarget(e: *const Ext, entity_id: spine.EntityId) ?spine.EntityId {
    var current = entity_id;
    var hop_count: usize = 0;
    while (hop_count < e.ctx.g.symbol_table.entities.items.len) : (hop_count += 1) {
        const entity = e.ctx.g.symbol_table.get(current) orelse return null;
        if (isNominalEntity(entity.kind)) return current;
        switch (entity.kind) {
            .type_alias => {},
            .use_ => current = resolveUseTarget(e, current) orelse return null,
            else => return null,
        }
        if (entity.kind == .use_) continue;
        if (current >= e.ctx.bodies_list.items.len) return null;
        const target = switch (e.ctx.bodies_list.items[current]) {
            .type_alias => |alias| alias.target,
            else => return null,
        };
        current = switch (target) {
            .generic_inst => |generic| generic.decl,
            .path => |path| resolveTypePath(e, path) orelse return null,
            else => return null,
        };
    }
    return null;
}

/// Follow aliases or imported type bindings to their nominal method owner.
fn resolveAliasNominalType(e: *const Ext, entity_id: spine.EntityId) ?spine.EntityId {
    return resolveNominalTarget(e, entity_id);
}

/// Resolve an associated function on a nominal type or its implementation.
fn resolveTypeMethod(
    e: *const Ext,
    type_id: spine.EntityId,
    method: []const u8,
) ?spine.EntityId {
    const type_ent = e.ctx.g.symbol_table.get(type_id) orelse return null;
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind != .fn_) continue;
        if (!std.mem.eql(u8, ent.name, method)) continue;
        const parent = ent.parent orelse continue;
        if (parent == type_id) return ent.id;
        const parent_ent = e.ctx.g.symbol_table.get(parent) orelse continue;
        if (parent_ent.kind != .impl_) continue;
        if (parent_ent.parent == type_id) return ent.id;
        if (nominalNamesEqual(parent_ent.name, type_ent.name)) return ent.id;
    }
    return null;
}

/// Resolve `Self` for a function nested in an implementation block.
fn resolveSelfType(e: *const Ext) ?spine.EntityId {
    var current = e.ctx.g.symbol_table.get(e.fn_id).?.parent;
    while (current) |id| {
        const ent = e.ctx.g.symbol_table.get(id) orelse return null;
        switch (ent.kind) {
            .struct_, .enum_, .union_ => return ent.id,
            .impl_ => {
                if (ent.parent) |parent_id| {
                    if (e.ctx.g.symbol_table.get(parent_id)) |parent_ent| {
                        switch (parent_ent.kind) {
                            .struct_, .enum_, .union_ => return parent_ent.id,
                            else => {},
                        }
                    }
                }
                const type_name = nominalName(ent.name);
                if (lookupModuleEntity(e, type_name)) |type_id| {
                    if (e.ctx.g.symbol_table.get(type_id)) |type_ent| {
                        switch (type_ent.kind) {
                            .struct_, .enum_, .union_ => return type_id,
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
        current = ent.parent;
    }
    return null;
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
        } else if (std.mem.eql(u8, k, "value") or std.mem.eql(u8, k, "call_expression") or std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "integer_literal") or std.mem.eql(u8, k, "float_literal") or std.mem.eql(u8, k, "boolean_literal") or std.mem.eql(u8, k, "string_literal") or std.mem.eql(u8, k, "char_literal") or std.mem.eql(u8, k, "macro_invocation") or std.mem.eql(u8, k, "binary_expression") or std.mem.eql(u8, k, "array_expression") or std.mem.eql(u8, k, "struct_expression") or std.mem.eql(u8, k, "match_expression")) {
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
        } else if (std.mem.eql(u8, k, "macro_invocation")) {
            const eid = try lowerMacroInvocation(e, c);
            const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
            try e.ctx.stmts.append(e.ctx.alloc, .{ .id = sid, .span = span_of, .ty = null, .kind = .{ .expr = eid } });
            try stmt_ids.append(e.ctx.alloc, sid);
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

    // Macro invocation.
    if (std.mem.eql(u8, kind, "macro_invocation")) {
        return lowerMacroInvocation(e, node);
    }
    // Literals.
    if (std.mem.eql(u8, kind, "integer_literal")) {
        return lowerIntLit(e, node);
    }
    if (std.mem.eql(u8, kind, "float_literal")) {
        return lowerFloatLit(e, node);
    }
    if (std.mem.eql(u8, kind, "char_literal")) {
        return lowerCharLit(e, node);
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

    // Calls & construction.
    if (std.mem.eql(u8, kind, "call_expression")) {
        return lowerCall(e, node);
    }
    if (std.mem.eql(u8, kind, "struct_expression")) {
        return lowerStructExpr(e, node);
    }
    if (std.mem.eql(u8, kind, "match_expression")) {
        return lowerMatch(e, node);
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
        const operand = node.namedChild(0) orelse return unsupported(e, "unary operand");
        const operator_text = opOf(e, node);
        const operator: exprs.UnaryOp = if (std.mem.eql(u8, operator_text, "!"))
            .logical_not
        else if (std.mem.eql(u8, operator_text, "-"))
            .negate
        else
            return unsupported(e, "unary operator");
        return appendExpr(e, .{ .unary = .{
            .op = operator,
            .operand = try lowerExpr(e, operand),
        } });
    }
    if (std.mem.eql(u8, kind, "unit_expression")) {
        return appendExpr(e, .{ .unit = {} });
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

const int_suffixes = [_][]const u8{
    "i128",  "i64",   "i32", "i16", "i8",
    "u128",  "u64",   "u32", "u16", "u8",
    "isize", "usize",
};

const ParsedInt = struct {
    body: []const u8,
    base: u8,
    value: i128,
    suffix: []const u8,
};

fn parseIntText(raw: []const u8) ?ParsedInt {
    var body = raw;
    for (int_suffixes) |suffix| {
        if (raw.len > suffix.len and std.mem.endsWith(u8, raw, suffix)) {
            const prefix = raw[0 .. raw.len - suffix.len];
            if (prefix.len > 0 and (std.ascii.isDigit(prefix[prefix.len - 1]) or prefix[prefix.len - 1] == '_')) {
                body = prefix;
                break;
            }
        }
    }
    if (body.len == 0) return null;
    const base: u8 = if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X'))
        16
    else if (body.len > 2 and body[0] == '0' and (body[1] == 'b' or body[1] == 'B'))
        2
    else if (body.len > 2 and (body[0] == '0' and (body[1] == 'o' or body[1] == 'O')))
        8
    else
        10;
    const digits = if (base != 10) body[2..] else body;
    const value = std.fmt.parseInt(i128, digits, base) catch return null;
    return .{
        .body = body,
        .base = base,
        .value = value,
        .suffix = raw[body.len..],
    };
}

fn lowerIntLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    const parsed = parseIntText(t) orelse return unsupported(e, "integer literal out of range");
    const suffix = if (parsed.suffix.len == 0) null else try e.ctx.alloc.dupe(u8, parsed.suffix);
    return appendExpr(e, .{ .literal = .{ .int = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = parsed.value,
        .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
        .ty_suffix = suffix,
    } } });
}

fn lowerStrLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const raw = text(e, node);
    var s = raw;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return appendExpr(e, .{ .literal = .{ .string = .{ .bytes = try e.ctx.alloc.dupe(u8, s) } } });
}
fn lowerFloatLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    const value = std.fmt.parseFloat(f64, t) catch return unsupported(e, "invalid float literal");
    return appendExpr(e, .{ .literal = .{ .float = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = value,
    } } });
}

fn lowerCharLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    var val: u32 = 0;
    if (t.len >= 3 and t[0] == '\'' and t[t.len - 1] == '\'') {
        val = t[1];
    }
    return appendExpr(e, .{ .literal = .{ .character = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = val,
    } } });
}

fn lowerStructExpr(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    var name_node: ?ts.Node = null;
    var fields_node: ?ts.Node = null;

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "field_initializer_list")) {
            fields_node = c;
        } else if (name_node == null and !isComment(c)) {
            name_node = c;
        }
    }

    const n_node = name_node orelse return unsupported(e, "struct expression missing name");
    const raw_name = text(e, n_node);
    const last_colon = std.mem.lastIndexOfScalar(u8, raw_name, ':');
    var leaf_name = if (last_colon) |idx| raw_name[idx + 1 ..] else raw_name;
    if (std.mem.indexOfScalar(u8, leaf_name, '<')) |lt_idx| {
        leaf_name = leaf_name[0..lt_idx];
    }
    leaf_name = std.mem.trim(u8, leaf_name, " \t\r\n:");
    const def = resolveName(e, leaf_name) orelse (resolveName(e, raw_name) orelse return unsupported(e, "unresolved struct type"));

    var fields: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
    defer fields.deinit(e.ctx.alloc);

    var base_id: ?exprs.NodeId = null;

    if (fields_node) |fn_node| {
        var j: u32 = 0;
        while (fn_node.namedChild(j)) |c| : (j += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "field_initializer")) {
                var fname_node: ?ts.Node = null;
                var fval_node: ?ts.Node = null;
                var m: u32 = 0;
                while (c.namedChild(m)) |child| : (m += 1) {
                    const ck = child.kind();
                    if (std.mem.eql(u8, ck, "field_identifier") or std.mem.eql(u8, ck, "identifier")) {
                        if (fname_node == null) fname_node = child else if (fval_node == null) fval_node = child;
                    } else if (!isComment(child)) {
                        if (fval_node == null) fval_node = child;
                    }
                }
                const fnm = if (fname_node) |fnn| text(e, fnn) else "";
                if (fnm.len == 0) continue;
                if (fval_node) |fvn| {
                    const val_id = try lowerExpr(e, fvn);
                    try fields.append(e.ctx.alloc, .{
                        .field = try e.ctx.alloc.dupe(u8, fnm),
                        .value = val_id,
                        .shorthand = false,
                    });
                } else {
                    // Shorthand `Point { x }` -> PathExpr(x)
                    const var_def = resolveName(e, fnm) orelse try pushLocal(e, fnm);
                    const val_id = try appendExpr(e, .{ .path = .{ .def = var_def, .generic_args = &.{} } });
                    try fields.append(e.ctx.alloc, .{
                        .field = try e.ctx.alloc.dupe(u8, fnm),
                        .value = val_id,
                        .shorthand = true,
                    });
                }
            } else if (std.mem.eql(u8, k, "shorthand_field_initializer")) {
                const fnm = text(e, c);
                const var_def = resolveName(e, fnm) orelse try pushLocal(e, fnm);
                const val_id = try appendExpr(e, .{ .path = .{ .def = var_def, .generic_args = &.{} } });
                try fields.append(e.ctx.alloc, .{
                    .field = try e.ctx.alloc.dupe(u8, fnm),
                    .value = val_id,
                    .shorthand = true,
                });
            } else if (std.mem.eql(u8, k, "base_field_initializer")) {
                if (c.namedChild(0)) |bn| {
                    base_id = try lowerExpr(e, bn);
                }
            }
        }
    }

    return appendExpr(e, .{ .struct_lit = .{
        .def = def,
        .fields = try fields.toOwnedSlice(e.ctx.alloc),
        .base = base_id,
    } });
}

fn lowerFieldPattern(e: *Ext, node: ts.Node) anyerror!exprs.FieldPat {
    // `width` shorthand → `shorthand_field_identifier` child, pattern implied
    // by name. `x: ax` → `field_identifier` x + pattern `ax`.
    var fname: []const u8 = "";
    var fpat_node: ?ts.Node = null;
    var is_shorthand = false;

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "field_identifier")) {
            fname = text(e, c);
        } else if (std.mem.eql(u8, k, "shorthand_field_identifier")) {
            fname = text(e, c);
            is_shorthand = true;
        } else if (std.mem.eql(u8, k, "identifier")) {
            // `x: ax` — the nested pattern binding is an identifier.
            fpat_node = c;
        } else if (!isComment(c) and !std.mem.eql(u8, k, ":")) {
            fpat_node = c;
        }
    }

    if (fname.len == 0) {
        return .{ .field = "", .pat = try appendPat(e, .{ .wildcard = {} }), .shorthand = true };
    }

    if (fpat_node) |fpn| {
        const pid = try lowerPattern(e, fpn);
        return .{
            .field = try e.ctx.alloc.dupe(u8, fname),
            .pat = pid,
            .shorthand = false,
        };
    }

    // Shorthand `Point { width }` binds a local named `width`.
    _ = try pushLocal(e, fname);
    const pid = try appendPat(e, .{ .binding = .{
        .name = try e.ctx.alloc.dupe(u8, fname),
        .mode = .{ .value = {} },
        .mutable = false,
    } });
    return .{
        .field = try e.ctx.alloc.dupe(u8, fname),
        .pat = pid,
        .shorthand = true,
    };
}

fn lowerPattern(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const kind = node.kind();

    if (std.mem.eql(u8, kind, "wildcard_pattern") or std.mem.eql(u8, kind, "_")) {
        return appendPat(e, .{ .wildcard = {} });
    }

    if (std.mem.eql(u8, kind, "mut_pattern")) {
        var nm: []const u8 = "";
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "identifier")) nm = text(e, c);
        }
        _ = try pushLocal(e, nm);
        return appendPat(e, .{ .binding = .{
            .name = try e.ctx.alloc.dupe(u8, nm),
            .mode = .{ .value = {} },
            .mutable = true,
        } });
    }

    if (std.mem.eql(u8, kind, "identifier")) {
        const nm = text(e, node);
        if (resolveName(e, nm)) |def| {
            if (e.ctx.g.symbol_table.get(def)) |ent| {
                if (ent.kind == .variant or ent.kind == .const_) {
                    return appendPat(e, .{ .path = .{ .def = def, .variant = null } });
                }
            }
        }
        _ = try pushLocal(e, nm);
        return appendPat(e, .{ .binding = .{
            .name = try e.ctx.alloc.dupe(u8, nm),
            .mode = .{ .value = {} },
            .mutable = false,
        } });
    }

    if (std.mem.eql(u8, kind, "scoped_identifier") or std.mem.eql(u8, kind, "path")) {
        const t = text(e, node);
        const last = std.mem.lastIndexOfScalar(u8, t, ':');
        const leaf = if (last) |idx| t[idx + 1 ..] else t;
        const def = resolveName(e, leaf) orelse (resolveName(e, t) orelse try pushLocal(e, leaf));
        return appendPat(e, .{ .path = .{
            .def = def,
            .variant = try e.ctx.alloc.dupe(u8, leaf),
        } });
    }

    if (std.mem.eql(u8, kind, "tuple_pattern")) {
        var elems: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer elems.deinit(e.ctx.alloc);
        var has_rest = false;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "rest_pattern") or std.mem.eql(u8, c.kind(), "..")) {
                has_rest = true;
            } else if (!isComment(c)) {
                try elems.append(e.ctx.alloc, try lowerPattern(e, c));
            }
        }
        return appendPat(e, .{ .tuple = .{
            .elements = try elems.toOwnedSlice(e.ctx.alloc),
            .rest = has_rest,
        } });
    }

    if (std.mem.eql(u8, kind, "match_pattern")) {
        // `match_pattern` wraps the real pattern. A bare `_` has no named
        // children → wildcard. Otherwise lower the first named child.
        if (node.namedChildCount() == 0) return appendPat(e, .{ .wildcard = {} });
        return lowerPattern(e, node.namedChild(0).?);
    }

    if (std.mem.eql(u8, kind, "tuple_struct_pattern")) {
        var type_node: ?ts.Node = null;
        var pat_nodes: std.ArrayListUnmanaged(ts.Node) = .empty;
        defer pat_nodes.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (type_node == null and (std.mem.eql(u8, k, "scoped_identifier") or std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "scoped_type_identifier") or std.mem.eql(u8, k, "path"))) {
                type_node = c;
            } else if (!isComment(c) and !std.mem.eql(u8, k, "..")) {
                // Field patterns are direct children (e.g. `r` in `Circle(r)`).
                try pat_nodes.append(e.ctx.alloc, c);
            }
        }
        const raw_type = if (type_node) |tn| text(e, tn) else "";
        const last_colon = std.mem.lastIndexOfScalar(u8, raw_type, ':');
        const leaf = if (last_colon) |idx| raw_type[idx + 1 ..] else raw_type;
        const def = resolveName(e, leaf) orelse (resolveName(e, raw_type) orelse try pushLocal(e, leaf));

        var field_pats: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        defer field_pats.deinit(e.ctx.alloc);
        for (pat_nodes.items) |pnode| {
            const pid = try lowerPattern(e, pnode);
            const ptext = text(e, pnode);
            try field_pats.append(e.ctx.alloc, .{
                .field = try e.ctx.alloc.dupe(u8, ptext),
                .pat = pid,
                .shorthand = true,
            });
        }
        return appendPat(e, .{ .struct_pat = .{
            .def = def,
            .fields = try field_pats.toOwnedSlice(e.ctx.alloc),
            .rest = false,
        } });
    }

    if (std.mem.eql(u8, kind, "struct_pattern")) {
        var type_node: ?ts.Node = null;
        var fields_list_node: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (type_node == null and (std.mem.eql(u8, k, "scoped_identifier") or std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "scoped_type_identifier") or std.mem.eql(u8, k, "path"))) {
                type_node = c;
            } else if (std.mem.eql(u8, k, "field_pattern_list") or std.mem.eql(u8, k, "field_initializer_list")) {
                fields_list_node = c;
            }
        }
        const raw_type = if (type_node) |tn| text(e, tn) else "";
        const last_colon = std.mem.lastIndexOfScalar(u8, raw_type, ':');
        const leaf = if (last_colon) |idx| raw_type[idx + 1 ..] else raw_type;
        const def = resolveName(e, leaf) orelse (resolveName(e, raw_type) orelse try pushLocal(e, leaf));

        var field_pats: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        defer field_pats.deinit(e.ctx.alloc);
        var has_rest = false;

        // When the struct_pattern's field nodes are direct children (no
        // field_pattern_list wrapper), fold them in here.
        if (fields_list_node == null) {
            var j: u32 = 0;
            while (node.namedChild(j)) |c| : (j += 1) {
                if (type_node) |tn| {
                    if (c.id == tn.id) continue;
                }
                const k = c.kind();
                if (std.mem.eql(u8, k, "field_pattern")) {
                    const fpat = try lowerFieldPattern(e, c);
                    try field_pats.append(e.ctx.alloc, fpat);
                } else if (std.mem.eql(u8, k, "remaining_field_pattern") or std.mem.eql(u8, k, "..")) {
                    has_rest = true;
                }
            }
        } else if (fields_list_node) |fln| {
            var j: u32 = 0;
            while (fln.namedChild(j)) |c| : (j += 1) {
                const k = c.kind();
                if (std.mem.eql(u8, k, "field_pattern")) {
                    try field_pats.append(e.ctx.alloc, try lowerFieldPattern(e, c));
                } else if (std.mem.eql(u8, k, "remaining_field_pattern") or std.mem.eql(u8, k, "..")) {
                    has_rest = true;
                }
            }
        }
        return appendPat(e, .{ .struct_pat = .{
            .def = def,
            .fields = try field_pats.toOwnedSlice(e.ctx.alloc),
            .rest = has_rest,
        } });
    }

    if (std.mem.eql(u8, kind, "or_pattern")) {
        var alts: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer alts.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (!isComment(c)) {
                try alts.append(e.ctx.alloc, try lowerPattern(e, c));
            }
        }
        return appendPat(e, .{ .@"or" = .{ .alternatives = try alts.toOwnedSlice(e.ctx.alloc) } });
    }

    if (std.mem.eql(u8, kind, "reference_pattern")) {
        if (node.namedChild(0)) |inner| {
            const pid = try lowerPattern(e, inner);
            return appendPat(e, .{ .reference = .{
                .mode = .{ .value = {} },
                .inner = pid,
            } });
        }
    }

    if (std.mem.eql(u8, kind, "integer_literal")) {
        const t = text(e, node);
        const parsed = parseIntText(t) orelse return appendPat(e, .{ .wildcard = {} });
        const suffix = if (parsed.suffix.len == 0) null else try e.ctx.alloc.dupe(u8, parsed.suffix);
        return appendPat(e, .{ .literal = .{ .int = .{
            .text = try e.ctx.alloc.dupe(u8, t),
            .value = parsed.value,
            .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
            .ty_suffix = suffix,
        } } });
    }

    if (std.mem.eql(u8, kind, "string_literal")) {
        const raw = text(e, node);
        var s = raw;
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
        return appendPat(e, .{ .literal = .{ .string = .{ .bytes = try e.ctx.alloc.dupe(u8, s) } } });
    }

    if (std.mem.eql(u8, kind, "boolean_literal")) {
        return appendPat(e, .{ .literal = .{ .boolean = std.mem.eql(u8, text(e, node), "true") } });
    }

    return appendPat(e, .{ .wildcard = {} });
}

fn lowerMatch(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    var val_node: ?ts.Node = null;
    var block_node: ?ts.Node = null;

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "match_block")) {
            block_node = c;
        } else if (val_node == null and !isComment(c)) {
            if (std.mem.eql(u8, k, "condition") or std.mem.eql(u8, k, "match_condition")) {
                if (c.namedChildCount() > 0) val_node = c.namedChild(0) else val_node = c;
            } else {
                val_node = c;
            }
        }
    }

    const scr_node = val_node orelse return unsupported(e, "match expression missing scrutinee");
    const scrutinee_id = try lowerExpr(e, scr_node);

    var arms: std.ArrayListUnmanaged(exprs.MatchArm) = .empty;
    defer arms.deinit(e.ctx.alloc);

    if (block_node) |bn| {
        var j: u32 = 0;
        while (bn.namedChild(j)) |c| : (j += 1) {
            if (!std.mem.eql(u8, c.kind(), "match_arm")) continue;

            // `match_arm` = `match_pattern` + body-expr. The `match_pattern`
            // node wraps the actual pattern; when a guard is present
            // (`n if n > 5`) the guard expression is a sibling of the pattern
            // inside `match_pattern`.
            var match_pattern: ?ts.Node = null;
            var body_node: ?ts.Node = null;

            var m: u32 = 0;
            while (c.namedChild(m)) |child| : (m += 1) {
                if (std.mem.eql(u8, child.kind(), "match_pattern")) {
                    match_pattern = child;
                } else if (body_node == null) {
                    body_node = child;
                }
            }

            const mp = match_pattern orelse continue;
            const bn_arm = body_node orelse continue;

            // Pattern node: first named child of `match_pattern`, or the
            // bare `_` wildcard token when the wrapper is empty.
            var pn: ts.Node = undefined;
            var has_pat = false;
            var guard_node: ?ts.Node = null;
            if (mp.namedChildCount() > 0) {
                pn = mp.namedChild(0).?;
                has_pat = true;
                if (mp.namedChildCount() > 1) guard_node = mp.namedChild(1);
            }

            var pat_ids: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
            defer pat_ids.deinit(e.ctx.alloc);

            if (has_pat) {
                if (std.mem.eql(u8, pn.kind(), "or_pattern")) {
                    // Collapse `a | b | c` into one entry per alternative.
                    var k: u32 = 0;
                    while (pn.namedChild(k)) |alt| : (k += 1) {
                        if (!isComment(alt) and !std.mem.eql(u8, alt.kind(), "|")) {
                            try pat_ids.append(e.ctx.alloc, try lowerPattern(e, alt));
                        }
                    }
                } else {
                    try pat_ids.append(e.ctx.alloc, try lowerPattern(e, pn));
                }
            } else {
                try pat_ids.append(e.ctx.alloc, try appendPat(e, .{ .wildcard = {} }));
            }

            var guard_id: ?exprs.NodeId = null;
            if (guard_node) |gn| {
                guard_id = try lowerExpr(e, gn);
            }

            const arm_body_id = try lowerExpr(e, bn_arm);

            try arms.append(e.ctx.alloc, .{
                .patterns = try pat_ids.toOwnedSlice(e.ctx.alloc),
                .guard = guard_id,
                .body = arm_body_id,
            });
        }
    }

    return appendExpr(e, .{ .match = .{
        .scrutinee = scrutinee_id,
        .arms = try arms.toOwnedSlice(e.ctx.alloc),
        .option_scrutinee = false,
    } });
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
    } else if (std.mem.eql(u8, callee.kind(), "scoped_identifier") or
        std.mem.eql(u8, callee.kind(), "scoped_type_identifier") or
        std.mem.eql(u8, callee.kind(), "path"))
    {
        const t = text(e, callee);
        const sep = std.mem.indexOf(u8, t, "::");
        if (sep == null) {
            cdef = resolveName(e, t);
        } else {
            const last = std.mem.lastIndexOfScalar(u8, t, ':') orelse
                return unsupported(e, "scoped call");
            const base_name = t[0..sep.?];
            const method_name = t[last + 1 ..];
            const base_id = if (std.mem.eql(u8, base_name, "Self"))
                resolveSelfType(e)
            else if (std.mem.eql(u8, base_name, "crate") or
                std.mem.eql(u8, base_name, "self") or
                std.mem.eql(u8, base_name, "super"))
                null
            else
                resolveName(e, base_name);
            if (base_id) |bid| {
                const base_ent = e.ctx.g.symbol_table.get(bid) orelse
                    return unsupported(e, "unresolved associated call");
                if (resolveAliasNominalType(e, bid)) |type_id| {
                    if (resolveTypeMethod(e, type_id, method_name)) |method_id| {
                        return appendExpr(e, .{ .call = .{
                            .call_kind = .{ .associated = method_id },
                            .args = try arg_list.toOwnedSlice(e.ctx.alloc),
                        } });
                    }
                    return unsupported(e, "unresolved associated call");
                }

                // A module-qualified call remains a free call. Imported
                // module bindings need the same treatment.
                const module_id = if (base_ent.kind == .use_)
                    resolveUseTarget(e, bid)
                else if (base_ent.kind == .module)
                    bid
                else
                    null;
                if (module_id) |mid| {
                    const module_ent = e.ctx.g.symbol_table.get(mid) orelse
                        return unsupported(e, "unresolved scoped module");
                    if (module_ent.kind != .module) {
                        return unsupported(e, "unresolved associated call");
                    }
                } else if (base_ent.kind != .module) {
                    return unsupported(e, "unresolved associated call");
                }
            } else if (std.mem.eql(u8, base_name, "Self") or
                (!std.mem.eql(u8, base_name, "crate") and
                    !std.mem.eql(u8, base_name, "self") and
                    !std.mem.eql(u8, base_name, "super")))
            {
                return unsupported(e, "unresolved associated call");
            }
            cdef = resolveName(e, method_name);
        }
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
            const block = try lowerBlock(e, en);
            else_branch = .{ .block = block };
        } else if (std.mem.eql(u8, enk, "if_expression")) {
            const chain = try lowerIf(e, en);
            else_branch = .{ .chain = chain };
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

fn parseAndLowerSubExpr(e: *Ext, arg_str: []const u8) anyerror!exprs.NodeId {
    const trimmed = std.mem.trim(u8, arg_str, " \t\r\n");
    if (trimmed.len == 0) return appendExpr(e, .{ .unit = {} });

    // Build a wrapper function string to parse the expression safely
    const prefix = "fn __macro_sub__() { ";
    const suffix = "; }";
    const wrapped = try std.fmt.allocPrint(e.ctx.alloc, "{s}{s}{s}", .{ prefix, trimmed, suffix });
    defer e.ctx.alloc.free(wrapped);

    const parser = ts.Parser.create();
    defer parser.destroy();
    if (parser.setLanguage(rust.language())) |_| {} else |_| {}
    const tree = parser.parseString(wrapped, null) orelse return unsupported(e, "failed to parse macro argument");
    defer tree.destroy();

    const root = tree.rootNode();
    const fn_node = root.namedChild(0) orelse return unsupported(e, "macro argument parse error");
    var block_node: ?ts.Node = null;
    var i: u32 = 0;
    while (fn_node.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "block")) {
            block_node = c;
            break;
        }
    }
    const blk = block_node orelse return unsupported(e, "macro argument block missing");
    const first_child = blk.namedChild(0) orelse return unsupported(e, "macro argument empty");

    var expr_node = first_child;
    if (std.mem.eql(u8, first_child.kind(), "expression_statement")) {
        expr_node = first_child.namedChild(0) orelse first_child;
    }

    const orig_src = e.ctx.src;
    e.ctx.src = wrapped;
    defer e.ctx.src = orig_src;

    return lowerExpr(e, expr_node);
}

fn lowerMacroInvocation(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    var mname_node: ?ts.Node = null;
    var token_tree_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "scoped_identifier")) {
            if (mname_node == null) mname_node = c;
        } else if (std.mem.eql(u8, k, "token_tree")) {
            token_tree_node = c;
        }
    }

    const mname = if (mname_node) |mn| text(e, mn) else return unsupported(e, "macro invocation missing name");
    const raw_tokens = if (token_tree_node) |tt| text(e, tt) else "";
    const kind = expand.identifyMacro(mname);

    switch (kind) {
        .panic, .todo, .unimplemented => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            const msg = try expand.expandPanicMessage(e.ctx.alloc, args);
            defer e.ctx.alloc.free(msg);
            const prefix = switch (kind) {
                .panic => "panic",
                .todo => "todo",
                .unimplemented => "unimplemented",
                else => unreachable,
            };
            const full_msg = if (msg.len > 0)
                try std.fmt.allocPrint(e.ctx.alloc, "{s}: {s}", .{ prefix, msg })
            else
                try std.fmt.allocPrint(e.ctx.alloc, "{s}", .{prefix});
            return unsupported(e, full_msg);
        },
        .unreachable_ => {
            return unsupported(e, "unreachable");
        },
        .assert_eq, .assert_ne => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            if (args.len >= 2) {
                const lhs = try parseAndLowerSubExpr(e, args[0]);
                const rhs = try parseAndLowerSubExpr(e, args[1]);
                const bop: exprs.BinaryOp = if (kind == .assert_eq) .eq else .ne;
                return appendExpr(e, .{ .binary = .{
                    .op = bop,
                    .overflow = .wrapping,
                    .lhs = lhs,
                    .rhs = rhs,
                } });
            }
            return unsupported(e, "assert_eq: expected at least 2 arguments");
        },
        .assert => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            if (args.len >= 1) {
                return parseAndLowerSubExpr(e, args[0]);
            }
            return unsupported(e, "assert: missing condition");
        },
        .vec => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            if (args.len == 0) {
                return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = try e.ctx.alloc.dupe(u8, &[_]u8{}) } } });
            }
            const bytes = try e.ctx.alloc.alloc(u8, args.len);
            var all_u8 = true;
            for (args, 0..) |arg, idx| {
                const trimmed = std.mem.trim(u8, arg, " \t\r\n");
                var base: u8 = 10;
                var slice = trimmed;
                if (slice.len > 2 and slice[0] == '0' and (slice[1] == 'x' or slice[1] == 'X')) {
                    base = 16;
                    slice = slice[2..];
                } else if (slice.len > 2 and slice[0] == '0' and (slice[1] == 'b' or slice[1] == 'B')) {
                    base = 2;
                    slice = slice[2..];
                } else if (slice.len > 2 and slice[0] == '0' and (slice[1] == 'o' or slice[1] == 'O')) {
                    base = 8;
                    slice = slice[2..];
                }
                if (std.fmt.parseInt(u8, slice, base)) |val| {
                    bytes[idx] = val;
                } else |_| {
                    all_u8 = false;
                    break;
                }
            }
            if (all_u8) {
                return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
            }
            e.ctx.alloc.free(bytes);
            return unsupported(e, "vec macro non-byte elements");
        },
        .println, .eprintln, .format => {
            return unsupported(e, try std.fmt.allocPrint(e.ctx.alloc, "macro {s}", .{@tagName(kind)}));
        },
        .custom => {
            return unsupported(e, try std.fmt.allocPrint(e.ctx.alloc, "macro {s}", .{mname}));
        },
    }
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
    if (parser.setLanguage(rust.language())) |_| {} else |_| {}
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
        ctx.bodies_list.items[fn_entity].fn_.body = body_expr;
        return true;
    }
    return false;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "lower built-in macro invocations in fn bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Root module entity (id 0).
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });
    // Fn entity (id 1).
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "check"),
        .span = span,
        .visibility = .public,
        .parent = 0,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });

    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    defer exprs_list.deinit(alloc);
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    defer stmts_list.deinit(alloc);
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    defer pats_list.deinit(alloc);
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    defer types_list.deinit(alloc);
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    defer bodies_list.deinit(alloc);
    try bodies_list.append(alloc, .none);
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    const src =
        \\fn check() {
        \\    assert!(true);
        \\    assert_eq!(1 + 1, 2);
        \\    assert_ne!(a, b);
        \\    panic!("boom");
        \\    unreachable!();
        \\    let v = vec![1, 2, 3];
        \\    let n = 0x1u64;
        \\}
    ;
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = 0,
    };
    const ok = try extractFunction(&ctx, 1);
    try std.testing.expect(ok);
    // The body must have been lowered to a real block expr (not left empty).
    try std.testing.expect(bodies_list.items[1].fn_.body > 0);

    var found_eq = false;
    var found_ne = false;
    var found_byte_array = false;
    var found_suffixed_u64 = false;
    var found_unsupported = false;
    for (exprs_list.items) |ex| {
        switch (ex.kind) {
            .binary => |b| {
                if (b.op == .eq) found_eq = true;
                if (b.op == .ne) found_ne = true;
            },
            .literal => |l| switch (l) {
                .byte_array => found_byte_array = true,
                .int => |int| found_suffixed_u64 = std.mem.eql(u8, int.ty_suffix orelse "", "u64"),
                else => {},
            },
            .unsupported => found_unsupported = true,
            else => {},
        }
    }
    try std.testing.expect(found_eq); // assert_eq! → .eq binary
    try std.testing.expect(found_ne); // assert_ne! → .ne binary
    try std.testing.expect(found_byte_array); // vec![1,2,3] → byte_array literal
    try std.testing.expect(found_suffixed_u64); // 0x1u64 preserves its authoritative suffix
    try std.testing.expect(found_unsupported); // panic!/unreachable!/unresolved → .unsupported
}

test "lower struct_expression to .struct_lit and match_expression to .match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Root module entity (id 0).
    _ = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = 0,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = &.{},
        .attributes = &.{},
    });

    // fn area (1), fn origin (2), struct Point (3), enum Shape (4).
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "area"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "origin"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .struct_, .name = try alloc.dupe(u8, "Point"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .enum_, .name = try alloc.dupe(u8, "Shape"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .variant, .name = try alloc.dupe(u8, "Circle"), .span = span, .visibility = .public, .parent = 4, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .variant, .name = try alloc.dupe(u8, "Rect"), .span = span, .visibility = .public, .parent = 4, .resolved = null, .renamed_to = null, .attributes = &.{} });

    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    defer exprs_list.deinit(alloc);
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    defer stmts_list.deinit(alloc);
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    defer pats_list.deinit(alloc);
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    defer types_list.deinit(alloc);
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    defer bodies_list.deinit(alloc);
    try bodies_list.append(alloc, .none);
    try bodies_list.append(alloc, .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .f64 }, .body = 0 } });
    try bodies_list.append(alloc, .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .f64 }, .body = 0 } });
    try bodies_list.append(alloc, .{ .struct_ = .{ .generic_params = &.{}, .layout = .named, .fields = &.{} } });
    try bodies_list.append(alloc, .{ .enum_ = .{
        .kind = .data,
        .variants = &.{
            .{ .name = "Circle", .fields = .{ .tuple = &.{.{ .prim = .f64 }} }, .discriminant = null },
            .{ .name = "Rect", .fields = .{ .named = &.{} }, .discriminant = null },
        },
        .repr_int = null,
        .non_exhaustive = false,
    } });

    const src =
        \\pub fn area(shape: Shape) -> f64 {
        \\    match shape {
        \\        Shape::Circle(r) => r * r * 3.14159,
        \\        Shape::Rect { width, height } => width * height,
        \\    }
        \\}
        \\pub fn origin() -> Point {
        \\    Point { x: 0, y: 0 }
        \\}
    ;
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = 0,
    };

    try std.testing.expect(try extractFunction(&ctx, 1)); // area
    try std.testing.expect(try extractFunction(&ctx, 2)); // origin

    var found_struct_lit = false;
    var found_match = false;
    var match_arm_count: usize = 0;
    var struct_pat_count: usize = 0;
    var found_float = false;
    var found_binding_r = false;
    for (exprs_list.items) |ex| {
        switch (ex.kind) {
            .struct_lit => |sl| {
                found_struct_lit = true;
                try std.testing.expectEqual(@as(exprs.DefId, 3), sl.def); // Point
                try std.testing.expectEqual(@as(usize, 2), sl.fields.len);
                try std.testing.expectEqualStrings("x", sl.fields[0].field);
                try std.testing.expectEqualStrings("y", sl.fields[1].field);
            },
            .match => |me| {
                found_match = true;
                try std.testing.expect(!me.option_scrutinee);
                match_arm_count = me.arms.len;
            },
            .literal => |l| {
                if (l == .float) found_float = true;
            },
            else => {},
        }
    }
    for (pats_list.items) |pt| {
        switch (pt.kind) {
            .struct_pat => |sp| {
                struct_pat_count += 1;
                const sp_ent = g.symbol_table.get(sp.def) orelse return error.UnexpectedMissing;
                if (sp_ent.kind != .variant) return error.UnexpectedNonVariant;
            },
            .binding => |bd| {
                if (std.mem.eql(u8, bd.name, "r")) found_binding_r = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_struct_lit); // Point { x: 0, y: 0 }
    try std.testing.expect(found_match); // match shape { ... }
    try std.testing.expectEqual(@as(usize, 2), match_arm_count);
    try std.testing.expectEqual(@as(usize, 2), struct_pat_count); // Circle + Rect
    try std.testing.expect(found_binding_r); // r bound by Circle(r)
    try std.testing.expect(found_float); // 3.14159 in the Circle arm body
}

test "lower associated constructor through a compatible type alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    const module_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fletcher_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try alloc.dupe(u8, "Fletcher"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const alias_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .type_alias,
        .name = try alloc.dupe(u8, "Fletcher16"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const impl_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .impl_,
        .name = try alloc.dupe(u8, "Fletcher<T>"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const new_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "new"),
        .span = span,
        .visibility = .public,
        .parent = impl_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const caller_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "make"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = module_id,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(spine.EntityId, &.{ fletcher_id, alias_id, caller_id }),
        .attributes = &.{},
    });

    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    defer exprs_list.deinit(alloc);
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    defer stmts_list.deinit(alloc);
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    defer pats_list.deinit(alloc);
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    defer types_list.deinit(alloc);
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    defer bodies_list.deinit(alloc);
    try bodies_list.append(alloc, .none);
    try bodies_list.append(alloc, .{ .struct_ = .{
        .generic_params = &.{"T"},
        .layout = .named,
        .fields = &.{},
    } });
    try bodies_list.append(alloc, .{ .type_alias = .{
        .target = .{ .generic_inst = .{
            .decl = fletcher_id,
            .args = .{ .params = &.{.{ .prim = .u16 }} },
        } },
    } });
    try bodies_list.append(alloc, .none);
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    const src =
        \\fn make() {
        \\    Missing::new();
        \\    Fletcher16::new()
        \\}
    ;
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = module_id,
    };
    try std.testing.expect(try extractFunction(&ctx, caller_id));

    const body = exprs_list.items[bodies_list.items[caller_id].fn_.body];
    try std.testing.expect(body.kind == .block);
    const call_id = body.kind.block.tail orelse return error.MissingTailExpression;
    switch (exprs_list.items[call_id].kind) {
        .call => |call| switch (call.call_kind) {
            .associated => |target| try std.testing.expectEqual(
                @as(exprs.DefId, new_id),
                target,
            ),
            else => return error.ExpectedAssociatedCall,
        },
        else => return error.ExpectedCall,
    }
    if (body.kind.block.statements.len == 0) return error.MissingUnsupportedStatement;
    const missing_stmt_id = body.kind.block.statements[0];
    const missing_expr_id = switch (stmts_list.items[missing_stmt_id].kind) {
        .expr => |expr_id| expr_id,
        else => return error.ExpectedUnsupportedCallStatement,
    };
    switch (exprs_list.items[missing_expr_id].kind) {
        .unsupported => {},
        else => return error.ExpectedUnsupportedCall,
    }

    var saw_unsupported = false;
    var saw_free_new = false;
    for (exprs_list.items) |expression| {
        switch (expression.kind) {
            .unsupported => saw_unsupported = true,
            .call => |call| switch (call.call_kind) {
                .free => |target| {
                    if (target == new_id) saw_free_new = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(saw_unsupported);
    try std.testing.expect(!saw_free_new);
}

test "refuse rejected numeric and unknown unary expressions while preserving unit and return controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    const module_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = try alloc.dupe(u8, ""),
        .span = span,
        .visibility = .public,
        .parent = null,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const function_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "check"),
        .span = span,
        .visibility = .public,
        .parent = module_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    _ = try g.addModule(.{
        .id = module_id,
        .kind = .root,
        .name = "",
        .parent = null,
        .source_path = null,
        .is_crate = true,
        .is_extern = false,
        .span = span,
        .items = try alloc.dupe(spine.EntityId, &.{function_id}),
        .attributes = &.{},
    });

    var exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty;
    defer exprs_list.deinit(alloc);
    var stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty;
    defer stmts_list.deinit(alloc);
    var pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty;
    defer pats_list.deinit(alloc);
    var types_list: std.ArrayListUnmanaged(types.Type) = .empty;
    defer types_list.deinit(alloc);
    var bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty;
    defer bodies_list.deinit(alloc);
    try bodies_list.append(alloc, .none);
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    const src =
        \\fn check() {
        \\    340282366920938463463374607431768211455u128;
        \\    1.25f32;
        \\    -7i32;
        \\    !false;
        \\    *1;
        \\    ();
        \\    return;
        \\}
    ;
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src = src,
        .mod_id = module_id,
    };
    try std.testing.expect(try extractFunction(&ctx, function_id));

    const body_id = bodies_list.items[function_id].fn_.body;
    const block = switch (exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedBlockExpression,
    };
    try std.testing.expectEqual(@as(usize, 7), block.statements.len);

    const numeric_reasons = [_][]const u8{
        "integer literal out of range",
        "invalid float literal",
    };
    for (block.statements[0..2], numeric_reasons) |statement_id, expected_reason| {
        const expression_id = switch (stmts_list.items[statement_id].kind) {
            .expr => |expression_id| expression_id,
            else => return error.ExpectedExpressionStatement,
        };
        switch (exprs_list.items[expression_id].kind) {
            .unsupported => |rejection| {
                try std.testing.expectEqualStrings(expected_reason, rejection.reason);
            },
            else => return error.ExpectedUnsupportedExpression,
        }
    }

    const expected_unary_ops = [_]std.meta.Tag(exprs.UnaryOp){
        .negate,
        .logical_not,
    };
    for (block.statements[2..4], expected_unary_ops) |statement_id, expected_op| {
        const expression_id = switch (stmts_list.items[statement_id].kind) {
            .expr => |expression_id| expression_id,
            else => return error.ExpectedExpressionStatement,
        };
        switch (exprs_list.items[expression_id].kind) {
            .unary => |unary| {
                try std.testing.expectEqual(expected_op, std.meta.activeTag(unary.op));
            },
            else => return error.ExpectedUnaryExpression,
        }
    }

    const unknown_unary_id = switch (stmts_list.items[block.statements[4]].kind) {
        .expr => |expression_id| expression_id,
        else => return error.ExpectedExpressionStatement,
    };
    switch (exprs_list.items[unknown_unary_id].kind) {
        .unsupported => |rejection| {
            try std.testing.expectEqualStrings("unary operator", rejection.reason);
        },
        else => return error.ExpectedUnsupportedUnary,
    }

    const unit_id = switch (stmts_list.items[block.statements[5]].kind) {
        .expr => |expression_id| expression_id,
        else => return error.ExpectedExpressionStatement,
    };
    try std.testing.expect(exprs_list.items[unit_id].kind == .unit);

    const return_id = switch (stmts_list.items[block.statements[6]].kind) {
        .expr => |expression_id| expression_id,
        else => return error.ExpectedExpressionStatement,
    };
    switch (exprs_list.items[return_id].kind) {
        .return_ => |return_expression| {
            try std.testing.expect(return_expression.value == null);
        },
        else => return error.ExpectedReturnExpression,
    }
}
