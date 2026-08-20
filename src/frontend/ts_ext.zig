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
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const types = ir.types;
const exprs = ir.exprs;
const graph = ir.graph;
const bodies = ir.bodies;
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
    /// The struct/enum/union entity this fn's impl block implements, when the
    /// enclosing fn is an associated method (`Self::method(...)` resolution).
    self_ty: ?spine.EntityId = null,
    locals: std.ArrayListUnmanaged(Local) = .empty,

    fn deinit(self: *Ext) void {
        self.locals.deinit(self.ctx.alloc);
        self.* = undefined;
    }
};

fn text(e: *const Ext, node: ts.Node) []const u8 {
    return e.ctx.src[node.startByte()..node.endByte()];
}

/// Resolve an associated / inherent method on a type: given a type entity id
/// (struct/enum/union), find the `.fn_` entity named `method` parented to it,
/// either directly or via an inherent `impl` block whose parent is the type.
fn resolveTypeMethod(e: *const Ext, type_id: spine.EntityId, method: []const u8) ?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind != .fn_) continue;
        if (!std.mem.eql(u8, ent.name, method)) continue;
        const parent = ent.parent orelse continue;
        if (parent == type_id) return ent.id;
        if (e.ctx.g.symbol_table.get(parent)) |p| {
            if (p.kind == .impl_ and p.parent == type_id) return ent.id;
        }
    }
    return null;
}
fn resolveNominalTypePath(
    e: *const Ext,
    alias_id: spine.EntityId,
    path: types.Path,
) ?spine.EntityId {
    if (path.segments.len == 0) return null;
    const terminal = path.segments[path.segments.len - 1];
    if (terminal.id) |id| return id;

    var current = owningModule(e, alias_id) orelse return null;
    var index: usize = 0;
    if (std.mem.eql(u8, path.segments[0].name, "crate")) {
        current = rootModuleEntity(e) orelse return null;
        index = 1;
    } else if (std.mem.eql(u8, path.segments[0].name, "self")) {
        index = 1;
    } else {
        while (index < path.segments.len and
            std.mem.eql(u8, path.segments[index].name, "super"))
        {
            current = parentModuleEntity(e, current) orelse return null;
            index += 1;
        }
    }
    if (index == path.segments.len) return null;

    while (index < path.segments.len) : (index += 1) {
        const segment = path.segments[index];
        const found = segment.id orelse resolveModuleItem(e, current, segment.name) orelse return null;
        if (index + 1 == path.segments.len) return found;
        const entity = e.ctx.g.symbol_table.get(found) orelse return null;
        if (entity.kind != .module) return null;
        current = found;
    }
    return null;
}

/// Follow a local type alias to the nominal declaration that owns its methods.
fn resolveAliasNominalType(e: *const Ext, alias_id: spine.EntityId) ?spine.EntityId {
    var current = alias_id;
    var hop_count: usize = 0;
    while (hop_count < e.ctx.bodies_list.items.len) : (hop_count += 1) {
        const entity = e.ctx.g.symbol_table.get(current) orelse return null;
        switch (entity.kind) {
            .struct_, .enum_, .union_ => return current,
            .type_alias => {},
            else => return null,
        }
        if (current >= e.ctx.bodies_list.items.len) return null;
        const target = switch (e.ctx.bodies_list.items[current]) {
            .type_alias => |alias| alias.target,
            else => return null,
        };
        current = switch (target) {
            .generic_inst => |generic| generic.decl,
            .path => |path| resolveNominalTypePath(e, current, path) orelse return null,
            else => return null,
        };
    }
    return null;
}

/// Resolve an enum variant entity id parented to `enum_id`.
fn resolveVariant(e: *const Ext, enum_id: spine.EntityId, variant: []const u8) ?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind != .variant) continue;
        if (!std.mem.eql(u8, ent.name, variant)) continue;
        if (ent.parent == enum_id) return ent.id;
    }
    return null;
}

/// Climb an fn entity's parent chain to its innermost owning type entity
/// (struct/enum/union via its inherent `impl` block), for `Self::method(...)`.
fn findSelfType(e: *const Ext, ent: spine.Entity) ?spine.EntityId {
    var cur = ent.parent;
    while (cur) |pid| {
        const p = e.ctx.g.symbol_table.get(pid) orelse return null;
        if (p.kind == .module) return null;
        if (p.kind == .struct_ or p.kind == .enum_ or p.kind == .union_) return pid;
        cur = p.parent;
    }
    return null;
}

/// Return the module entity that owns `start`, climbing through impl/type
/// entities when the current function is an associated item.
fn owningModule(e: *const Ext, start: spine.EntityId) ?spine.EntityId {
    var current: ?spine.EntityId = start;
    while (current) |id| {
        const ent = e.ctx.g.symbol_table.get(id) orelse return null;
        if (ent.kind == .module) return id;
        current = ent.parent;
    }
    return null;
}

/// Find the Module row for its symbol-table entity. Module ids are dense in the
/// module table, while symbol-table ids also include every item, so the two
/// indices must not be assumed to match.
fn moduleByEntity(e: *const Ext, module_id: spine.EntityId) ?graph.Module {
    const ent = e.ctx.g.symbol_table.get(module_id) orelse return null;
    for (e.ctx.g.modules.items) |mod| {
        if (mod.parent == ent.parent and std.mem.eql(u8, mod.name, ent.name)) return mod;
    }
    return null;
}

fn rootModuleEntity(e: *const Ext) ?spine.EntityId {
    for (e.ctx.g.modules.items) |mod| {
        if (!mod.is_crate) continue;
        for (e.ctx.g.symbol_table.entities.items) |ent| {
            if (ent.kind != .module) continue;
            if (ent.parent == mod.parent and std.mem.eql(u8, ent.name, mod.name)) return ent.id;
        }
    }
    return null;
}

/// Resolve a use binding through its already-resolved target, or by walking
/// the binding's source path in the lexical module tree. The latter keeps
/// source-driven extraction correct when a graph was built without the names
/// pass (or when a use target was left unresolved).
fn resolveImportedEntity(e: *const Ext, use_id: spine.EntityId) ?spine.EntityId {
    const entity_count = e.ctx.g.symbol_table.entities.items.len;
    var current = use_id;
    var hop_count: usize = 0;
    while (hop_count < entity_count) : (hop_count += 1) {
        const entity = e.ctx.g.symbol_table.get(current) orelse return null;
        if (entity.kind != .use_) return current;

        if (entity.resolved) |resolved| {
            current = resolved;
            continue;
        }
        if (e.ctx.g.useById(current)) |use_decl| {
            if (use_decl.target != 0) {
                current = use_decl.target;
                continue;
            }
        }

        const target = resolveUseSourcePath(e, current, hop_count + 1) orelse return null;
        if (target == current) return null;
        current = target;
    }
    return null;
}

/// Return the lexical parent of a module entity. Entity ids are not module-row
/// indices, so this deliberately follows the symbol-table parent edge.
fn parentModuleEntity(e: *const Ext, module_id: spine.EntityId) ?spine.EntityId {
    const module_ent = e.ctx.g.symbol_table.get(module_id) orelse return null;
    if (module_ent.kind != .module) return null;
    return module_ent.parent;
}

/// Resolve a use entity's source path relative to the module that contains it.
/// This is a bounded path walk: every intermediate segment must name a module,
/// and no crate-wide same-name fallback is permitted.
fn resolveUseSourcePath(
    e: *const Ext,
    use_id: spine.EntityId,
    depth: usize,
) ?spine.EntityId {
    if (depth >= e.ctx.g.symbol_table.entities.items.len) return null;
    const use_ent = e.ctx.g.symbol_table.get(use_id) orelse return null;
    if (use_ent.kind != .use_) return use_id;
    var raw = use_ent.name;
    if (std.mem.indexOf(u8, raw, " as ")) |alias_start| raw = raw[0..alias_start];
    raw = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.endsWith(u8, raw, "*")) {
        var end = raw.len - 1;
        while (end > 0 and (raw[end - 1] == ' ' or raw[end - 1] == '\t')) end -= 1;
        if (end >= 2 and raw[end - 1] == ':' and raw[end - 2] == ':') end -= 2;
        raw = std.mem.trim(u8, raw[0..end], " \t\r\n");
    }
    if (raw.len == 0) return null;

    var segments: [32][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, raw, "::");
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (count == segments.len) return null;
        segments[count] = trimmed;
        count += 1;
    }
    if (count == 0) return null;

    var current = use_ent.parent orelse return null;
    var index: usize = 0;
    if (std.mem.eql(u8, segments[0], "crate")) {
        current = rootModuleEntity(e) orelse return null;
        index = 1;
    } else if (std.mem.eql(u8, segments[0], "self")) {
        index = 1;
    } else {
        while (index < count and std.mem.eql(u8, segments[index], "super")) {
            current = parentModuleEntity(e, current) orelse return null;
            index += 1;
        }
    }
    if (index >= count) return current;

    while (index < count) : (index += 1) {
        const found = resolveModuleItem(e, current, segments[index]) orelse return null;
        if (index + 1 == count) {
            if (e.ctx.g.symbol_table.get(found) == null) return null;
            // Return aliases to the bounded outer walk so cycle detection is
            // not reset while following a re-export chain.
            return found;
        }
        const found_ent = e.ctx.g.symbol_table.get(found) orelse return null;
        if (found_ent.kind != .module) return null;
        current = found;
    }
    return null;
}

/// Resolve a name introduced by a module item, including a `use` alias.
fn resolveModuleItem(e: *const Ext, module_id: spine.EntityId, name: []const u8) ?spine.EntityId {
    const mod = moduleByEntity(e, module_id) orelse return null;
    for (mod.items) |item_id| {
        const ent = e.ctx.g.symbol_table.get(item_id) orelse continue;
        if (ent.kind == .use_) {
            const use_decl = e.ctx.g.useById(item_id) orelse continue;
            if (!std.mem.eql(u8, use_decl.local_name, name)) continue;
            return resolveImportedEntity(e, item_id);
        }
        if (std.mem.eql(u8, ent.name, name)) return item_id;
    }

    // A partially constructed graph can have a stale module item slice. Keep
    // the fallback constrained to entities owned by this exact module, and
    // resolve aliases by their binding name rather than their path spelling.
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.parent != module_id) continue;
        if (ent.kind == .use_) {
            const use_decl = e.ctx.g.useById(ent.id) orelse continue;
            if (std.mem.eql(u8, use_decl.local_name, name)) {
                return resolveImportedEntity(e, ent.id);
            }
        } else if (std.mem.eql(u8, ent.name, name)) {
            return ent.id;
        }
    }
    return null;
}

/// Resolve a member on `type_id`, including constants and methods in any
/// inherent or trait impl whose parent is that type.
fn resolveTypeMember(e: *const Ext, type_id: spine.EntityId, name: []const u8) ?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (!std.mem.eql(u8, ent.name, name)) continue;
        const parent = ent.parent orelse continue;
        if (parent == type_id) return ent.id;
        if (e.ctx.g.symbol_table.get(parent)) |p| {
            if (p.kind == .impl_ and p.parent == type_id) return ent.id;
        }
    }
    return null;
}

/// Resolve a relative path through module entities.
fn resolveModulePath(
    e: *const Ext,
    start: spine.EntityId,
    segments: []const []const u8,
) ?spine.EntityId {
    if (segments.len == 0) return null;
    var current = start;
    for (segments, 0..) |segment, index| {
        const found = resolveModuleItem(e, current, segment) orelse return null;
        if (index + 1 == segments.len) return found;
        const ent = e.ctx.g.symbol_table.get(found) orelse return null;
        if (ent.kind != .module) return null;
        current = found;
    }
    return null;
}

/// Resolve a scoped path string to its terminal entity.
fn resolveScopedPathText(e: *const Ext, raw: []const u8) ?spine.EntityId {
    var segments: [8][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, raw, "::");
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (count == segments.len) return null;
        segments[count] = segment;
        count += 1;
    }
    if (count == 0) return null;
    if (std.mem.eql(u8, segments[0], "Self")) {
        if (count == 1) return e.self_ty;
        if (count == 2) {
            if (e.self_ty) |type_id| {
                if (resolveTypeMember(e, type_id, segments[1])) |member| return member;
            }
        }
        return null;
    }

    const owner = owningModule(e, e.ctx.mod_id) orelse return null;
    var start = owner;
    var offset: usize = 0;
    if (std.mem.eql(u8, segments[0], "crate")) {
        start = rootModuleEntity(e) orelse return null;
        offset = 1;
    } else if (std.mem.eql(u8, segments[0], "self")) {
        offset = 1;
    } else {
        while (offset < count and std.mem.eql(u8, segments[offset], "super")) {
            start = parentModuleEntity(e, start) orelse return null;
            offset += 1;
        }
    }
    if (offset >= count) return null;
    return resolveModulePath(e, start, segments[offset..count]);
}

/// Resolve a CST scoped path to its terminal entity.
fn resolveScopedPath(e: *const Ext, node: ts.Node) ?spine.EntityId {
    return resolveScopedPathText(e, text(e, node));
}

/// Resolve a pattern path, including an enum variant under its exact owner.
fn resolvePatternPath(e: *const Ext, node: ts.Node) ?spine.EntityId {
    const raw = text(e, node);
    const separator = std.mem.lastIndexOf(u8, raw, "::");
    if (separator) |index| {
        const owner_path = raw[0..index];
        const variant_name = raw[index + 2 ..];
        if (owner_path.len != 0 and variant_name.len != 0) {
            if (resolveScopedPathText(e, owner_path)) |owner| {
                if (e.ctx.g.symbol_table.get(owner)) |owner_entity| {
                    if (owner_entity.kind == .enum_) {
                        if (resolveVariant(e, owner, variant_name)) |variant| return variant;
                    }
                }
            }
        }
    }
    return resolveScopedPath(e, node);
}

/// Resolve an identifier: local scope first, then the current module scope.
fn lookupModuleEntity(e: *const Ext, name: []const u8) ?spine.EntityId {
    const owner = owningModule(e, e.ctx.mod_id) orelse return null;
    return resolveModuleItem(e, owner, name);
}

fn resolveName(e: *const Ext, name: []const u8) ?spine.EntityId {
    var i = e.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, e.locals.items[i].name, name)) return e.locals.items[i].def;
    }
    if (lookupModuleEntity(e, name)) |def| return def;
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

fn isSliceTypeNode(node: ts.Node) bool {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "slice_type")) return true;
    if (!std.mem.eql(u8, kind, "array_type")) return false;

    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), ";")) return false;
    }
    return true;
}

// ── type lowering ───────────────────────────────────────────────────────────

/// Lower a tree-sitter type node to a wire `types.Type`. Handles primitives,
/// slices, arrays, references, named types (path / generic), and tuples.
/// Unsupported types → `.unsupported` (loud @panic marker, never a wrong type).
fn mapCstType(e: *const Ext, node: ts.Node) types.Type {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type")) {
        if (node.namedChildCount() > 0) return mapCstType(e, node.namedChild(0).?);
        return unsupportedCstType();
    }
    if (std.mem.eql(u8, kind, "primitive_type")) {
        const nm = text(e, node);
        if (std.mem.eql(u8, nm, "str")) {
            return cstSlice(e, .{ .prim = .u8 }, true);
        }
        const from = mapPrim(nm);
        if (from) |p| return .{ .prim = p };
        return unsupportedCstType();
    }
    if (std.mem.eql(u8, kind, "reference_type")) {
        // &[T] / &mut [T] / &str / &T / &mut T
        var mut = false;
        var inner: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "mutable_specifier")) {
                mut = true;
            } else if (!std.mem.eql(u8, k, "lifetime")) {
                if (inner == null) inner = c;
            }
        }
        if (inner) |inn| {
            if (isSliceTypeNode(inn)) {
                var elem: types.Type = .{ .prim = .unit };
                if (inn.namedChildCount() > 0) elem = mapCstType(e, inn.namedChild(0).?);
                return cstSlice(e, elem, !mut);
            }
            if (std.mem.eql(u8, inn.kind(), "primitive_type") and std.mem.eql(u8, text(e, inn), "str")) {
                return cstSlice(e, .{ .prim = .u8 }, !mut);
            }
            if (std.mem.eql(u8, inn.kind(), "array_type")) return mapCstType(e, inn);
            const r = e.ctx.alloc.create(types.Ref) catch return unsupportedCstType();
            r.* = .{ .mut = mut, .pointee = mapCstType(e, inn) };
            return .{ .reference = r };
        }
        return unsupportedCstType();
    }
    if (std.mem.eql(u8, kind, "slice_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChildCount() > 0) elem = mapCstType(e, node.namedChild(0).?);
        return cstSlice(e, elem, true);
    }
    if (std.mem.eql(u8, kind, "array_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChild(0)) |elem_node| elem = mapCstType(e, elem_node);
        if (isSliceTypeNode(node)) return cstSlice(e, elem, true);

        var len_lit: u32 = 0;
        if (node.namedChild(1)) |len_node| {
            if (std.mem.eql(u8, len_node.kind(), "integer_literal")) {
                len_lit = std.fmt.parseInt(u32, text(e, len_node), 10) catch 0;
            }
        }
        const a = e.ctx.alloc.create(types.Array) catch return unsupportedCstType();
        a.* = .{ .elem = elem, .len = .{ .literal = len_lit } };
        return .{ .array = a };
    }
    if (std.mem.eql(u8, kind, "generic_type") or std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "identifier") or std.mem.eql(u8, kind, "scoped_type_identifier")) {
        return mapCstNamedType(e, node);
    }
    if (std.mem.eql(u8, kind, "tuple_type") or std.mem.eql(u8, kind, "unit_type")) {
        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            tup.append(e.ctx.alloc, mapCstType(e, c)) catch return unsupportedCstType();
        }
        if (tup.items.len == 0) return .{ .prim = .unit };
        return .{ .tuple = tup.toOwnedSlice(e.ctx.alloc) catch return unsupportedCstType() };
    }
    if (node.namedChildCount() > 0) return mapCstType(e, node.namedChild(0).?);
    return unsupportedCstType();
}

fn cstSlice(e: *const Ext, elem: types.Type, const_: bool) types.Type {
    const s = e.ctx.alloc.create(types.Slice) catch return unsupportedCstType();
    s.* = .{ .const_ = const_, .elem = elem };
    return .{ .slice = s };
}

fn unsupportedCstType() types.Type {
    return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
}

/// Map a named (path) type — possibly generic — to the wire model.
fn mapCstNamedType(e: *const Ext, node: ts.Node) types.Type {
    var name: ?[]const u8 = null;
    var arg_nodes: [8]ts.Node = undefined;
    var arg_count: usize = 0;
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;

    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "identifier")) {
        name = text(e, node);
    } else {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "identifier")) {
                name = text(e, c);
            } else if (std.mem.eql(u8, k, "scoped_type_identifier")) {
                const sub = mapCstScopedSegments(e, c);
                for (sub) |seg| segs.append(e.ctx.alloc, seg) catch return unsupportedCstType();
            } else if (std.mem.eql(u8, k, "type_arguments") or std.mem.eql(u8, k, "generic_type")) {
                var j: u32 = 0;
                while (c.namedChild(j)) |a| : (j += 1) {
                    if (arg_count < arg_nodes.len) {
                        arg_nodes[arg_count] = a;
                        arg_count += 1;
                    }
                }
            }
        }
    }
    const nm = name orelse return unsupportedCstType();
    var args: []const types.Type = &.{};
    if (arg_count > 0) {
        const args_arr = e.ctx.alloc.alloc(types.Type, arg_count) catch return unsupportedCstType();
        for (arg_nodes[0..arg_count], 0..) |an, ai| args_arr[ai] = mapCstType(e, an);
        args = args_arr;
    }

    if (std.mem.eql(u8, nm, "Option") and args.len == 1) {
        const inner = e.ctx.alloc.create(types.Type) catch return unsupportedCstType();
        inner.* = args[0];
        return .{ .option = inner };
    }
    if (std.mem.eql(u8, nm, "Result") and args.len == 2) {
        const r = e.ctx.alloc.create(types.Result) catch return unsupportedCstType();
        r.* = .{ .ok = args[0], .err = args[1], .is_error_unionable = true };
        return .{ .result = r };
    }
    if (std.mem.eql(u8, nm, "Box") and args.len == 1) {
        const inner = e.ctx.alloc.create(types.Type) catch return unsupportedCstType();
        inner.* = args[0];
        return .{ .boxed = inner };
    }
    if (args.len > 0) {
        var base_def: spine.EntityId = 0;
        for (e.ctx.g.symbol_table.entities.items) |ent| {
            if (std.mem.eql(u8, ent.name, nm)) {
                base_def = ent.id;
                break;
            }
        }
        if (base_def == 0) {
            const new_id = dismiss(e, nm) catch 0;
            if (new_id == 0) return unsupportedCstType();
            base_def = new_id;
        }
        return .{ .generic_inst = .{ .decl = base_def, .args = .{ .params = args } } };
    }
    segs.append(e.ctx.alloc, .{ .name = nm, .id = null }) catch return unsupportedCstType();
    return .{ .path = .{ .segments = segs.toOwnedSlice(e.ctx.alloc) catch return unsupportedCstType() } };
}

fn mapCstScopedSegments(e: *const Ext, node: ts.Node) []const types.PathSegment {
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (std.mem.eql(u8, k, "scoped_identifier") or std.mem.eql(u8, k, "scoped_type_identifier")) {
            const sub = mapCstScopedSegments(e, c);
            segs.appendSlice(e.ctx.alloc, sub) catch return &.{};
        } else if (std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "type_identifier")) {
            segs.append(e.ctx.alloc, .{ .name = text(e, c), .id = null }) catch return &.{};
        }
    }
    return segs.toOwnedSlice(e.ctx.alloc) catch &.{};
}

/// Register a placeholder `.struct_` entity for an unresolved generic name and
/// return its id (0 on failure).
fn dismiss(e: *const Ext, nm: []const u8) !spine.EntityId {
    const id: spine.EntityId = @intCast(e.ctx.g.symbol_table.entities.items.len);
    _ = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .struct_,
        .name = try e.ctx.alloc.dupe(u8, nm),
        .span = span_of,
        .visibility = .public,
        .parent = e.ctx.mod_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    return id;
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

/// Lower a `let_declaration`: registers the binding(s) locally via
/// `lowerPattern` and appends a `let` statement.
fn lowerLet(e: *Ext, node: ts.Node) anyerror!void {
    var pat_node: ?ts.Node = null;
    var type_node: ?ts.Node = null;
    var init_node: ?ts.Node = null;
    var binding_mutable = false;

    var child_i: u32 = 0;
    while (node.child(child_i)) |child| : (child_i += 1) {
        if (std.mem.eql(u8, child.kind(), "mutable_specifier") or
            std.mem.eql(u8, text(e, child), "mut"))
        {
            binding_mutable = true;
            break;
        }
    }

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (pat_node == null and isPatternNode(c)) {
            pat_node = c;
        } else if (std.mem.eql(u8, k, "type") or
            std.mem.eql(u8, k, "primitive_type") or
            std.mem.eql(u8, k, "generic_type") or
            std.mem.eql(u8, k, "reference_type") or
            std.mem.eql(u8, k, "type_identifier") or
            std.mem.eql(u8, k, "array_type") or
            std.mem.eql(u8, k, "slice_type") or
            std.mem.eql(u8, k, "tuple_type"))
        {
            type_node = c;
        } else if (init_node == null and
            !std.mem.eql(u8, k, "mutable_specifier") and
            !std.mem.eql(u8, k, "let"))
        {
            init_node = c;
        }
    }
    if (init_node == null) init_node = node.childByFieldName("value");
    var ann: ?exprs.TypeId = null;
    if (type_node) |tn| {
        const t = mapCstType(e, tn);
        if (t != .unsupported) ann = try appendType(e, t);
    }

    var init_id: ?exprs.NodeId = null;
    if (init_node) |inn| init_id = try lowerExpr(e, inn);

    var pat_id: exprs.NodeId = 0;
    if (pat_node) |pn| {
        pat_id = try lowerPattern(e, pn);
        if (binding_mutable) {
            switch (e.ctx.pats.items[pat_id].kind) {
                .binding => |binding_value| {
                    var binding = binding_value;
                    binding.mutable = true;
                    e.ctx.pats.items[pat_id].kind = .{ .binding = binding };
                },
                else => {},
            }
        }
    } else {
        pat_id = try appendPat(e, .{ .wildcard = {} });
    }
    _ = try appendStmt(e, .{ .let = .{
        .pattern = pat_id,
        .init = init_id,
        .ty = ann,
    } });
}

fn isPatternNode(node: ts.Node) bool {
    const k = node.kind();
    return std.mem.eql(u8, k, "pattern") or
        std.mem.eql(u8, k, "identifier") or
        std.mem.eql(u8, k, "mut_pattern") or
        std.mem.eql(u8, k, "tuple_pattern") or
        std.mem.eql(u8, k, "struct_pattern") or
        std.mem.eql(u8, k, "tuple_struct_pattern") or
        std.mem.eql(u8, k, "reference_pattern") or
        std.mem.eql(u8, k, "wildcard_pattern") or
        std.mem.eql(u8, k, "or_pattern") or
        std.mem.eql(u8, k, "scoped_identifier") or
        std.mem.eql(u8, k, "slice_pattern") or
        std.mem.eql(u8, k, "literal_pattern");
}

/// Classification of a `for` iterable produced by `unwrapIterable`.
const UnwrappedIter = struct {
    kind: exprs.IterKind,
    /// Carrier iterator expression (slice for `.slice`, end bound for
    /// `.range`, base slice for `.enumerate`, primary zip iterator for
    /// `.multi`).
    eid: exprs.NodeId,
};

/// The method name of a `recv.method(...)` call node, or null.
fn methodNameOf(e: *Ext, node: ts.Node) ?[]const u8 {
    if (!std.mem.eql(u8, node.kind(), "call_expression")) return null;
    const callee = node.namedChild(0) orelse return null;
    if (!std.mem.eql(u8, callee.kind(), "field_expression")) return null;
    const method = callee.namedChild(1) orelse return null;
    return text(e, method);
}

/// The receiver (`recv`) of a `recv.method(...)` call node, or null.
fn receiverOf(node: ts.Node) ?ts.Node {
    if (!std.mem.eql(u8, node.kind(), "call_expression")) return null;
    const callee = node.namedChild(0) orelse return null;
    if (!std.mem.eql(u8, callee.kind(), "field_expression")) return null;
    return callee.namedChild(0);
}

/// The `arguments` child of a call node, or null.
fn argumentsOf(node: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "arguments")) return c;
    }
    return null;
}

/// Peel a range node (`a..b`, `a..=b`, `a..`) into its iterator classification.
/// Only `0..b` / `0..=b` are lowered (start must be the literal `0`); `..=b`
/// lowers to the inclusive bound `b+1` which the backend emits as `0..(b+1)`.
fn lowerRangeIter(e: *Ext, node: ts.Node) anyerror!UnwrappedIter {
    var start_n: ?ts.Node = null;
    var end_n: ?ts.Node = null;
    var inclusive = false;
    var saw_op = false;
    var i: u32 = 0;
    while (node.child(i)) |c| : (i += 1) {
        const t = text(e, c);
        if (std.mem.eql(u8, t, "..=")) {
            saw_op = true;
            inclusive = true;
        } else if (std.mem.eql(u8, t, "..")) {
            saw_op = true;
        } else if (c.isNamed()) {
            if (saw_op) end_n = c else start_n = c;
        }
    }
    if (start_n) |sn| {
        const st = std.mem.trim(u8, text(e, sn), " \t\r\n");
        if (!std.mem.eql(u8, st, "0")) return unsupportedIter(e, "range start");
    }
    if (end_n == null) return unsupportedIter(e, "range no end");
    var end_eid = try lowerExpr(e, end_n.?);
    if (inclusive) {
        const one = try appendExpr(e, .{ .literal = .{ .int = .{ .text = "1", .value = 1, .base = .dec, .ty_suffix = null } } });
        end_eid = try appendExpr(e, .{ .binary = .{ .op = .add, .overflow = .wrapping, .lhs = end_eid, .rhs = one } });
    }
    return .{ .kind = .{ .range = {} }, .eid = end_eid };
}

/// The iterator equivalent of `unsupported`: a `.slice` iterable whose carrier
/// is an `.unsupported` expr (renders as a loud `@panic`, never a wrong value).
fn unsupportedIter(e: *Ext, reason: []const u8) anyerror!UnwrappedIter {
    const eid = try unsupported(e, reason);
    return .{ .kind = .{ .slice = {} }, .eid = eid };
}

/// Classify a `for` iterable expression, peeling `.iter()`, `.iter_mut()`,
/// `.as_ref()` and detecting `.enumerate()` / `.zip()` / ranges.
fn unwrapIterable(e: *Ext, node: ts.Node) anyerror!UnwrappedIter {
    const k = node.kind();
    if (std.mem.eql(u8, k, "range_expression")) {
        return lowerRangeIter(e, node);
    }
    if (std.mem.eql(u8, k, "call_expression")) {
        if (methodNameOf(e, node)) |mname| {
            if (std.mem.eql(u8, mname, "enumerate")) {
                const recv = receiverOf(node) orelse return unsupportedIter(e, "enumerate receiver");
                const base = try unwrapIterable(e, recv);
                return .{ .kind = .{ .enumerate = {} }, .eid = base.eid };
            }
            if (std.mem.eql(u8, mname, "zip")) {
                const recv = receiverOf(node) orelse return unsupportedIter(e, "zip receiver");
                const base = try unwrapIterable(e, recv);
                const arg = firstArg(e, argumentsOf(node)) orelse return unsupportedIter(e, "zip arg");
                const other = try lowerExpr(e, arg);
                const ids = try e.ctx.alloc.alloc(exprs.NodeId, 2);
                ids[0] = base.eid;
                ids[1] = other;
                return .{ .kind = .{ .multi = ids }, .eid = base.eid };
            }
            if (std.mem.eql(u8, mname, "iter") or std.mem.eql(u8, mname, "iter_mut") or std.mem.eql(u8, mname, "as_ref") or std.mem.eql(u8, mname, "clone")) {
                const recv = receiverOf(node) orelse return unsupportedIter(e, "iter receiver");
                return unwrapIterable(e, recv);
            }
        }
    }
    const eid = try lowerExpr(e, node);
    return .{ .kind = .{ .slice = {} }, .eid = eid };
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
        if (isPatternNode(c)) {
            if (pat_node == null) pat_node = c;
        } else if (std.mem.eql(u8, k, "block")) {
            body_node = c;
        } else if (iter_node == null) {
            iter_node = c;
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

    // Lower the pattern first so every loop binding is in local scope before
    // the body is lowered (`lowerPattern` registers each binding via
    // `pushLocal`, including tuple and reference patterns).
    const pat_id = if (pat_node) |pn|
        try lowerPattern(e, pn)
    else
        try appendPat(e, .{ .wildcard = {} });

    const it = try unwrapIterable(e, iter_node orelse return unsupported(e, "for iterable"));
    const iter_eid = it.eid;
    const body_blk = try lowerBlock(e, body_node orelse return unsupported(e, "for body"));

    return appendExpr(e, .{ .for_ = .{
        .pattern = pat_id,
        .iterable = iter_eid,
        .body = body_blk,
        .iter_kind = it.kind,
    } });
}

fn isComment(node: ts.Node) bool {
    const k = node.kind();
    return std.mem.eql(u8, k, "line_comment") or std.mem.eql(u8, k, "block_comment");
}

/// Return whether a CST statement has an explicit trailing semicolon.
///
/// Tree-sitter may wrap a bare trailing control-flow expression (for example,
/// `if ... { ... } else { ... }`) in `expression_statement`. Use the source
/// terminator instead of the wrapper kind so the expression remains the block
/// tail when Rust omitted `;`, while an explicit expression statement remains
/// a statement.
fn isSemicolonTerminated(e: *const Ext, node: ts.Node) bool {
    const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
    return raw.len > 0 and raw[raw.len - 1] == ';';
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
                if (is_last and !isSemicolonTerminated(e, c)) {
                    // The grammar can wrap a bare final expression in an
                    // expression_statement node. Keep it as the block tail.
                    tail = eid;
                } else {
                    const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
                    try e.ctx.stmts.append(e.ctx.alloc, .{
                        .id = sid,
                        .span = span_of,
                        .ty = null,
                        .kind = .{ .expr = eid },
                    });
                    try stmt_ids.append(e.ctx.alloc, sid);
                }
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
        } else if (std.mem.eql(u8, k, "assignment_expression") or
            std.mem.eql(u8, k, "compound_assignment_expr"))
        {
            const eid = try lowerAssignmentExpression(e, c);
            const sid: exprs.NodeId = @intCast(e.ctx.stmts.items.len);
            try e.ctx.stmts.append(e.ctx.alloc, .{
                .id = sid,
                .span = span_of,
                .ty = null,
                .kind = .{ .expr = eid },
            });
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

fn lowerAssignmentExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const lhs = node.childByFieldName("left");
    const rhs = node.childByFieldName("right");
    if (lhs == null or rhs == null) return unsupported(e, "assignment operands");

    const op: exprs.AssignOp = if (std.mem.eql(u8, node.kind(), "assignment_expression"))
        .plain
    else
        mapAssignOp(opOf(e, node)) orelse return unsupported(e, "assignment operator");

    return appendExpr(e, .{ .assign = .{
        .target = try lowerExpr(e, lhs.?),
        .op = op,
        .value = try lowerExpr(e, rhs.?),
        .overflow = .wrapping,
    } });
}
fn lowerExpr(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const kind = node.kind();

    // `self` is a distinct tree-sitter node in field expressions, but it
    // resolves through the same local binding as an identifier.
    if (std.mem.eql(u8, kind, "self")) {
        if (resolveName(e, "self")) |def| {
            return appendExpr(e, .{ .path = .{ .def = def, .generic_args = &.{} } });
        }
        return unsupported(e, "unresolved self");
    }

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
    if (std.mem.eql(u8, kind, "char_literal") or std.mem.eql(u8, kind, "byte_literal")) {
        return lowerCharLit(e, node);
    }
    if (std.mem.eql(u8, kind, "string_literal") or
        std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "raw_string_literal"))
    {
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
        std.debug.print("unresolved identifier text={s}\n", .{nm});
        return unsupported(e, "unresolved identifier");
    }
    if (std.mem.eql(u8, kind, "scoped_identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier"))
    {
        if (resolveScopedPath(e, node)) |def| {
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
    if (std.mem.eql(u8, kind, "assignment_expression") or
        std.mem.eql(u8, kind, "compound_assignment_expr"))
    {
        return lowerAssignmentExpression(e, node);
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
        const cond = cond_node orelse return unsupported(e, "while cond");
        // `while let <pat> = <expr>` — the condition may be a `let_condition`
        // (or wrap one inside a generic `condition` / `let_chain`).
        var capture: ?exprs.NodeId = null;
        var val_node: ?ts.Node = null;
        if (std.mem.eql(u8, cond.kind(), "let_condition")) {
            const pl = try lowerWhileLet(e, cond);
            capture = pl.pattern;
            val_node = pl.value;
        } else if (std.mem.eql(u8, cond.kind(), "condition") and cond.namedChildCount() > 0) {
            const inner = cond.namedChild(0).?;
            if (std.mem.eql(u8, inner.kind(), "let_condition")) {
                const pl = try lowerWhileLet(e, inner);
                capture = pl.pattern;
                val_node = pl.value;
            }
        }
        const cond_expr = val_node orelse cond;
        const body = body_node orelse return unsupported(e, "while body");
        return appendExpr(e, .{ .while_ = .{
            .cond = try lowerExpr(e, cond_expr),
            .capture = capture,
            .body = try lowerBlock(e, body),
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
        const operand = if (node.namedChildCount() > 0)
            node.namedChild(node.namedChildCount() - 1)
        else
            null;
        if (operand == null) return appendExpr(e, .{ .unit = {} });
        const operator = opOf(e, node);
        const operand_id = try lowerExpr(e, operand.?);
        if (std.mem.eql(u8, operator, "!")) {
            return appendExpr(e, .{ .unary = .{ .op = .logical_not, .operand = operand_id } });
        }
        if (std.mem.eql(u8, operator, "-")) {
            return appendExpr(e, .{ .unary = .{ .op = .negate, .operand = operand_id } });
        }
        if (std.mem.eql(u8, operator, "*")) {
            return appendExpr(e, .{ .unary = .{ .op = .deref, .operand = operand_id } });
        }
        if (std.mem.eql(u8, operator, "&")) {
            return appendExpr(e, .{ .unary = .{ .op = .{ .ref = .shared }, .operand = operand_id } });
        }
        return operand_id;
    }
    if (std.mem.eql(u8, kind, "tuple_expression")) {
        var elements: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer elements.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (isComment(child)) continue;
            try elements.append(e.ctx.alloc, try lowerExpr(e, child));
        }
        if (elements.items.len == 0) return appendExpr(e, .{ .unit = {} });
        return appendExpr(e, .{ .array = .{
            .elements = try elements.toOwnedSlice(e.ctx.alloc),
            .repeat = null,
        } });
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
    const parsed = parseIntLiteral(t);
    return appendExpr(e, .{ .literal = .{ .int = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = parsed.value,
        .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
        .ty_suffix = parsed.ty_suffix,
    } } });
}

const ParsedIntLiteral = struct {
    body: []const u8,
    value: i128,
    base: u8,
    ty_suffix: ?[]const u8,
};

const int_suffixes = [_][]const u8{
    "i128",  "i64",   "i32", "i16", "i8",
    "u128",  "u64",   "u32", "u16", "u8",
    "isize", "usize",
};

fn parseIntLiteral(raw: []const u8) ParsedIntLiteral {
    var body = raw;
    var ty_suffix: ?[]const u8 = null;
    for (int_suffixes) |suffix| {
        if (body.len > suffix.len and std.mem.endsWith(u8, body, suffix)) {
            const prefix = body[0 .. body.len - suffix.len];
            if (prefix.len > 0) {
                const last = prefix[prefix.len - 1];
                if (std.ascii.isDigit(last) or last == '_') {
                    body = prefix;
                    ty_suffix = suffix;
                    break;
                }
            }
        }
    }

    var base: u8 = 10;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) base = 16;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'b' or body[1] == 'B')) base = 2;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'o' or body[1] == 'O')) base = 8;
    const digits = if (base == 10) body else body[2..];
    const value = std.fmt.parseInt(i128, digits, base) catch 0;
    return .{
        .body = body,
        .value = value,
        .base = base,
        .ty_suffix = ty_suffix,
    };
}

fn parseVecRepeatCount(raw: []const u8) ?usize {
    const trimmed_literal = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed_literal.len == 0) return null;

    var literal = trimmed_literal;
    if (std.mem.endsWith(u8, literal, "usize")) {
        const suffix_start = literal.len - "usize".len;
        if (suffix_start == 0) return null;
        literal = literal[0..suffix_start];
        if (literal.len == 0) return null;
        if (literal[literal.len - 1] == '_') {
            literal = literal[0 .. literal.len - 1];
            if (literal.len == 0) return null;
        }
    }

    var base: usize = 10;
    var digits = literal;
    var has_base_prefix = false;
    if (literal.len >= 2 and literal[0] == '0') {
        switch (literal[1]) {
            'x', 'X' => {
                base = 16;
                digits = literal[2..];
                has_base_prefix = true;
            },
            'o', 'O' => {
                base = 8;
                digits = literal[2..];
                has_base_prefix = true;
            },
            'b', 'B' => {
                base = 2;
                digits = literal[2..];
                has_base_prefix = true;
            },
            else => {},
        }
        if (has_base_prefix and digits.len > 0 and digits[0] == '_') {
            digits = digits[1..];
        }
    }
    if (digits.len == 0) return null;

    var value: usize = 0;
    var saw_digit = false;
    var previous_separator = false;
    for (digits, 0..) |character, index| {
        if (character == '_') {
            if (!saw_digit or previous_separator or index + 1 == digits.len) return null;
            previous_separator = true;
            continue;
        }

        const digit: usize = switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => return null,
        };
        if (digit >= base) return null;
        if (value > (std.math.maxInt(usize) - digit) / base) return null;
        value = value * base + digit;
        saw_digit = true;
        previous_separator = false;
    }

    if (!saw_digit or previous_separator) return null;
    return value;
}

fn hexDigit(value: u8) ?u8 {
    if (value >= '0' and value <= '9') return value - '0';
    if (value >= 'a' and value <= 'f') return value - 'a' + 10;
    if (value >= 'A' and value <= 'F') return value - 'A' + 10;
    return null;
}

fn decodeEscapedBytes(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) {
        const current = body[i];
        if (current != '\\') {
            try bytes.append(allocator, current);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) return error.InvalidLiteral;
        const escaped = body[i];
        switch (escaped) {
            'n' => try bytes.append(allocator, '\n'),
            'r' => try bytes.append(allocator, '\r'),
            't' => try bytes.append(allocator, '\t'),
            '0' => try bytes.append(allocator, 0),
            '\\' => try bytes.append(allocator, '\\'),
            '"' => try bytes.append(allocator, '"'),
            '\'' => try bytes.append(allocator, '\''),
            'x' => {
                if (i + 2 >= body.len) return error.InvalidLiteral;
                const high = hexDigit(body[i + 1]) orelse return error.InvalidLiteral;
                const low = hexDigit(body[i + 2]) orelse return error.InvalidLiteral;
                try bytes.append(allocator, high * 16 + low);
                i += 2;
            },
            '\n' => {},
            '\r' => {
                if (i + 1 < body.len and body[i + 1] == '\n') i += 1;
            },
            else => return error.InvalidLiteral,
        }
        i += 1;
    }
    return bytes.toOwnedSlice(allocator);
}

fn decodeRawBytes(allocator: std.mem.Allocator, raw: []const u8, prefix_len: usize) !?[]const u8 {
    var marker = prefix_len;
    var hash_count: usize = 0;
    while (marker < raw.len and raw[marker] == '#') : (marker += 1) {
        hash_count += 1;
    }
    if (marker >= raw.len or raw[marker] != '"') return null;
    const body_start = marker + 1;
    if (raw.len < body_start + hash_count + 1) return null;
    const close_start = raw.len - hash_count - 1;
    if (close_start < body_start or raw[close_start] != '"') return null;
    var i: usize = 0;
    while (i < hash_count) : (i += 1) {
        if (raw[close_start + 1 + i] != '#') return null;
    }
    return try allocator.dupe(u8, raw[body_start..close_start]);
}

/// Decode Rust byte strings (`b"..."`, `br#"..."#`) and byte characters.
/// A null result means that `raw` is not a byte literal.
fn decodeRustByteLiteral(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (std.mem.startsWith(u8, raw, "br")) return decodeRawBytes(allocator, raw, 2);
    if (!std.mem.startsWith(u8, raw, "b")) return null;
    const prefix_len: usize = 1;
    if (prefix_len >= raw.len) return null;

    const quote = raw[prefix_len];
    if (quote == '\'') {
        if (raw.len < prefix_len + 3 or raw[raw.len - 1] != '\'') return null;
        const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. raw.len - 1]);
        if (bytes.len == 1) return bytes;
        allocator.free(bytes);
        return null;
    }
    if (quote != '"' or raw.len < prefix_len + 2 or raw[raw.len - 1] != '"') return null;
    return try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. raw.len - 1]);
}

fn lowerStrLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const raw = text(e, node);
    const kind = node.kind();
    const is_byte = std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.startsWith(u8, raw, "b");
    const decoded = decodeRustByteLiteral(e.ctx.alloc, raw) catch return unsupported(e, "invalid byte literal");
    if (decoded) |bytes| {
        return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
    }
    if (is_byte) return unsupported(e, "invalid byte literal");
    var s = raw;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return appendExpr(e, .{ .literal = .{ .string = .{ .bytes = try e.ctx.alloc.dupe(u8, s) } } });
}
fn lowerFloatLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    const value = std.fmt.parseFloat(f64, t) catch 0.0;
    return appendExpr(e, .{ .literal = .{ .float = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = value,
    } } });
}

fn lowerCharLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    const is_byte = std.mem.eql(u8, node.kind(), "byte_literal") or
        std.mem.startsWith(u8, t, "b");
    const decoded = decodeRustByteLiteral(e.ctx.alloc, t) catch return unsupported(e, "invalid byte literal");
    if (decoded) |bytes| {
        return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
    }
    if (is_byte) return unsupported(e, "invalid byte literal");
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
    const def = if (last_colon != null)
        (resolveScopedPath(e, n_node) orelse return unsupported(e, "unresolved struct type"))
    else
        (resolveName(e, leaf_name) orelse return unsupported(e, "unresolved struct type"));

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

    // A generic `pattern` wrapper: unwrap when it simply wraps another
    // pattern, or handle an inline `mutable_specifier`+identifier binding.
    if (std.mem.eql(u8, kind, "pattern")) {
        var mut = false;
        var inner: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "mutable_specifier")) {
                mut = true;
            } else if (k.len > 0 and !std.mem.eql(u8, k, "let") and inner == null) {
                inner = c;
            }
        }
        if (inner) |inn| {
            if (std.mem.eql(u8, inn.kind(), "identifier")) {
                const nm = text(e, inn);
                _ = try pushLocal(e, nm);
                return appendPat(e, .{ .binding = .{
                    .name = try e.ctx.alloc.dupe(u8, nm),
                    .mode = .{ .value = {} },
                    .mutable = mut,
                } });
            }
            return lowerPattern(e, inn);
        }
        return appendPat(e, .{ .wildcard = {} });
    }

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
        const def = if (last != null)
            (resolvePatternPath(e, node) orelse 0)
        else
            (resolveName(e, leaf) orelse 0);
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
        var type_node: ?ts.Node = node.childByFieldName("type");
        var pat_nodes: std.ArrayListUnmanaged(ts.Node) = .empty;
        defer pat_nodes.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (type_node == null and
                (std.mem.eql(u8, k, "scoped_identifier") or
                    std.mem.eql(u8, k, "identifier") or
                    std.mem.eql(u8, k, "type_identifier") or
                    std.mem.eql(u8, k, "scoped_type_identifier") or
                    std.mem.eql(u8, k, "path")))
            {
                type_node = c;
                continue;
            }
            if (type_node) |tn| {
                if (c.id == tn.id) continue;
            }
            if (!isComment(c) and !std.mem.eql(u8, k, "..")) {
                // Field patterns are direct children (e.g. `r` in `Circle(r)`).
                try pat_nodes.append(e.ctx.alloc, c);
            }
        }
        const def: spine.EntityId = if (type_node) |tn| blk: {
            const raw_type = std.mem.trim(u8, text(e, tn), " \t\r\n");
            if (raw_type.len == 0) break :blk 0;
            const last_colon = std.mem.lastIndexOfScalar(u8, raw_type, ':');
            if (last_colon != null) break :blk resolvePatternPath(e, tn) orelse 0;
            break :blk resolveName(e, raw_type) orelse 0;
        } else 0;

        var field_pats: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        defer field_pats.deinit(e.ctx.alloc);
        for (pat_nodes.items, 0..) |pnode, field_index| {
            const pid = try lowerPattern(e, pnode);
            try field_pats.append(e.ctx.alloc, .{
                .field = try std.fmt.allocPrint(e.ctx.alloc, "{d}", .{field_index}),
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
        const def = if (last_colon != null) blk: {
            if (type_node) |tn| break :blk resolvePatternPath(e, tn) orelse 0;
            break :blk 0;
        } else resolveName(e, leaf) orelse 0;
        var field_pats: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        defer field_pats.deinit(e.ctx.alloc);
        var has_rest = false;
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
        const parsed = parseIntLiteral(t);
        return appendPat(e, .{ .literal = .{ .int = .{
            .text = try e.ctx.alloc.dupe(u8, t),
            .value = parsed.value,
            .base = if (parsed.base == 16) .hex else if (parsed.base == 2) .bin else if (parsed.base == 8) .oct else .dec,
            .ty_suffix = parsed.ty_suffix,
        } } });
    }

    if (std.mem.eql(u8, kind, "string_literal") or
        std.mem.eql(u8, kind, "byte_string_literal") or
        std.mem.eql(u8, kind, "byte_literal") or
        std.mem.eql(u8, kind, "raw_string_literal"))
    {
        const raw = text(e, node);
        const is_byte = std.mem.eql(u8, kind, "byte_string_literal") or
            std.mem.eql(u8, kind, "byte_literal") or
            std.mem.startsWith(u8, raw, "b");
        const decoded = decodeRustByteLiteral(e.ctx.alloc, raw) catch
            return appendPat(e, .{ .wildcard = {} });
        if (decoded) |bytes| {
            return appendPat(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
        }
        if (is_byte) return appendPat(e, .{ .wildcard = {} });
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

fn lowerGenericCallArgs(e: *Ext, node: ts.Node) anyerror![]const types.Type {
    var args: std.ArrayListUnmanaged(types.Type) = .empty;
    var type_args_node: ?ts.Node = node.childByFieldName("type_arguments");
    if (type_args_node == null) {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), "type_arguments")) {
                type_args_node = child;
                break;
            }
        }
    }
    if (type_args_node) |type_args| {
        var i: u32 = 0;
        while (type_args.namedChild(i)) |arg| : (i += 1) {
            try args.append(e.ctx.alloc, mapCstType(e, arg));
        }
    }
    return args.toOwnedSlice(e.ctx.alloc);
}

fn appendGenericCall(
    e: *Ext,
    call_kind: exprs.CallKind,
    args: []const exprs.NodeId,
    generic_args: []const types.Type,
) anyerror!exprs.NodeId {
    const id = try appendExpr(e, .{ .call = .{
        .call_kind = call_kind,
        .args = args,
    } });
    if (generic_args.len > 0) {
        const owned_args = try e.ctx.alloc.dupe(types.Type, generic_args);
        errdefer e.ctx.alloc.free(owned_args);
        const type_id = try appendType(e, .{ .generic_inst = .{
            .decl = switch (call_kind) {
                .free => |def| def,
                .associated => |def| def,
                .constructor => |def| def,
            },
            .args = .{ .params = owned_args },
        } });
        e.ctx.exprs.items[id].ty = type_id;
    }
    return id;
}

fn lowerCall(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const callee = node.namedChild(0) orelse return appendExpr(e, .{ .unit = {} });
    var callee_base = callee;
    var generic_args: []const types.Type = &.{};
    if (std.mem.eql(u8, callee.kind(), "generic_function")) {
        if (callee.childByFieldName("function")) |function_node| {
            callee_base = function_node;
        } else {
            var child_index: u32 = 0;
            while (callee.namedChild(child_index)) |child| : (child_index += 1) {
                if (std.mem.eql(u8, child.kind(), "type_arguments")) continue;
                callee_base = child;
                break;
            }
        }
        generic_args = try lowerGenericCallArgs(e, callee);
    }
    defer if (generic_args.len > 0) e.ctx.alloc.free(generic_args);

    var args_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "arguments")) args_node = c;
    }

    // method call: recv.method(args)
    if (std.mem.eql(u8, callee_base.kind(), "field_expression")) {
        const recv = callee_base.namedChild(0) orelse return appendExpr(e, .{ .unit = {} });
        const method = callee_base.namedChild(1) orelse return appendExpr(e, .{ .unit = {} });
        const mname = text(e, method);
        // Rust `x.wrapping_mul(y)` → Zig `x *% y` (wrapping binary).
        if (std.mem.eql(u8, mname, "wrapping_mul") or
            std.mem.eql(u8, mname, "wrapping_add") or
            std.mem.eql(u8, mname, "wrapping_sub"))
        {
            const lhs = try lowerExpr(e, recv);
            const rhs = try lowerExpr(e, firstArg(e, args_node) orelse return unsupported(e, "wrapping arg"));
            const op: exprs.BinaryOp = if (std.mem.eql(u8, mname, "wrapping_mul"))
                .mul
            else if (std.mem.eql(u8, mname, "wrapping_add"))
                .add
            else
                .sub;
            return appendExpr(e, .{ .binary = .{
                .op = op,
                .overflow = .wrapping,
                .lhs = lhs,
                .rhs = rhs,
            } });
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

    // free / associated / enum-variant / constructor call
    var arg_list: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer arg_list.deinit(e.ctx.alloc);
    if (args_node) |an| {
        var j: u32 = 0;
        while (an.namedChild(j)) |a| : (j += 1) {
            try arg_list.append(e.ctx.alloc, try lowerExpr(e, a));
        }
    }
    const args = try arg_list.toOwnedSlice(e.ctx.alloc);

    if (std.mem.eql(u8, callee_base.kind(), "scoped_identifier")) {
        // Struct::method(...) / Enum::Variant(...) / Self::method(...) /
        // Type::constructor(...). Split the scoped path at "::".
        const t = text(e, callee_base);
        // Resolve the complete path before interpreting the first segment as
        // a type name. A path-qualified function is free, but a type-qualified
        // function must continue through the associated lookup below. This
        // distinction matters when a resolver can see a method through an
        // alias or re-export.
        if (resolveScopedPath(e, callee_base)) |path_def| {
            if (e.ctx.g.symbol_table.get(path_def)) |path_ent| {
                if (path_ent.kind == .fn_) {
                    const sep = std.mem.indexOf(u8, t, "::");
                    const base_name = if (sep) |idx| t[0..idx] else "";
                    const base_def = if (std.mem.eql(u8, base_name, "Self"))
                        e.self_ty
                    else if (base_name.len > 0)
                        resolveName(e, base_name)
                    else
                        null;
                    var is_type_qualified = false;
                    if (base_def) |bid| {
                        if (e.ctx.g.symbol_table.get(bid)) |base_ent| {
                            is_type_qualified = switch (base_ent.kind) {
                                .struct_, .enum_, .union_, .type_alias => true,
                                else => false,
                            };
                        }
                    }
                    if (!is_type_qualified) {
                        return appendGenericCall(e, .{ .free = path_def }, args, generic_args);
                    }
                }
            }
        }
        const sep = std.mem.indexOf(u8, t, "::") orelse return unsupported(e, "unresolved call");
        const base_name = t[0..sep];
        const leaf = t[sep + 2 ..];
        if (base_name.len == 0 or leaf.len == 0) return unsupported(e, "unresolved call");

        // Base type resolution: `Self` → the enclosing impl's type; else the
        // named module-scope type.
        var base_def: ?spine.EntityId = null;
        if (std.mem.eql(u8, base_name, "Self")) {
            base_def = e.self_ty;
        } else {
            base_def = resolveName(e, base_name);
        }

        if (base_def) |bid| {
            if (e.ctx.g.symbol_table.get(bid)) |base_ent| {
                var type_id = bid;
                if (base_ent.kind == .type_alias) {
                    type_id = resolveAliasNominalType(e, bid) orelse
                        return unsupported(e, "unresolved associated call");
                }
                if (e.ctx.g.symbol_table.get(type_id)) |type_ent| {
                    if (type_ent.kind == .enum_ and resolveVariant(e, type_id, leaf) != null) {
                        // Enum variant constructor: Shape::Circle(r)
                        return appendExpr(e, .{ .enum_variant = .{
                            .def = type_id,
                            .variant = try e.ctx.alloc.dupe(u8, leaf),
                            .tuple_fields = args,
                            .named_fields = &.{},
                        } });
                    }
                    if (type_ent.kind == .struct_ or
                        type_ent.kind == .union_ or
                        type_ent.kind == .enum_)
                    {
                        if (resolveTypeMethod(e, type_id, leaf)) |method_id| {
                            return appendGenericCall(
                                e,
                                .{ .associated = method_id },
                                args,
                                generic_args,
                            );
                        }
                    }
                }
                if (base_ent.kind == .type_alias) {
                    return unsupported(e, "unresolved associated call");
                }
            }
        }
        return unsupported(e, "unresolved call");
    }

    if (std.mem.eql(u8, callee_base.kind(), "identifier")) {
        const name = text(e, callee_base);
        if (resolveName(e, name)) |def| {
            // An identifier resolving to a type used directly as a
            // constructor: `Fletcher(...)` → constructor call on the type.
            if (e.ctx.g.symbol_table.get(def)) |ent| {
                if (ent.kind == .struct_ or ent.kind == .enum_ or ent.kind == .union_) {
                    return appendGenericCall(e, .{ .constructor = def }, args, generic_args);
                }
            }
            return appendGenericCall(e, .{ .free = def }, args, generic_args);
        }
        std.debug.print("unresolved call text={s}\n", .{text(e, node)});
        return unsupported(e, "unresolved call");
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

/// Result of lowering a `let_condition`: the pattern id and the scrutinee
/// expression node (lowered later with the rest of the condition).
const WhileLetPat = struct {
    pattern: exprs.NodeId,
    value: ?ts.Node,
};

/// Lower a `let_condition` (`while let <pat> = <expr>`).
///
/// The `let_condition` node has a pattern as its first named child followed by
/// the scrutinee expression (the `value` field).
fn lowerWhileLet(e: *Ext, node: ts.Node) anyerror!WhileLetPat {
    const pat_node = node.namedChild(0) orelse {
        _ = try unsupported(e, "while let pattern");
        return error.UnsupportedWhileLetPattern;
    };
    var val_node: ?ts.Node = null;
    var i: u32 = 1;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isComment(c) or std.mem.eql(u8, c.kind(), "=")) continue;
        if (val_node == null) val_node = c;
    }
    const pat_id = try lowerPattern(e, pat_node);
    // Register the pattern's bindings as locals so the loop body can resolve
    // them (e.g. `byte` in `while let Some(byte) = ...`).
    try registerPatternLocals(e, pat_node);
    return .{ .pattern = pat_id, .value = val_node };
}

/// Register every binding identifier in a tree-sitter pattern as a local
/// (mirrors how `let` / `for` register their pattern bindings).
fn registerPatternLocals(e: *Ext, node: ts.Node) anyerror!void {
    if (std.mem.eql(u8, node.kind(), "identifier")) {
        const nm = text(e, node);
        if (!std.mem.eql(u8, nm, "_")) _ = try pushLocal(e, nm);
        return;
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        try registerPatternLocals(e, c);
    }
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
    const cond_node = node.childByFieldName("condition");
    const then_node = node.childByFieldName("consequence");
    const cond_id = try lowerExpr(e, cond_node orelse return appendExpr(e, .{ .unit = {} }));
    const then_blk = try lowerBlock(e, then_node orelse return appendExpr(e, .{ .unit = {} }));

    var else_node = node.childByFieldName("alternative");
    if (else_node) |en| {
        if (std.mem.eql(u8, en.kind(), "else_clause")) {
            else_node = en.namedChild(0);
        }
    }
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

fn mapAssignOp(op: []const u8) ?exprs.AssignOp {
    if (op.len == 0) return null;
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
    return null;
}

fn unsupported(e: *Ext, reason: []const u8) anyerror!exprs.NodeId {
    std.debug.print("unsupported: {s}\n", .{reason});
    return appendExpr(e, .{ .unsupported = .{ .reason = reason, .suggested_version = .v3 } });
}

/// Preserve an assertion condition for the backend without treating the macro
/// itself as an unsupported expression. The condition remains a normal IR
/// expression (so type inference and diagnostics can inspect it); the marker
/// carries its node id to the Zig backend, which emits `std.debug.assert`.
fn lowerAssertionMarker(e: *Ext, condition: ?exprs.NodeId) anyerror!exprs.NodeId {
    const marker = if (condition) |id|
        try std.fmt.allocPrint(e.ctx.alloc, "assertion:{d}", .{id})
    else
        try e.ctx.alloc.dupe(u8, "assertion:none");
    return unsupported(e, marker);
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
    var kind = expand.identifyMacro(mname);
    // `debug_assert!` is a distinct Rust macro family, but it has the same
    // boolean condition shape as `assert!`/`assert_eq!`. Normalize its
    // basename here so the backend never sees it as an unsupported macro.
    var macro_base = mname;
    if (std.mem.lastIndexOf(u8, macro_base, "::")) |sep| {
        macro_base = macro_base[sep + 2 ..];
    }
    macro_base = std.mem.trim(u8, macro_base, " \t\r\n");
    if (std.mem.endsWith(u8, macro_base, "!")) {
        macro_base = macro_base[0 .. macro_base.len - 1];
    }
    if (std.mem.eql(u8, macro_base, "debug_assert")) {
        kind = .assert;
    } else if (std.mem.eql(u8, macro_base, "debug_assert_eq")) {
        kind = .assert_eq;
    } else if (std.mem.eql(u8, macro_base, "debug_assert_ne")) {
        kind = .assert_ne;
    }

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
                const condition = try appendExpr(e, .{ .binary = .{
                    .op = bop,
                    .overflow = .wrapping,
                    .lhs = lhs,
                    .rhs = rhs,
                } });
                return lowerAssertionMarker(e, condition);
            }
            // Keep malformed assertions compilable as a no-op assertion.
            return lowerAssertionMarker(e, null);
        },
        .assert => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            if (args.len >= 1) {
                const condition = try parseAndLowerSubExpr(e, args[0]);
                return lowerAssertionMarker(e, condition);
            }
            // Keep malformed assertions compilable as a no-op assertion.
            return lowerAssertionMarker(e, null);
        },
        .vec => {
            var invocation = expand.parseVecInvocation(e.ctx.alloc, raw_tokens) catch |err| switch (err) {
                error.MalformedVecInvocation => return unsupported(e, "vec macro malformed invocation"),
                else => return err,
            };
            defer invocation.deinit(e.ctx.alloc);

            switch (invocation) {
                .elements => |elements| {
                    const lowered = try e.ctx.alloc.alloc(exprs.NodeId, elements.len);
                    errdefer e.ctx.alloc.free(lowered);
                    for (elements, 0..) |element, index| {
                        lowered[index] = try parseAndLowerSubExpr(e, element);
                    }
                    return appendExpr(e, .{ .array = .{
                        .elements = lowered,
                        .repeat = null,
                    } });
                },
                .repeat => |repeat| {
                    const count = parseVecRepeatCount(repeat.count) orelse
                        return unsupported(e, "vec macro nonliteral repeat length");
                    const lowered = try e.ctx.alloc.alloc(exprs.NodeId, 1);
                    errdefer e.ctx.alloc.free(lowered);
                    lowered[0] = try parseAndLowerSubExpr(e, repeat.element);
                    return appendExpr(e, .{ .array = .{
                        .elements = lowered,
                        .repeat = count,
                    } });
                },
            }
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

/// Register every local binding introduced by a function parameter node
/// (`parameter`, `self_parameter`, or a plain `mut`/destructuring pattern) so
/// the body resolves references to them.
fn registerParamLocals(e: *Ext, node: ts.Node) anyerror!void {
    const k = node.kind();
    if (std.mem.eql(u8, k, "identifier")) {
        _ = try pushLocal(e, text(e, node));
    } else if (std.mem.eql(u8, k, "self_parameter")) {
        _ = try pushLocal(e, "self");
    } else {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try registerParamLocals(e, c);
        }
    }
}

fn ctxText(ctx: *const Ctx, node: ts.Node) []const u8 {
    return ctx.src[node.startByte()..node.endByte()];
}

fn isImplTypeNode(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "generic_type") or
        std.mem.eql(u8, kind, "primitive_type") or
        std.mem.eql(u8, kind, "scoped_type_identifier") or
        std.mem.eql(u8, kind, "type_path");
}

fn implTypeBase(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n&*");
    if (std.mem.startsWith(u8, value, "mut ")) value = value[4..];
    if (std.mem.indexOf(u8, value, "<")) |idx| value = value[0..idx];
    if (std.mem.lastIndexOf(u8, value, "::")) |idx| value = value[idx + 2 ..];
    return std.mem.trim(u8, value, " \t\r\n");
}

fn sameImplName(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, left, " \t\r\n"), std.mem.trim(u8, right, " \t\r\n"))) {
        return true;
    }
    return std.mem.eql(u8, implTypeBase(left), implTypeBase(right));
}

fn implNodeMatches(ctx: *const Ctx, node: ts.Node, wanted_name: []const u8) bool {
    var trait_node: ?ts.Node = node.childByFieldName("trait");
    var type_node: ?ts.Node = node.childByFieldName("type");

    if (trait_node == null or type_node == null) {
        var first_type: ?ts.Node = null;
        var second_type: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (!isImplTypeNode(child.kind())) continue;
            if (first_type == null) {
                first_type = child;
            } else if (second_type == null) {
                second_type = child;
            }
        }
        if (type_node == null) {
            if (trait_node == null and second_type != null) {
                trait_node = first_type;
                type_node = second_type;
            } else {
                type_node = second_type orelse first_type;
            }
        }
    }

    const type_text = if (type_node) |type_node_value| ctxText(ctx, type_node_value) else return false;
    const separator = std.mem.indexOf(u8, wanted_name, " for ");
    if (separator) |split| {
        const trait_text = if (trait_node) |trait| ctxText(ctx, trait) else return false;
        const wanted_trait = wanted_name[0..split];
        const wanted_type = wanted_name[split + 5 ..];
        return sameImplName(trait_text, wanted_trait) and
            sameImplName(type_text, wanted_type);
    }

    if (trait_node != null) return false;
    return sameImplName(type_text, wanted_name);
}

fn functionNodeName(ctx: *const Ctx, node: ts.Node) ?[]const u8 {
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "identifier")) return ctxText(ctx, child);
    }
    return null;
}

fn findFunctionNode(
    ctx: *const Ctx,
    node: ts.Node,
    wanted_name: []const u8,
    wanted_impl: ?[]const u8,
    enclosing_impl: ?ts.Node,
) ?ts.Node {
    var current_impl = enclosing_impl;
    if (std.mem.eql(u8, node.kind(), "impl_item")) current_impl = node;

    if (std.mem.eql(u8, node.kind(), "function_item")) {
        if (functionNodeName(ctx, node)) |name| {
            if (std.mem.eql(u8, name, wanted_name)) {
                if (wanted_impl) |impl_name| {
                    if (current_impl) |impl_node| {
                        if (implNodeMatches(ctx, impl_node, impl_name)) return node;
                    }
                } else if (current_impl == null) {
                    return node;
                }
            }
        }
    }

    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (findFunctionNode(ctx, child, wanted_name, wanted_impl, current_impl)) |found| {
            return found;
        }
    }
    return null;
}

fn updateStructMethodBody(ctx: *Ctx, ent: spine.Entity, body_id: exprs.NodeId) void {
    var current = ent.parent;
    while (current) |parent_id| {
        const parent = ctx.g.symbol_table.get(parent_id) orelse return;
        if (parent.kind == .struct_ or parent.kind == .enum_ or parent.kind == .union_) {
            if (parent_id >= ctx.bodies_list.items.len) return;
            switch (ctx.bodies_list.items[parent_id]) {
                .struct_ => |*struct_body| {
                    const methods = @constCast(struct_body.methods);
                    for (methods) |*method| {
                        if (std.mem.eql(u8, method.name, ent.name)) {
                            method.body = body_id;
                            return;
                        }
                    }
                },
                else => {},
            }
            return;
        }
        current = parent.parent;
    }
}

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
    var wanted_impl: ?[]const u8 = null;
    if (ent.parent) |parent_id| {
        if (ctx.g.symbol_table.get(parent_id)) |parent| {
            if (parent.kind == .impl_) wanted_impl = parent.name;
        }
    }
    const item = findFunctionNode(ctx, root, ent.name, wanted_impl, null) orelse return false;

    var block: ?ts.Node = null;
    var params_node: ?ts.Node = null;
    var i: u32 = 0;
    while (item.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "block")) block = child;
        if (std.mem.eql(u8, kind, "parameters")) params_node = child;
    }
    const blk_node = block orelse return false;

    var ex: Ext = .{ .ctx = ctx, .fn_id = fn_entity };
    ex.self_ty = findSelfType(&ex, ent);
    defer ex.deinit();

    // Register params as locals so the body resolves them. Handles
    // `self`, `mut x: T`, destructured patterns, and plain identifiers.
    if (params_node) |pn| {
        var p: u32 = 0;
        while (pn.namedChild(p)) |pnode| : (p += 1) {
            try registerParamLocals(&ex, pnode);
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
    updateStructMethodBody(ctx, ent, body_expr);
    return true;
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
        \\fn check(mut self) {
        \\    let mut x = 0;
        \\    x = 1;
        \\    x += 2;
        \\    x *= 3;
        \\    x ^= 4;
        \\    x &= 5;
        \\    x |= 6;
        \\    x -= 7;
        \\    self.0 = 8;
        \\    assert!(true);
        \\    assert_eq!(1 + 1, 2);
        \\    assert_ne!(a, b);
        \\    debug_assert!(x > 0);
        \\    debug_assert_eq!(rem, n % d);
        \\    panic!("boom");
        \\    unreachable!();
        \\    let v = vec![1, 2, 3];
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
    var found_array = false;
    var found_unsupported = false;
    var found_assert_marker = false;
    var found_debug_assert_ge = false;
    const expected_assign_ops = [_]exprs.AssignOp{
        .plain,
        .add,
        .mul,
        .bit_xor,
        .bit_and,
        .bit_or,
        .sub,
        .plain,
    };
    var assign_count: usize = 0;
    for (exprs_list.items) |ex| {
        switch (ex.kind) {
            .assign => |assignment| {
                try std.testing.expect(assign_count < expected_assign_ops.len);
                try std.testing.expectEqual(expected_assign_ops[assign_count], assignment.op);
                if (assign_count == expected_assign_ops.len - 1) {
                    const target = exprs_list.items[assignment.target];
                    try std.testing.expect(target.kind == .field);
                    try std.testing.expectEqualStrings("0", target.kind.field.field);
                }
                assign_count += 1;
            },
            .binary => |b| {
                if (b.op == .eq) found_eq = true;
                if (b.op == .ne) found_ne = true;
                if (b.op == .gt) found_debug_assert_ge = true;
            },
            .array => |array| {
                if (array.elements.len == 3 and array.repeat == null) found_array = true;
            },
            .unsupported => |u| {
                if (std.mem.startsWith(u8, u.reason, "assertion:")) {
                    found_assert_marker = true;
                } else {
                    found_unsupported = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(expected_assign_ops.len, assign_count);
    // The block statement table must reference every lowered assignment.
    var statement_assign_count: usize = 0;
    for (stmts_list.items) |statement| {
        if (statement.kind != .expr) continue;
        const expr_id = statement.kind.expr;
        if (expr_id >= exprs_list.items.len) continue;
        if (exprs_list.items[expr_id].kind == .assign) statement_assign_count += 1;
    }
    try std.testing.expectEqual(expected_assign_ops.len, statement_assign_count);
    try std.testing.expect(found_eq); // assert_eq! → .eq binary
    try std.testing.expect(found_ne); // assert_ne! → .ne binary
    try std.testing.expect(found_array); // vec![1,2,3] → non-repeated three-element array
    try std.testing.expect(found_assert_marker); // assert!/debug_assert! → assertion: marker
    try std.testing.expect(found_debug_assert_ge); // debug_assert!(x > 0) → .gt binary
    try std.testing.expect(found_unsupported); // panic!/unreachable!/unresolved → .unsupported
}

test "lower literal vec macro forms to arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    const root_id = try g.symbol_table.add(.{
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
        .id = root_id,
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
    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "build_vectors"),
        .span = span,
        .visibility = .private,
        .parent = root_id,
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

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src =
        \\fn build_vectors() {
        \\    let explicit = vec![1, (2, 3), 4];
        \\    let repeated = vec![0xff; 200_000];
        \\    let suffixed_decimal = vec![0xff; 1_usize];
        \\    let suffixed_hex = vec![0xff; 0x_FF_usize];
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = bodies_list.items[fn_id].fn_.body;
    const body = switch (exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 4), body.statements.len);

    const explicit_let = switch (stmts_list.items[body.statements[0]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedExplicitVecLet,
    };
    const explicit_binding = switch (pats_list.items[explicit_let.pattern].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedExplicitVecBinding,
    };
    try std.testing.expectEqualStrings("explicit", explicit_binding.name);
    const explicit_init_id = explicit_let.init orelse return error.ExpectedExplicitVecInitializer;
    const explicit_init = exprs_list.items[explicit_init_id].kind;
    try std.testing.expect(explicit_init == .array);
    try std.testing.expect(explicit_init != .unsupported);
    const explicit_array = switch (explicit_init) {
        .array => |array| array,
        else => return error.ExpectedExplicitVecArray,
    };
    try std.testing.expectEqual(@as(usize, 3), explicit_array.elements.len);
    try std.testing.expect(explicit_array.repeat == null);

    const repeated_let = switch (stmts_list.items[body.statements[1]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedRepeatedVecLet,
    };
    const repeated_binding = switch (pats_list.items[repeated_let.pattern].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedRepeatedVecBinding,
    };
    try std.testing.expectEqualStrings("repeated", repeated_binding.name);
    const repeated_init_id = repeated_let.init orelse return error.ExpectedRepeatedVecInitializer;
    const repeated_init = exprs_list.items[repeated_init_id].kind;
    try std.testing.expect(repeated_init == .array);
    try std.testing.expect(repeated_init != .unsupported);
    const repeated_array = switch (repeated_init) {
        .array => |array| array,
        else => return error.ExpectedRepeatedVecArray,
    };
    try std.testing.expectEqual(@as(usize, 1), repeated_array.elements.len);
    try std.testing.expectEqual(
        @as(usize, 200_000),
        repeated_array.repeat orelse return error.ExpectedRepeatedVecCount,
    );

    const suffixed_decimal_let = switch (stmts_list.items[body.statements[2]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedSuffixedDecimalVecLet,
    };
    const suffixed_decimal_binding = switch (pats_list.items[suffixed_decimal_let.pattern].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedSuffixedDecimalVecBinding,
    };
    try std.testing.expectEqualStrings("suffixed_decimal", suffixed_decimal_binding.name);
    const suffixed_decimal_init_id =
        suffixed_decimal_let.init orelse return error.ExpectedSuffixedDecimalVecInitializer;
    const suffixed_decimal_init = exprs_list.items[suffixed_decimal_init_id].kind;
    try std.testing.expect(suffixed_decimal_init == .array);
    try std.testing.expect(suffixed_decimal_init != .unsupported);
    const suffixed_decimal_array = switch (suffixed_decimal_init) {
        .array => |array| array,
        else => return error.ExpectedSuffixedDecimalVecArray,
    };
    try std.testing.expectEqual(@as(usize, 1), suffixed_decimal_array.elements.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        suffixed_decimal_array.repeat orelse return error.ExpectedSuffixedDecimalVecCount,
    );

    const suffixed_hex_let = switch (stmts_list.items[body.statements[3]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedSuffixedHexVecLet,
    };
    const suffixed_hex_binding = switch (pats_list.items[suffixed_hex_let.pattern].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedSuffixedHexVecBinding,
    };
    try std.testing.expectEqualStrings("suffixed_hex", suffixed_hex_binding.name);
    const suffixed_hex_init_id =
        suffixed_hex_let.init orelse return error.ExpectedSuffixedHexVecInitializer;
    const suffixed_hex_init = exprs_list.items[suffixed_hex_init_id].kind;
    try std.testing.expect(suffixed_hex_init == .array);
    try std.testing.expect(suffixed_hex_init != .unsupported);
    const suffixed_hex_array = switch (suffixed_hex_init) {
        .array => |array| array,
        else => return error.ExpectedSuffixedHexVecArray,
    };
    try std.testing.expectEqual(@as(usize, 1), suffixed_hex_array.elements.len);
    try std.testing.expectEqual(
        @as(usize, 255),
        suffixed_hex_array.repeat orelse return error.ExpectedSuffixedHexVecCount,
    );
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

test "lowerCall resolves associated, enum-variant, constructor, and free calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    const span: spine.Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 1 };

    // Root module (0).
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .module, .name = try alloc.dupe(u8, ""), .span = span, .visibility = .public, .parent = null, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.addModule(.{ .id = 0, .kind = .root, .name = "", .parent = null, .source_path = null, .is_crate = true, .is_extern = false, .span = span, .items = &.{}, .attributes = &.{} });

    // struct Fletcher (1), impl (2), methods new(3) value(4) update(5) mk(6),
    // enum Shape (7) variants Circle(8) Rect(9), free fns calc(10) reduce(11).
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .struct_, .name = try alloc.dupe(u8, "Fletcher"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .impl_, .name = try alloc.dupe(u8, "Fletcher"), .span = span, .visibility = .public, .parent = 1, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "new"), .span = span, .visibility = .public, .parent = 2, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "value"), .span = span, .visibility = .public, .parent = 2, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "update"), .span = span, .visibility = .public, .parent = 2, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "mk"), .span = span, .visibility = .public, .parent = 2, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .enum_, .name = try alloc.dupe(u8, "Shape"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .variant, .name = try alloc.dupe(u8, "Circle"), .span = span, .visibility = .public, .parent = 7, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .variant, .name = try alloc.dupe(u8, "Rect"), .span = span, .visibility = .public, .parent = 7, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "calc"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });
    _ = try g.symbol_table.add(.{ .id = 0, .kind = .fn_, .name = try alloc.dupe(u8, "reduce"), .span = span, .visibility = .public, .parent = 0, .resolved = null, .renamed_to = null, .attributes = &.{} });

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

    // Bodies parallel to symbol-table entities (same insertion order).
    for (g.symbol_table.entities.items) |en| {
        switch (en.kind) {
            .fn_ => try bodies_list.append(alloc, .{ .fn_ = .{ .params = &.{}, .ret = .{ .prim = .unit }, .body = 0 } }),
            .struct_ => try bodies_list.append(alloc, .{ .struct_ = .{ .generic_params = &.{}, .layout = .named, .fields = &.{} } }),
            .enum_ => try bodies_list.append(alloc, .{ .enum_ = .{
                .kind = .data,
                .variants = &.{
                    .{ .name = "Circle", .fields = .{ .tuple = &.{.{ .prim = .f64 }} }, .discriminant = null },
                    .{ .name = "Rect", .fields = .{ .tuple = &.{ .{ .prim = .f64 }, .{ .prim = .f64 } } }, .discriminant = null },
                },
                .repr_int = null,
                .non_exhaustive = false,
            } }),
            else => try bodies_list.append(alloc, .none),
        }
    }

    const src =
        \\pub struct Fletcher { a: u16, b: u16 }
        \\impl Fletcher {
        \\    pub fn mk() -> Fletcher {
        \\        Self::new(1, 2)
        \\    }
        \\}
        \\pub fn calc(x: u16) -> f64 {
        \\    let f = Fletcher::new(x, x);
        \\    let v = f.value();
        \\    let r = reduce(x + 1);
        \\    bogus();
        \\    Shape::Circle(1.5)
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

    // `mk`'s entity is a method inside the inherent `impl Fletcher` block, so
    // its owning type is Fletcher — the base for `Self::` resolution.
    const mk_ent = g.symbol_table.get(6).?;
    var mk_ext: Ext = .{ .ctx = &ctx, .fn_id = 6 };
    defer mk_ext.deinit();
    try std.testing.expectEqual(@as(spine.EntityId, 1), findSelfType(&mk_ext, mk_ent));

    // Lower the top-level free fn `calc`.
    try std.testing.expect(try extractFunction(&ctx, 10)); // calc

    var found_assoc_new = false;
    var found_free_reduce = false;
    var found_method_call = false;
    var found_enum_variant = false;
    var found_unresolved = false;

    for (exprs_list.items) |ex| {
        switch (ex.kind) {
            .call => |c| switch (c.call_kind) {
                .associated => |def| {
                    // Fletcher::new(...) -> def == method `new` (3).
                    // Self::new(...)  -> def == method `new` (3).
                    try std.testing.expectEqual(@as(exprs.DefId, 3), def);
                    found_assoc_new = true;
                },
                .free => |def| {
                    if (def == 11) found_free_reduce = true;
                },
                .constructor => {},
            },
            .method_call => found_method_call = true, // f.value()
            .enum_variant => |ev| {
                try std.testing.expectEqual(@as(exprs.DefId, 7), ev.def); // Shape
                try std.testing.expectEqualStrings("Circle", ev.variant);
                try std.testing.expectEqual(@as(usize, 1), ev.tuple_fields.len);
                found_enum_variant = true;
            },
            .unsupported => |u| {
                if (std.mem.eql(u8, u.reason, "unresolved call")) found_unresolved = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found_assoc_new); // Fletcher::new(...) -> .associated on `new`
    try std.testing.expect(found_free_reduce); // reduce(x + 1)
    try std.testing.expect(found_method_call); // f.value()
    try std.testing.expect(found_enum_variant); // Shape::Circle(1.5)
    try std.testing.expect(found_unresolved); // bogus() -> .unsupported("unresolved call")
}

test "lowerCall resolves associated constructor through generic type alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();
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
        .parent = fletcher_id,
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
        .items = &.{ fletcher_id, alias_id, caller_id },
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

    const body_expr = exprs_list.items[bodies_list.items[caller_id].fn_.body];
    try std.testing.expect(body_expr.kind == .block);
    const call_id = body_expr.kind.block.tail orelse return error.MissingTailExpression;
    const lowered = exprs_list.items[call_id];
    switch (lowered.kind) {
        .call => |call| switch (call.call_kind) {
            .associated => |target| try std.testing.expectEqual(
                @as(exprs.DefId, new_id),
                target,
            ),
            else => return error.ExpectedAssociatedCall,
        },
        else => return error.ExpectedCall,
    }
}

test "resolve scoped constants and forward calls within the owning module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    const add_module = struct {
        fn run(
            alloc_: std.mem.Allocator,
            graph_: *graph.CrateGraph,
            name: []const u8,
            parent: ?spine.EntityId,
            is_crate: bool,
        ) !spine.EntityId {
            const id = try graph_.symbol_table.add(.{
                .id = 0,
                .kind = .module,
                .name = try alloc_.dupe(u8, name),
                .span = span,
                .visibility = .public,
                .parent = parent,
                .resolved = null,
                .renamed_to = null,
                .attributes = &.{},
            });
            _ = try graph_.addModule(.{
                .id = id,
                .kind = if (is_crate) .root else .file,
                .name = try alloc_.dupe(u8, name),
                .parent = parent,
                .source_path = null,
                .is_crate = is_crate,
                .is_extern = false,
                .span = span,
                .items = &.{},
                .attributes = &.{},
            });
            return id;
        }
    }.run;

    const root_id = try add_module(alloc, &g, "", null, true);
    const local_mod_id = try add_module(alloc, &g, "local", root_id, false);
    const other_mod_id = try add_module(alloc, &g, "other", root_id, false);

    const add_entity = struct {
        fn run(
            alloc_: std.mem.Allocator,
            graph_: *graph.CrateGraph,
            kind: spine.EntityKind,
            name: []const u8,
            parent: ?spine.EntityId,
        ) !spine.EntityId {
            return graph_.symbol_table.add(.{
                .id = 0,
                .kind = kind,
                .name = try alloc_.dupe(u8, name),
                .span = span,
                .visibility = .public,
                .parent = parent,
                .resolved = null,
                .renamed_to = null,
                .attributes = &.{},
            });
        }
    }.run;

    // The unrelated declarations are inserted first to prove that resolution
    // does not use a global first-name match.
    const wrong_call_id = try add_entity(alloc, &g, .fn_, "wymix", other_mod_id);
    const right_call_id = try add_entity(alloc, &g, .fn_, "wymix", local_mod_id);
    const hasher_id = try add_entity(alloc, &g, .struct_, "Hasher", local_mod_id);
    const impl_id = try add_entity(alloc, &g, .impl_, "Hasher", hasher_id);
    const wrong_const_id = try add_entity(alloc, &g, .const_, "CONTINUATION_BIT", other_mod_id);
    const right_const_id = try add_entity(alloc, &g, .const_, "CONTINUATION_BIT", impl_id);
    const caller_id = try add_entity(alloc, &g, .fn_, "caller", impl_id);
    const local_items = try alloc.alloc(spine.EntityId, 3);
    local_items[0] = right_call_id;
    local_items[1] = hasher_id;
    local_items[2] = impl_id;
    g.modules.items[local_mod_id].items = local_items;
    const other_items = try alloc.alloc(spine.EntityId, 2);
    other_items[0] = wrong_call_id;
    other_items[1] = wrong_const_id;
    g.modules.items[other_mod_id].items = other_items;
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
    for (g.symbol_table.entities.items) |ent| {
        switch (ent.kind) {
            .fn_ => try bodies_list.append(alloc, .{ .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = .u64 },
                .body = 0,
            } }),
            .struct_ => try bodies_list.append(alloc, .{ .struct_ = .{
                .generic_params = &.{},
                .layout = .named,
                .fields = &.{},
            } }),
            .const_ => try bodies_list.append(alloc, .{ .const_ = .{
                .ty = .{ .prim = .u64 },
                .init = 0,
            } }),
            else => try bodies_list.append(alloc, .none),
        }
    }

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src =
        \\impl Hasher {
        \\fn caller() -> u64 {
        \\    Self::CONTINUATION_BIT;
        \\    wymix()
        \\}
        \\}
        ,
        .mod_id = local_mod_id,
    };
    try std.testing.expect(try extractFunction(&ctx, caller_id));

    var found_constant = false;
    var found_forward_call = false;
    for (exprs_list.items) |expression| {
        switch (expression.kind) {
            .path => |path| {
                if (path.def == right_const_id) found_constant = true;
            },
            .call => |call| switch (call.call_kind) {
                .free => |def| {
                    if (def == right_call_id) found_forward_call = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(found_constant);
    try std.testing.expect(found_forward_call);
}

test "preserve non-generic function body fidelity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();
    const span: spine.Span = .{
        .start_line = 1,
        .start_col = 1,
        .end_line = 1,
        .end_col = 1,
    };

    const root_id = try g.symbol_table.add(.{
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
        .id = root_id,
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
    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "preserve"),
        .span = span,
        .visibility = .private,
        .parent = root_id,
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
        .ret = .{ .tuple = &.{ .{ .prim = .u16 }, .{ .prim = .u8 } } },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &exprs_list,
        .stmts = &stmts_list,
        .pats = &pats_list,
        .types = &types_list,
        .bodies_list = &bodies_list,
        .src =
        \\fn preserve(flag: bool) -> (u16, u8) {
        \\    let mut count = 37u16;
        \\    let nul = b'\0';
        \\    let (left, right) = (count, nul);
        \\    if flag {
        \\        return (left, right);
        \\    } else {
        \\        return (count, nul);
        \\    }
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = bodies_list.items[fn_id].fn_.body;
    const body = switch (exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 3), body.statements.len);

    const count_let = switch (stmts_list.items[body.statements[0]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedCountLet,
    };
    const count_binding = switch (pats_list.items[count_let.pattern].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedCountBinding,
    };
    try std.testing.expectEqualStrings("count", count_binding.name);
    try std.testing.expect(count_binding.mutable);
    const count_init = count_let.init orelse return error.ExpectedCountInitializer;
    const count_literal = switch (exprs_list.items[count_init].kind) {
        .literal => |literal| switch (literal) {
            .int => |integer| integer,
            else => return error.ExpectedIntegerLiteral,
        },
        else => return error.ExpectedLiteralExpression,
    };
    try std.testing.expectEqual(@as(i128, 37), count_literal.value);
    try std.testing.expectEqualStrings(
        "u16",
        count_literal.ty_suffix orelse return error.ExpectedIntegerSuffix,
    );

    const nul_let = switch (stmts_list.items[body.statements[1]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedNulLet,
    };
    const nul_init = nul_let.init orelse return error.ExpectedNulInitializer;
    const nul_literal = switch (exprs_list.items[nul_init].kind) {
        .literal => |literal| switch (literal) {
            .byte_array => |byte_array| byte_array,
            else => return error.ExpectedByteLiteral,
        },
        else => return error.ExpectedLiteralExpression,
    };
    try std.testing.expectEqual(@as(usize, 1), nul_literal.items.len);
    try std.testing.expectEqual(@as(u8, 0), nul_literal.items[0]);

    const tuple_let = switch (stmts_list.items[body.statements[2]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedTupleLet,
    };
    const tuple_pattern = switch (pats_list.items[tuple_let.pattern].kind) {
        .tuple => |tuple| tuple,
        else => return error.ExpectedTuplePattern,
    };
    try std.testing.expectEqual(@as(usize, 2), tuple_pattern.elements.len);
    try std.testing.expect(!tuple_pattern.rest);
    const left_binding = switch (pats_list.items[tuple_pattern.elements[0]].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedLeftBinding,
    };
    const right_binding = switch (pats_list.items[tuple_pattern.elements[1]].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedRightBinding,
    };
    try std.testing.expectEqualStrings("left", left_binding.name);
    try std.testing.expectEqualStrings("right", right_binding.name);
    const tuple_init = tuple_let.init orelse return error.ExpectedTupleInitializer;
    try std.testing.expect(exprs_list.items[tuple_init].kind != .unsupported);

    const tail_id = body.tail orelse return error.ExpectedIfTail;
    const if_expr = switch (exprs_list.items[tail_id].kind) {
        .if_else => |if_else| if_else,
        else => return error.ExpectedIfExpression,
    };
    try std.testing.expect(exprs_list.items[if_expr.cond].kind == .path);
    try std.testing.expectEqual(@as(usize, 1), if_expr.then_.statements.len);
    try std.testing.expect(if_expr.then_.tail == null);
    const then_return_id = switch (stmts_list.items[if_expr.then_.statements[0]].kind) {
        .expr => |expr_id| expr_id,
        else => return error.ExpectedThenReturnStatement,
    };
    const then_return = switch (exprs_list.items[then_return_id].kind) {
        .return_ => |return_expr| return_expr,
        else => return error.ExpectedThenReturn,
    };
    const then_value = then_return.value orelse return error.ExpectedThenValue;
    const then_tuple = switch (exprs_list.items[then_value].kind) {
        .array => |tuple| tuple,
        else => return error.ExpectedThenTuple,
    };
    try std.testing.expectEqual(@as(usize, 2), then_tuple.elements.len);
    try std.testing.expect(exprs_list.items[then_value].kind != .unsupported);

    const else_block = switch (if_expr.@"else") {
        .block => |block| block,
        else => return error.ExpectedElseBlock,
    };
    try std.testing.expectEqual(@as(usize, 1), else_block.statements.len);
    try std.testing.expect(else_block.tail == null);
    const else_return_id = switch (stmts_list.items[else_block.statements[0]].kind) {
        .expr => |expr_id| expr_id,
        else => return error.ExpectedElseReturnStatement,
    };
    const else_return = switch (exprs_list.items[else_return_id].kind) {
        .return_ => |return_expr| return_expr,
        else => return error.ExpectedElseReturn,
    };
    const else_value = else_return.value orelse return error.ExpectedElseValue;
    const else_tuple = switch (exprs_list.items[else_value].kind) {
        .array => |tuple| tuple,
        else => return error.ExpectedElseTuple,
    };
    try std.testing.expectEqual(@as(usize, 2), else_tuple.elements.len);
    try std.testing.expect(exprs_list.items[else_value].kind != .unsupported);
}
