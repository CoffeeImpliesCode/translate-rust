//! ts_ext — tree-sitter CST → RustIr function-body extraction.
//!
//! The CST declaration pass supplies the crate symbol table. This module
//! lowers source function bodies into expression, statement, pattern, and
//! type tables for inference and method resolution.
//!
//! Parameters and local bindings become entities under their enclosing
//! function. Global names resolve against the crate's module-scope entities.
//!
//! Lossless-lowering contract: fn bodies are always lowered in full. An
//! unresolvable but syntactically valid sub-expression becomes a per-node
//! `.unsupported` expr (with a non-empty `.reason`) until the canonical
//! validator rejects it. Malformed CST, missing source matches, and missing
//! function blocks are fatal extraction errors; they never become silent
//! semantic defaults.

const std = @import("std");
const ir = @import("translate_rust.ir");
const spine = ir.spine;
const types = ir.types;
const exprs = ir.exprs;
const items = ir.items;
const graph = ir.graph;
const bodies = ir.bodies;
const expand = @import("expand.zig");
const infer = @import("infer.zig");
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
    ty: ?types.Type = null,
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

/// True when `type_id` is a local struct that carries a `next` method, which
/// is what makes a user type an `Iterator` that a chain can drive.
fn isUserIteratorType(e: *const Ext, type_id: spine.EntityId) bool {
    const entity = e.ctx.g.symbol_table.get(type_id) orelse return false;
    if (entity.kind != .struct_) return false;
    if (type_id >= e.ctx.bodies_list.items.len) return false;
    switch (e.ctx.bodies_list.items[type_id]) {
        .struct_ => |structure| {
            for (structure.methods) |method| {
                if (std.mem.eql(u8, method.name, "next")) return true;
            }
        },
        else => {},
    }
    return resolveTypeMethod(e, type_id, "next") != null;
}

/// Resolve a syntactic expression to the local struct type it denotes, for the
/// shapes a user `Iterator` is usually written in: a struct literal, a
/// `Type::method(..)` associated call, or a binding of that type.
fn userIteratorSourceType(e: *const Ext, node: ts.Node) ?spine.EntityId {
    const current = peelParenthesized(node);
    const kind = current.kind();
    if (std.mem.eql(u8, kind, "identifier")) {
        const def = resolveName(e, text(e, current)) orelse return null;
        const ty = localType(e, def) orelse return null;
        return switch (ty) {
            .path => |path| blk: {
                if (path.segments.len == 0) break :blk null;
                break :blk path.segments[path.segments.len - 1].id;
            },
            .@"opaque" => |opaque_type| blk: {
                const concrete = opaque_type.concrete orelse break :blk null;
                break :blk switch (concrete.*) {
                    .path => |path| if (path.segments.len == 0)
                        null
                    else
                        path.segments[path.segments.len - 1].id,
                    else => null,
                };
            },
            else => null,
        };
    }
    if (std.mem.eql(u8, kind, "struct_expression")) {
        const name_node = current.childByFieldName("name") orelse return null;
        return resolvePatternPath(e, name_node) orelse resolveName(e, text(e, name_node));
    }
    if (std.mem.eql(u8, kind, "call_expression")) {
        const callee = current.childByFieldName("function") orelse return null;
        const raw = text(e, callee);
        // `Type::new(..)` constructs a `Type`, so the prefix is the type and
        // not the method. Resolving the whole callee would yield the method.
        if (std.mem.lastIndexOf(u8, raw, "::")) |split| {
            return resolveName(e, raw[0..split]) orelse
                resolvePatternPath(e, callee);
        }
        return resolvePatternPath(e, callee) orelse resolveName(e, raw);
    }
    return null;
}

/// True when `node` is a value of a local struct type implementing `Iterator`.
fn isUserIteratorSource(e: *const Ext, node: ts.Node) bool {
    const type_id = userIteratorSourceType(e, node) orelse return false;
    return isUserIteratorType(e, type_id);
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
        if (entity.kind != .module and entity.kind != .extern_crate) return null;
        current = found;
    }
    return null;
}
fn isNominalEntityKind(kind: spine.EntityKind) bool {
    return switch (kind) {
        .struct_, .enum_, .union_, .trait_, .type_alias => true,
        else => false,
    };
}

fn bodyHasGenericParam(body: bodies.BodyKind, name: []const u8) bool {
    if (body == .impl_) {
        if (body.impl_.generics) |generics| {
            for (generics.params) |param| {
                if (param == .type_ and std.mem.eql(u8, param.type_.name, name)) return true;
            }
        }
        return false;
    }
    const params: []const []const u8 = switch (body) {
        .fn_ => |fn_body| fn_body.generic_params,
        .struct_ => |struct_body| struct_body.generic_params,
        .enum_ => |enum_body| enum_body.generic_params,
        .trait_ => |trait_body| trait_body.generic_params,
        else => &.{},
    };
    for (params) |param| {
        if (std.mem.eql(u8, param, name)) return true;
    }
    return false;
}

fn activeTypeParameter(e: *const Ext, name: []const u8) bool {
    var current: ?spine.EntityId = e.fn_id;
    var depth: usize = 0;
    while (current) |entity_id| : (depth += 1) {
        if (depth >= e.ctx.g.symbol_table.entities.items.len) return false;
        if (entity_id < e.ctx.bodies_list.items.len and
            bodyHasGenericParam(e.ctx.bodies_list.items[entity_id], name))
        {
            return true;
        }
        const entity = e.ctx.g.symbol_table.get(entity_id) orelse return false;
        current = entity.parent;
    }
    return false;
}

fn resolveCstTypePath(e: *const Ext, path: *types.Path) !spine.EntityId {
    if (path.segments.len == 0) return error.UnresolvedNominalType;
    if (std.mem.eql(u8, path.segments[0].name, "Self")) {
        if (path.segments.len != 1) return error.UnresolvedNominalType;
        const fn_entity = e.ctx.g.symbol_table.get(e.fn_id) orelse
            return error.UnresolvedNominalType;
        const self_id = findSelfType(e, fn_entity) orelse return error.UnresolvedNominalType;
        @constCast(path.segments)[0].id = self_id;
        return self_id;
    }
    const target = resolveNominalTypePath(e, e.fn_id, path.*) orelse
        return error.UnresolvedNominalType;
    const entity = e.ctx.g.symbol_table.get(target) orelse return error.UnresolvedNominalType;
    if (!isNominalEntityKind(entity.kind)) return error.InvalidNominalType;
    @constCast(path.segments)[path.segments.len - 1].id = target;
    return target;
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
        if (found_ent.kind != .module and found_ent.kind != .extern_crate) return null;
        current = found;
    }
    return null;
}

/// Resolve a name introduced by a module item, including a `use` alias.
fn resolveModuleItem(e: *const Ext, module_id: spine.EntityId, name: []const u8) ?spine.EntityId {
    var visited: std.ArrayListUnmanaged(spine.EntityId) = .empty;
    defer visited.deinit(e.ctx.alloc);
    return resolveModuleItemThroughGlobs(e, module_id, name, &visited);
}

/// Search a module's direct items first, then its resolved glob targets.
///
/// The visited path and entity-count bound make malformed glob cycles fail
/// closed without allowing one glob to shadow a direct declaration.
fn resolveModuleItemThroughGlobs(
    e: *const Ext,
    module_id: spine.EntityId,
    name: []const u8,
    visited: *std.ArrayListUnmanaged(spine.EntityId),
) ?spine.EntityId {
    const entity_count = e.ctx.g.symbol_table.entities.items.len;
    if (module_id >= entity_count) return null;
    if (visited.items.len >= entity_count) return null;
    for (visited.items) |seen| {
        if (seen == module_id) return null;
    }

    const previous_len = visited.items.len;
    visited.append(e.ctx.alloc, module_id) catch return null;
    defer visited.items.len = previous_len;

    if (moduleByEntity(e, module_id)) |mod| {
        for (mod.items) |item_id| {
            const ent = e.ctx.g.symbol_table.get(item_id) orelse continue;
            if (ent.kind == .use_) {
                const use_decl = e.ctx.g.useById(item_id) orelse continue;
                if (!std.mem.eql(u8, use_decl.local_name, name)) continue;
                return resolveImportedEntity(e, item_id);
            }
            if (std.mem.eql(u8, ent.name, name)) return item_id;
        }
    }

    // A partially constructed graph can have a stale module item slice. Keep
    // the fallback constrained to entities owned by this exact module.
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
    // A glob has no local binding name. Its target is the module whose
    // declarations become visible here. Check both the normal module slice and
    // the exact-parent fallback used for partially built graphs.
    if (moduleByEntity(e, module_id)) |mod| {
        for (mod.items) |item_id| {
            const ent = e.ctx.g.symbol_table.get(item_id) orelse continue;
            if (ent.kind != .use_) continue;
            const use_decl = e.ctx.g.useById(item_id) orelse continue;
            const target = switch (use_decl.kind) {
                .glob => use_decl.target,
                else => continue,
            };
            const target_ent = e.ctx.g.symbol_table.get(target) orelse continue;
            if (target_ent.kind != .module) continue;
            if (resolveModuleItemThroughGlobs(e, target, name, visited)) |found| {
                return found;
            }
        }
    }
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.parent != module_id or ent.kind != .use_) continue;
        const use_decl = e.ctx.g.useById(ent.id) orelse continue;
        const target = switch (use_decl.kind) {
            .glob => use_decl.target,
            else => continue,
        };
        const target_ent = e.ctx.g.symbol_table.get(target) orelse continue;
        if (target_ent.kind != .module) continue;
        if (resolveModuleItemThroughGlobs(e, target, name, visited)) |found| {
            return found;
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
    for (segments) |segment| {
        const owner = e.ctx.g.symbol_table.get(current) orelse return null;
        current = if (owner.kind == .module)
            resolveModuleItem(e, current, segment) orelse return null
        else blk: {
            const nominal = if (owner.kind == .type_alias)
                resolveAliasNominalType(e, current) orelse return null
            else
                current;
            break :blk resolveTypeMember(e, nominal, segment) orelse return null;
        };
    }
    return current;
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
        var owner: ?spine.EntityId = e.fn_id;
        while (owner) |id| {
            const entity = e.ctx.g.symbol_table.get(id) orelse return null;
            if (entity.kind == .impl_) {
                if (resolveModulePath(e, id, segments[1..count])) |member| return member;
                break;
            }
            if (entity.kind == .module) break;
            owner = entity.parent;
        }
        return resolveModulePath(e, e.self_ty orelse return null, segments[1..count]);
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

/// Resolve a nominal by lexical/module lookup, then by definition name.
///
/// The source extractor can see a re-exported enum before the names pass has
/// attached its use target. The bounded graph walk above is preferred; this
/// fallback keeps enum-variant patterns lossless in that intermediate state.
fn resolveNominalName(e: *const Ext, name: []const u8) ?spine.EntityId {
    const clean = std.mem.trim(u8, name, " \t\r\n");
    if (clean.len == 0) return null;
    if (resolveName(e, clean)) |candidate| {
        if (e.ctx.g.symbol_table.get(candidate)) |entity| {
            if (isNominalEntityKind(entity.kind)) return candidate;
        }
    }
    for (e.ctx.g.symbol_table.entities.items) |entity| {
        if (!isNominalEntityKind(entity.kind)) continue;
        if (std.mem.eql(u8, entity.name, clean)) return entity.id;
    }
    return null;
}

fn resolvePatternOwner(e: *const Ext, raw: []const u8) ?spine.EntityId {
    const clean = std.mem.trim(u8, raw, " \t\r\n");
    if (clean.len == 0) return null;
    if (resolveScopedPathText(e, clean)) |resolved| return resolved;
    if (resolveNominalName(e, clean)) |resolved| return resolved;
    if (std.mem.lastIndexOf(u8, clean, "::")) |separator| {
        return resolveNominalName(e, clean[separator + 2 ..]);
    }
    return null;
}

/// Resolve an enum variant path against the enum body table.
fn enumBodyHasVariant(e: *const Ext, enum_id: spine.EntityId, variant: []const u8) bool {
    if (@as(usize, enum_id) >= e.ctx.bodies_list.items.len) return false;
    return switch (e.ctx.bodies_list.items[@as(usize, enum_id)]) {
        .enum_ => |body| blk: {
            for (body.variants) |entry| {
                if (std.mem.eql(u8, entry.name, variant)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// True when `enum_id` declares `variant` as a unit variant. A unit variant is
/// a value in Rust, so a path naming one is a value expression rather than a
/// bare path to the enum type.
fn enumBodyHasUnitVariant(e: *const Ext, enum_id: spine.EntityId, variant: []const u8) bool {
    if (@as(usize, enum_id) >= e.ctx.bodies_list.items.len) return false;
    return switch (e.ctx.bodies_list.items[@as(usize, enum_id)]) {
        .enum_ => |body| blk: {
            for (body.variants) |entry| {
                if (entry.fields != .none) continue;
                if (std.mem.eql(u8, entry.name, variant)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// The enum a path owner names, seeing through `type` aliases.
fn pathOwnerEnum(e: *const Ext, owner: spine.EntityId) ?spine.EntityId {
    const owner_entity = e.ctx.g.symbol_table.get(owner) orelse return null;
    if (owner_entity.kind == .enum_) return owner;
    if (owner_entity.kind != .type_alias) return null;
    const target = resolveAliasNominalType(e, owner) orelse return null;
    const target_entity = e.ctx.g.symbol_table.get(target) orelse return null;
    return if (target_entity.kind == .enum_) target else null;
}

/// Lower a `Enum::Unit` path in value position to an `enum_variant` node.
///
/// The source extractor keeps variants in the enum body rather than the symbol
/// table, so `resolvePatternPath` can only hand back the owning enum. Without
/// this the variant identity is lost and the backend sees a type where a value
/// is required. Only unit variants qualify: a variant with a payload names a
/// constructor, which stays a path.
fn lowerUnitVariantPath(e: *Ext, node: ts.Node) anyerror!?exprs.NodeId {
    const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
    const separator = std.mem.lastIndexOf(u8, raw, "::") orelse return null;
    const owner_path = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const variant_name = std.mem.trim(u8, raw[separator + 2 ..], " \t\r\n");
    if (owner_path.len == 0 or variant_name.len == 0) return null;
    const owner = resolvePatternOwner(e, owner_path) orelse return null;
    const enum_id = pathOwnerEnum(e, owner) orelse return null;
    if (!enumBodyHasUnitVariant(e, enum_id, variant_name)) return null;
    const variant = try appendExpr(e, .{ .enum_variant = .{
        .def = enum_id,
        .variant = try e.ctx.alloc.dupe(u8, variant_name),
        .tuple_fields = &.{},
        .named_fields = &.{},
    } });
    return variant;
}

/// Resolve a pattern path, including an enum variant under its exact owner.
fn resolvePatternPath(e: *const Ext, node: ts.Node) ?spine.EntityId {
    const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
    const separator = std.mem.lastIndexOf(u8, raw, "::");
    if (separator) |index| {
        const owner_path = std.mem.trim(u8, raw[0..index], " \t\r\n");
        const variant_name = std.mem.trim(u8, raw[index + 2 ..], " \t\r\n");
        if (owner_path.len != 0 and variant_name.len != 0) {
            if (resolvePatternOwner(e, owner_path)) |owner| {
                if (e.ctx.g.symbol_table.get(owner)) |owner_entity| {
                    if (owner_entity.kind == .enum_) {
                        if (resolveVariant(e, owner, variant_name)) |variant| return variant;
                        return if (enumBodyHasVariant(e, owner, variant_name)) owner else null;
                    }
                }
            }
        }
    }
    return resolveScopedPathText(e, raw) orelse resolveNominalName(e, raw);
}

const QualifiedAssociatedPath = struct {
    receiver: ts.Node,
    trait: ts.Node,
    name: []const u8,
};

fn qualifiedAssociatedPath(e: *const Ext, node: ts.Node) ?QualifiedAssociatedPath {
    if (!std.mem.eql(u8, node.kind(), "scoped_identifier") and
        !std.mem.eql(u8, node.kind(), "scoped_type_identifier"))
    {
        return null;
    }
    const path = node.childByFieldName("path") orelse return null;
    var qualified: ?ts.Node = null;
    if (std.mem.eql(u8, path.kind(), "qualified_type")) {
        qualified = path;
    } else if (std.mem.eql(u8, path.kind(), "bracketed_type")) {
        var i: u32 = 0;
        while (path.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), "qualified_type")) {
                qualified = child;
                break;
            }
        }
    }
    const qualified_node = qualified orelse return null;
    return .{
        .receiver = qualified_node.childByFieldName("type") orelse return null,
        .trait = qualified_node.childByFieldName("alias") orelse
            qualified_node.childByFieldName("trait") orelse return null,
        .name = text(e, node.childByFieldName("name") orelse return null),
    };
}

/// True when `trait_id` declares a method called `name` in its own body. A
/// method a supertrait provides is not declared here, which is what makes the
/// declaring trait — not the bound that was written — the owner of the
/// reference `ensureTraitMethodRefEntity` mints.
fn traitDeclaresMethod(e: *const Ext, trait_id: spine.EntityId, name: []const u8) bool {
    if (trait_id >= e.ctx.bodies_list.items.len) return false;
    const trait_body = switch (e.ctx.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    for (trait_body.methods) |method| {
        if (std.mem.eql(u8, method.name, name)) return true;
    }
    return false;
}

fn ensureTraitMethodRefEntity(
    e: *Ext,
    trait_id: spine.EntityId,
    name: []const u8,
) anyerror!?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |entity| {
        if (entity.kind == .method_ref and entity.parent == trait_id and
            std.mem.eql(u8, entity.name, name))
        {
            return entity.id;
        }
    }
    if (!traitDeclaresMethod(e, trait_id, name)) return null;
    const id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = try e.ctx.alloc.dupe(u8, name),
        .span = span_of,
        .visibility = .public,
        .parent = trait_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    return id;
}

/// Trait named by Rust's explicit trait-qualified form, `<[u8; 6] as FromHex>`.
/// Only the trait is meaningful here: the bracketed self type is a coercion
/// target that names no entity, so resolution must go through the trait.
fn qualifiedTraitName(raw: []const u8) ?[]const u8 {
    const clean = std.mem.trim(u8, raw, " \t\r\n");
    if (clean.len < 3 or clean[0] != '<' or clean[clean.len - 1] != '>') return null;
    const inner = std.mem.trim(u8, clean[1 .. clean.len - 1], " \t\r\n");
    const separator = std.mem.lastIndexOf(u8, inner, " as ") orelse return null;
    const trait_name = std.mem.trim(u8, inner[separator + 4 ..], " \t\r\n");
    if (trait_name.len == 0) return null;
    return trait_name;
}

/// Concrete method entity behind `<[u8; 6] as FromHex>::from_hex`.
///
/// The explicit self type names exactly one impl, so the call binds straight to
/// that impl's method. Resolving through the trait alone would leave an untyped
/// trait method reference, because choosing the impl needs the self type that a
/// trait signature only ever spells as `Self`.
fn qualifiedImplMethod(
    e: *Ext,
    node: ts.Node,
    trait_name: []const u8,
    method_name: []const u8,
) anyerror!?spine.EntityId {
    const bracketed = node.child(0) orelse return null;
    if (!std.mem.eql(u8, bracketed.kind(), "bracketed_type")) return null;
    const qualified = bracketed.child(1) orelse return null;
    if (!std.mem.eql(u8, qualified.kind(), "qualified_type")) return null;
    const self_type = mapCstType(e, qualified.child(0) orelse return null) catch return null;

    for (e.ctx.g.symbol_table.entities.items) |entity| {
        if (entity.kind != .impl_) continue;
        if (!implImplementsTrait(e, entity.id, trait_name)) continue;
        if (entity.id >= e.ctx.bodies_list.items.len) continue;
        const impl_body = switch (e.ctx.bodies_list.items[entity.id]) {
            .impl_ => |body| body,
            else => continue,
        };
        if (!infer.typeEqual(impl_body.self_ty, self_type)) continue;
        for (e.ctx.g.symbol_table.entities.items) |child| {
            if (child.kind == .fn_ and child.parent == entity.id and
                std.mem.eql(u8, child.name, method_name))
            {
                return child.id;
            }
        }
    }
    return null;
}

/// True when `impl_id` is a trait impl for the trait spelled `trait_name`.
/// The impl's name carries both halves (`FromHex for [u8; 6]`), which is the
/// only linkage a macro-generated impl keeps.
fn implImplementsTrait(e: *const Ext, impl_id: spine.EntityId, trait_name: []const u8) bool {
    const entity = e.ctx.g.symbol_table.get(impl_id) orelse return false;
    const separator = std.mem.indexOf(u8, entity.name, " for ") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, entity.name[0..separator], " \t\r\n"), trait_name);
}

/// The head nominal name a type is written under, or null when the type has
/// none. `Vec<u8>` and a local `Vec<T>` both answer `Vec`, which is the identity
/// a `Type::method` path carries: the callee never spells the type arguments.
fn nominalHeadName(e: *const Ext, t: types.Type) ?[]const u8 {
    return switch (t) {
        .path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else null,
        .external_nominal => |x| if (x.path.len > 0) x.path[x.path.len - 1] else null,
        .generic_inst => |instance| blk: {
            const entity = e.ctx.g.symbol_table.get(instance.decl) orelse break :blk null;
            break :blk entity.name;
        },
        else => null,
    };
}

/// Concrete method entity behind `Type::method(..)` when the owner names a type
/// this crate has no entity for, such as `Vec::from_hex(..)`.
///
/// Rust reads that spelling as `<Vec<u8> as FromHex>::from_hex(..)`: the owner
/// is the receiver type and the leaf is a trait method, so only a trait impl
/// declared here can supply it. The owner has no entity to resolve against,
/// which is why `resolvePatternOwner` cannot bind it; the impl that carries the
/// method can still be, and binding it is what `qualifiedImplMethod` does for
/// the explicit `<T as Trait>::` spelling. Leaving the call unbound instead
/// destroys the callee, and every method chained off its result — `unwrap`,
/// `unwrap_err` — then loses the receiver type it needs.
///
/// Two impls for the same type and method would leave the choice to the trait
/// bounds, which this path does not spell. That stays unresolved rather than
/// guessed.
fn implMethodForOwnerType(
    e: *const Ext,
    owner_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    var found: ?spine.EntityId = null;
    for (e.ctx.g.symbol_table.entities.items) |entity| {
        if (entity.kind != .impl_) continue;
        if (entity.id >= e.ctx.bodies_list.items.len) continue;
        const impl_body = switch (e.ctx.bodies_list.items[entity.id]) {
            .impl_ => |body| body,
            else => continue,
        };
        if (impl_body.trait_path == null) continue;
        const head = nominalHeadName(e, impl_body.self_ty) orelse continue;
        if (!std.mem.eql(u8, head, owner_name)) continue;
        for (e.ctx.g.symbol_table.entities.items) |child| {
            if (child.kind != .fn_ or child.parent != entity.id) continue;
            if (!std.mem.eql(u8, child.name, method_name)) continue;
            if (found != null) return null;
            found = child.id;
        }
    }
    return found;
}

fn traitMethodForPath(e: *Ext, node: ts.Node) anyerror!?spine.EntityId {
    const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
    const separator = std.mem.lastIndexOf(u8, raw, "::") orelse return null;
    const owner_text = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const method_name = std.mem.trim(u8, raw[separator + 2 ..], " \t\r\n");
    if (owner_text.len == 0 or method_name.len == 0) return null;
    if (qualifiedTraitName(owner_text)) |trait_name| {
        if (try qualifiedImplMethod(e, node, trait_name, method_name)) |method| return method;
    }
    const owner = resolvePatternOwner(e, owner_text) orelse
        (if (qualifiedTraitName(owner_text)) |trait_name|
            resolvePatternOwner(e, trait_name)
        else
            null) orelse
        return implMethodForOwnerType(e, owner_text, method_name);
    const owner_entity = e.ctx.g.symbol_table.get(owner) orelse return null;
    if (owner_entity.kind != .trait_) return null;
    return ensureTraitMethodRefEntity(e, owner, method_name);
}

const StandardPreludeVariant = struct {
    enum_id: spine.EntityId,
    variant_id: spine.EntityId,
    module_name: []const u8,
    enum_name: []const u8,
    variant_name: []const u8,
};

const standard_type_param_t: types.Type = .{ .path = .{
    .segments = &.{.{ .name = "T", .id = null }},
} };
const standard_type_param_e: types.Type = .{ .path = .{
    .segments = &.{.{ .name = "E", .id = null }},
} };
const standard_option_variants: []const items.Variant = &.{
    .{ .name = "None", .fields = .{ .none = {} }, .discriminant = null },
    .{ .name = "Some", .fields = .{ .tuple = &.{standard_type_param_t} }, .discriminant = null },
};
const standard_result_variants: []const items.Variant = &.{
    .{ .name = "Ok", .fields = .{ .tuple = &.{standard_type_param_t} }, .discriminant = null },
    .{ .name = "Err", .fields = .{ .tuple = &.{standard_type_param_e} }, .discriminant = null },
};

fn standardPreludeVariantName(name: []const u8) ?struct {
    module_name: []const u8,
    enum_name: []const u8,
    variant_name: []const u8,
} {
    if (std.mem.eql(u8, name, "Some")) {
        return .{ .module_name = "option", .enum_name = "Option", .variant_name = "Some" };
    }
    if (std.mem.eql(u8, name, "None")) {
        return .{ .module_name = "option", .enum_name = "Option", .variant_name = "None" };
    }
    if (std.mem.eql(u8, name, "Ok")) {
        return .{ .module_name = "result", .enum_name = "Result", .variant_name = "Ok" };
    }
    if (std.mem.eql(u8, name, "Err")) {
        return .{ .module_name = "result", .enum_name = "Result", .variant_name = "Err" };
    }
    return null;
}

/// Lazily materialize the canonical prelude variant for a fully qualified
/// path. Ordinary source resolution runs first at each call site, so a source
/// declaration with the same spelling retains precedence.
fn ensureStandardPreludePath(e: *Ext, raw: []const u8) anyerror!?StandardPreludeVariant {
    const separator = std.mem.lastIndexOf(u8, raw, "::") orelse return null;
    const owner = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const variant = std.mem.trim(u8, raw[separator + 2 ..], " \t\r\n");
    if (owner.len == 0 or variant.len == 0) return null;

    const expected_owner =
        (std.mem.eql(u8, owner, "core::option::Option") and
            (std.mem.eql(u8, variant, "Some") or std.mem.eql(u8, variant, "None"))) or
        (std.mem.eql(u8, owner, "core::result::Result") and
            (std.mem.eql(u8, variant, "Ok") or std.mem.eql(u8, variant, "Err")));
    if (!expected_owner) return null;
    return ensureStandardPreludeVariant(e, variant);
}

fn moduleEntityForRow(e: *const Ext, row: graph.Module) ?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind != .module) continue;
        if (ent.parent != row.parent) continue;
        if (!std.mem.eql(u8, ent.name, row.name)) continue;
        return ent.id;
    }
    return null;
}

fn existingExternalModule(
    e: *const Ext,
    parent: ?spine.EntityId,
    name: []const u8,
) ?spine.EntityId {
    for (e.ctx.g.modules.items) |row| {
        if (!row.is_extern or row.parent != parent or
            !std.mem.eql(u8, row.name, name)) continue;
        if (moduleEntityForRow(e, row)) |module_id| return module_id;
    }
    return null;
}

fn appendGraphModuleItem(
    e: *Ext,
    module_id: spine.EntityId,
    item_id: spine.EntityId,
) !void {
    const module_ent = e.ctx.g.symbol_table.get(module_id) orelse
        return error.InvalidModuleEntity;
    for (e.ctx.g.modules.items) |*row| {
        if (moduleEntityForRow(e, row.*) != module_id) continue;
        const old_items = row.items;
        const new_items = try e.ctx.alloc.alloc(spine.EntityId, old_items.len + 1);
        @memcpy(new_items[0..old_items.len], old_items);
        new_items[old_items.len] = item_id;
        if (old_items.len > 0) e.ctx.alloc.free(old_items);
        row.items = new_items;
        return;
    }
    _ = module_ent;
    return error.InvalidModuleEntity;
}

fn ensureExternalModule(
    e: *Ext,
    parent: ?spine.EntityId,
    name: []const u8,
) !spine.EntityId {
    if (existingExternalModule(e, parent, name)) |module_id| return module_id;
    const owned_name = try e.ctx.alloc.dupe(u8, name);
    errdefer e.ctx.alloc.free(owned_name);
    const module_id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .module,
        .name = owned_name,
        .span = span_of,
        .visibility = .public,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    const row_name = try e.ctx.alloc.dupe(u8, name);
    errdefer e.ctx.alloc.free(row_name);
    _ = try e.ctx.g.addModule(.{
        .id = 0,
        .kind = if (parent == null) .file else .@"inline",
        .name = row_name,
        .parent = parent,
        .source_path = null,
        .is_crate = false,
        .is_extern = true,
        .span = span_of,
        .items = &.{},
        .attributes = &.{},
    });
    if (parent) |parent_id| try appendGraphModuleItem(e, parent_id, module_id);
    return module_id;
}

fn appendStandardEnumEntity(
    e: *Ext,
    parent: spine.EntityId,
    info: anytype,
) !spine.EntityId {
    const enum_id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .enum_,
        .name = try e.ctx.alloc.dupe(u8, info.enum_name),
        .span = span_of,
        .visibility = .public,
        .parent = parent,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    const variants: []const items.Variant = if (std.mem.eql(u8, info.enum_name, "Option"))
        standard_option_variants
    else
        standard_result_variants;
    e.ctx.bodies_list.items[enum_id] = .{ .enum_ = .{
        .generic_params = if (std.mem.eql(u8, info.enum_name, "Option"))
            &.{"T"}
        else
            &.{ "T", "E" },
        .kind = .data,
        .variants = variants,
        .repr_int = null,
        .non_exhaustive = false,
    } };
    try appendGraphModuleItem(e, parent, enum_id);
    return enum_id;
}

fn ensureStandardPreludeVariant(
    e: *Ext,
    name: []const u8,
) !?StandardPreludeVariant {
    const info = standardPreludeVariantName(name) orelse return null;
    const core_id = try ensureExternalModule(e, null, "core");
    const module_id = try ensureExternalModule(e, core_id, info.module_name);
    var enum_id: ?spine.EntityId = null;
    for (e.ctx.g.symbol_table.entities.items) |ent| {
        if (ent.kind == .enum_ and ent.parent == module_id and
            std.mem.eql(u8, ent.name, info.enum_name))
        {
            enum_id = ent.id;
            break;
        }
    }
    const actual_enum = enum_id orelse try appendStandardEnumEntity(e, module_id, info);
    const variant_id = if (resolveVariant(e, actual_enum, info.variant_name)) |existing|
        existing
    else blk: {
        const id = try e.ctx.g.symbol_table.add(.{
            .id = 0,
            .kind = .variant,
            .name = try e.ctx.alloc.dupe(u8, info.variant_name),
            .span = span_of,
            .visibility = .public,
            .parent = actual_enum,
            .resolved = null,
            .renamed_to = null,
            .attributes = &.{},
        });
        try e.ctx.bodies_list.append(e.ctx.alloc, .none);
        break :blk id;
    };
    return .{
        .enum_id = actual_enum,
        .variant_id = variant_id,
        .module_name = info.module_name,
        .enum_name = info.enum_name,
        .variant_name = info.variant_name,
    };
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
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    try e.locals.append(e.ctx.alloc, .{ .name = name, .def = id });
    return id;
}

/// Register a method reference without introducing a lexical binding.
fn pushMethodRef(e: *Ext, name: []const u8) anyerror!spine.EntityId {
    const id: spine.EntityId = @intCast(e.ctx.g.symbol_table.entities.items.len);
    const duped = try e.ctx.alloc.dupe(u8, name);
    _ = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .method_ref,
        .name = duped,
        .span = span_of,
        .visibility = .public,
        .parent = e.fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    return id;
}

fn setLocalType(e: *Ext, def: spine.EntityId, ty: types.Type) void {
    for (e.locals.items) |*local| {
        if (local.def == def) {
            local.ty = ty;
            return;
        }
    }
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
fn patternContainsUnsupported(e: *const Ext, pat_id: exprs.NodeId) bool {
    if (pat_id >= e.ctx.pats.items.len) return false;
    return switch (e.ctx.pats.items[pat_id].kind) {
        .unsupported => true,
        .tuple => |tuple| blk: {
            for (tuple.elements) |element_id| {
                if (patternContainsUnsupported(e, element_id)) break :blk true;
            }
            break :blk false;
        },
        .slice => |slice| blk: {
            for (slice.elements) |element_id| {
                if (patternContainsUnsupported(e, element_id)) break :blk true;
            }
            if (slice.rest) |rest_id| {
                if (patternContainsUnsupported(e, rest_id)) break :blk true;
            }
            break :blk false;
        },
        .struct_pat => |struct_pat| blk: {
            for (struct_pat.fields) |field| {
                if (field.pat) |field_id| {
                    if (patternContainsUnsupported(e, field_id)) break :blk true;
                }
            }
            break :blk false;
        },
        .external_variant => |external| blk: {
            for (external.fields) |field| {
                if (field.pat) |field_id| {
                    if (patternContainsUnsupported(e, field_id)) break :blk true;
                }
            }
            break :blk false;
        },
        .range => |range| blk: {
            if (range.lo) |lo| {
                if (lo >= e.ctx.exprs.items.len or e.ctx.exprs.items[lo].kind == .unsupported) break :blk true;
            }
            if (range.hi) |hi| {
                if (hi >= e.ctx.exprs.items.len or e.ctx.exprs.items[hi].kind == .unsupported) break :blk true;
            }
            break :blk false;
        },
        .reference => |reference| patternContainsUnsupported(e, reference.inner),
        .@"or" => |or_pattern| blk: {
            for (or_pattern.alternatives) |alternative_id| {
                if (patternContainsUnsupported(e, alternative_id)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn appendType(e: *Ext, t: types.Type) !?exprs.TypeId {
    // Generic parameters and expression-valued array lengths are valid type
    // table entries. Keep the concrete-return policy at its call sites instead
    // of dropping otherwise valid cast, parameter, and local annotation types.
    if (t == .unsupported) return null;
    if (infer.findTypeIndexInSlice(e.ctx.types.items, t)) |existing| return existing;
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
/// Unsupported syntax is explicit; unresolved nominal paths are typed errors.
fn mapCstType(e: *Ext, node: ts.Node) anyerror!types.Type {
    const kind = node.kind();
    // `_` is Rust's inference placeholder, not a nominal name. It shares the
    // spelling a wildcard cast target lowers to, so inference can recover the
    // concrete type later instead of extraction failing on an unresolvable
    // path.
    if (try wildcardScalarTarget(e, node)) |placeholder| return placeholder;
    if (std.mem.eql(u8, kind, "type")) {
        if (node.namedChildCount() > 0) {
            const mapped_type = try mapCstType(e, node.namedChild(0).?);
            return mapped_type;
        }
        return unsupportedCstType();
    }
    if (std.mem.eql(u8, kind, "primitive_type")) {
        const nm = text(e, node);
        if (std.mem.eql(u8, nm, "str")) return types.str_type;
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
                if (inn.namedChildCount() > 0) {
                    elem = try mapCstType(e, inn.namedChild(0).?);
                }
                const slice_type = try cstSlice(e, elem, !mut);
                return slice_type;
            }
            if (std.mem.eql(u8, inn.kind(), "primitive_type") and
                std.mem.eql(u8, text(e, inn), "str"))
            {
                const slice_type = try cstSlice(e, .{ .prim = .u8 }, !mut);
                return slice_type;
            }
            if (std.mem.eql(u8, inn.kind(), "array_type")) return mapCstType(e, inn);
            const r = try e.ctx.alloc.create(types.Ref);
            r.* = .{ .mut = mut, .pointee = try mapCstType(e, inn) };
            return .{ .reference = r };
        }
        return unsupportedCstType();
    }
    if (std.mem.eql(u8, kind, "pointer_type")) {
        var mutable = false;
        var pointee: types.Type = .{ .prim = .unit };
        var child_index: u32 = 0;
        while (node.namedChild(child_index)) |child| : (child_index += 1) {
            const child_kind = child.kind();
            if (std.mem.eql(u8, child_kind, "mutable_specifier")) {
                mutable = true;
            } else if (!std.mem.eql(u8, child_kind, "const_specifier")) {
                pointee = try mapCstType(e, child);
            }
        }
        const raw_ptr = try e.ctx.alloc.create(types.RawPtr);
        raw_ptr.* = .{ .mut = mutable, .pointee = pointee };
        return .{ .raw_ptr = raw_ptr };
    }
    if (std.mem.eql(u8, kind, "slice_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChildCount() > 0) {
            elem = try mapCstType(e, node.namedChild(0).?);
        }
        const slice_type = try cstSlice(e, elem, true);
        return slice_type;
    }
    if (std.mem.eql(u8, kind, "array_type")) {
        var elem: types.Type = .{ .prim = .unit };
        if (node.namedChild(0)) |elem_node| elem = try mapCstType(e, elem_node);
        if (isSliceTypeNode(node)) {
            const slice_type = try cstSlice(e, elem, true);
            return slice_type;
        }

        var len: types.ArrayLen = undefined;
        if (node.namedChild(1)) |len_node| {
            if (std.mem.eql(u8, len_node.kind(), "integer_literal")) {
                const len_lit = std.fmt.parseInt(u64, text(e, len_node), 10) catch
                    return error.InvalidType;
                len = .{ .literal = len_lit };
            } else {
                const len_expr = try lowerExpr(e, len_node);
                len = .{ .expression = @intCast(len_expr) };
            }
        } else {
            return error.InvalidType;
        }
        const a = try e.ctx.alloc.create(types.Array);
        a.* = .{ .elem = elem, .len = len };
        return .{ .array = a };
    }
    if (std.mem.eql(u8, kind, "qualified_type")) {
        return mapCstQualifiedType(e, node);
    }
    if (std.mem.eql(u8, kind, "generic_type") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier"))
    {
        const named_type = try mapCstNamedType(e, node);
        return named_type;
    }
    if (std.mem.eql(u8, kind, "tuple_type") or std.mem.eql(u8, kind, "unit_type")) {
        var tup: std.ArrayListUnmanaged(types.Type) = .empty;
        defer tup.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            try tup.append(e.ctx.alloc, try mapCstType(e, c));
        }
        if (tup.items.len == 0) return .{ .prim = .unit };
        return .{ .tuple = try tup.toOwnedSlice(e.ctx.alloc) };
    }
    if (node.namedChildCount() > 0) return mapCstType(e, node.namedChild(0).?);
    return unsupportedCstType();
}
fn mapCstQualifiedType(e: *Ext, node: ts.Node) anyerror!types.Type {
    const receiver_node = node.childByFieldName("type") orelse return error.UnresolvedNominalType;
    const trait_node = node.childByFieldName("trait") orelse return error.UnresolvedNominalType;
    const assoc_node = node.childByFieldName("path") orelse return error.UnresolvedNominalType;
    const receiver = try mapCstType(e, receiver_node);
    const receiver_path = switch (receiver) {
        .path => |path| path,
        else => return error.UnresolvedNominalType,
    };
    if (receiver_path.segments.len != 1) return error.UnresolvedNominalType;

    const trait_def = resolvePatternPath(e, trait_node) orelse return error.UnresolvedNominalType;
    const trait_raw = std.mem.trim(u8, text(e, trait_node), " \t\r\n");
    const trait_name = if (std.mem.lastIndexOf(u8, trait_raw, "::")) |sep|
        trait_raw[sep + 2 ..]
    else
        trait_raw;
    const assoc_name = std.mem.trim(u8, text(e, assoc_node), " \t\r\n");
    if (trait_name.len == 0 or assoc_name.len == 0) return error.UnresolvedNominalType;

    const segments = try e.ctx.alloc.alloc(types.PathSegment, 3);
    segments[0] = receiver_path.segments[0];
    segments[1] = .{
        .name = try e.ctx.alloc.dupe(u8, trait_name),
        .id = trait_def,
    };
    segments[2] = .{
        .name = try e.ctx.alloc.dupe(u8, assoc_name),
        .id = null,
    };
    return .{ .path = .{ .segments = segments } };
}

fn cstSlice(e: *const Ext, elem: types.Type, const_: bool) !types.Type {
    const s = try e.ctx.alloc.create(types.Slice);
    s.* = .{ .const_ = const_, .elem = elem };
    return .{ .slice = s };
}

fn unsupportedCstType() types.Type {
    return .{ .unsupported = .{ .reason = .cfg_gated, .message = "unsupported type", .span = span_of } };
}

/// Map a named (path) type — possibly generic — to the wire model.
fn mapCstNamedType(e: *Ext, node: ts.Node) anyerror!types.Type {
    var name: ?[]const u8 = null;
    var arg_nodes: [8]ts.Node = undefined;
    var arg_count: usize = 0;
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    defer segs.deinit(e.ctx.alloc);

    const kind = node.kind();
    if (std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "identifier"))
    {
        name = text(e, node);
    } else if (std.mem.eql(u8, kind, "scoped_type_identifier")) {
        const sub = try mapCstScopedSegments(e, node);
        try segs.appendSlice(e.ctx.alloc, sub);
    } else {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "type_identifier") or
                std.mem.eql(u8, k, "identifier"))
            {
                name = text(e, c);
            } else if (std.mem.eql(u8, k, "scoped_type_identifier")) {
                const sub = try mapCstScopedSegments(e, c);
                try segs.appendSlice(e.ctx.alloc, sub);
            } else if (std.mem.eql(u8, k, "type_arguments") or
                std.mem.eql(u8, k, "generic_type"))
            {
                var j: u32 = 0;
                while (c.namedChild(j)) |a| : (j += 1) {
                    if (std.mem.eql(u8, a.kind(), "lifetime")) continue;
                    if (arg_count == arg_nodes.len) return error.TooManyTypeArguments;
                    arg_nodes[arg_count] = a;
                    arg_count += 1;
                }
            }
        }
    }
    const nm = name orelse if (segs.items.len > 0)
        segs.items[segs.items.len - 1].name
    else
        return error.UnresolvedNominalType;
    var args: []const types.Type = &.{};
    if (arg_count > 0) {
        const args_arr = try e.ctx.alloc.alloc(types.Type, arg_count);
        for (arg_nodes[0..arg_count], 0..) |an, ai| {
            args_arr[ai] = try mapCstType(e, an);
        }
        args = args_arr;
    }

    if (std.mem.eql(u8, nm, "Option") and args.len == 1) {
        const inner = try e.ctx.alloc.create(types.Type);
        inner.* = args[0];
        return .{ .option = inner };
    }
    if (std.mem.eql(u8, nm, "Result") and args.len == 2) {
        const r = try e.ctx.alloc.create(types.Result);
        r.* = .{ .ok = args[0], .err = args[1], .is_error_unionable = true };
        return .{ .result = r };
    }
    if (std.mem.eql(u8, nm, "Box") and args.len == 1) {
        const inner = try e.ctx.alloc.create(types.Type);
        inner.* = args[0];
        return .{ .boxed = inner };
    }
    if (segs.items.len == 0 and resolveName(e, nm) == null and
        (std.mem.eql(u8, nm, "String") or std.mem.eql(u8, nm, "Vec")))
    {
        const prelude_path = if (std.mem.eql(u8, nm, "String")) "alloc::string::String" else "alloc::vec::Vec";
        var external = (try externalNominalForPath(e, prelude_path)) orelse
            return error.UnresolvedNominalType;
        external.args = args;
        return .{ .external_nominal = external };
    }

    const had_scoped_segments = segs.items.len > 0;
    if (segs.items.len == 0 or
        !std.mem.eql(u8, segs.items[segs.items.len - 1].name, nm))
    {
        try segs.append(e.ctx.alloc, .{ .name = try e.ctx.alloc.dupe(u8, nm), .id = null });
    }
    // `core`/`std`/`alloc` name a crate, not a type, so a root segment needs a
    // nominal segment after it. This is the same guard the declaration
    // binder applies, and it keeps a bare `std` from resolving.
    const ext_root = segs.items.len > 1 and isExternalCrateRoot(segs.items[0].name);
    if (ext_root) {
        const external_path = try e.ctx.alloc.alloc([]const u8, segs.items.len);
        for (segs.items, 0..) |segment, index| {
            if (segment.name.len == 0) return error.InvalidType;
            external_path[index] = try e.ctx.alloc.dupe(u8, segment.name);
        }
        return .{ .external_nominal = .{
            .path = external_path,
            .args = args,
        } };
    }

    if (had_scoped_segments) {
        if (try externalAliasNominalType(e, segs.items, args)) |external| {
            return .{ .external_nominal = external };
        }
    }
    if (!had_scoped_segments) {
        if (try externalUsePath(e, nm)) |external_path| {
            return .{ .external_nominal = .{
                .path = external_path,
                .args = args,
            } };
        }
    }

    const path_segments = try segs.toOwnedSlice(e.ctx.alloc);
    var path: types.Path = .{ .segments = path_segments };
    if (args.len == 0 and path.segments.len == 1 and activeTypeParameter(e, nm)) {
        return .{ .path = path };
    }
    const base_def = try resolveCstTypePath(e, &path);
    if (args.len > 0) {
        return .{ .generic_inst = .{ .decl = base_def, .args = .{ .params = args } } };
    }
    return .{ .path = path };
}

/// True when `name` is a crate root whose types are never graph entities. A
/// dependency root names real translated entities, so it is not one of these.
fn isExternalCrateRoot(name: []const u8) bool {
    return std.mem.eql(u8, name, "core") or
        std.mem.eql(u8, name, "std") or
        std.mem.eql(u8, name, "alloc");
}

/// Preserve every segment of a scoped type path. The body mapper resolves the
/// terminal nominal entity against the active function owner.
fn mapCstScopedSegments(e: *const Ext, node: ts.Node) ![]const types.PathSegment {
    var segs: std.ArrayListUnmanaged(types.PathSegment) = .empty;
    errdefer segs.deinit(e.ctx.alloc);
    var source = std.mem.trim(u8, text(e, node), " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return error.UnresolvedNominalType;
    var path_parts = std.mem.splitSequence(u8, source, "::");
    while (path_parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0) return error.UnresolvedNominalType;
        try segs.append(e.ctx.alloc, .{ .name = try e.ctx.alloc.dupe(u8, name), .id = null });
    }
    return segs.toOwnedSlice(e.ctx.alloc);
}
fn externalUsePath(e: *const Ext, name: []const u8) !?[]const []const u8 {
    const module_id = owningModule(e, e.fn_id) orelse return null;
    const module = moduleByEntity(e, module_id) orelse return null;
    var found: ?[]const []const u8 = null;
    for (module.items) |item_id| {
        const entity = e.ctx.g.symbol_table.get(item_id) orelse continue;
        if (entity.kind != .use_) continue;
        const use_decl = e.ctx.g.useById(item_id) orelse continue;
        if (!std.mem.eql(u8, use_decl.local_name, name)) continue;
        const external = switch (use_decl.kind) {
            .external => |value| value,
            else => continue,
        };
        if (found != null) return null;
        found = external.path;
    }
    return found;
}

fn externalNominalForPath(e: *const Ext, raw_path: []const u8) !?types.ExternalNominal {
    var source = std.mem.trim(u8, raw_path, " \t\r\n");
    if (std.mem.startsWith(u8, source, "::")) source = source[2..];
    if (source.len == 0) return null;

    var parts: [16][]const u8 = undefined;
    var part_count: usize = 0;
    var iterator = std.mem.splitSequence(u8, source, "::");
    while (iterator.next()) |part| {
        const name = std.mem.trim(u8, part, " \t\r\n");
        if (name.len == 0 or part_count == parts.len) return null;
        parts[part_count] = name;
        part_count += 1;
    }
    if (part_count == 0) return null;

    var prefix: []const []const u8 = &.{};
    if (part_count > 1 and std.mem.eql(u8, parts[0], "String") and
        resolveName(e, "String") == null)
    {
        prefix = &.{ "alloc", "string", "String" };
    } else if (part_count == 1) {
        prefix = (try externalUsePath(e, parts[0])) orelse return null;
    } else if (!std.mem.eql(u8, parts[0], "core") and
        !std.mem.eql(u8, parts[0], "std") and
        !std.mem.eql(u8, parts[0], "alloc"))
    {
        prefix = (try externalUsePath(e, parts[0])) orelse return null;
    }

    const source_start: usize = if (prefix.len > 0) 1 else 0;
    return .{ .path = try externalNominalPath(e, prefix, parts[source_start..part_count]) };
}

/// `prefix` followed by `parts` as one owned external path. The prefix is
/// graph-owned and the parts come from source text, so both are copied.
fn externalNominalPath(
    e: *const Ext,
    prefix: []const []const u8,
    parts: []const []const u8,
) ![]const []const u8 {
    const owned_path = try e.ctx.alloc.alloc([]const u8, prefix.len + parts.len);
    var copied: usize = 0;
    errdefer {
        for (owned_path[0..copied]) |segment| e.ctx.alloc.free(segment);
        e.ctx.alloc.free(owned_path);
    }
    for (prefix) |segment| {
        owned_path[copied] = try e.ctx.alloc.dupe(u8, segment);
        copied += 1;
    }
    for (parts) |segment| {
        owned_path[copied] = try e.ctx.alloc.dupe(u8, segment);
        copied += 1;
    }
    return owned_path;
}

/// The external nominal a scoped type path names when its head is bound by an
/// external `use` alias (`use core::iter;` then `iter::FromIterator`). The
/// declaration binder prefers a graph entity for the head and only falls back
/// to the alias, so a head that still resolves locally is left alone.
fn externalAliasNominalType(
    e: *const Ext,
    segs: []const types.PathSegment,
    args: []const types.Type,
) !?types.ExternalNominal {
    if (segs.len < 2) return null;
    const module_id = owningModule(e, e.fn_id) orelse return null;
    if (resolveModuleItem(e, module_id, segs[0].name) != null) return null;
    const alias = (try externalUsePath(e, segs[0].name)) orelse return null;
    const tail = try e.ctx.alloc.alloc([]const u8, segs.len - 1);
    defer e.ctx.alloc.free(tail);
    for (segs[1..], 0..) |segment, index| tail[index] = segment.name;
    return .{ .path = try externalNominalPath(e, alias, tail), .args = args };
}

fn externalCowVariantForPath(
    e: *const Ext,
    owner_path: []const u8,
    variant: []const u8,
) !?types.ExternalNominal {
    if (!std.mem.eql(u8, variant, "Owned") and
        !std.mem.eql(u8, variant, "Borrowed")) return null;
    const owner = (try externalNominalForPath(e, owner_path)) orelse return null;
    if (owner.path.len < 3 or
        !std.mem.eql(u8, owner.path[owner.path.len - 2], "borrow") or
        !std.mem.eql(u8, owner.path[owner.path.len - 1], "Cow"))
    {
        for (owner.path) |segment| e.ctx.alloc.free(segment);
        e.ctx.alloc.free(owner.path);
        return null;
    }
    return owner;
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
    const pat_node = node.childByFieldName("pattern");
    const type_node = node.childByFieldName("type");
    const init_node = node.childByFieldName("value");
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

    var ann: ?exprs.TypeId = null;
    if (type_node) |tn| {
        const t = try mapCstType(e, tn);
        if (t != .unsupported) ann = try appendType(e, t);
    }

    var init_id: ?exprs.NodeId = null;
    if (init_node) |inn| init_id = try lowerExpr(e, inn);

    var pat_id: exprs.NodeId = 0;
    if (pat_node) |pn| {
        pat_id = try lowerPattern(e, pn);
        if (e.ctx.pats.items[pat_id].kind == .binding) {
            const binding = e.ctx.pats.items[pat_id].kind.binding;
            const def = resolveName(e, binding.name) orelse return error.MalformedCst;
            if (ann) |type_id| {
                setLocalType(e, def, e.ctx.types.items[type_id]);
            } else if (init_id) |value| {
                if (knownCastOperandType(e, value)) |ty| setLocalType(e, def, ty);
            }
        }
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
        return error.MalformedCst;
    }
    _ = try appendStmt(e, .{ .let = .{
        .pattern = pat_id,
        .init = init_id,
        .ty = ann,
    } });
}
/// Local const lowering is intentionally conservative. Keep only pure scalar
/// expressions whose value is independent of all names; reject captures,
/// forward references, calls, and aggregate values explicitly.
fn isPureLocalConstExpr(e: *const Ext, node: exprs.NodeId) bool {
    if (node >= e.ctx.exprs.items.len) return false;
    return switch (e.ctx.exprs.items[node].kind) {
        .literal => |literal| switch (literal) {
            .int, .float, .boolean, .character => true,
            else => false,
        },
        .binary => |binary| switch (binary.op) {
            .add, .sub, .mul, .div, .rem, .bit_and, .bit_or, .bit_xor, .shl, .shr => isPureLocalConstExpr(e, binary.lhs) and isPureLocalConstExpr(e, binary.rhs),
            else => false,
        },
        .unary => |unary| switch (unary.op) {
            .negate, .bit_not => isPureLocalConstExpr(e, unary.operand),
            else => false,
        },
        .cast => |cast| isPureLocalConstExpr(e, cast.operand),
        else => false,
    };
}

/// Lower a block-local `const` as an immutable let binding. Lower the
/// initializer before registering the name so a declaration cannot resolve
/// itself when it shadows an outer binding.
fn lowerConstItem(e: *Ext, node: ts.Node) anyerror!void {
    var name: ?[]const u8 = null;
    var type_node: ?ts.Node = null;
    var init_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (name == null and std.mem.eql(u8, k, "identifier")) {
            name = text(e, c);
            continue;
        }
        if (type_node == null and
            (std.mem.eql(u8, k, "type") or
                std.mem.eql(u8, k, "primitive_type") or
                std.mem.eql(u8, k, "generic_type") or
                std.mem.eql(u8, k, "reference_type") or
                std.mem.eql(u8, k, "pointer_type") or
                std.mem.eql(u8, k, "type_identifier") or
                std.mem.eql(u8, k, "scoped_type_identifier") or
                std.mem.eql(u8, k, "array_type") or
                std.mem.eql(u8, k, "slice_type") or
                std.mem.eql(u8, k, "tuple_type") or
                std.mem.eql(u8, k, "unit_type")))
        {
            type_node = c;
            continue;
        }
        if (init_node == null) init_node = c;
    }
    const binding_name = name orelse return error.MalformedCst;
    const initializer = init_node orelse node.childByFieldName("value") orelse
        return error.MalformedCst;

    var ann: ?exprs.TypeId = null;
    var local_ty: ?types.Type = null;
    if (type_node) |tn| {
        const t = try mapCstType(e, tn);
        if (t != .unsupported) {
            const type_id = try appendType(e, t);
            ann = type_id;
            local_ty = t;
        }
    }
    var init_id = try lowerExpr(e, initializer);
    if (!isPureLocalConstExpr(e, init_id)) {
        init_id = try unsupported(e, "local const initializer is not a pure scalar");
    }
    const local_def = try pushLocal(e, binding_name);
    if (local_ty) |ty| {
        setLocalType(e, local_def, ty);
    } else if (knownCastOperandType(e, init_id)) |ty| {
        setLocalType(e, local_def, ty);
    }
    const pat_id = try appendPat(e, .{ .binding = .{
        .name = try e.ctx.alloc.dupe(u8, binding_name),
        .mode = .value,
        .mutable = false,
    } });
    _ = try appendStmt(e, .{ .let = .{
        .pattern = pat_id,
        .init = init_id,
        .ty = ann,
    } });
}

/// Lower a function-local `static` with item identity preserved. The item is
/// represented by a static entity and const body, while the enclosing block
/// receives only an item statement and a lexical name binding. Its initializer
/// is lowered before that binding is installed.
fn lowerStaticItem(e: *Ext, node: ts.Node) anyerror!void {
    var name_node: ?ts.Node = node.childByFieldName("name");
    var type_node: ?ts.Node = node.childByFieldName("type");
    var init_node: ?ts.Node = node.childByFieldName("value");

    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (name_node == null and std.mem.eql(u8, kind, "identifier")) {
            name_node = child;
            continue;
        }
        if (type_node == null and
            (isClosureTypeNode(kind) or std.mem.eql(u8, kind, "unit_type")))
        {
            type_node = child;
            continue;
        }
        if (init_node == null and
            (name_node == null or child.id != name_node.?.id) and
            (type_node == null or child.id != type_node.?.id))
        {
            init_node = child;
        }
    }

    const name = name_node orelse return error.MalformedCst;
    const ty_node = type_node orelse return error.MalformedCst;
    const initializer = init_node orelse return error.MalformedCst;
    const static_ty = try mapCstType(e, ty_node);
    if (static_ty == .unsupported) return error.UnsupportedStaticType;
    const init_id = try lowerExpr(e, initializer);
    const static_id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .static_,
        .name = try e.ctx.alloc.dupe(u8, text(e, name)),
        .span = span_of,
        .visibility = .private,
        .parent = e.fn_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .{ .const_ = .{
        .ty = static_ty,
        .init = init_id,
    } });
    try e.locals.append(e.ctx.alloc, .{
        .name = text(e, name),
        .def = static_id,
        .ty = static_ty,
    });
    _ = try appendStmt(e, .{ .item = static_id });
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
        std.mem.eql(u8, k, "ref_pattern") or
        std.mem.eql(u8, k, "range_pattern") or
        std.mem.eql(u8, k, "captured_pattern") or
        std.mem.eql(u8, k, "wildcard_pattern") or
        std.mem.eql(u8, k, "_") or
        std.mem.eql(u8, k, "or_pattern") or
        std.mem.eql(u8, k, "slice_pattern") or
        std.mem.eql(u8, k, "literal_pattern") or
        std.mem.eql(u8, k, "char_literal");
}

const CstRange = struct {
    left: ?ts.Node,
    right: ?ts.Node,
    inclusive: bool,
};

fn cstRange(e: *const Ext, node: ts.Node) CstRange {
    const named_left = node.childByFieldName("left");
    const named_right = node.childByFieldName("right");
    const raw = text(e, node);
    const inclusive = std.mem.indexOf(u8, raw, "..=") != null or
        std.mem.indexOf(u8, raw, "...") != null;
    // Rust's range_expression production has no fields in the vendored
    // grammar. Prefer named bounds when a grammar revision provides them,
    // then use the operator as the delimiter for the lossless fallback.
    if (named_left != null or named_right != null) {
        return .{ .left = named_left, .right = named_right, .inclusive = inclusive };
    }
    var left: ?ts.Node = null;
    var right: ?ts.Node = null;
    var after_operator = false;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (!child.isNamed()) {
            const child_text = text(e, child);
            if (std.mem.eql(u8, child_text, "..") or
                std.mem.eql(u8, child_text, "..=") or
                std.mem.eql(u8, child_text, "..."))
            {
                after_operator = true;
            }
            continue;
        }
        if (isBlockTrivia(child)) continue;
        if (after_operator) {
            if (right == null) right = child;
        } else if (left == null) {
            left = child;
        }
    }
    return .{ .left = left, .right = right, .inclusive = inclusive };
}

/// Peel a range node (`a..b`, `a..=b`, `a..`) into its iterator classification.
/// The iterable is the whole `.range` node rather than its end bound: that is
/// the shape a `.range` iter_kind is validated against, and the shape the
/// backend's `for` input path lowers.
fn lowerRangeIter(e: *Ext, node: ts.Node) anyerror!UnwrappedIter {
    const range = cstRange(e, node);
    if (range.right == null) return unsupportedIter(e, "range no end");
    const range_id = try lowerRangeExpression(e, node);
    if (e.ctx.exprs.items[range_id].kind != .range) return unsupportedIter(e, "range");
    return .{ .kind = .{ .slice = {} }, .eid = range_id };
}

/// Lower a source range while retaining an absent end for open-ended slices.
fn lowerRangeExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const range = cstRange(e, node);
    const start_id = if (range.left) |start| blk: {
        const lowered = try lowerExpr(e, start);
        if (e.ctx.exprs.items[lowered].kind == .unsupported) {
            return unsupported(e, "iterator range bound");
        }
        break :blk lowered;
    } else try appendExpr(e, .{ .literal = .{ .int = .{
        .text = "0",
        .value = 0,
        .base = .dec,
        .ty_suffix = null,
    } } });

    var end_id: ?exprs.NodeId = null;
    if (range.right) |end| {
        const lowered = try lowerExpr(e, end);
        if (e.ctx.exprs.items[lowered].kind == .unsupported) {
            return unsupported(e, "iterator range bound");
        }
        end_id = lowered;
    }
    return appendExpr(e, .{ .range = .{
        .start = start_id,
        .end = end_id,
        .inclusive = range.inclusive,
    } });
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

fn peelParenthesized(node: ts.Node) ts.Node {
    var current = node;
    while (std.mem.eql(u8, current.kind(), "parenthesized_expression") and
        current.namedChildCount() == 1)
    {
        current = current.namedChild(0).?;
    }
    return current;
}

fn isClosureTypeNode(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "type") or
        std.mem.eql(u8, kind, "primitive_type") or
        std.mem.eql(u8, kind, "generic_type") or
        std.mem.eql(u8, kind, "reference_type") or
        std.mem.eql(u8, kind, "pointer_type") or
        std.mem.eql(u8, kind, "array_type") or
        std.mem.eql(u8, kind, "slice_type") or
        std.mem.eql(u8, kind, "tuple_type") or
        std.mem.eql(u8, kind, "type_identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier");
}

fn closurePatternNode(node: ts.Node) ?ts.Node {
    if (isPatternNode(node) or std.mem.eql(u8, node.kind(), "_")) return node;
    if (std.mem.eql(u8, node.kind(), "parameter") or
        std.mem.eql(u8, node.kind(), "self_parameter"))
    {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (isPatternNode(child)) return child;
        }
    }
    return null;
}

fn localType(e: *const Ext, def: spine.EntityId) ?types.Type {
    for (e.locals.items) |local| {
        if (local.def == def) return local.ty;
    }
    const entity = e.ctx.g.symbol_table.get(def) orelse return null;
    if (e.fn_id >= e.ctx.bodies_list.items.len) return null;
    return switch (e.ctx.bodies_list.items[e.fn_id]) {
        .fn_ => |fn_body| blk: {
            for (fn_body.params) |param| {
                if (std.mem.eql(u8, param.name, entity.name)) break :blk param.ty;
            }
            break :blk null;
        },
        else => null,
    };
}

fn writesCapturedLocal(e: *const Ext, expression: exprs.Expr, definition: spine.EntityId) bool {
    var target = switch (expression.kind) {
        .assign => |assignment| assignment.target,
        .unary => |unary| if (unary.op == .ref and unary.op.ref == .mutable)
            unary.operand
        else
            return false,
        .method_call => |call| if (call.receiver_mode == .mutable)
            call.receiver
        else
            return false,
        else => return false,
    };
    var depth: usize = 0;
    while (target < e.ctx.exprs.items.len and depth < e.ctx.exprs.items.len) : (depth += 1) {
        switch (e.ctx.exprs.items[target].kind) {
            .path => |path| return path.def == definition,
            .field => |field| target = field.base,
            .index => |index| target = index.base,
            .unary => |unary| {
                if (unary.op != .deref) return false;
                target = unary.operand;
            },
            else => return false,
        }
    }
    return false;
}

fn lowerClosureExpression(e: *Ext, node: ts.Node) anyerror!?exprs.ClosureExpr {
    if (!std.mem.eql(u8, node.kind(), "closure_expression")) return null;

    const outer_local_count = e.locals.items.len;
    defer e.locals.items.len = outer_local_count;

    var parameters_node: ?ts.Node = node.childByFieldName("parameters");
    var body_node: ?ts.Node = node.childByFieldName("body");
    var fallback_body: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "closure_parameters")) {
            parameters_node = child;
        } else {
            fallback_body = child;
        }
    }
    if (body_node == null) body_node = fallback_body;
    var closure_return_ty: ?exprs.TypeId = null;
    if (node.childByFieldName("return_type")) |return_node| {
        const return_type = mapCstType(e, return_node) catch return null;
        closure_return_ty = try appendType(e, return_type) orelse return null;
    }

    var params: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer params.deinit(e.ctx.alloc);
    if (parameters_node) |parameters| {
        // The wildcard in `|_|` is an anonymous grammar token, so it is not
        // returned by `namedChild`. Walk all children to retain each
        // parameter slot.
        var parameter_index: u32 = 0;
        while (parameters.child(parameter_index)) |parameter| : (parameter_index += 1) {
            if (isComment(parameter)) continue;
            const parameter_text = std.mem.trim(u8, text(e, parameter), " \t\r\n");
            if (!parameter.isNamed() and
                (std.mem.eql(u8, parameter_text, "|") or
                    std.mem.eql(u8, parameter_text, ",")))
            {
                continue;
            }
            const pattern_node = closurePatternNode(parameter) orelse return null;
            const pattern_id = lowerPattern(e, pattern_node) catch |err| switch (err) {
                error.MalformedCst => return null,
                else => return err,
            };
            if (parameter.childByFieldName("type")) |type_node| {
                const parameter_type = mapCstType(e, type_node) catch return null;
                setPatternLocalTypes(e, pattern_id, parameter_type);
            }
            if (patternContainsUnsupported(e, pattern_id)) return null;
            try params.append(e.ctx.alloc, pattern_id);
        }
    }

    const body = body_node orelse return null;
    if (isClosureTypeNode(body.kind())) return null;
    const body_expr_start = e.ctx.exprs.items.len;
    const body_block: exprs.BlockExpr = if (std.mem.eql(u8, body.kind(), "block")) blk: {
        break :blk lowerBlock(e, body) catch |err| switch (err) {
            error.MalformedCst => return null,
            else => return err,
        };
    } else blk: {
        const expression_node = if (std.mem.eql(u8, body.kind(), "expression_statement"))
            body.namedChild(0) orelse return null
        else
            body;
        const expression_id = lowerExpr(e, expression_node) catch |err| switch (err) {
            error.MalformedCst => return null,
            else => return err,
        };
        break :blk .{ .statements = &.{}, .tail = expression_id, .labelled = null };
    };

    for (e.ctx.exprs.items[body_expr_start..]) |expression| {
        switch (expression.kind) {
            .unsupported => return null,
            else => {},
        }
    }

    var captures: std.ArrayListUnmanaged(exprs.Capture) = .empty;
    defer captures.deinit(e.ctx.alloc);
    var capture_mode: exprs.CaptureMode = .by_ref;
    var child_index: u32 = 0;
    while (node.child(child_index)) |child| : (child_index += 1) {
        if (std.mem.eql(u8, std.mem.trim(u8, text(e, child), " \t\r\n"), "move")) {
            capture_mode = .by_value;
            break;
        }
    }
    var closure_trait: exprs.ClosureTrait = .@"fn";
    for (e.locals.items[0..outer_local_count]) |outer_local| {
        var referenced = false;
        var mutated = false;
        for (e.ctx.exprs.items[body_expr_start..]) |expression| {
            mutated = mutated or writesCapturedLocal(e, expression, outer_local.def);
            switch (expression.kind) {
                .path => |path| {
                    if (path.def == outer_local.def) referenced = true;
                },
                else => {},
            }
        }
        if (!referenced) continue;
        if (mutated) closure_trait = .fn_mut;

        const capture_entity = e.ctx.g.symbol_table.get(outer_local.def) orelse return null;
        const capture_type = localType(e, outer_local.def) orelse return null;
        switch (capture_type) {
            .unsupported => return null,
            else => {},
        }
        const capture_type_id = (try appendType(e, capture_type)) orelse return null;
        try captures.append(e.ctx.alloc, .{
            .name = capture_entity.name,
            .mode = if (mutated and capture_mode != .by_value) .by_mut_ref else capture_mode,
            .ty = capture_type_id,
        });
    }

    const closure_captures = try captures.toOwnedSlice(e.ctx.alloc);
    errdefer e.ctx.alloc.free(closure_captures);
    const closure_params = try params.toOwnedSlice(e.ctx.alloc);
    errdefer e.ctx.alloc.free(closure_params);

    return .{
        .captures = closure_captures,
        .params = closure_params,
        .return_ty = closure_return_ty,
        .body = body_block,
        .trait = closure_trait,
    };
}

fn discardClosureStorage(e: *Ext, closure: exprs.ClosureExpr) void {
    if (closure.captures.len > 0) e.ctx.alloc.free(closure.captures);
    if (closure.params.len > 0) e.ctx.alloc.free(closure.params);
}

fn discardIteratorAdapter(e: *Ext, adapter: exprs.IteratorAdapter) void {
    switch (adapter) {
        .map => |map| discardClosureStorage(e, map.closure),
        .filter => |filter| discardClosureStorage(e, filter.closure),
        .flat_map => |closure| discardClosureStorage(e, closure),
        .enumerate, .range_rev, .other => {},
        .zip => {},
    }
}

fn discardIteratorAdapters(
    e: *Ext,
    adapters: *std.ArrayListUnmanaged(exprs.IteratorAdapter),
) void {
    for (adapters.items) |adapter| discardIteratorAdapter(e, adapter);
    adapters.deinit(e.ctx.alloc);
}

fn iteratorArgumentsEmpty(arguments: ts.Node) bool {
    var index: u32 = 0;
    while (arguments.namedChild(index)) |argument| : (index += 1) {
        if (!isComment(argument)) return false;
    }
    return true;
}

fn iteratorClosureArgument(arguments: ts.Node) ?ts.Node {
    var closure: ?ts.Node = null;
    var index: u32 = 0;
    while (arguments.namedChild(index)) |argument| : (index += 1) {
        if (isComment(argument)) continue;
        if (closure != null) return null;
        closure = argument;
    }
    return closure;
}

fn isSliceIteratorSourceType(ty: types.Type) bool {
    return switch (ty) {
        .slice, .array => true,
        .reference => |reference| switch (reference.pointee) {
            .slice, .array => true,
            else => false,
        },
        else => false,
    };
}

/// Slice methods that hand back a chunked-slice iterator. Each takes a single
/// `usize` size argument and names its carrier in `infer.zig`, so a chain may
/// ROOT at one: `src.chunks(2).enumerate().map(..)`. `windows` is absent
/// because no method lowering exists for it — a receiver's `.windows(n)` is
/// refused long before it could become a chain.
const chunked_iterator_methods = [_][]const u8{ "chunks", "chunks_exact" };

fn isChunkedIteratorMethod(name: []const u8) bool {
    for (chunked_iterator_methods) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// True when `current` is `slice.chunks(n)` or `slice.chunks_exact(n)` over a
/// plain slice or array. The chunk iterator itself is the chain's SOURCE, not
/// an adapter: the backend walks it with the same chunk loop a `for` over the
/// same call uses.
fn isChunkedIteratorSource(e: *Ext, node: ts.Node) bool {
    const current = peelParenthesized(node);
    if (!std.mem.eql(u8, current.kind(), "call_expression")) return false;
    const method = methodNameOf(e, current) orelse return false;
    if (!isChunkedIteratorMethod(method)) return false;
    const receiver = receiverOf(current) orelse return false;
    const arguments = argumentsOf(current) orelse return false;
    return iteratorSingleArgument(arguments) != null and
        isStandardIteratorSource(e, receiver);
}

fn isStandardIteratorSource(e: *Ext, node: ts.Node) bool {
    var current = peelParenthesized(node);
    while (std.mem.eql(u8, current.kind(), "reference_expression")) {
        current = peelParenthesized(current.childByFieldName("value") orelse return false);
    }
    if (std.mem.eql(u8, current.kind(), "array_expression")) return true;
    if (!std.mem.eql(u8, current.kind(), "identifier")) return false;
    const definition = resolveName(e, text(e, current)) orelse return false;
    const source_type = localType(e, definition) orelse
        return isAsRefByteSequenceLocal(e, definition);
    return isSliceIteratorSourceType(source_type);
}

/// The expression a `let` bound to `def` was initialized from, or null when
/// nothing lowered so far binds `def`. The enclosing fn's own body block is
/// still being lowered when a chain is recognised, so its block id is not
/// written down yet and the statement table is what there is to read. A name
/// only resolves to `def` inside the function that declares it, so a `let` in
/// another function never matches.
fn localInitializer(e: *const Ext, def: spine.EntityId) ?exprs.Expr {
    for (e.ctx.stmts.items) |statement| {
        if (statement.kind != .let) continue;
        const binding = statement.kind.let;
        if (binding.pattern >= e.ctx.pats.items.len) continue;
        const pattern = e.ctx.pats.items[binding.pattern];
        const name = switch (pattern.kind) {
            .binding => |value| value.name,
            else => continue,
        };
        if (resolveName(e, name) orelse continue != def) continue;
        const init = binding.init orelse return null;
        if (init >= e.ctx.exprs.items.len) return null;
        return e.ctx.exprs.items[init];
    }
    return null;
}

/// Whether the enclosing function declares a byte-sequence `AsRef` bound on
/// `source_def`'s own type — `fn f<T: AsRef<[u8]>>(source: T)`. The bound is
/// the only statement in the source that the borrow is a byte sequence, and
/// nothing in this pass can turn it into a type for the new local: the
/// inference pass that reads generic bounds runs after this lowering.
fn isByteSequenceAsRefValue(e: *const Ext, source_def: spine.EntityId) bool {
    if (e.fn_id >= e.ctx.bodies_list.items.len) return false;
    const generics = switch (e.ctx.bodies_list.items[e.fn_id]) {
        .fn_ => |fn_body| fn_body.generics,
        else => null,
    } orelse return false;
    const source_ty = localType(e, source_def) orelse return false;
    const type_path = switch (source_ty) {
        .path => |path| path,
        else => return false,
    };
    if (type_path.segments.len != 1) return false;
    for (generics.params) |param| {
        if (param != .type_) continue;
        if (!std.mem.eql(u8, param.type_.name, type_path.segments[0].name)) continue;
        for (param.type_.bounds) |bound| {
            if (bound.optional or bound.args.len != 1) continue;
            const segments = bound.path.segments;
            if (segments.len == 0) continue;
            const bound_name = segments[segments.len - 1].name;
            if (!std.mem.eql(u8, bound_name, "AsRef") and
                !std.mem.eql(u8, bound_name, "AsMut"))
            {
                continue;
            }
            switch (bound.args[0]) {
                .slice, .array => return true,
                else => continue,
            }
        }
    }
    return false;
}

/// `let bytes = source.as_ref();` names a byte sequence exactly when the
/// `AsRef` bound on `source`'s type says so. The local itself stays untyped
/// here, so a chain rooted at it is recognised from the bound instead.
fn isAsRefByteSequenceLocal(e: *const Ext, def: spine.EntityId) bool {
    const init = localInitializer(e, def) orelse return false;
    const call = switch (init.kind) {
        .method_call => |method| method,
        else => return false,
    };
    if (call.args.len != 0) return false;
    const method = e.ctx.g.symbol_table.get(call.method) orelse return false;
    if (!std.mem.eql(u8, method.name, "as_ref") and
        !std.mem.eql(u8, method.name, "as_mut") and
        !std.mem.eql(u8, method.name, "borrow"))
    {
        return false;
    }
    if (call.receiver >= e.ctx.exprs.items.len) return false;
    const receiver = e.ctx.exprs.items[call.receiver];
    if (receiver.kind != .path) return false;
    return isByteSequenceAsRefValue(e, receiver.kind.path.def);
}

/// A user `Iterator` is a chain source too, even though it is neither a slice
/// nor a range. The backend drives such a source through `next()`.
fn isIteratorSourceNode(e: *Ext, node: ts.Node) bool {
    if (isStandardIteratorSource(e, node)) return true;
    return isUserIteratorSource(e, node);
}

fn isSimpleIteratorSource(e: *Ext, node: ts.Node) bool {
    const current = peelParenthesized(node);
    if (std.mem.eql(u8, current.kind(), "range_expression")) return true;
    if (isIteratorSourceNode(e, current)) return true;
    if (isChunkedIteratorSource(e, current)) return true;
    if (!std.mem.eql(u8, current.kind(), "call_expression")) return false;

    const method = methodNameOf(e, current) orelse return false;
    const receiver = receiverOf(current) orelse return false;
    const arguments = argumentsOf(current) orelse return false;
    if (std.mem.eql(u8, method, "iter") or std.mem.eql(u8, method, "iter_mut")) {
        return iteratorArgumentsEmpty(arguments) and isStandardIteratorSource(e, receiver);
    }
    if (!std.mem.eql(u8, method, "copied")) return false;
    if (!iteratorArgumentsEmpty(arguments)) return false;
    const iter_call = peelParenthesized(receiver);
    if (!std.mem.eql(u8, iter_call.kind(), "call_expression")) return false;
    const iter_method = methodNameOf(e, iter_call) orelse return false;
    if (!std.mem.eql(u8, iter_method, "iter") and
        !std.mem.eql(u8, iter_method, "iter_mut"))
    {
        return false;
    }
    const iter_arguments = argumentsOf(iter_call) orelse return false;
    if (!iteratorArgumentsEmpty(iter_arguments)) return false;
    const iter_receiver = receiverOf(iter_call) orelse return false;
    return isStandardIteratorSource(e, iter_receiver);
}

fn iteratorSingleArgument(arguments: ts.Node) ?ts.Node {
    var value: ?ts.Node = null;
    var index: u32 = 0;
    while (arguments.namedChild(index)) |argument| : (index += 1) {
        if (isComment(argument)) continue;
        if (value != null) return null;
        value = argument;
    }
    return value;
}

fn isStandardIteratorChain(e: *Ext, node: ts.Node) bool {
    const current = peelParenthesized(node);
    if (isSimpleIteratorSource(e, current)) return true;
    if (!std.mem.eql(u8, current.kind(), "call_expression")) return false;
    const method = methodNameOf(e, current) orelse return false;
    if (!(std.mem.eql(u8, method, "map") or
        std.mem.eql(u8, method, "filter") or
        std.mem.eql(u8, method, "flat_map") or
        std.mem.eql(u8, method, "enumerate") or
        std.mem.eql(u8, method, "zip") or
        std.mem.eql(u8, method, "rev") or
        std.mem.eql(u8, method, "cloned") or
        std.mem.eql(u8, method, "take") or
        std.mem.eql(u8, method, "skip") or
        std.mem.eql(u8, method, "fuse")))
    {
        return false;
    }
    const receiver = receiverOf(current) orelse return false;
    return isStandardIteratorChain(e, receiver);
}

fn lowerIteratorSource(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const current = peelParenthesized(node);
    if (std.mem.eql(u8, current.kind(), "range_expression")) {
        const source = try lowerRangeExpression(e, current);
        if (e.ctx.exprs.items[source].kind != .range) return error.UnsupportedIteratorChain;
        return source;
    }
    if (isIteratorSourceNode(e, current)) return lowerExpr(e, current);
    if (!std.mem.eql(u8, current.kind(), "call_expression")) {
        return error.UnsupportedIteratorChain;
    }
    const method = methodNameOf(e, current) orelse return error.UnsupportedIteratorChain;
    const receiver = receiverOf(current) orelse return error.UnsupportedIteratorChain;
    const arguments = argumentsOf(current) orelse return error.UnsupportedIteratorChain;
    if (std.mem.eql(u8, method, "iter") or std.mem.eql(u8, method, "iter_mut")) {
        if (!iteratorArgumentsEmpty(arguments) or !isStandardIteratorSource(e, receiver)) {
            return error.UnsupportedIteratorChain;
        }
        return lowerExpr(e, current);
    }
    // `slice.chunks(n)` and `slice.chunks_exact(n)` ARE the chain's source.
    // The call is lowered whole, so the backend drives it with the same chunk
    // loop a `for` over the same call emits.
    if (isChunkedIteratorSource(e, current)) return lowerExpr(e, current);
    if (!std.mem.eql(u8, method, "copied") or !iteratorArgumentsEmpty(arguments)) {
        return error.UnsupportedIteratorChain;
    }
    const iter_call = peelParenthesized(receiver);
    if (!std.mem.eql(u8, iter_call.kind(), "call_expression")) {
        return error.UnsupportedIteratorChain;
    }
    const iter_method = methodNameOf(e, iter_call) orelse return error.UnsupportedIteratorChain;
    if (!std.mem.eql(u8, iter_method, "iter") and
        !std.mem.eql(u8, iter_method, "iter_mut"))
    {
        return error.UnsupportedIteratorChain;
    }
    const iter_arguments = argumentsOf(iter_call) orelse return error.UnsupportedIteratorChain;
    if (!iteratorArgumentsEmpty(iter_arguments)) return error.UnsupportedIteratorChain;
    const iter_receiver = receiverOf(iter_call) orelse return error.UnsupportedIteratorChain;
    if (!isStandardIteratorSource(e, iter_receiver)) return error.UnsupportedIteratorChain;
    return lowerExpr(e, iter_receiver);
}

fn lowerIteratorChainParts(
    e: *Ext,
    node: ts.Node,
    source: *exprs.NodeId,
    adapters: *std.ArrayListUnmanaged(exprs.IteratorAdapter),
) anyerror!void {
    const current = peelParenthesized(node);
    if (std.mem.eql(u8, current.kind(), "range_expression")) {
        source.* = try lowerIteratorSource(e, current);
        return;
    }
    if (isUserIteratorSource(e, current)) {
        source.* = try lowerExpr(e, current);
        return;
    }
    if (!std.mem.eql(u8, current.kind(), "call_expression")) {
        return error.UnsupportedIteratorChain;
    }
    const method = methodNameOf(e, current) orelse return error.UnsupportedIteratorChain;
    const receiver = receiverOf(current) orelse return error.UnsupportedIteratorChain;
    const arguments = argumentsOf(current) orelse return error.UnsupportedIteratorChain;

    if (std.mem.eql(u8, method, "iter") or std.mem.eql(u8, method, "iter_mut") or
        std.mem.eql(u8, method, "copied") or isChunkedIteratorMethod(method))
    {
        source.* = try lowerIteratorSource(e, current);
        return;
    }
    if (std.mem.eql(u8, method, "enumerate")) {
        if (!iteratorArgumentsEmpty(arguments)) return error.UnsupportedIteratorChain;
        try lowerIteratorChainParts(e, receiver, source, adapters);
        try adapters.append(e.ctx.alloc, .{ .enumerate = {} });
        return;
    }
    if (std.mem.eql(u8, method, "zip")) {
        const other_node = iteratorSingleArgument(arguments) orelse
            return error.UnsupportedIteratorChain;
        try lowerIteratorChainParts(e, receiver, source, adapters);
        const other = try lowerIteratorSource(e, other_node);
        try adapters.append(e.ctx.alloc, .{ .zip = .{ .other = other } });
        return;
    }
    if (std.mem.eql(u8, method, "rev")) {
        if (!iteratorArgumentsEmpty(arguments)) return error.UnsupportedIteratorChain;
        const adapter_start = adapters.items.len;
        try lowerIteratorChainParts(e, receiver, source, adapters);
        if (adapters.items.len != adapter_start or
            e.ctx.exprs.items[source.*].kind != .range)
        {
            return error.UnsupportedIteratorChain;
        }
        try adapters.append(e.ctx.alloc, .{ .range_rev = {} });
        return;
    }
    if (!std.mem.eql(u8, method, "map") and !std.mem.eql(u8, method, "filter") and
        !std.mem.eql(u8, method, "flat_map"))
    {
        return error.UnsupportedIteratorChain;
    }
    try lowerIteratorChainParts(e, receiver, source, adapters);
    const closure_source = iteratorClosureArgument(arguments) orelse
        return error.UnsupportedIteratorChain;
    if (!std.mem.eql(u8, closure_source.kind(), "closure_expression")) {
        return error.UnsupportedIteratorChain;
    }
    const closure = (try lowerClosureExpression(e, closure_source)) orelse
        return error.UnsupportedIteratorChain;
    errdefer discardClosureStorage(e, closure);
    if (closure.params.len != 1) return error.UnsupportedIteratorChain;
    try adapters.append(e.ctx.alloc, if (std.mem.eql(u8, method, "map"))
        .{ .map = .{ .closure = closure } }
    else if (std.mem.eql(u8, method, "filter"))
        .{ .filter = .{ .closure = closure } }
    else
        .{ .flat_map = closure });
}

fn lowerIteratorChainData(
    e: *Ext,
    receiver: ts.Node,
    terminal: exprs.IteratorTerminal,
) anyerror!exprs.IteratorChainExpr {
    var adapters: std.ArrayListUnmanaged(exprs.IteratorAdapter) = .empty;
    errdefer discardIteratorAdapters(e, &adapters);
    var source: exprs.NodeId = 0;
    try lowerIteratorChainParts(e, receiver, &source, &adapters);
    return .{
        .source = source,
        .adapters = try adapters.toOwnedSlice(e.ctx.alloc),
        .terminal = terminal,
    };
}

fn lowerIteratorExpression(
    e: *Ext,
    receiver: ts.Node,
    terminal: exprs.IteratorTerminal,
) anyerror!exprs.NodeId {
    const chain = lowerIteratorChainData(e, receiver, terminal) catch |err| {
        if (err == error.UnsupportedIteratorChain) return unsupported(e, "iterator chain");
        return err;
    };
    errdefer {
        for (chain.adapters) |adapter| discardIteratorAdapter(e, adapter);
        e.ctx.alloc.free(chain.adapters);
    }
    return appendExpr(e, .{ .iterator_chain = chain });
}

/// The iterator equivalent of `unsupported`: a `.slice` iterable whose carrier
/// is an `.unsupported` expr (renders as a loud `@panic`, never a wrong value).
fn unsupportedIter(e: *Ext, reason: []const u8) anyerror!UnwrappedIter {
    const eid = try unsupported(e, reason);
    return .{ .kind = .{ .slice = {} }, .eid = eid };
}

/// True when a `.method(..)` call's receiver is spelled as a range
/// expression. Rust's `rev` is the one adapter whose wire form differs by
/// source: `range.rev()` lowers to a direction flag on a Zig range, while
/// `slice.iter().rev()` is an ordinary `core::iter::Rev` carrier the runtime
/// already has.
fn isRangeReceiver(node: ts.Node) bool {
    const receiver = receiverOf(node) orelse return false;
    return std.mem.eql(u8, peelParenthesized(receiver).kind(), "range_expression");
}

/// Classify a `for` iterable expression, peeling `.iter()`, `.iter_mut()`,
/// `.as_ref()` and detecting `.enumerate()` / `.zip()` / ranges.
fn unwrapIterable(e: *Ext, node: ts.Node) anyerror!UnwrappedIter {
    const k = node.kind();
    if (std.mem.eql(u8, k, "range_expression")) {
        return lowerRangeIter(e, node);
    }

    if (std.mem.eql(u8, k, "call_expression")) {
        const mname = methodNameOf(e, node);
        if (mname) |name| {
            // `.rev()` over a RANGE is a chain adapter; over any other
            // iterator it is an ordinary method call the runtime already
            // models as a `core::iter::Rev` carrier.
            if ((std.mem.eql(u8, name, "map") or std.mem.eql(u8, name, "filter") or
                std.mem.eql(u8, name, "flat_map") or
                (std.mem.eql(u8, name, "rev") and isRangeReceiver(node))) and
                isStandardIteratorChain(e, node))
            {
                const chain = lowerIteratorChainData(e, node, .iterator) catch |err| {
                    if (err == error.UnsupportedIteratorChain) return unsupportedIter(e, "iterator chain");
                    return err;
                };
                return .{ .kind = .{ .adapter = chain }, .eid = chain.source };
            }
            if (std.mem.eql(u8, name, "enumerate")) {
                const recv = receiverOf(node) orelse return error.MalformedCst;
                const base = try unwrapIterable(e, recv);
                return .{ .kind = .{ .enumerate = {} }, .eid = base.eid };
            }
            if (std.mem.eql(u8, name, "zip")) {
                const recv = receiverOf(node) orelse return error.MalformedCst;
                const base = try unwrapIterable(e, recv);
                const arg = firstArg(e, argumentsOf(node)) orelse return error.MalformedCst;
                const other = try lowerExpr(e, arg);
                const ids = try e.ctx.alloc.alloc(exprs.NodeId, 2);
                ids[0] = base.eid;
                ids[1] = other;
                return .{ .kind = .{ .multi = ids }, .eid = base.eid };
            }
            if (std.mem.eql(u8, name, "iter") or std.mem.eql(u8, name, "iter_mut")) {
                // Keep the iterator call as the carrier. Inference uses the
                // receiver to recover the element type and the method name to
                // preserve shared versus mutable iteration semantics.
                return .{ .kind = .{ .slice = {} }, .eid = try lowerExpr(e, node) };
            }
            if (std.mem.eql(u8, name, "as_ref") or std.mem.eql(u8, name, "clone")) {
                const recv = receiverOf(node) orelse return error.MalformedCst;
                return unwrapIterable(e, recv);
            }
        }
    }

    const eid = try lowerExpr(e, node);
    return .{ .kind = .{ .slice = {} }, .eid = eid };
}
/// Lower a `for_expression` to a wire `for_` expr, returning its expr id.
fn lowerFor(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const outer_local_count = e.locals.items.len;
    defer e.locals.items.len = outer_local_count;
    // `for <pattern> in <iter> { <block> }`
    var iter_node: ?ts.Node = node.childByFieldName("value");
    var body_node: ?ts.Node = node.childByFieldName("body");
    var pat_node: ?ts.Node = node.childByFieldName("pattern");

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        const k = c.kind();
        if (pat_node == null and isPatternNode(c)) {
            pat_node = c;
        } else if (body_node == null and std.mem.eql(u8, k, "block")) {
            body_node = c;
        } else if (iter_node == null and !isPatternNode(c)) {
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
    const pn = pat_node orelse return error.MalformedCst;
    const pat_id = try lowerPattern(e, pn);

    const iter = iter_node orelse return error.MalformedCst;
    const it = try unwrapIterable(e, iter);
    const iter_eid = it.eid;
    const body = body_node orelse return error.MalformedCst;
    const body_blk = try lowerBlock(e, body);

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

fn isBlockTrivia(node: ts.Node) bool {
    const k = node.kind();
    return isComment(node) or
        std.mem.eql(u8, k, "attribute_item") or
        std.mem.eql(u8, k, "inner_attribute_item") or
        std.mem.eql(u8, k, "empty_statement");
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
    const outer_local_count = e.locals.items.len;
    defer e.locals.items.len = outer_local_count;
    var stmt_ids: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer stmt_ids.deinit(e.ctx.alloc);
    var tail: ?exprs.NodeId = null;

    // Find the last value-bearing child so trivia cannot become the block tail.
    var last: ?ts.Node = null;
    {
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (isBlockTrivia(c)) continue;
            last = c;
        }
    }

    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (isBlockTrivia(c)) continue;
        const k = c.kind();
        const is_last = last != null and last.?.id == c.id;

        if (std.mem.eql(u8, k, "const_item")) {
            try lowerConstItem(e, c);
            try stmt_ids.append(e.ctx.alloc, @intCast(e.ctx.stmts.items.len - 1));
        } else if (std.mem.eql(u8, k, "static_item")) {
            try lowerStaticItem(e, c);
            try stmt_ids.append(e.ctx.alloc, @intCast(e.ctx.stmts.items.len - 1));
        } else if (std.mem.eql(u8, k, "let_declaration")) {
            try lowerLet(e, c);
            try stmt_ids.append(e.ctx.alloc, @intCast(e.ctx.stmts.items.len - 1));
        } else if (std.mem.eql(u8, k, "expression_statement") or
            std.mem.eql(u8, k, "macro_invocation"))
        {
            const sub = if (std.mem.eql(u8, k, "macro_invocation"))
                c
            else
                c.namedChild(0) orelse return error.MalformedCst;
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

fn controlBlock(node: ts.Node) ?ts.Node {
    if (node.childByFieldName("body")) |body| return body;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "block")) return child;
    }
    return null;
}

fn controlLabel(e: *Ext, node: ts.Node) anyerror!?[]const u8 {
    var label = node.childByFieldName("label");
    if (label == null) {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), "lifetime")) {
                label = child;
                break;
            }
        }
    }
    const raw = label orelse return null;
    var name = std.mem.trim(u8, text(e, raw), " \t\r\n");
    if (name.len > 0 and name[0] == '\'') name = name[1..];
    if (name.len == 0) return null;
    const owned_name = try e.ctx.alloc.dupe(u8, name);
    return owned_name;
}

fn controlValue(e: *Ext, node: ts.Node) anyerror!?exprs.NodeId {
    if (node.childByFieldName("value")) |value| {
        const lowered = try lowerExpr(e, value);
        return lowered;
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "lifetime")) {
            const lowered = try lowerExpr(e, child);
            return lowered;
        }
    }
    return null;
}

// ── expression lowering ─────────────────────────────────────────────────────

fn lowerAssignmentExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const lhs = node.childByFieldName("left");
    const rhs = node.childByFieldName("right");
    if (lhs == null or rhs == null) return error.MalformedCst;

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

fn isScalarCastType(ty: types.Type) bool {
    return switch (ty) {
        .prim => |primitive| switch (primitive) {
            .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize, .f32, .f64, .char => true,
            .bool, .unit, .never => false,
        },
        else => false,
    };
}
fn isBoolType(ty: types.Type) bool {
    return switch (ty) {
        .prim => |primitive| primitive == .bool,
        else => false,
    };
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
fn isIntegerPrimitive(primitive: types.Prim) bool {
    return switch (primitive) {
        .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => true,
        .f32, .f64, .bool, .char, .unit, .never => false,
    };
}

fn isThinRawPointer(raw_ptr: *const types.RawPtr) bool {
    return switch (raw_ptr.pointee) {
        .slice => false,
        else => true,
    };
}

fn referenceToRawPointerCompatible(source_ref: *const types.Ref, target_raw: *const types.RawPtr) bool {
    if (target_raw.mut and !source_ref.mut) return false;
    if (infer.typeEqual(source_ref.pointee, target_raw.pointee)) return true;
    switch (source_ref.pointee) {
        .array => |arr| {
            if (infer.typeEqual(arr.elem, target_raw.pointee)) return true;
            if (target_raw.pointee == .slice and infer.typeEqual(arr.elem, target_raw.pointee.slice.elem)) {
                return true;
            }
        },
        else => {},
    }
    return false;
}

fn rawPointeesCastCompatible(source_pointee: types.Type, target_pointee: types.Type) bool {
    const source_is_fat = (source_pointee == .slice);
    const target_is_fat = (target_pointee == .slice);
    if (target_is_fat and !source_is_fat) return false;
    return true;
}

fn isSupportedCastTarget(ty: types.Type) bool {
    // `x as _` names its destination with the inference placeholder, which is
    // a real type-table entry that solving fills in from the surrounding
    // constraints. The cast is valid; only the destination is not yet known.
    if (infer.isInferPlaceholderType(ty)) return true;
    return switch (ty) {
        .prim => isScalarCastType(ty),
        .raw_ptr, .slice => true,
        else => false,
    };
}

fn placeholderRawPointerTarget(
    e: *const Ext,
    node: ts.Node,
    source: ?types.Type,
) anyerror!?types.Type {
    const raw = std.mem.trim(u8, text(e, node), " \t\r\n");
    const mutable = std.mem.startsWith(u8, raw, "*mut ");
    const immutable = std.mem.startsWith(u8, raw, "*const ");
    if ((!mutable and !immutable) or !std.mem.endsWith(u8, raw, "_")) return null;
    var pointee: types.Type = undefined;
    if (source) |source_type| {
        pointee = switch (source_type) {
            .reference => |reference| reference.pointee,
            .raw_ptr => |raw_ptr| raw_ptr.pointee,
            else => return null,
        };
    } else {
        const wildcard_path = try e.ctx.alloc.alloc([]const u8, 1);
        wildcard_path[0] = "_";
        pointee = .{ .external_nominal = .{
            .path = wildcard_path,
            .args = &.{},
        } };
    }
    const pointer = try e.ctx.alloc.create(types.RawPtr);
    pointer.* = .{ .mut = mutable, .pointee = pointee };
    return .{ .raw_ptr = pointer };
}

fn wildcardScalarTarget(e: *const Ext, node: ts.Node) anyerror!?types.Type {
    if (!std.mem.eql(u8, std.mem.trim(u8, text(e, node), " \t\r\n"), "_")) return null;
    const path = try e.ctx.alloc.alloc([]const u8, 1);
    path[0] = "_";
    return .{ .external_nominal = .{ .path = path, .args = &.{} } };
}

fn isWildcardRawPointerCst(e: *const Ext, node: ts.Node) bool {
    if (!std.mem.eql(u8, node.kind(), "pointer_type")) return false;
    const pointee = node.childByFieldName("type") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, text(e, pointee), " \t\r\n"), "_");
}

fn knownCastCompatible(source: types.Type, target: types.Type) ?bool {
    // An `as _` destination is not yet a type, so nothing can be decided about
    // the cast until solving resolves it. Report "unknown", not "incompatible".
    if (infer.isInferPlaceholderType(target)) return null;
    if (isScalarCastType(target)) {
        if (isScalarCastType(source) or isBoolType(source)) return true;
        if (source == .raw_ptr) {
            return isThinRawPointer(source.raw_ptr) and isIntegerPrimitive(target.prim);
        }
        return false;
    }
    if (target == .slice) {
        const target_slice = target.slice;
        return switch (source) {
            .reference => |source_ref| {
                if (!target_slice.const_ and !source_ref.mut) return false;
                return switch (source_ref.pointee) {
                    .array => |array| infer.typeEqual(array.elem, target_slice.elem),
                    .slice => |slice| infer.typeEqual(slice.elem, target_slice.elem),
                    else => false,
                };
            },
            .slice => |source_slice| {
                if (!target_slice.const_ and source_slice.const_) return false;
                return infer.typeEqual(source_slice.elem, target_slice.elem);
            },
            else => false,
        };
    }
    if (target == .raw_ptr) {
        switch (source) {
            .raw_ptr => |source_ptr| return rawPointeesCastCompatible(source_ptr.pointee, target.raw_ptr.pointee),
            .reference => |source_ref| return referenceToRawPointerCompatible(source_ref, target.raw_ptr),
            .prim => |source_prim| return isIntegerPrimitive(source_prim) and isThinRawPointer(target.raw_ptr),
            else => return false,
        }
    }
    return false;
}
fn indexedElementType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .array => |array| array.elem,
        .slice => |slice| slice.elem,
        .reference => |reference| indexedElementType(reference.pointee),
        else => null,
    };
}

fn knownFieldType(e: *const Ext, field_id: spine.EntityId) ?types.Type {
    const field_entity = e.ctx.g.symbol_table.get(field_id) orelse return null;
    const parent = field_entity.parent orelse return null;
    if (parent >= e.ctx.bodies_list.items.len) return null;
    return switch (e.ctx.bodies_list.items[parent]) {
        .struct_ => |struct_body| for (struct_body.fields) |field| {
            if (std.mem.eql(u8, field.name, field_entity.name)) break field.ty;
        } else null,
        else => null,
    };
}

fn activeGenericPathType(e: *const Ext, ty: types.Type) ?types.Type {
    return switch (ty) {
        .path => |path| if (path.segments.len == 1 and
            path.segments[0].id == null and
            activeTypeParameter(e, path.segments[0].name))
            activeGenericReceiver(e, path.segments[0].name) catch null
        else
            null,
        else => null,
    };
}

fn optionPayloadType(e: *const Ext, ty: types.Type) ?types.Type {
    return switch (ty) {
        .option => |inner| activeGenericPathType(e, inner.*) orelse
            if (isConcreteDeclaredReturnType(inner.*)) inner.* else null,
        .result => |result| activeGenericPathType(e, result.ok) orelse
            if (isConcreteDeclaredReturnType(result.ok)) result.ok else null,
        else => null,
    };
}

fn knownCallPayloadType(e: *const Ext, call: exprs.Call) ?types.Type {
    const def = switch (call.call_kind) {
        .free => |value| value,
        .associated => |value| value,
        .constructor => return null,
    };
    if (def >= e.ctx.bodies_list.items.len) return null;
    const ret = switch (e.ctx.bodies_list.items[def]) {
        .fn_ => |body| body.ret,
        else => return null,
    };
    return optionPayloadType(e, ret);
}

fn knownPatternPayloadType(e: *const Ext, node_id: exprs.NodeId) ?types.Type {
    if (node_id >= e.ctx.exprs.items.len) return null;
    const expression = e.ctx.exprs.items[node_id];
    if (expression.ty) |type_id| {
        if (type_id < e.ctx.types.items.len) {
            if (optionPayloadType(e, e.ctx.types.items[type_id])) |payload| return payload;
        }
    }
    return switch (expression.kind) {
        .call => |call| knownCallPayloadType(e, call),
        else => null,
    };
}

fn setPatternLocalTypes(e: *Ext, pattern_id: exprs.NodeId, ty: types.Type) void {
    if (pattern_id >= e.ctx.pats.items.len) return;
    switch (e.ctx.pats.items[pattern_id].kind) {
        .binding => |binding| {
            if (resolveName(e, binding.name)) |def| setLocalType(e, def, ty);
        },
        .tuple => |tuple| for (tuple.elements) |element| setPatternLocalTypes(e, element, ty),
        .slice => |slice| {
            for (slice.elements) |element| setPatternLocalTypes(e, element, ty);
            if (slice.rest) |rest| setPatternLocalTypes(e, rest, ty);
        },
        .struct_pat => |structure| {
            for (structure.fields) |field| {
                if (field.pat) |field_pattern| setPatternLocalTypes(e, field_pattern, ty);
            }
        },
        .external_variant => |variant| for (variant.fields) |field| {
            if (field.pat) |field_pattern| setPatternLocalTypes(e, field_pattern, ty);
        },
        .reference => |reference| setPatternLocalTypes(e, reference.inner, ty),
        .@"or" => |or_pattern| for (or_pattern.alternatives) |alternative|
            setPatternLocalTypes(e, alternative, ty),
        else => {},
    }
}

fn knownCastOperandType(e: *const Ext, node_id: exprs.NodeId) ?types.Type {
    if (node_id >= e.ctx.exprs.items.len) return null;
    const expression = e.ctx.exprs.items[node_id];
    if (expression.ty) |type_id| {
        if (type_id < e.ctx.types.items.len) return e.ctx.types.items[type_id];
    }
    return switch (expression.kind) {
        .path => |path| localType(e, path.def),
        .field => |field| knownFieldType(e, field.resolved),
        .cast => |cast| if (cast.target < e.ctx.types.items.len)
            e.ctx.types.items[cast.target]
        else
            null,
        .index => |index| if (knownCastOperandType(e, index.base)) |base_type|
            indexedElementType(base_type)
        else
            null,
        .literal => |literal| switch (literal) {
            .int => |integer| if (integer.ty_suffix) |suffix|
                if (mapPrim(suffix)) |primitive| .{ .prim = primitive } else null
            else
                .{ .prim = .i32 },
            .float => |float| .{ .prim = if (std.mem.endsWith(u8, float.text, "f32")) .f32 else .f64 },
            .boolean => .{ .prim = .bool },
            .character => .{ .prim = .char },
            else => null,
        },
        .unary => |unary| switch (unary.op) {
            .deref => if (knownCastOperandType(e, unary.operand)) |operand_type| switch (operand_type) {
                .reference => |reference| reference.pointee,
                .raw_ptr => |raw_ptr| raw_ptr.pointee,
                else => null,
            } else null,
            .negate, .bit_not => knownCastOperandType(e, unary.operand),
            .logical_not => .{ .prim = .bool },
            .ref => |mode| if (knownCastOperandType(e, unary.operand)) |pointee| blk: {
                const ref_ptr = e.ctx.alloc.create(types.Ref) catch break :blk null;
                ref_ptr.* = .{ .mut = (mode == .mutable), .pointee = pointee };
                break :blk types.Type{ .reference = ref_ptr };
            } else null,
        },
        .try_ => |t| if (knownCastOperandType(e, t.inner)) |inner_ty| switch (inner_ty) {
            .option => |opt| opt.*,
            .result => |res| res.ok,
            else => null,
        } else null,
        .method_call => |method| blk: {
            const method_name = if (e.ctx.g.symbol_table.get(method.method)) |ent| ent.name else break :blk null;
            if (std.mem.eql(u8, method_name, "as_ptr") or std.mem.eql(u8, method_name, "as_mut_ptr")) {
                if (knownCastOperandType(e, method.receiver)) |recv_ty| {
                    if (indexedElementType(recv_ty)) |elem| {
                        const ptr = e.ctx.alloc.create(types.RawPtr) catch break :blk null;
                        ptr.* = .{ .mut = std.mem.eql(u8, method_name, "as_mut_ptr"), .pointee = elem };
                        break :blk types.Type{ .raw_ptr = ptr };
                    }
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn pendingCastSourceType() types.Type {
    return .{ .unsupported = .{
        .reason = .iterators,
        .message = "cast source type pending inference",
        .span = span_of,
    } };
}
fn primitiveFromTarget(raw: []const u8) ?types.Prim {
    const suffix = "::from";
    if (!std.mem.endsWith(u8, raw, suffix)) return null;
    const base = raw[0 .. raw.len - suffix.len];
    const primitive = mapPrim(base) orelse return null;
    return switch (primitive) {
        .u8, .u16, .u32, .u64, .u128, .usize, .char => primitive,
        else => null,
    };
}

fn appendPrimitiveFrom(
    e: *Ext,
    target_primitive: types.Prim,
    args: []const exprs.NodeId,
) anyerror!exprs.NodeId {
    defer e.ctx.alloc.free(args);
    if (args.len != 1) return unsupported(e, "primitive from call");
    const target = (try appendType(e, .{ .prim = target_primitive })) orelse unreachable;
    const operand = args[0];
    const source_type = knownCastOperandType(e, operand) orelse pendingCastSourceType();
    const cast = try appendExpr(e, .{ .cast = .{
        .kind = .primitive_from,
        .operand = operand,
        .source_type = source_type,
        .target = target,
    } });
    e.ctx.exprs.items[cast].ty = target;
    return cast;
}
fn primitiveTryFromTarget(raw: []const u8) ?types.Prim {
    const suffix = "::try_from";
    if (!std.mem.endsWith(u8, raw, suffix)) return null;
    const base = raw[0 .. raw.len - suffix.len];
    const primitive = mapPrim(base) orelse return null;
    return switch (primitive) {
        .i8,
        .i16,
        .i32,
        .i64,
        .i128,
        .isize,
        .u8,
        .u16,
        .u32,
        .u64,
        .u128,
        .usize,
        => primitive,
        else => null,
    };
}

fn appendPrimitiveTryFrom(
    e: *Ext,
    target_primitive: types.Prim,
    args: []const exprs.NodeId,
) anyerror!exprs.NodeId {
    defer e.ctx.alloc.free(args);
    if (args.len != 1) return unsupported(e, "primitive try_from call");

    const result = try e.ctx.alloc.create(types.Result);
    var result_owned = true;
    const error_external =
        (try externalNominalForPath(e, "core::num::TryFromIntError")) orelse
        return error.UnresolvedNominalType;
    var error_external_owned = true;
    defer {
        if (result_owned) e.ctx.alloc.destroy(result);
        if (error_external_owned) {
            for (error_external.path) |segment| e.ctx.alloc.free(segment);
            e.ctx.alloc.free(error_external.path);
        }
    }
    result.* = .{
        .ok = .{ .prim = target_primitive },
        .err = .{ .external_nominal = error_external },
        .is_error_unionable = false,
    };
    const result_type: types.Type = .{ .result = result };
    const result_id = if (infer.findTypeIndexInSlice(e.ctx.types.items, result_type)) |existing| blk: {
        break :blk existing;
    } else blk: {
        const id = (try appendType(e, result_type)) orelse unreachable;
        result_owned = false;
        error_external_owned = false;
        break :blk id;
    };
    const method = try pushMethodRef(e, "try_into");
    const call = try appendExpr(e, .{ .method_call = .{
        .receiver = args[0],
        .receiver_mode = .value,
        .method = method,
        .args = &.{},
    } });
    e.ctx.exprs.items[call].ty = result_id;
    return call;
}

fn lowerCast(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const operand_node = node.childByFieldName("value") orelse return error.MalformedCst;
    const target_node = node.childByFieldName("type") orelse return error.MalformedCst;
    const operand = try lowerExpr(e, operand_node);
    const known_source = knownCastOperandType(e, operand);
    var target_type = mapCstType(e, target_node) catch blk: {
        if (try placeholderRawPointerTarget(e, target_node, known_source)) |placeholder| {
            break :blk placeholder;
        }
        if (try wildcardScalarTarget(e, target_node)) |placeholder| {
            break :blk placeholder;
        }
        return unsupported(e, "cast target type");
    };
    if (isWildcardRawPointerCst(e, target_node)) {
        if (try placeholderRawPointerTarget(e, target_node, known_source)) |placeholder| {
            target_type = placeholder;
        }
    }
    if (!isSupportedCastTarget(target_type)) {
        return unsupported(e, "cast target type");
    }
    const target = (try appendType(e, target_type)) orelse {
        return unsupported(e, "cast target type");
    };
    if (known_source) |source_type| {
        if (knownCastCompatible(source_type, target_type)) |compatible| {
            if (!compatible) {
                return unsupported(e, "cast target type");
            }
        }
    }
    const source_type = known_source orelse pendingCastSourceType();
    const cast = try appendExpr(e, .{ .cast = .{
        .kind = .as_,
        .operand = operand,
        .source_type = source_type,
        .target = target,
    } });
    e.ctx.exprs.items[cast].ty = target;
    return cast;
}
fn lowerReferenceExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    var operand: ?ts.Node = node.childByFieldName("value");
    var operand_count: usize = 0;
    var mutable = false;
    var child_index: u32 = 0;
    while (node.namedChild(child_index)) |child| : (child_index += 1) {
        const child_kind = child.kind();
        if (std.mem.eql(u8, child_kind, "mutable_specifier") or
            std.mem.eql(u8, text(e, child), "mut"))
        {
            if (mutable) return unsupported(e, "reference expression");
            mutable = true;
            continue;
        }
        if (std.mem.eql(u8, child_kind, "lifetime")) continue;
        operand_count += 1;
        if (operand_count == 1) operand = child;
    }
    if (operand_count != 1) return unsupported(e, "reference expression");
    const operand_id = try lowerExpr(e, operand.?);
    return appendExpr(e, .{ .unary = .{
        .op = .{ .ref = if (mutable) .mutable else .shared },
        .operand = operand_id,
    } });
}

const PrimitiveAssociatedConstant = struct {
    primitive: types.Prim,
    value: i128,
};

fn primitiveAssociatedConstant(raw: []const u8) ?PrimitiveAssociatedConstant {
    var segments: [4][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, std.mem.trim(u8, raw, " \t\r\n"), "::");
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (count == segments.len) return null;
        segments[count] = trimmed;
        count += 1;
    }
    if (count < 2) return null;
    if (count > 2 and
        !std.mem.eql(u8, segments[0], "std") and
        !std.mem.eql(u8, segments[0], "core"))
    {
        return null;
    }
    const primitive = mapPrim(segments[count - 2]) orelse return null;
    const is_max = std.mem.eql(u8, segments[count - 1], "MAX");
    const is_min = std.mem.eql(u8, segments[count - 1], "MIN");
    if (!is_max and !is_min) return null;
    const value: i128 = switch (primitive) {
        .i8 => if (is_max) std.math.maxInt(i8) else std.math.minInt(i8),
        .i16 => if (is_max) std.math.maxInt(i16) else std.math.minInt(i16),
        .i32 => if (is_max) std.math.maxInt(i32) else std.math.minInt(i32),
        .i64 => if (is_max) std.math.maxInt(i64) else std.math.minInt(i64),
        .i128 => if (is_max) std.math.maxInt(i128) else std.math.minInt(i128),
        .u8 => if (is_max) std.math.maxInt(u8) else 0,
        .u16 => if (is_max) std.math.maxInt(u16) else 0,
        .u32 => if (is_max) std.math.maxInt(u32) else 0,
        .u64 => if (is_max) std.math.maxInt(u64) else 0,
        .usize => if (is_max) std.math.maxInt(usize) else 0,
        .u128 => if (is_max) return null else 0,
        else => return null,
    };
    return .{ .primitive = primitive, .value = value };
}

fn lowerPrimitiveAssociatedConstant(e: *Ext, constant: PrimitiveAssociatedConstant) anyerror!exprs.NodeId {
    return appendExpr(e, .{ .literal = .{ .int = .{
        .text = try std.fmt.allocPrint(e.ctx.alloc, "{d}{s}", .{
            constant.value,
            @tagName(constant.primitive),
        }),
        .value = constant.value,
        .base = .dec,
        .ty_suffix = @tagName(constant.primitive),
    } } });
}
fn lowerPathValue(e: *Ext, def: spine.EntityId) anyerror!exprs.NodeId {
    const entity = e.ctx.g.symbol_table.get(def) orelse return error.MalformedCst;
    if (entity.kind == .variant) {
        const owner = entity.parent orelse return error.MalformedCst;
        if (owner < e.ctx.bodies_list.items.len) {
            switch (e.ctx.bodies_list.items[owner]) {
                .enum_ => |enum_body| for (enum_body.variants) |variant| {
                    if (variant.fields == .none and std.mem.eql(u8, variant.name, entity.name)) {
                        return appendExpr(e, .{ .enum_variant = .{
                            .def = owner,
                            .variant = try e.ctx.alloc.dupe(u8, entity.name),
                            .tuple_fields = &.{},
                            .named_fields = &.{},
                        } });
                    }
                },
                else => {},
            }
        }
    }
    return appendExpr(e, .{ .path = .{ .def = def, .generic_args = &.{} } });
}

fn lowerExpr(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const kind = node.kind();

    // Identifiers & paths.
    if (std.mem.eql(u8, kind, "identifier")) {
        const nm = text(e, node);
        var def = resolveName(e, nm);
        if (def == null) {
            if (try ensureStandardPreludeVariant(e, nm)) |standard| {
                def = standard.variant_id;
            }
        }
        if (def) |resolved| {
            return lowerPathValue(e, resolved);
        }
        return unsupported(e, "unresolved identifier");
    }
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
    if (std.mem.eql(u8, kind, "unit_expression")) {
        return appendExpr(e, .{ .unit = {} });
    }

    if (std.mem.eql(u8, kind, "generic_function")) {
        const function_node = node.childByFieldName("function") orelse
            return error.MalformedCst;
        const generic_args = try lowerGenericCallArgs(e, node);
        if (try coreFunction(e, text(e, function_node))) |function| {
            return appendExpr(e, .{ .core_function = .{
                .function = function,
                .generic_args = generic_args,
            } });
        }

        var def: ?spine.EntityId = null;
        if (std.mem.eql(u8, function_node.kind(), "identifier")) {
            def = resolveName(e, text(e, function_node));
        } else if (std.mem.eql(u8, function_node.kind(), "scoped_identifier") or
            std.mem.eql(u8, function_node.kind(), "scoped_type_identifier"))
        {
            def = resolvePatternPath(e, function_node);
        }
        if (def) |resolved| {
            return appendExpr(e, .{ .path = .{
                .def = resolved,
                .generic_args = generic_args,
            } });
        }
        if (generic_args.len > 0) e.ctx.alloc.free(generic_args);
        return unsupported(e, "unresolved generic function");
    }

    if (std.mem.eql(u8, kind, "scoped_identifier") or
        std.mem.eql(u8, kind, "scoped_type_identifier"))
    {
        if (try lowerQualifiedAssociatedConstPath(e, node)) |associated_const| {
            return associated_const;
        }
        if (try lowerBoundAssociatedConstPath(e, text(e, node))) |associated_const| {
            return associated_const;
        }
        if (primitiveAssociatedConstant(text(e, node))) |constant| {
            return lowerPrimitiveAssociatedConstant(e, constant);
        }
        if (try lowerUnitVariantPath(e, node)) |variant| {
            return variant;
        }
        if (resolvePatternPath(e, node)) |def| {
            return lowerPathValue(e, def);
        }
        if (try ensureStandardPreludePath(e, text(e, node))) |standard| {
            return lowerPathValue(e, standard.variant_id);
        }
        return unsupported(e, "unresolved scoped path");
    }
    if (std.mem.eql(u8, kind, "mutable_specifier")) return error.MalformedCst;

    // Binary / compound assignments.
    if (std.mem.eql(u8, kind, "binary_expression")) {
        const lhs = node.namedChild(0);
        const rhs = node.namedChild(if (node.namedChildCount() > 2) 2 else 1);
        if (lhs == null or rhs == null) return error.MalformedCst;
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

    if (std.mem.eql(u8, kind, "range_expression")) {
        return lowerRangeExpression(e, node);
    }
    if (std.mem.eql(u8, kind, "closure_expression")) {
        const closure = (try lowerClosureExpression(e, node)) orelse
            return unsupported(e, "closure expression");
        return appendExpr(e, .{ .closure = closure });
    }

    // Calls & construction.
    if (std.mem.eql(u8, kind, "call_expression")) {
        return lowerCall(e, node);
    }
    if (std.mem.eql(u8, kind, "method_call_expression")) {
        return lowerMethodCall(e, node);
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
        if (base == null) return error.MalformedCst;
        var fname = if (field) |field_node| text(e, field_node) else "";
        if (fname.len == 0) {
            var child_index: u32 = 0;
            while (node.child(child_index)) |child| : (child_index += 1) {
                if (child.isNamed()) continue;
                const candidate = text(e, child);
                if (candidate.len > 0 and !std.mem.eql(u8, candidate, ".")) {
                    fname = candidate;
                }
            }
        }
        if (fname.len == 0) {
            const raw = text(e, node);
            if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| {
                fname = std.mem.trim(u8, raw[dot + 1 ..], " \t\r\n");
            }
        }
        if (fname.len == 0) return error.MalformedCst;
        return appendExpr(e, .{ .field = .{
            .base = try lowerExpr(e, base.?),
            .field = try e.ctx.alloc.dupe(u8, fname),
            .resolved = 0,
        } });
    }
    if (std.mem.eql(u8, kind, "index_expression")) {
        const base = node.namedChild(0);
        const idx = node.namedChild(1);
        if (base == null or idx == null) return error.MalformedCst;
        return appendExpr(e, .{ .index = .{
            .base = try lowerExpr(e, base.?),
            .index = try lowerExpr(e, idx.?),
        } });
    }

    // Cast / block / for / if / return / unary / paren / reference.
    if (std.mem.eql(u8, kind, "type_cast_expression")) return lowerCast(e, node);
    if (std.mem.eql(u8, kind, "unsafe_block")) {
        const body = controlBlock(node) orelse return error.MalformedCst;
        return appendExpr(e, .{ .block = try lowerBlock(e, body) });
    }
    if (std.mem.eql(u8, kind, "loop_expression")) {
        const body_node = controlBlock(node) orelse return error.MalformedCst;
        var body = try lowerBlock(e, body_node);
        body.labelled = try controlLabel(e, node);
        return appendExpr(e, .{ .loop_ = .{ .body = body } });
    }
    if (std.mem.eql(u8, kind, "break_expression")) {
        return appendExpr(e, .{ .break_ = .{
            .label = try controlLabel(e, node),
            .value = try controlValue(e, node),
        } });
    }
    if (std.mem.eql(u8, kind, "continue_expression")) {
        return appendExpr(e, .{ .continue_ = .{ .label = try controlLabel(e, node) } });
    }
    if (std.mem.eql(u8, kind, "while_expression")) {
        const outer_local_count = e.locals.items.len;
        defer e.locals.items.len = outer_local_count;
        var cond_node: ?ts.Node = null;
        var body_node: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (std.mem.eql(u8, c.kind(), "block")) body_node = c else if (cond_node == null) cond_node = c;
        }
        const cond = cond_node orelse return error.MalformedCst;
        const body = body_node orelse return error.MalformedCst;
        var capture: ?exprs.NodeId = null;
        var cond_id: exprs.NodeId = undefined;
        if (try splitLetCondition(e, cond)) |let_cond| {
            // Evaluate the scrutinee before introducing pattern bindings.
            cond_id = try lowerExpr(e, let_cond.value);
            capture = try lowerPattern(e, let_cond.pattern);
            if (knownPatternPayloadType(e, cond_id)) |payload| {
                setPatternLocalTypes(e, capture.?, payload);
            }
        } else {
            cond_id = try lowerExpr(e, cond);
        }
        return appendExpr(e, .{ .while_ = .{
            .cond = cond_id,
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
        if (operand == null) return error.MalformedCst;
        const operator = opOf(e, node);
        const operand_id = try lowerExpr(e, operand.?);
        if (std.mem.eql(u8, operator, "!")) {
            const op_ty = knownCastOperandType(e, operand_id);
            const op: exprs.UnaryOp = if (op_ty != null and isIntegerType(op_ty.?))
                .bit_not
            else
                .logical_not;
            return appendExpr(e, .{ .unary = .{ .op = op, .operand = operand_id } });
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
    }
    if (std.mem.eql(u8, kind, "reference_expression")) {
        return lowerReferenceExpression(e, node);
    }
    if (std.mem.eql(u8, kind, "array_expression")) {
        return lowerArrayExpression(e, node);
    }
    if (std.mem.eql(u8, kind, "tuple_expression")) {
        var elements: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer elements.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (isComment(child)) continue;
            try elements.append(e.ctx.alloc, try lowerExpr(e, child));
        }
        if (elements.items.len == 0) return error.MalformedCst;
        const owned_elements = try elements.toOwnedSlice(e.ctx.alloc);
        const tuple_id = try appendExpr(e, .{ .array = .{
            .elements = owned_elements,
            .repeat = null,
        } });
        try attachKnownTupleType(e, tuple_id, owned_elements);
        return tuple_id;
    }
    if (std.mem.eql(u8, kind, "parenthesized_expression")) {
        if (node.namedChildCount() > 0) return lowerExpr(e, node.namedChild(0).?);
        return error.MalformedCst;
    }
    if (std.mem.eql(u8, kind, "try_expression")) {
        const inner_node = node.namedChild(0) orelse node.childByFieldName("expression") orelse return error.MalformedCst;
        const inner_id = try lowerExpr(e, inner_node);
        return appendExpr(e, .{ .try_ = .{ .inner = inner_id } });
    }
    return unsupported(e, kind);
}

fn lowerIntLit(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const t = text(e, node);
    const parsed = parseIntLiteral(t) orelse return unsupported(e, "integer literal out of range");
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

fn parseIntLiteral(raw: []const u8) ?ParsedIntLiteral {
    var body = raw;
    var ty_suffix: ?[]const u8 = null;
    for (int_suffixes) |suffix| {
        if (body.len > suffix.len and std.mem.endsWith(u8, body, suffix)) {
            body = body[0 .. body.len - suffix.len];
            ty_suffix = suffix;
            break;
        }
    }

    var base: u8 = 10;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) base = 16;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'b' or body[1] == 'B')) base = 2;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'o' or body[1] == 'O')) base = 8;
    const untrimmed_digits = if (base == 10) body else body[2..];
    const digits = std.mem.trimEnd(u8, untrimmed_digits, "_");
    if (digits.len == 0) return null;
    const value = std.fmt.parseInt(i128, digits, base) catch return null;
    return .{
        .body = body,
        .value = value,
        .base = base,
        .ty_suffix = ty_suffix,
    };
}

test "Rust integer suffixes preserve separated and hexadecimal values" {
    const separated = parseIntLiteral("0_u8") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 0), separated.value);
    try std.testing.expectEqualStrings("u8", separated.ty_suffix.?);
    const hexadecimal = parseIntLiteral("0xffu8") orelse return error.LiteralRejected;
    try std.testing.expectEqual(@as(i128, 255), hexadecimal.value);
    try std.testing.expectEqualStrings("u8", hexadecimal.ty_suffix.?);
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

fn checkedArrayLenBinary(op: exprs.BinaryOp, lhs: usize, rhs: usize) ?usize {
    return switch (op) {
        .add => std.math.add(usize, lhs, rhs) catch null,
        .sub => std.math.sub(usize, lhs, rhs) catch null,
        .mul => std.math.mul(usize, lhs, rhs) catch null,
        .div => if (rhs == 0) null else lhs / rhs,
        .rem => if (rhs == 0) null else lhs % rhs,
        .bit_and => lhs & rhs,
        .bit_or => lhs | rhs,
        .bit_xor => lhs ^ rhs,
        .shl => blk: {
            if (rhs >= @bitSizeOf(usize)) break :blk null;
            const shift: std.math.Log2Int(usize) = @intCast(rhs);
            if (lhs > (@as(usize, std.math.maxInt(usize)) >> shift)) break :blk null;
            break :blk lhs << shift;
        },
        .shr => blk: {
            if (rhs >= @bitSizeOf(usize)) break :blk null;
            break :blk lhs >> @as(std.math.Log2Int(usize), @intCast(rhs));
        },
        else => null,
    };
}

fn constArrayLenFromExpr(e: *const Ext, node_id: exprs.NodeId, remaining: usize) ?usize {
    if (remaining == 0 or node_id >= e.ctx.exprs.items.len) return null;
    return switch (e.ctx.exprs.items[node_id].kind) {
        .literal => |literal| switch (literal) {
            .int => |integer| blk: {
                if (integer.value < 0) break :blk null;
                const max_usize: i128 = @intCast(std.math.maxInt(usize));
                if (integer.value > max_usize) break :blk null;
                break :blk @intCast(integer.value);
            },
            else => null,
        },
        .binary => |binary| blk: {
            const lhs = constArrayLenFromExpr(e, binary.lhs, remaining - 1) orelse break :blk null;
            const rhs = constArrayLenFromExpr(e, binary.rhs, remaining - 1) orelse break :blk null;
            break :blk checkedArrayLenBinary(binary.op, lhs, rhs);
        },
        .cast => |cast| constArrayLenFromExpr(e, cast.operand, remaining - 1),
        .path => |path| blk: {
            if (path.def >= e.ctx.bodies_list.items.len) break :blk null;
            const body = switch (e.ctx.bodies_list.items[path.def]) {
                .const_ => |const_body| const_body,
                else => break :blk null,
            };
            break :blk constArrayLenFromExpr(e, body.init, remaining - 1);
        },
        else => null,
    };
}

fn constArrayLenFromCst(e: *const Ext, node: ts.Node, remaining: usize) ?usize {
    if (remaining == 0) return null;
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "integer_literal")) {
        return parseVecRepeatCount(text(e, node));
    }
    if (std.mem.eql(u8, kind, "parenthesized_expression")) {
        const inner = node.namedChild(0) orelse return null;
        return constArrayLenFromCst(e, inner, remaining - 1);
    }
    if (std.mem.eql(u8, kind, "type_cast_expression")) {
        const operand = node.namedChild(0) orelse return null;
        return constArrayLenFromCst(e, operand, remaining - 1);
    }
    if (std.mem.eql(u8, kind, "binary_expression")) {
        const lhs_node = node.childByFieldName("left") orelse node.namedChild(0) orelse return null;
        const rhs_node = node.childByFieldName("right") orelse
            node.namedChild(if (node.namedChildCount() > 2) 2 else 1) orelse return null;
        const op = mapBinaryOp(opOf(e, node)) orelse return null;
        const lhs = constArrayLenFromCst(e, lhs_node, remaining - 1) orelse return null;
        const rhs = constArrayLenFromCst(e, rhs_node, remaining - 1) orelse return null;
        return checkedArrayLenBinary(op, lhs, rhs);
    }
    if (std.mem.eql(u8, kind, "identifier")) {
        const def = resolveName(e, text(e, node)) orelse return null;
        if (def >= e.ctx.bodies_list.items.len) return null;
        const body = switch (e.ctx.bodies_list.items[def]) {
            .const_ => |const_body| const_body,
            else => return null,
        };
        return constArrayLenFromExpr(e, body.init, remaining - 1);
    }
    if (std.mem.eql(u8, kind, "scoped_identifier")) {
        const def = resolveScopedPath(e, node) orelse return null;
        if (def >= e.ctx.bodies_list.items.len) return null;
        const body = switch (e.ctx.bodies_list.items[def]) {
            .const_ => |const_body| const_body,
            else => return null,
        };
        return constArrayLenFromExpr(e, body.init, remaining - 1);
    }
    return null;
}

fn sourceDeterminedExprType(e: *const Ext, node_id: exprs.NodeId) ?types.Type {
    if (node_id >= e.ctx.exprs.items.len) return null;
    const expression = e.ctx.exprs.items[node_id];
    if (expression.ty) |type_id| {
        if (type_id < e.ctx.types.items.len) return e.ctx.types.items[type_id];
    }
    switch (expression.kind) {
        .literal => |literal| return switch (literal) {
            .int => |integer| if (integer.ty_suffix != null)
                knownCastOperandType(e, node_id)
            else
                null,
            .float => |float| if (std.mem.endsWith(u8, float.text, "f32") or
                std.mem.endsWith(u8, float.text, "f64"))
                knownCastOperandType(e, node_id)
            else
                null,
            .boolean => .{ .prim = .bool },
            .character => .{ .prim = .char },
            else => null,
        },
        else => return knownCastOperandType(e, node_id),
    }
}

fn attachKnownArrayType(
    e: *Ext,
    array_id: exprs.NodeId,
    elements: []const exprs.NodeId,
    len: usize,
) !void {
    if (elements.len == 0) return;
    const element_type = sourceDeterminedExprType(e, elements[0]) orelse return;
    for (elements[1..]) |element| {
        const candidate = sourceDeterminedExprType(e, element) orelse return;
        if (!infer.typeEqual(element_type, candidate)) return;
    }
    const array_type = try e.ctx.alloc.create(types.Array);
    errdefer e.ctx.alloc.destroy(array_type);
    array_type.* = .{
        .elem = element_type,
        .len = .{ .literal = @intCast(len) },
    };
    const aggregate: types.Type = .{ .array = array_type };
    if (!isConcreteDeclaredReturnType(aggregate)) return;
    if (infer.findTypeIndexInSlice(e.ctx.types.items, aggregate)) |existing| {
        e.ctx.alloc.destroy(array_type);
        e.ctx.exprs.items[array_id].ty = existing;
        return;
    }
    const type_id: exprs.TypeId = @intCast(e.ctx.types.items.len);
    try e.ctx.types.append(e.ctx.alloc, aggregate);
    e.ctx.exprs.items[array_id].ty = type_id;
}

fn attachKnownTupleType(
    e: *Ext,
    tuple_id: exprs.NodeId,
    elements: []const exprs.NodeId,
) !void {
    if (elements.len == 0) return;
    const tuple_types = try e.ctx.alloc.alloc(types.Type, elements.len);
    errdefer e.ctx.alloc.free(tuple_types);
    for (elements, 0..) |element, index| {
        tuple_types[index] = sourceDeterminedExprType(e, element) orelse {
            e.ctx.alloc.free(tuple_types);
            return;
        };
    }
    const aggregate: types.Type = .{ .tuple = tuple_types };
    if (!isConcreteDeclaredReturnType(aggregate)) {
        e.ctx.alloc.free(tuple_types);
        return;
    }
    if (infer.findTypeIndexInSlice(e.ctx.types.items, aggregate)) |existing| {
        e.ctx.alloc.free(tuple_types);
        e.ctx.exprs.items[tuple_id].ty = existing;
        return;
    }
    const type_id: exprs.TypeId = @intCast(e.ctx.types.items.len);
    try e.ctx.types.append(e.ctx.alloc, aggregate);
    e.ctx.exprs.items[tuple_id].ty = type_id;
}

fn lowerArrayExpression(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    if (node.childByFieldName("length")) |length_node| {
        const element_node = node.childByFieldName("element") orelse
            node.childByFieldName("value") orelse
            node.namedChild(0) orelse return error.MalformedCst;
        const repeat = constArrayLenFromCst(
            e,
            length_node,
            e.ctx.g.symbol_table.entities.items.len + e.ctx.exprs.items.len + 1,
        ) orelse return unsupported(e, "array repeat count is not a source constant");
        const element = try lowerExpr(e, element_node);
        const elements = try e.ctx.alloc.alloc(exprs.NodeId, 1);
        elements[0] = element;
        const array_id = try appendExpr(e, .{ .array = .{
            .elements = elements,
            .repeat = repeat,
        } });
        try attachKnownArrayType(e, array_id, elements, repeat);
        return array_id;
    }

    var elements: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer elements.deinit(e.ctx.alloc);
    var index: u32 = 0;
    while (node.namedChild(index)) |child| : (index += 1) {
        if (isComment(child)) continue;
        try elements.append(e.ctx.alloc, try lowerExpr(e, child));
    }
    const owned_elements = try elements.toOwnedSlice(e.ctx.alloc);
    const array_id = try appendExpr(e, .{ .array = .{
        .elements = owned_elements,
        .repeat = null,
    } });
    try attachKnownArrayType(e, array_id, owned_elements, owned_elements.len);
    return array_id;
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
fn isUnicodeScalar(value: u32) bool {
    return value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff);
}

fn decodeUtf8Codepoint(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    const first = bytes[0];
    if (first < 0x80) return if (bytes.len == 1) @as(u32, first) else null;

    var width: usize = 0;
    var value: u32 = 0;
    var minimum: u32 = 0;
    if (first >= 0xc2 and first <= 0xdf) {
        width = 2;
        value = @as(u32, first & 0x1f);
        minimum = 0x80;
    } else if (first >= 0xe0 and first <= 0xef) {
        width = 3;
        value = @as(u32, first & 0x0f);
        minimum = 0x800;
    } else if (first >= 0xf0 and first <= 0xf4) {
        width = 4;
        value = @as(u32, first & 0x07);
        minimum = 0x10000;
    } else {
        return null;
    }

    if (bytes.len != width) return null;
    for (bytes[1..width]) |byte| {
        if (byte < 0x80 or byte > 0xbf) return null;
        value = (value << 6) | @as(u32, byte & 0x3f);
    }
    if (value < minimum or !isUnicodeScalar(value)) return null;
    return value;
}

fn decodeRustCharCodepoint(raw: []const u8) ?u32 {
    if (raw.len < 3 or raw[0] != '\'' or raw[raw.len - 1] != '\'') return null;
    const body = raw[1 .. raw.len - 1];
    if (body.len == 0) return null;
    if (body[0] != '\\') return decodeUtf8Codepoint(body);
    if (body.len < 2) return null;

    return switch (body[1]) {
        'n' => 0x0a,
        'r' => 0x0d,
        't' => 0x09,
        '0' => 0,
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'x' => blk: {
            if (body.len != 4) break :blk null;
            const high = hexDigit(body[2]) orelse break :blk null;
            const low = hexDigit(body[3]) orelse break :blk null;
            const value = @as(u32, high) * 16 + @as(u32, low);
            break :blk if (value <= 0x7f) value else null;
        },
        'u' => blk: {
            if (body.len < 5 or body[2] != '{' or body[body.len - 1] != '}') {
                break :blk null;
            }
            const digits = body[3 .. body.len - 1];
            if (digits.len == 0 or digits.len > 6) break :blk null;
            var value: u32 = 0;
            for (digits) |digit| {
                const nibble = hexDigit(digit) orelse break :blk null;
                value = value * 16 + @as(u32, nibble);
            }
            if (!isUnicodeScalar(value)) break :blk null;
            break :blk value;
        },
        else => null,
    };
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
    const bytes = try allocator.dupe(u8, raw[body_start..close_start]);
    return bytes;
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
        if (raw.len < prefix_len + 3) return null;
        const closing_quote = raw.len - 1;
        if (raw[closing_quote] != '\'') return null;
        const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. closing_quote]);
        if (bytes.len == 1) return bytes;
        allocator.free(bytes);
        return null;
    }
    if (quote != '"') return null;
    if (raw.len < prefix_len + 2) return null;
    const closing_quote = raw.len - 1;
    if (raw[closing_quote] != '"') return null;
    const bytes = try decodeEscapedBytes(allocator, raw[prefix_len + 1 .. closing_quote]);
    return bytes;
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
    const value = std.fmt.parseFloat(f64, t) catch return unsupported(e, "invalid float literal");
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
        if (is_byte) {
            if (bytes.len != 1) {
                e.ctx.alloc.free(bytes);
                return unsupported(e, "invalid byte literal");
            }
            const value = bytes[0];
            e.ctx.alloc.free(bytes);
            return appendExpr(e, .{ .literal = .{ .int = .{
                .text = try std.fmt.allocPrint(e.ctx.alloc, "{d}u8", .{value}),
                .value = value,
                .base = .dec,
                .ty_suffix = "u8",
            } } });
        }
        return appendExpr(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
    }
    if (is_byte) return unsupported(e, "invalid byte literal");
    const value = decodeRustCharCodepoint(t) orelse return unsupported(e, "invalid char literal");
    return appendExpr(e, .{ .literal = .{ .character = .{
        .text = try e.ctx.alloc.dupe(u8, t),
        .value = value,
    } } });
}

fn lowerStructExpr(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const name_node = node.childByFieldName("name") orelse return error.MalformedCst;
    const fields_node = node.childByFieldName("body") orelse return error.MalformedCst;
    const raw_name = std.mem.trim(u8, text(e, name_node), " \t\r\n");
    var leaf_name = raw_name;
    if (std.mem.lastIndexOfScalar(u8, leaf_name, ':')) |index| leaf_name = leaf_name[index + 1 ..];
    if (std.mem.indexOfScalar(u8, leaf_name, '<')) |index| leaf_name = leaf_name[0..index];
    leaf_name = std.mem.trim(u8, leaf_name, " \t\r\n:");
    const def = resolvePatternPath(e, name_node) orelse
        (resolveName(e, leaf_name) orelse return unsupported(e, "unresolved struct type"));

    var fields: std.ArrayListUnmanaged(exprs.FieldInit) = .empty;
    defer fields.deinit(e.ctx.alloc);
    var base_id: ?exprs.NodeId = null;
    var i: u32 = 0;
    while (fields_node.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "field_initializer")) {
            const field_node = child.childByFieldName("field") orelse return error.MalformedCst;
            const value_node = child.childByFieldName("value") orelse return error.MalformedCst;
            try fields.append(e.ctx.alloc, .{
                .field = try e.ctx.alloc.dupe(u8, text(e, field_node)),
                .value = try lowerExpr(e, value_node),
                .shorthand = false,
            });
        } else if (std.mem.eql(u8, kind, "shorthand_field_initializer")) {
            var field_node: ?ts.Node = null;
            var j: u32 = 0;
            while (child.namedChild(j)) |field| : (j += 1) {
                if (isBlockTrivia(field)) continue;
                if (std.mem.eql(u8, field.kind(), "identifier")) {
                    field_node = field;
                    break;
                }
            }
            const field = field_node orelse return error.MalformedCst;
            const field_name = text(e, field);
            const value_def = resolveName(e, field_name) orelse
                return unsupported(e, "unresolved struct field");
            const value_id = try appendExpr(e, .{ .path = .{
                .def = value_def,
                .generic_args = &.{},
            } });
            try fields.append(e.ctx.alloc, .{
                .field = try e.ctx.alloc.dupe(u8, field_name),
                .value = value_id,
                .shorthand = true,
            });
        } else if (std.mem.eql(u8, kind, "base_field_initializer")) {
            const base_node = child.namedChild(0) orelse return error.MalformedCst;
            base_id = try lowerExpr(e, base_node);
        } else if (isBlockTrivia(child)) {
            continue;
        } else {
            return error.MalformedCst;
        }
    }

    const entity = e.ctx.g.symbol_table.get(def) orelse return error.MalformedCst;
    if (entity.kind == .variant) {
        if (base_id != null) return unsupported(e, "enum variant update expression");
        return appendExpr(e, .{ .enum_variant = .{
            .def = entity.parent orelse return error.MalformedCst,
            .variant = try e.ctx.alloc.dupe(u8, entity.name),
            .tuple_fields = &.{},
            .named_fields = try fields.toOwnedSlice(e.ctx.alloc),
        } });
    }
    // A variant carrying named fields has no `.variant` entity of its own, so
    // path resolution lands on the enum. Recognize the variant by name so
    // `Enum::Variant { .. }` is not mistaken for a struct literal.
    if (entity.kind == .enum_ and enumBodyHasVariant(e, def, leaf_name)) {
        if (base_id != null) return unsupported(e, "enum variant update expression");
        return appendExpr(e, .{ .enum_variant = .{
            .def = def,
            .variant = try e.ctx.alloc.dupe(u8, leaf_name),
            .tuple_fields = &.{},
            .named_fields = try fields.toOwnedSlice(e.ctx.alloc),
        } });
    }
    return appendExpr(e, .{ .struct_lit = .{
        .def = def,
        .fields = try fields.toOwnedSlice(e.ctx.alloc),
        .base = base_id,
    } });
}

fn lowerFieldPattern(e: *Ext, node: ts.Node) anyerror!exprs.FieldPat {
    const field_node = node.childByFieldName("name") orelse return error.MalformedCst;
    const field_name = text(e, field_node);
    if (field_name.len == 0) return error.MalformedCst;
    const pattern_node = node.childByFieldName("pattern");
    var by_ref = false;
    var mutable = false;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        const child_text = std.mem.trim(u8, text(e, child), " \t\r\n");
        if (std.mem.eql(u8, child_text, "ref")) by_ref = true;
        if (std.mem.eql(u8, child.kind(), "mutable_specifier") or
            std.mem.eql(u8, child_text, "mut"))
        {
            mutable = true;
        }
    }
    if (pattern_node) |nested| {
        const pattern_id = try lowerPattern(e, nested);
        if (by_ref or mutable) {
            if (e.ctx.pats.items[pattern_id].kind == .binding) {
                var binding = e.ctx.pats.items[pattern_id].kind.binding;
                binding.mutable = binding.mutable or mutable;
                binding.mode = if (mutable) .{ .mut_ref = {} } else .{ .shared_ref = {} };
                e.ctx.pats.items[pattern_id].kind = .{ .binding = binding };
            }
        }
        return .{
            .field = try e.ctx.alloc.dupe(u8, field_name),
            .pat = pattern_id,
            .shorthand = false,
        };
    }
    _ = try pushLocal(e, field_name);
    const pattern_id = try appendPat(e, .{ .binding = .{
        .name = try e.ctx.alloc.dupe(u8, field_name),
        .mode = if (mutable) .{ .mut_ref = {} } else if (by_ref) .{ .shared_ref = {} } else .{ .value = {} },
        .mutable = mutable,
    } });
    return .{
        .field = try e.ctx.alloc.dupe(u8, field_name),
        .pat = pattern_id,
        .shorthand = true,
    };
}

fn lowerPatternBound(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    if (std.mem.eql(u8, node.kind(), "literal_pattern")) {
        const literal = node.namedChild(0) orelse return error.MalformedCst;
        return lowerExpr(e, literal);
    }
    return lowerExpr(e, node);
}

fn patternRangeInclusive(e: *const Ext, node: ts.Node) bool {
    const raw = text(e, node);
    return std.mem.indexOf(u8, raw, "..=") != null or
        std.mem.indexOf(u8, raw, "...") != null;
}
fn lowerPattern(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "literal_pattern")) {
        if (node.namedChild(0)) |inner| return lowerPattern(e, inner);
        return appendPat(e, .{ .unsupported = .{
            .reason = "empty literal pattern",
            .suggested_version = .v3,
        } });
    }

    // A generic `pattern` wrapper: unwrap when it simply wraps another
    // pattern, or handle an inline `mutable_specifier`+identifier binding.
    if (std.mem.eql(u8, kind, "pattern")) {
        var mut = false;
        var inner: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |c| : (i += 1) {
            if (isBlockTrivia(c)) continue;
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
        return error.MalformedCst;
    }

    if (std.mem.eql(u8, kind, "identifier")) {
        const name = text(e, node);
        if (resolveName(e, name)) |def| {
            const entity = e.ctx.g.symbol_table.get(def) orelse return error.MalformedCst;
            if (entity.kind == .variant or entity.kind == .const_) {
                return appendPat(e, .{ .path = .{
                    .def = def,
                    .variant = try e.ctx.alloc.dupe(u8, name),
                } });
            }
        } else if (try ensureStandardPreludeVariant(e, name)) |standard| {
            return appendPat(e, .{ .path = .{
                .def = standard.variant_id,
                .variant = try e.ctx.alloc.dupe(u8, name),
            } });
        }
        _ = try pushLocal(e, name);
        return appendPat(e, .{ .binding = .{
            .name = try e.ctx.alloc.dupe(u8, name),
            .mode = .value,
            .mutable = false,
        } });
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
        if (nm.len == 0) return error.MalformedCst;
        _ = try pushLocal(e, nm);
        return appendPat(e, .{ .binding = .{
            .name = try e.ctx.alloc.dupe(u8, nm),
            .mode = .{ .value = {} },
            .mutable = true,
        } });
    }

    if (std.mem.eql(u8, kind, "scoped_identifier") or std.mem.eql(u8, kind, "path")) {
        const t = text(e, node);
        const last = std.mem.lastIndexOfScalar(u8, t, ':');
        const leaf = if (last) |idx| t[idx + 1 ..] else t;
        var def_opt: ?spine.EntityId = null;
        if (last != null) {
            def_opt = resolvePatternPath(e, node);
            if (def_opt == null) {
                if (try ensureStandardPreludePath(e, t)) |standard|
                    def_opt = standard.variant_id;
            }
        } else {
            def_opt = resolveName(e, leaf);
        }
        const def = def_opt orelse return appendPat(e, .{ .unsupported = .{
            .reason = "unresolved pattern path",
            .suggested_version = .v3,
        } });
        return appendPat(e, .{ .path = .{
            .def = def,
            .variant = try e.ctx.alloc.dupe(u8, leaf),
        } });
    }

    if (std.mem.eql(u8, kind, "range_pattern")) {
        const left = node.childByFieldName("left");
        const right = node.childByFieldName("right");
        if (left == null and right == null) return error.MalformedCst;
        var lower: ?exprs.NodeId = null;
        if (left) |bound| lower = try lowerPatternBound(e, bound);
        var upper: ?exprs.NodeId = null;
        if (right) |bound| upper = try lowerPatternBound(e, bound);
        return appendPat(e, .{ .range = .{
            .lo = lower,
            .hi = upper,
            .inclusive = patternRangeInclusive(e, node),
        } });
    }

    if (std.mem.eql(u8, kind, "ref_pattern")) {
        const inner = firstNestedPatternChild(node) orelse return error.MalformedCst;
        const pattern_id = try lowerPattern(e, inner);
        if (e.ctx.pats.items[pattern_id].kind != .binding) {
            return appendPat(e, .{ .unsupported = .{
                .reason = "ref pattern",
                .suggested_version = .v3,
            } });
        }
        var binding = e.ctx.pats.items[pattern_id].kind.binding;
        binding.mode = if (binding.mutable) .{ .mut_ref = {} } else .{ .shared_ref = {} };
        e.ctx.pats.items[pattern_id].kind = .{ .binding = binding };
        return pattern_id;
    }
    if (std.mem.eql(u8, kind, "slice_pattern")) {
        return appendPat(e, .{ .unsupported = .{
            .reason = "slice pattern",
            .suggested_version = .v3,
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
            } else if (!isBlockTrivia(c)) {
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
        if (firstMatchPatternChild(node)) |inner| return lowerPattern(e, inner);
        if (std.mem.eql(u8, std.mem.trim(u8, text(e, node), " \t\r\n"), "_")) {
            return appendPat(e, .{ .wildcard = {} });
        }
        return error.MalformedCst;
    }

    if (std.mem.eql(u8, kind, "tuple_struct_pattern")) {
        const type_node = node.childByFieldName("type") orelse return error.MalformedCst;
        var pat_nodes: std.ArrayListUnmanaged(ts.Node) = .empty;
        defer pat_nodes.deinit(e.ctx.alloc);
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (child.id == type_node.id or isBlockTrivia(child)) continue;
            try pat_nodes.append(e.ctx.alloc, child);
        }

        const raw_type = std.mem.trim(u8, text(e, type_node), " \t\r\n");
        var leaf = raw_type;
        if (std.mem.lastIndexOfScalar(u8, leaf, ':')) |index| leaf = leaf[index + 1 ..];
        if (std.mem.indexOfScalar(u8, leaf, '<')) |index| leaf = leaf[0..index];
        leaf = std.mem.trim(u8, leaf, " \t\r\n:");
        const def_opt: ?spine.EntityId = blk: {
            if (resolvePatternPath(e, type_node)) |resolved| break :blk resolved;
            if (resolveName(e, leaf)) |resolved| break :blk resolved;
            if (try ensureStandardPreludeVariant(e, leaf)) |standard| break :blk standard.variant_id;
            break :blk null;
        };
        if (def_opt == null) {
            if (std.mem.lastIndexOf(u8, raw_type, "::")) |last_sep| {
                const owner_text = raw_type[0..last_sep];
                const variant_name = std.mem.trim(u8, raw_type[last_sep + 2 ..], " \t\r\n");
                if (variant_name.len > 0) {
                    if (try externalCowVariantForPath(e, owner_text, variant_name)) |owner| {
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
                        return appendPat(e, .{ .external_variant = .{
                            .owner = owner,
                            .variant = try e.ctx.alloc.dupe(u8, variant_name),
                            .fields = try field_pats.toOwnedSlice(e.ctx.alloc),
                            .rest = false,
                        } });
                    }
                }
            }
        }

        const def = def_opt orelse return appendPat(e, .{ .unsupported = .{
            .reason = "unresolved tuple struct pattern",
            .suggested_version = .v3,
        } });

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
        const type_node = node.childByFieldName("type") orelse return error.MalformedCst;
        var field_pats: std.ArrayListUnmanaged(exprs.FieldPat) = .empty;
        defer field_pats.deinit(e.ctx.alloc);
        var has_rest = false;
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (child.id == type_node.id or isBlockTrivia(child)) continue;
            const child_kind = child.kind();
            if (std.mem.eql(u8, child_kind, "field_pattern")) {
                try field_pats.append(e.ctx.alloc, try lowerFieldPattern(e, child));
            } else if (std.mem.eql(u8, child_kind, "remaining_field_pattern")) {
                has_rest = true;
            } else {
                return error.MalformedCst;
            }
        }

        const raw_type = std.mem.trim(u8, text(e, type_node), " \t\r\n");
        var leaf = raw_type;
        if (std.mem.lastIndexOfScalar(u8, leaf, ':')) |index| leaf = leaf[index + 1 ..];
        leaf = std.mem.trim(u8, leaf, " \t\r\n:");
        const def_opt: ?spine.EntityId = blk: {
            if (resolvePatternPath(e, type_node)) |resolved| break :blk resolved;
            if (resolveName(e, leaf)) |resolved| break :blk resolved;
            if (try ensureStandardPreludeVariant(e, leaf)) |standard| break :blk standard.variant_id;
            break :blk null;
        };
        if (def_opt == null) {
            if (std.mem.lastIndexOf(u8, raw_type, "::")) |last_sep| {
                const owner_text = raw_type[0..last_sep];
                const variant_name = std.mem.trim(u8, raw_type[last_sep + 2 ..], " \t\r\n");
                if (variant_name.len > 0) {
                    if (try externalCowVariantForPath(e, owner_text, variant_name)) |owner| {
                        return appendPat(e, .{ .external_variant = .{
                            .owner = owner,
                            .variant = try e.ctx.alloc.dupe(u8, variant_name),
                            .fields = try field_pats.toOwnedSlice(e.ctx.alloc),
                            .rest = has_rest,
                        } });
                    }
                }
            }
        }

        const def = def_opt orelse return appendPat(e, .{ .unsupported = .{
            .reason = "unresolved struct pattern",
            .suggested_version = .v3,
        } });
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
            if (!isBlockTrivia(c)) {
                try alts.append(e.ctx.alloc, try lowerPattern(e, c));
            }
        }
        if (alts.items.len == 0) return error.MalformedCst;
        return appendPat(e, .{ .@"or" = .{ .alternatives = try alts.toOwnedSlice(e.ctx.alloc) } });
    }

    if (std.mem.eql(u8, kind, "reference_pattern")) {
        if (firstNestedPatternChild(node)) |inner| {
            const pid = try lowerPattern(e, inner);
            return appendPat(e, .{ .reference = .{
                .mode = .{ .value = {} },
                .inner = pid,
            } });
        }
        return error.MalformedCst;
    }

    if (std.mem.eql(u8, kind, "char_literal") or std.mem.eql(u8, kind, "byte_literal")) {
        const raw = text(e, node);
        if (std.mem.startsWith(u8, raw, "b")) {
            const decoded = decodeRustByteLiteral(e.ctx.alloc, raw) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return appendPat(e, .{ .unsupported = .{
                    .reason = "invalid byte pattern",
                    .suggested_version = .v3,
                } }),
            };
            const bytes = decoded orelse return error.MalformedCst;
            defer e.ctx.alloc.free(bytes);
            if (bytes.len != 1) return appendPat(e, .{ .unsupported = .{
                .reason = "invalid byte pattern",
                .suggested_version = .v3,
            } });
            return appendPat(e, .{ .literal = .{ .int = .{
                .text = try std.fmt.allocPrint(e.ctx.alloc, "{d}u8", .{bytes[0]}),
                .value = bytes[0],
                .base = .dec,
                .ty_suffix = "u8",
            } } });
        }
        const value = decodeRustCharCodepoint(raw) orelse return appendPat(e, .{ .unsupported = .{
            .reason = "invalid char pattern",
            .suggested_version = .v3,
        } });
        return appendPat(e, .{ .literal = .{ .character = .{
            .text = try e.ctx.alloc.dupe(u8, raw),
            .value = value,
        } } });
    }

    if (std.mem.eql(u8, kind, "integer_literal")) {
        const t = text(e, node);
        const parsed = parseIntLiteral(t) orelse return appendPat(e, .{ .unsupported = .{
            .reason = "integer literal out of range",
            .suggested_version = .v3,
        } });
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
            return appendPat(e, .{ .unsupported = .{
                .reason = "invalid byte pattern",
                .suggested_version = .v3,
            } });
        if (decoded) |bytes| {
            return appendPat(e, .{ .literal = .{ .byte_array = .{ .items = bytes } } });
        }
        if (is_byte) return appendPat(e, .{ .unsupported = .{
            .reason = "invalid byte pattern",
            .suggested_version = .v3,
        } });
        var s = raw;
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
        return appendPat(e, .{ .literal = .{ .string = .{ .bytes = try e.ctx.alloc.dupe(u8, s) } } });
    }

    if (std.mem.eql(u8, kind, "boolean_literal")) {
        return appendPat(e, .{ .literal = .{ .boolean = std.mem.eql(u8, text(e, node), "true") } });
    }

    return appendPat(e, .{ .unsupported = .{
        .reason = "unsupported pattern",
        .suggested_version = .v3,
    } });
}

/// Return the semantic pattern child from a `match_pattern` wrapper.
///
/// Comments are extras and may occur before the grammar's `_pattern` child.
/// Anonymous `_` must remain visible, so this scans raw children instead of
/// using `namedChild`.
fn firstMatchPatternChild(wrapper: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (wrapper.child(i)) |child| : (i += 1) {
        if (isBlockTrivia(child)) continue;
        if (!child.isNamed() and std.mem.eql(u8, child.kind(), "if")) continue;
        return child;
    }
    return null;
}

/// Return the semantic nested pattern from a ref/reference wrapper.
///
/// The `ref`, `&`, and `mut` tokens are anonymous grammar children. Skip
/// those tokens and comments while retaining anonymous wildcard `_`.
fn firstNestedPatternChild(wrapper: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (wrapper.child(i)) |child| : (i += 1) {
        if (isBlockTrivia(child)) continue;
        if (!child.isNamed()) {
            const child_text = std.mem.trim(u8, child.kind(), " \t\r\n");
            if (std.mem.eql(u8, child_text, "ref") or
                std.mem.eql(u8, child_text, "mut") or
                std.mem.eql(u8, child_text, "&"))
            {
                continue;
            }
        }
        return child;
    }
    return null;
}

fn lowerMatch(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const scr_node = node.childByFieldName("value") orelse return error.MalformedCst;
    const block_node = node.childByFieldName("body") orelse return error.MalformedCst;
    const scrutinee_id = try lowerExpr(e, scr_node);

    var arms: std.ArrayListUnmanaged(exprs.MatchArm) = .empty;
    defer arms.deinit(e.ctx.alloc);
    var contains_unsupported_pattern = false;

    var i: u32 = 0;
    while (block_node.namedChild(i)) |arm_node| : (i += 1) {
        if (isBlockTrivia(arm_node)) continue;
        if (!std.mem.eql(u8, arm_node.kind(), "match_arm")) return error.MalformedCst;
        const arm_local_count = e.locals.items.len;
        defer e.locals.items.len = arm_local_count;

        const pattern_wrapper = arm_node.childByFieldName("pattern") orelse return error.MalformedCst;
        const body_node = arm_node.childByFieldName("value") orelse return error.MalformedCst;
        const pattern_node = firstMatchPatternChild(pattern_wrapper) orelse return error.MalformedCst;
        const guard_node = pattern_wrapper.childByFieldName("condition");

        var pat_ids: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
        defer pat_ids.deinit(e.ctx.alloc);
        if (std.mem.eql(u8, pattern_node.kind(), "or_pattern")) {
            var j: u32 = 0;
            while (pattern_node.namedChild(j)) |alternative| : (j += 1) {
                if (isBlockTrivia(alternative)) continue;
                try pat_ids.append(e.ctx.alloc, try lowerPattern(e, alternative));
            }
            if (pat_ids.items.len == 0) return error.MalformedCst;
        } else {
            try pat_ids.append(e.ctx.alloc, try lowerPattern(e, pattern_node));
        }

        for (pat_ids.items) |pat_id| {
            if (patternContainsUnsupported(e, pat_id)) {
                contains_unsupported_pattern = true;
            }
        }

        var guard_id: ?exprs.NodeId = null;
        if (guard_node) |guard| guard_id = try lowerExpr(e, guard);
        const arm_body_id = try lowerExpr(e, body_node);
        try arms.append(e.ctx.alloc, .{
            .patterns = try pat_ids.toOwnedSlice(e.ctx.alloc),
            .guard = guard_id,
            .body = arm_body_id,
        });
    }

    if (arms.items.len == 0) return error.MalformedCst;
    if (contains_unsupported_pattern) return unsupported(e, "unsupported match pattern");
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
            try args.append(e.ctx.alloc, try mapCstType(e, arg));
        }
    }
    return args.toOwnedSlice(e.ctx.alloc);
}

/// A declared return type is safe to pin only when every nested component is concrete.
/// Null-id paths are lexical generic parameters and must remain for inference.
fn isConcreteDeclaredReturnType(t: types.Type) bool {
    return switch (t) {
        .prim => true,
        .path => |path| blk: {
            if (path.segments.len == 0) break :blk false;
            break :blk path.segments[path.segments.len - 1].id != null;
        },
        .external_nominal => |external| blk: {
            if (external.path.len == 0) break :blk false;
            for (external.args) |arg| {
                if (!isConcreteDeclaredReturnType(arg)) break :blk false;
            }
            break :blk true;
        },
        .reference => |reference| isConcreteDeclaredReturnType(reference.pointee),
        .raw_ptr => |raw_ptr| isConcreteDeclaredReturnType(raw_ptr.pointee),
        .slice => |slice| isConcreteDeclaredReturnType(slice.elem),
        .array => |array| blk: {
            switch (array.len) {
                .literal => {},
                .generic, .expression => break :blk false,
            }
            break :blk isConcreteDeclaredReturnType(array.elem);
        },
        .tuple => |tuple| blk: {
            for (tuple) |element| {
                if (!isConcreteDeclaredReturnType(element)) break :blk false;
            }
            break :blk true;
        },
        .fn_ptr => |fn_ptr| blk: {
            for (fn_ptr.params) |param| {
                if (!isConcreteDeclaredReturnType(param)) break :blk false;
            }
            break :blk isConcreteDeclaredReturnType(fn_ptr.ret);
        },
        .generic_inst => |generic| blk: {
            for (generic.args.params) |arg| {
                if (!isConcreteDeclaredReturnType(arg)) break :blk false;
            }
            break :blk true;
        },
        .option => |inner| isConcreteDeclaredReturnType(inner.*),
        .result => |result| isConcreteDeclaredReturnType(result.ok) and
            isConcreteDeclaredReturnType(result.err),
        .boxed => |inner| isConcreteDeclaredReturnType(inner.*),
        .@"opaque" => |opaque_type| if (opaque_type.concrete) |concrete|
            isConcreteDeclaredReturnType(concrete.*)
        else
            false,
        .dyn_trait => |bounds| concreteDeclaredBounds(bounds),
        .unsupported => false,
    };
}

fn concreteDeclaredBounds(bounds: []const types.Bound) bool {
    for (bounds) |bound| {
        for (bound.args) |arg| {
            if (!isConcreteDeclaredReturnType(arg)) return false;
        }
        for (bound.associated_types) |binding| {
            if (!isConcreteDeclaredReturnType(binding.ty)) return false;
        }
    }
    return true;
}

fn appendDeclaredCallReturnType(
    e: *Ext,
    call_kind: exprs.CallKind,
    call_id: exprs.NodeId,
) anyerror!void {
    const def = switch (call_kind) {
        .free => |value| value,
        .associated => |value| value,
        .constructor => return,
    };
    if (def >= e.ctx.bodies_list.items.len) return;
    const fn_body = switch (e.ctx.bodies_list.items[def]) {
        .fn_ => |value| value,
        else => return,
    };
    if (fn_body.generic_params.len != 0) return;
    if (!isConcreteDeclaredReturnType(fn_body.ret)) return;
    e.ctx.exprs.items[call_id].ty = try appendType(e, fn_body.ret);
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
        const generic_decl: spine.EntityId = switch (call_kind) {
            .free => |def| def,
            .associated => |def| def,
            .constructor => |def| def,
        };
        const generic_type: types.Type = .{ .generic_inst = .{
            .decl = generic_decl,
            .args = .{ .params = generic_args },
        } };
        if (isConcreteDeclaredReturnType(generic_type)) {
            const owned_args = try e.ctx.alloc.dupe(types.Type, generic_args);
            errdefer e.ctx.alloc.free(owned_args);
            const type_id = (try appendType(e, .{ .generic_inst = .{
                .decl = generic_decl,
                .args = .{ .params = owned_args },
            } })) orelse unreachable;
            e.ctx.exprs.items[id].ty = type_id;
        }
    } else {
        try appendDeclaredCallReturnType(e, call_kind, id);
    }
    return id;
}

fn isReferenceExpr(e: *const Ext, node_id: exprs.NodeId) bool {
    if (node_id >= e.ctx.exprs.items.len) return false;
    const expr = e.ctx.exprs.items[node_id];
    if (expr.ty) |type_id| {
        if (type_id < e.ctx.types.items.len) {
            return e.ctx.types.items[type_id] == .reference;
        }
    }
    return switch (expr.kind) {
        .path => |p| if (localType(e, p.def)) |ty| ty == .reference else false,
        else => false,
    };
}

fn lowerMethodCall(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const receiver = node.childByFieldName("receiver") orelse return error.MalformedCst;
    const method = node.childByFieldName("method") orelse return error.MalformedCst;
    const arguments = node.childByFieldName("arguments") orelse return error.MalformedCst;
    const method_name = text(e, method);
    if (method_name.len == 0) return error.MalformedCst;
    if (std.mem.eql(u8, method_name, "wrapping_mul") or
        std.mem.eql(u8, method_name, "wrapping_add") or
        std.mem.eql(u8, method_name, "wrapping_sub"))
    {
        var lhs = try lowerExpr(e, receiver);
        if (isReferenceExpr(e, lhs)) {
            lhs = try appendExpr(e, .{ .unary = .{ .op = .deref, .operand = lhs } });
        }
        const rhs = try lowerExpr(e, firstArg(e, arguments) orelse return error.MalformedCst);
        const op: exprs.BinaryOp = if (std.mem.eql(u8, method_name, "wrapping_mul"))
            .mul
        else if (std.mem.eql(u8, method_name, "wrapping_add"))
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

    const method_def = try pushMethodRef(e, method_name);
    const args = try lowerArgs(e, arguments);
    const generic_args = try lowerGenericCallArgs(e, node);
    return appendExpr(e, .{ .method_call = .{
        .receiver = try lowerExpr(e, receiver),
        .receiver_mode = .value,
        .method = method_def,
        .generic_args = generic_args,
        .args = args,
    } });
}

fn stringCoreFunction(
    e: *const Ext,
    path_text: []const u8,
) !?exprs.CoreFunction {
    const path = if (std.mem.startsWith(u8, path_text, "::")) path_text[2..] else path_text;
    const first_end = std.mem.indexOf(u8, path, "::") orelse path.len;
    const first_name = path[0..first_end];
    if (resolveName(e, first_name)) |def| {
        const entity = e.ctx.g.symbol_table.get(def) orelse return null;
        if (entity.kind != .use_) {
            const module = moduleByEntity(e, def) orelse return null;
            if (!module.is_extern) return null;
        }
    }
    const external = (try externalNominalForPath(e, path_text)) orelse return null;
    defer {
        for (external.path) |segment| e.ctx.alloc.free(segment);
        e.ctx.alloc.free(external.path);
    }
    if (external.path.len != 4 or
        (!std.mem.eql(u8, external.path[0], "alloc") and
            !std.mem.eql(u8, external.path[0], "std")) or
        !std.mem.eql(u8, external.path[1], "string") or
        !std.mem.eql(u8, external.path[2], "String"))
    {
        return null;
    }
    if (std.mem.eql(u8, external.path[3], "from_utf8")) return .string_from_utf8;
    if (std.mem.eql(u8, external.path[3], "from_utf8_lossy")) return .string_from_utf8_lossy;
    if (std.mem.eql(u8, external.path[3], "from_utf8_unchecked")) {
        return .string_from_utf8_unchecked;
    }
    return null;
}

fn coreFunction(e: *const Ext, path_text: []const u8) !?exprs.CoreFunction {
    if (try stringCoreFunction(e, path_text)) |function| return function;
    const path = if (std.mem.startsWith(u8, path_text, "::")) path_text[2..] else path_text;
    var source_parts: [3][]const u8 = undefined;
    var source_count: usize = 0;
    var parts = std.mem.splitSequence(u8, path, "::");
    while (parts.next()) |part| {
        if (part.len == 0 or source_count == source_parts.len) return null;
        source_parts[source_count] = part;
        source_count += 1;
    }
    if (source_count == 0) return null;
    if (resolveName(e, source_parts[0])) |def| {
        const entity = e.ctx.g.symbol_table.get(def) orelse return null;
        if (entity.kind != .use_) {
            const module = moduleByEntity(e, def) orelse return null;
            if (!module.is_extern) return null;
        }
    }
    var canonical: [3][]const u8 = undefined;
    if (try externalUsePath(e, source_parts[0])) |prefix| {
        if (prefix.len + source_count - 1 != canonical.len) return null;
        @memcpy(canonical[0..prefix.len], prefix);
        @memcpy(canonical[prefix.len..], source_parts[1..source_count]);
    } else {
        if (source_count != canonical.len) return null;
        canonical = source_parts;
    }
    if (!std.mem.eql(u8, canonical[0], "core") and
        !std.mem.eql(u8, canonical[0], "std")) return null;
    const entries = [_]struct { namespace: []const u8, name: []const u8, function: exprs.CoreFunction }{
        .{ .namespace = "mem", .name = "size_of", .function = .mem_size_of },
        .{ .namespace = "mem", .name = "transmute", .function = .mem_transmute },
        .{ .namespace = "mem", .name = "size_of_val", .function = .mem_size_of_val },
        .{ .namespace = "ptr", .name = "copy_nonoverlapping", .function = .ptr_copy_nonoverlapping },
        .{ .namespace = "ptr", .name = "write_bytes", .function = .ptr_write_bytes },
        .{ .namespace = "ptr", .name = "read_unaligned", .function = .ptr_read_unaligned },
        .{ .namespace = "slice", .name = "from_raw_parts", .function = .slice_from_raw_parts },
        .{ .namespace = "slice", .name = "from_raw_parts_mut", .function = .slice_from_raw_parts_mut },
        .{ .namespace = "str", .name = "from_utf8", .function = .str_from_utf8 },
        .{ .namespace = "str", .name = "from_utf8_unchecked", .function = .str_from_utf8_unchecked },
        .{ .namespace = "cmp", .name = "min", .function = .cmp_min },
        .{ .namespace = "cmp", .name = "max", .function = .cmp_max },
    };
    for (entries) |entry| {
        if (std.mem.eql(u8, canonical[1], entry.namespace) and
            std.mem.eql(u8, canonical[2], entry.name)) return entry.function;
    }
    return null;
}

fn bodyView(e: *const Ext) bodies.Bodies {
    return .{
        .exprs = e.ctx.exprs.items,
        .stmts = e.ctx.stmts.items,
        .pats = e.ctx.pats.items,
        .types = e.ctx.types.items,
        .bodies = e.ctx.bodies_list.items,
    };
}

fn genericBodyParams(view: *const bodies.Bodies, entity_id: spine.EntityId) ?types.Generics {
    if (entity_id >= view.bodies.len) return null;
    return switch (view.bodies[entity_id]) {
        .fn_ => |function| function.generics,
        .impl_ => |implementation| implementation.generics,
        else => null,
    };
}

fn boundTraitEntity(e: *const Ext, bound: types.Bound) ?spine.EntityId {
    if (bound.path.segments.len == 0) return null;
    const terminal = bound.path.segments[bound.path.segments.len - 1];
    if (terminal.id) |id| {
        if (e.ctx.g.symbol_table.get(id)) |entity| {
            if (entity.kind == .trait_) return id;
        }
    }
    const candidate = resolveName(e, terminal.name) orelse return null;
    if (e.ctx.g.symbol_table.get(candidate)) |entity| {
        if (entity.kind == .trait_) return candidate;
    }
    return null;
}

fn externalPathMatchesStandard(actual: []const []const u8, wanted: []const []const u8) bool {
    if (actual.len != wanted.len) return false;
    for (actual, wanted, 0..) |actual_part, wanted_part, index| {
        if (index == 0 and std.mem.eql(u8, wanted_part, "core") and
            std.mem.eql(u8, actual_part, "std"))
        {
            continue;
        }
        if (!std.mem.eql(u8, actual_part, wanted_part)) return false;
    }
    return true;
}

fn textNamesStandardTrait(
    e: *const Ext,
    raw_text: []const u8,
    wanted: []const []const u8,
) anyerror!bool {
    if (wanted.len == 0) return false;
    var raw = std.mem.trim(u8, raw_text, " \t\r\n");
    if (std.mem.startsWith(u8, raw, "::")) raw = raw[2..];
    if (std.mem.indexOfScalar(u8, raw, '<')) |generic_start| {
        raw = std.mem.trim(u8, raw[0..generic_start], " \t\r\n");
    }
    const wanted_name = wanted[wanted.len - 1];
    if (std.mem.indexOf(u8, raw, "::") != null) {
        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        var iterator = std.mem.splitSequence(u8, raw, "::");
        while (iterator.next()) |part| {
            if (part.len == 0 or count == parts.len) return false;
            parts[count] = part;
            count += 1;
        }
        return externalPathMatchesStandard(parts[0..count], wanted);
    }
    if (!std.mem.eql(u8, raw, wanted_name)) return false;
    if (try externalUsePath(e, raw)) |external| {
        return externalPathMatchesStandard(external, wanted);
    }
    // An unqualified standard prelude trait is valid only when no lexical
    // declaration shadows it.
    return resolveName(e, raw) == null;
}

fn traitHasStandardSupertrait(
    e: *const Ext,
    trait_id: spine.EntityId,
    wanted: []const []const u8,
    depth: usize,
) anyerror!bool {
    if (depth >= e.ctx.g.symbol_table.entities.items.len or
        trait_id >= e.ctx.bodies_list.items.len)
    {
        return false;
    }
    const trait_body = switch (e.ctx.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    for (trait_body.supertraits) |supertrait| {
        if (try textNamesStandardTrait(e, supertrait, wanted)) return true;
        var raw = std.mem.trim(u8, supertrait, " \t\r\n");
        if (std.mem.indexOfScalar(u8, raw, '<')) |generic_start| raw = raw[0..generic_start];
        const name = if (std.mem.lastIndexOf(u8, raw, "::")) |sep|
            raw[sep + 2 ..]
        else
            raw;
        const super_id = resolveName(e, name) orelse continue;
        if (try traitHasStandardSupertrait(e, super_id, wanted, depth + 1)) return true;
    }
    return false;
}

fn genericHasStandardTraitBound(
    e: *const Ext,
    receiver: types.Type,
    trait_path: []const []const u8,
) anyerror!bool {
    const view = bodyView(e);
    if (bodies.genericBound(e.ctx.g, &view, e.fn_id, receiver, trait_path) != null) return true;
    const receiver_name = switch (receiver) {
        .path => |path| if (path.segments.len == 1) path.segments[0].name else return false,
        else => return false,
    };
    var current: ?spine.EntityId = e.fn_id;
    var remaining = e.ctx.g.symbol_table.entities.items.len;
    while (current) |entity_id| {
        if (remaining == 0) return false;
        remaining -= 1;
        if (genericBodyParams(&view, entity_id)) |generics| {
            for (generics.params) |param| {
                if (param != .type_ or !std.mem.eql(u8, param.type_.name, receiver_name)) continue;
                for (param.type_.bounds) |bound| {
                    if (bound.optional) continue;
                    if (boundTraitEntity(e, bound)) |trait_id| {
                        if (try traitHasStandardSupertrait(e, trait_id, trait_path, 0)) return true;
                    }
                }
            }
            for (generics.where_clauses) |clause| {
                if (clause.self_ty.segments.len != 1 or
                    !std.mem.eql(u8, clause.self_ty.segments[0].name, receiver_name))
                {
                    continue;
                }
                for (clause.bounds) |bound| {
                    if (bound.optional) continue;
                    if (boundTraitEntity(e, bound)) |trait_id| {
                        if (try traitHasStandardSupertrait(e, trait_id, trait_path, 0)) return true;
                    }
                }
            }
        }
        const entity = e.ctx.g.symbol_table.get(entity_id) orelse return false;
        current = entity.parent;
    }
    return false;
}

fn activeGenericReceiver(e: *const Ext, name: []const u8) anyerror!?types.Type {
    if (!activeTypeParameter(e, name)) return null;
    const segments = try e.ctx.alloc.alloc(types.PathSegment, 1);
    segments[0] = .{ .name = try e.ctx.alloc.dupe(u8, name), .id = null };
    return .{ .path = .{ .segments = segments } };
}

fn traitDeclaresAssociatedConst(
    e: *const Ext,
    trait_id: spine.EntityId,
    name: []const u8,
) bool {
    if (trait_id >= e.ctx.bodies_list.items.len) return false;
    const trait_body = switch (e.ctx.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return false,
    };
    for (trait_body.assoc_consts) |assoc| {
        if (std.mem.eql(u8, assoc.name, name)) return true;
    }
    return false;
}

fn declaringAssociatedConstTrait(
    e: *const Ext,
    trait_id: spine.EntityId,
    name: []const u8,
    depth: usize,
) ?spine.EntityId {
    if (depth >= e.ctx.g.symbol_table.entities.items.len) return null;
    if (traitDeclaresAssociatedConst(e, trait_id, name)) return trait_id;
    if (trait_id >= e.ctx.bodies_list.items.len) return null;
    const trait_body = switch (e.ctx.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return null,
    };
    var found: ?spine.EntityId = null;
    for (trait_body.supertraits) |supertrait| {
        var raw = std.mem.trim(u8, supertrait, " \t\r\n");
        if (std.mem.indexOfScalar(u8, raw, '<')) |generic_start| raw = raw[0..generic_start];
        const super_name = if (std.mem.lastIndexOf(u8, raw, "::")) |separator|
            raw[separator + 2 ..]
        else
            raw;
        const super_id = resolveName(e, super_name) orelse continue;
        const candidate = declaringAssociatedConstTrait(e, super_id, name, depth + 1) orelse continue;
        if (found) |existing| {
            if (existing != candidate) return null;
        } else {
            found = candidate;
        }
    }
    return found;
}

/// The trait in `trait_id`'s supertrait closure that declares `name` as a
/// method. A method reaches a generic parameter through whichever bound in
/// that closure provides it, so the declaring trait — not the bound that was
/// written — is what a trait method reference has to hang from.
fn declaringAssociatedMethodTrait(
    e: *const Ext,
    trait_id: spine.EntityId,
    name: []const u8,
    depth: usize,
) ?spine.EntityId {
    if (depth >= e.ctx.g.symbol_table.entities.items.len) return null;
    if (traitDeclaresMethod(e, trait_id, name)) return trait_id;
    if (trait_id >= e.ctx.bodies_list.items.len) return null;
    const trait_body = switch (e.ctx.bodies_list.items[trait_id]) {
        .trait_ => |body| body,
        else => return null,
    };
    var found: ?spine.EntityId = null;
    for (trait_body.supertraits) |supertrait| {
        var raw = std.mem.trim(u8, supertrait, " \t\r\n");
        if (std.mem.indexOfScalar(u8, raw, '<')) |generic_start| raw = raw[0..generic_start];
        const super_name = if (std.mem.lastIndexOf(u8, raw, "::")) |separator|
            raw[separator + 2 ..]
        else
            raw;
        const super_id = resolveName(e, super_name) orelse continue;
        const candidate = declaringAssociatedMethodTrait(e, super_id, name, depth + 1) orelse continue;
        if (found) |existing| {
            if (existing != candidate) return null;
        } else {
            found = candidate;
        }
    }
    return found;
}

/// The one trait reachable from the bounds of the type parameter
/// `receiver_name` that declares `method_name`. Two bounds providing the same
/// method from different traits leave the choice to the source, which this
/// path does not spell, so that stays unresolved rather than guessed.
fn boundAssociatedMethodTrait(
    e: *const Ext,
    receiver_name: []const u8,
    method_name: []const u8,
) ?spine.EntityId {
    const view = bodyView(e);
    var found: ?spine.EntityId = null;
    var current: ?spine.EntityId = e.fn_id;
    var remaining = e.ctx.g.symbol_table.entities.items.len;
    while (current) |entity_id| {
        if (remaining == 0) return null;
        remaining -= 1;
        if (genericBodyParams(&view, entity_id)) |generics| {
            for (generics.params) |param| {
                if (param != .type_ or !std.mem.eql(u8, param.type_.name, receiver_name)) continue;
                for (param.type_.bounds) |bound| {
                    if (bound.optional) continue;
                    const trait_id = boundTraitEntity(e, bound) orelse continue;
                    const declaring = declaringAssociatedMethodTrait(e, trait_id, method_name, 0) orelse continue;
                    if (!mergeAssociatedConstTrait(&found, declaring)) return null;
                }
            }
            for (generics.where_clauses) |clause| {
                if (clause.self_ty.segments.len != 1 or
                    !std.mem.eql(u8, clause.self_ty.segments[0].name, receiver_name))
                {
                    continue;
                }
                for (clause.bounds) |bound| {
                    if (bound.optional) continue;
                    const trait_id = boundTraitEntity(e, bound) orelse continue;
                    const declaring = declaringAssociatedMethodTrait(e, trait_id, method_name, 0) orelse continue;
                    if (!mergeAssociatedConstTrait(&found, declaring)) return null;
                }
            }
        }
        const entity = e.ctx.g.symbol_table.get(entity_id) orelse return null;
        current = entity.parent;
    }
    return found;
}

fn mergeAssociatedConstTrait(
    destination: *?spine.EntityId,
    candidate: spine.EntityId,
) bool {
    if (destination.*) |existing| return existing == candidate;
    destination.* = candidate;
    return true;
}

fn boundAssociatedConstTrait(
    e: *const Ext,
    receiver_name: []const u8,
    assoc_name: []const u8,
) ?spine.EntityId {
    const view = bodyView(e);
    var found: ?spine.EntityId = null;
    var current: ?spine.EntityId = e.fn_id;
    var remaining = e.ctx.g.symbol_table.entities.items.len;
    while (current) |entity_id| {
        if (remaining == 0) return null;
        remaining -= 1;
        if (genericBodyParams(&view, entity_id)) |generics| {
            for (generics.params) |param| {
                if (param != .type_ or !std.mem.eql(u8, param.type_.name, receiver_name)) continue;
                for (param.type_.bounds) |bound| {
                    if (bound.optional) continue;
                    const trait_id = boundTraitEntity(e, bound) orelse continue;
                    const declaring = declaringAssociatedConstTrait(e, trait_id, assoc_name, 0) orelse continue;
                    if (!mergeAssociatedConstTrait(&found, declaring)) return null;
                }
            }
            for (generics.where_clauses) |clause| {
                if (clause.self_ty.segments.len != 1 or
                    !std.mem.eql(u8, clause.self_ty.segments[0].name, receiver_name))
                {
                    continue;
                }
                for (clause.bounds) |bound| {
                    if (bound.optional) continue;
                    const trait_id = boundTraitEntity(e, bound) orelse continue;
                    const declaring = declaringAssociatedConstTrait(e, trait_id, assoc_name, 0) orelse continue;
                    if (!mergeAssociatedConstTrait(&found, declaring)) return null;
                }
            }
        }
        const entity = e.ctx.g.symbol_table.get(entity_id) orelse return null;
        current = entity.parent;
    }
    return found;
}

fn ensureTraitAssociatedConstEntity(
    e: *Ext,
    trait_id: spine.EntityId,
    name: []const u8,
) anyerror!?spine.EntityId {
    for (e.ctx.g.symbol_table.entities.items) |entity| {
        if (entity.kind == .const_ and entity.parent == trait_id and
            std.mem.eql(u8, entity.name, name))
        {
            return entity.id;
        }
    }
    if (!traitDeclaresAssociatedConst(e, trait_id, name)) return null;
    const id = try e.ctx.g.symbol_table.add(.{
        .id = 0,
        .kind = .const_,
        .name = try e.ctx.alloc.dupe(u8, name),
        .span = span_of,
        .visibility = .public,
        .parent = trait_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    try e.ctx.bodies_list.append(e.ctx.alloc, .none);
    return id;
}

fn lowerQualifiedAssociatedConstPath(
    e: *Ext,
    node: ts.Node,
) anyerror!?exprs.NodeId {
    const qualified = qualifiedAssociatedPath(e, node) orelse return null;
    const receiver = mapCstType(e, qualified.receiver) catch return null;
    const receiver_path = switch (receiver) {
        .path => |path| path,
        else => return null,
    };
    if (receiver_path.segments.len != 1) return null;
    const trait_id = resolvePatternPath(e, qualified.trait) orelse return null;
    const trait_entity = e.ctx.g.symbol_table.get(trait_id) orelse return null;
    if (trait_entity.kind != .trait_) return null;
    const declaring_trait = declaringAssociatedConstTrait(e, trait_id, qualified.name, 0) orelse
        return null;
    const const_id = (try ensureTraitAssociatedConstEntity(
        e,
        declaring_trait,
        qualified.name,
    )) orelse return null;
    const generic_args = try e.ctx.alloc.alloc(types.Type, 1);
    generic_args[0] = receiver;
    const result = try appendExpr(e, .{ .path = .{
        .def = const_id,
        .generic_args = generic_args,
    } });
    return result;
}

fn lowerBoundAssociatedConstPath(
    e: *Ext,
    raw_path: []const u8,
) anyerror!?exprs.NodeId {
    const separator = std.mem.indexOf(u8, raw_path, "::") orelse return null;
    if (std.mem.lastIndexOf(u8, raw_path, "::").? != separator) return null;
    const receiver_name = std.mem.trim(u8, raw_path[0..separator], " \t\r\n");
    const assoc_name = std.mem.trim(u8, raw_path[separator + 2 ..], " \t\r\n");
    const receiver = (try activeGenericReceiver(e, receiver_name)) orelse return null;
    const trait_id = boundAssociatedConstTrait(e, receiver_name, assoc_name) orelse return null;
    const const_id = (try ensureTraitAssociatedConstEntity(e, trait_id, assoc_name)) orelse return null;
    const generic_args = try e.ctx.alloc.alloc(types.Type, 1);
    generic_args[0] = receiver;
    const result = try appendExpr(e, .{ .path = .{
        .def = const_id,
        .generic_args = generic_args,
    } });
    return result;
}

fn lowerBoundCoreAssociatedCall(
    e: *Ext,
    raw_path: []const u8,
    args: []const exprs.NodeId,
    explicit_generic_args: []const types.Type,
) anyerror!?exprs.NodeId {
    if (explicit_generic_args.len != 0) return null;
    const separator = std.mem.indexOf(u8, raw_path, "::") orelse return null;
    const receiver_name = std.mem.trim(u8, raw_path[0..separator], " \t\r\n");
    const method_name = std.mem.trim(u8, raw_path[separator + 2 ..], " \t\r\n");
    if (receiver_name.len == 0 or method_name.len == 0) return null;

    var receiver = try activeGenericReceiver(e, receiver_name);
    if (receiver == null) {
        if (std.mem.eql(u8, method_name, "from") and
            std.mem.eql(u8, receiver_name, "String") and
            resolveName(e, receiver_name) == null)
        {
            receiver = .{ .external_nominal = (try externalNominalForPath(e, "alloc::string::String")) orelse return null };
        } else {
            if (!std.mem.eql(u8, method_name, "default")) return null;
            const primitive = mapPrim(receiver_name) orelse return null;
            receiver = .{ .prim = primitive };
        }
    }
    const function: exprs.CoreFunction = if (std.mem.eql(u8, method_name, "default")) blk: {
        if (args.len != 0) return null;
        if (!(try genericHasStandardTraitBound(e, receiver.?, &.{ "core", "default", "Default" })) and
            receiver.? != .prim)
        {
            return null;
        }
        break :blk .default_value;
    } else if (std.mem.eql(u8, method_name, "from")) blk: {
        if (args.len != 1) return null;
        const is_string_receiver = switch (receiver.?) {
            .external_nominal => |external| external.path.len == 3 and
                std.mem.eql(u8, external.path[0], "alloc") and
                std.mem.eql(u8, external.path[1], "string") and
                std.mem.eql(u8, external.path[2], "String"),
            else => false,
        };
        if (!is_string_receiver and
            !(try genericHasStandardTraitBound(e, receiver.?, &.{ "core", "convert", "From" })))
        {
            return null;
        }
        break :blk .convert_from;
    } else return null;

    const generic_args = try e.ctx.alloc.alloc(types.Type, 1);
    generic_args[0] = receiver.?;
    const result = try appendExpr(e, .{ .core_call = .{
        .function = function,
        .generic_args = generic_args,
        .args = args,
    } });
    return result;
}

fn lowerCall(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const callee = node.namedChild(0) orelse return error.MalformedCst;
    var callee_base = callee;
    var generic_args: []const types.Type = &.{};
    if (std.mem.eql(u8, callee.kind(), "generic_function")) {
        if (callee.childByFieldName("function")) |function_node| {
            callee_base = function_node;
        } else {
            var found_function = false;
            var child_index: u32 = 0;
            while (callee.namedChild(child_index)) |child| : (child_index += 1) {
                if (std.mem.eql(u8, child.kind(), "type_arguments")) continue;
                callee_base = child;
                found_function = true;
                break;
            }
            if (!found_function) return error.MalformedCst;
        }
        generic_args = try lowerGenericCallArgs(e, callee);
    }
    defer if (generic_args.len > 0) e.ctx.alloc.free(generic_args);

    var args_node: ?ts.Node = null;
    var i: u32 = 0;
    while (node.namedChild(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.kind(), "arguments")) args_node = c;
    }
    const call_args = args_node orelse return error.MalformedCst;

    // method call: recv.method(args)
    if (std.mem.eql(u8, callee_base.kind(), "field_expression")) {
        const recv = callee_base.namedChild(0) orelse return error.MalformedCst;
        const method = callee_base.namedChild(1) orelse return error.MalformedCst;
        const mname = text(e, method);
        if (mname.len == 0) return error.MalformedCst;
        if ((std.mem.eql(u8, mname, "sum") or std.mem.eql(u8, mname, "collect")) and
            isStandardIteratorChain(e, recv))
        {
            if (!iteratorArgumentsEmpty(call_args)) return unsupported(e, "iterator terminal arguments");
            const terminal: exprs.IteratorTerminal = if (std.mem.eql(u8, mname, "sum"))
                .sum
            else
                .collect_vec;
            return lowerIteratorExpression(e, recv, terminal);
        }
        if (std.mem.eql(u8, mname, "flat_map") and isStandardIteratorChain(e, recv)) {
            return lowerIteratorExpression(e, node, .iterator);
        }

        // Rust `x.wrapping_mul(y)` → Zig `x *% y` (wrapping binary).
        if (std.mem.eql(u8, mname, "wrapping_mul") or
            std.mem.eql(u8, mname, "wrapping_add") or
            std.mem.eql(u8, mname, "wrapping_sub"))
        {
            var lhs = try lowerExpr(e, recv);
            if (isReferenceExpr(e, lhs)) {
                lhs = try appendExpr(e, .{ .unary = .{ .op = .deref, .operand = lhs } });
            }
            const rhs = try lowerExpr(e, firstArg(e, call_args) orelse return error.MalformedCst);
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
        const method_def = try pushMethodRef(e, mname);
        const args = try lowerArgs(e, call_args);
        // The turbofish on `recv.method::<T>(..)` is the callee's own, so it is
        // recorded here rather than dropped. `generic_args` is freed on
        // function exit, hence the dupe.
        return appendExpr(e, .{ .method_call = .{
            .receiver = try lowerExpr(e, recv),
            .receiver_mode = .value,
            .method = method_def,
            .generic_args = try e.ctx.alloc.dupe(types.Type, generic_args),
            .args = args,
        } });
    }

    // free / associated / enum-variant / constructor call
    var arg_list: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer arg_list.deinit(e.ctx.alloc);
    {
        var j: u32 = 0;
        while (call_args.namedChild(j)) |a| : (j += 1) {
            try arg_list.append(e.ctx.alloc, try lowerExpr(e, a));
        }
    }
    const args = try arg_list.toOwnedSlice(e.ctx.alloc);
    if (std.mem.eql(u8, callee_base.kind(), "scoped_identifier") or
        std.mem.eql(u8, callee_base.kind(), "scoped_type_identifier"))
    {
        if (try lowerBoundCoreAssociatedCall(e, text(e, callee_base), args, generic_args)) |core_call| {
            return core_call;
        }
    }
    if (try coreFunction(e, text(e, callee_base))) |function| {
        return appendExpr(e, .{ .core_call = .{
            .function = function,
            .generic_args = try e.ctx.alloc.dupe(types.Type, generic_args),
            .args = args,
        } });
    }

    if (std.mem.eql(u8, callee_base.kind(), "scoped_identifier") or
        std.mem.eql(u8, callee_base.kind(), "scoped_type_identifier"))
    {
        // Struct::method(...) / Enum::Variant(...) / Self::method(...) /
        // Type::constructor(...). Split the scoped path at "::".
        const t = text(e, callee_base);
        if (primitiveTryFromTarget(t)) |target_primitive| {
            if (generic_args.len != 0) {
                e.ctx.alloc.free(args);
                return unsupported(e, "primitive try_from call");
            }
            return appendPrimitiveTryFrom(e, target_primitive, args);
        }
        if (primitiveFromTarget(t)) |target_primitive| {
            if (generic_args.len != 0) {
                e.ctx.alloc.free(args);
                return unsupported(e, "primitive from call");
            }
            return appendPrimitiveFrom(e, target_primitive, args);
        }
        if (try traitMethodForPath(e, callee_base)) |method| {
            return appendGenericCall(e, .{ .associated = method }, args, generic_args);
        }
        // Resolve the complete path before interpreting the first segment as
        // a type name. A path-qualified function is free, but a type-qualified
        // function must continue through the associated lookup below. This
        // distinction matters when a resolver can see a method through an
        // alias or re-export.
        if (resolvePatternPath(e, callee_base)) |path_def| {
            if (e.ctx.g.symbol_table.get(path_def)) |path_ent| {
                if (path_ent.kind == .variant) {
                    return appendExpr(e, .{ .enum_variant = .{
                        .def = path_ent.parent orelse return error.MalformedCst,
                        .variant = try e.ctx.alloc.dupe(u8, path_ent.name),
                        .tuple_fields = args,
                        .named_fields = &.{},
                    } });
                }
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
        if (try ensureStandardPreludePath(e, t)) |standard| {
            return appendExpr(e, .{ .enum_variant = .{
                .def = standard.enum_id,
                .variant = try e.ctx.alloc.dupe(u8, standard.variant_name),
                .tuple_fields = args,
                .named_fields = &.{},
            } });
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
            base_def = resolveNominalName(e, base_name);
        }

        if (base_def) |bid| {
            if (e.ctx.g.symbol_table.get(bid)) |base_ent| {
                var type_id = bid;
                if (base_ent.kind == .type_alias) {
                    type_id = resolveAliasNominalType(e, bid) orelse
                        return unsupported(e, "unresolved associated call");
                }
                if (e.ctx.g.symbol_table.get(type_id)) |type_ent| {
                    if (type_ent.kind == .enum_ and
                        (resolveVariant(e, type_id, leaf) != null or
                            enumBodyHasVariant(e, type_id, leaf)))
                    {
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
        // `I::assoc(..)` where `I` is a type parameter of the enclosing fn or
        // impl. Rust resolves it through the parameter's declared bounds, and
        // `Self` in a bound is exactly that parameter, so the method hangs
        // from whichever bound declares it. A bound this crate has no entity
        // for — a trait from an external crate, say — resolves to nothing, and
        // the path then keeps whatever refusal it had before this arm.
        if ((try activeGenericReceiver(e, base_name)) != null) {
            const trait_id = boundAssociatedMethodTrait(e, base_name, leaf);
            const method_id = if (trait_id) |owner|
                try ensureTraitMethodRefEntity(e, owner, leaf)
            else
                null;
            if (method_id) |resolved| {
                return appendGenericCall(
                    e,
                    .{ .associated = resolved },
                    args,
                    generic_args,
                );
            }
        }
        if (std.mem.lastIndexOf(u8, t, "::")) |last_sep| {
            const owner_text = t[0..last_sep];
            const variant_name = t[last_sep + 2 ..];
            if (variant_name.len > 0) {
                if (try externalCowVariantForPath(e, owner_text, variant_name)) |owner| {
                    return appendExpr(e, .{ .external_variant = .{
                        .owner = owner,
                        .variant = try e.ctx.alloc.dupe(u8, variant_name),
                        .tuple_fields = args,
                        .named_fields = &.{},
                    } });
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
        if (try ensureStandardPreludeVariant(e, name)) |standard| {
            return appendExpr(e, .{ .enum_variant = .{
                .def = standard.enum_id,
                .variant = try e.ctx.alloc.dupe(u8, standard.variant_name),
                .tuple_fields = args,
                .named_fields = &.{},
            } });
        }
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

/// A source `let_condition` split without lowering either side. The scrutinee
/// must be lowered before the pattern so a binding cannot shadow a name used
/// by that scrutinee.
const LetCondition = struct {
    pattern: ts.Node,
    value: ts.Node,
};

fn findLetCondition(node: ts.Node) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), "let_condition")) return node;
    if (!std.mem.eql(u8, node.kind(), "condition") and
        !std.mem.eql(u8, node.kind(), "let_chain") and
        !std.mem.eql(u8, node.kind(), "_let_chain"))
    {
        return null;
    }
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (findLetCondition(child)) |let_node| return let_node;
    }
    return null;
}

fn splitLetCondition(e: *const Ext, node: ts.Node) anyerror!?LetCondition {
    const let_node = findLetCondition(node) orelse return null;
    const pattern = let_node.childByFieldName("pattern") orelse
        let_node.namedChild(0) orelse return error.MalformedCst;
    var value: ?ts.Node = let_node.childByFieldName("value");
    var i: u32 = 0;
    while (let_node.namedChild(i)) |child| : (i += 1) {
        if (child.id == pattern.id or isComment(child)) continue;
        if (std.mem.eql(u8, text(e, child), "=")) continue;
        if (value == null) value = child;
    }
    return .{
        .pattern = pattern,
        .value = value orelse return error.MalformedCst,
    };
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

fn lowerElseBranch(e: *Ext, else_node: ?ts.Node) anyerror!exprs.ElseBranch {
    var else_branch: exprs.ElseBranch = .{ .none = {} };
    if (else_node) |en| {
        const enk = en.kind();
        if (std.mem.eql(u8, enk, "block")) {
            else_branch = .{ .block = try lowerBlock(e, en) };
        } else if (std.mem.eql(u8, enk, "if_expression")) {
            else_branch = .{ .chain = try lowerIf(e, en) };
        } else {
            return error.MalformedCst;
        }
    }
    return else_branch;
}

fn lowerIf(e: *Ext, node: ts.Node) anyerror!exprs.NodeId {
    const outer_local_count = e.locals.items.len;
    defer e.locals.items.len = outer_local_count;
    const cond_node = node.childByFieldName("condition") orelse return error.MalformedCst;
    const then_node = node.childByFieldName("consequence") orelse return error.MalformedCst;

    var else_node = node.childByFieldName("alternative");
    if (else_node) |en| {
        if (std.mem.eql(u8, en.kind(), "else_clause")) {
            else_node = en.namedChild(0) orelse return error.MalformedCst;
        }
    }

    if (try splitLetCondition(e, cond_node)) |let_cond| {
        // The pattern bindings are visible only in the then branch. Lower the
        // scrutinee while the outer scope is still active.
        const scrutinee = try lowerExpr(e, let_cond.value);
        const pattern = try lowerPattern(e, let_cond.pattern);
        if (knownPatternPayloadType(e, scrutinee)) |payload| {
            setPatternLocalTypes(e, pattern, payload);
        }
        const then_blk = try lowerBlock(e, then_node);
        e.locals.items.len = outer_local_count;
        const else_branch = try lowerElseBranch(e, else_node);
        return appendExpr(e, .{ .if_let = .{
            .pattern = pattern,
            .scrutinee = scrutinee,
            .then_ = then_blk,
            .@"else" = else_branch,
        } });
    }

    const cond_id = try lowerExpr(e, cond_node);
    const then_blk = try lowerBlock(e, then_node);
    e.locals.items.len = outer_local_count;
    const else_branch = try lowerElseBranch(e, else_node);
    return appendExpr(e, .{ .if_else = .{
        .cond = cond_id,
        .then_ = then_blk,
        .@"else" = else_branch,
    } });
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
    if (trimmed.len == 0) return error.MalformedCst;

    // Build a wrapper function string to parse the expression safely
    const prefix = "fn __macro_sub__() { ";
    const suffix = "; }";
    const wrapped = try std.fmt.allocPrint(e.ctx.alloc, "{s}{s}{s}", .{ prefix, trimmed, suffix });
    defer e.ctx.alloc.free(wrapped);

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(rust.language());
    const tree = parser.parseString(wrapped, null) orelse return error.MalformedCst;
    defer tree.destroy();

    const root = tree.rootNode();
    if (root.hasError()) return error.MalformedCst;
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
fn lowerPanic(e: *Ext, message: []const u8) anyerror!exprs.NodeId {
    const id = try appendExpr(e, .{ .panic_ = .{
        .message = try e.ctx.alloc.dupe(u8, message),
    } });
    const never_id = try appendType(e, .{ .prim = .never });
    e.ctx.exprs.items[id].ty = never_id;
    return id;
}

/// Decode the literal format string carried by `write!`/`writeln!`.
/// Keep the template as bytes because the format IR stores its source text
/// after Rust escape processing.
fn decodeFormatLiteral(alloc: std.mem.Allocator, raw: []const u8) anyerror![]const u8 {
    const literal = std.mem.trim(u8, raw, " \t\r\n");
    if (literal.len == 0) return error.InvalidFormatLiteral;
    if (literal[0] == 'b') return error.InvalidFormatLiteral;
    if (literal[0] == 'r') {
        const decoded = try decodeRawBytes(alloc, literal, 1);
        return decoded orelse error.InvalidFormatLiteral;
    }
    if (literal[0] != '"' or literal.len < 2 or literal[literal.len - 1] != '"') {
        return error.InvalidFormatLiteral;
    }
    return decodeEscapedBytes(alloc, literal[1 .. literal.len - 1]);
}

fn isBuiltinFormatMacroName(raw: []const u8, basename: []const u8) bool {
    var name = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.endsWith(u8, name, "!")) {
        name = std.mem.trim(u8, name[0 .. name.len - 1], " \t\r\n");
    }
    var segments: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, name, "::");
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (count >= segments.len) return false;
        segments[count] = std.mem.trim(u8, segment, " \t\r\n");
        count += 1;
    }
    if (count == 1) return std.mem.eql(u8, segments[0], basename);
    return count == 2 and
        (std.mem.eql(u8, segments[0], "core") or std.mem.eql(u8, segments[0], "std")) and
        std.mem.eql(u8, segments[1], basename);
}

fn lowerFormatWrite(
    e: *Ext,
    raw_tokens: []const u8,
    newline: bool,
) anyerror!exprs.NodeId {
    const macro_args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
    defer e.ctx.alloc.free(macro_args);
    if (macro_args.len < 2) {
        if (!newline or macro_args.len != 1) {
            return unsupported(e, "format write requires a writer and format literal");
        }
    }

    const writer = try parseAndLowerSubExpr(e, macro_args[0]);
    var template = if (macro_args.len == 1)
        try e.ctx.alloc.dupe(u8, "")
    else
        decodeFormatLiteral(e.ctx.alloc, macro_args[1]) catch
            return unsupported(e, "format write requires a string literal");
    errdefer e.ctx.alloc.free(template);

    if (newline) {
        const with_newline = try std.fmt.allocPrint(e.ctx.alloc, "{s}\n", .{template});
        e.ctx.alloc.free(template);
        template = with_newline;
    }

    var lowered_args: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer lowered_args.deinit(e.ctx.alloc);
    if (macro_args.len > 2) {
        for (macro_args[2..]) |arg| {
            try lowered_args.append(e.ctx.alloc, try parseAndLowerSubExpr(e, arg));
        }
    }
    return appendExpr(e, .{ .format_write = .{
        .writer = writer,
        .template = template,
        .args = try lowered_args.toOwnedSlice(e.ctx.alloc),
    } });
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
        .panic => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            const msg = try expand.expandPanicMessage(e.ctx.alloc, args);
            defer e.ctx.alloc.free(msg);
            const full_msg = if (msg.len > 0)
                try std.fmt.allocPrint(e.ctx.alloc, "panic: {s}", .{msg})
            else
                try std.fmt.allocPrint(e.ctx.alloc, "panic", .{});
            return lowerPanic(e, full_msg);
        },
        .todo, .unimplemented => {
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            const msg = try expand.expandPanicMessage(e.ctx.alloc, args);
            defer e.ctx.alloc.free(msg);
            const prefix = if (kind == .todo) "todo" else "unimplemented";
            const full_msg = if (msg.len > 0)
                try std.fmt.allocPrint(e.ctx.alloc, "{s}: {s}", .{ prefix, msg })
            else
                try std.fmt.allocPrint(e.ctx.alloc, "{s}", .{prefix});
            return unsupported(e, full_msg);
        },
        .unreachable_ => {
            return lowerPanic(e, "unreachable");
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
            const args = try expand.splitMacroArgs(e.ctx.alloc, raw_tokens);
            defer e.ctx.alloc.free(args);
            for (args) |arg| {
                if (arg.len == 0) return unsupported(e, "empty macro argument");
            }

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
                    return appendExpr(e, .{ .vec_lit = .{
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
                    return appendExpr(e, .{ .vec_lit = .{
                        .elements = lowered,
                        .repeat = count,
                    } });
                },
            }
        },
        .write => {
            if (!isBuiltinFormatMacroName(mname, "write"))
                return unsupported(e, "unsupported qualified write macro");
            return lowerFormatWrite(e, raw_tokens, false);
        },
        .writeln => {
            if (!isBuiltinFormatMacroName(mname, "writeln"))
                return unsupported(e, "unsupported qualified writeln macro");
            return lowerFormatWrite(e, raw_tokens, true);
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

/// Return the pattern node carried by a source parameter.
fn paramPatternNode(node: ts.Node) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), "self_parameter")) return null;
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (isPatternNode(child)) return child;
    }
    return null;
}

/// Return a plain immutable parameter identifier. Any mutable or destructured
/// pattern must use a synthetic outer parameter and a root-body prologue.
fn plainParamName(e: *const Ext, node: ts.Node) ?[]const u8 {
    if (std.mem.eql(u8, node.kind(), "identifier")) return text(e, node);
    if (!std.mem.eql(u8, node.kind(), "pattern") or node.namedChildCount() != 1) return null;
    return plainParamName(e, node.namedChild(0).?);
}

/// Register one source parameter and lower a single destructuring prologue.
fn registerParamLocal(
    e: *Ext,
    source_node: ts.Node,
    param: items.Param,
    prelude: *std.ArrayListUnmanaged(exprs.NodeId),
) anyerror!void {
    if (std.mem.eql(u8, source_node.kind(), "self_parameter")) {
        const def = try pushLocal(e, "self");
        setLocalType(e, def, param.ty);
        return;
    }
    const pattern = paramPatternNode(source_node) orelse return error.MalformedCst;
    const def = try pushLocal(e, param.name);
    setLocalType(e, def, param.ty);
    if (plainParamName(e, pattern) != null) return;

    const pattern_id = try lowerPattern(e, pattern);
    const init_id = try appendExpr(e, .{ .path = .{
        .def = def,
        .generic_args = &.{},
    } });
    const ty = try appendType(e, param.ty);
    const stmt_id = try appendStmt(e, .{ .let = .{
        .pattern = pattern_id,
        .init = init_id,
        .ty = ty,
    } });
    try prelude.append(e.ctx.alloc, stmt_id);
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
    const parent_id = ent.parent orelse return;
    const parent = ctx.g.symbol_table.get(parent_id) orelse return;
    const target_id = switch (parent.kind) {
        .struct_, .enum_, .union_ => parent_id,
        .impl_ => parent.parent orelse return,
        else => return,
    };
    if (target_id >= ctx.bodies_list.items.len) return;
    switch (ctx.bodies_list.items[target_id]) {
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
}

/// Extract the body of the function whose entity is `fn_entity` by parsing
/// `src`. A missing source match, missing block, or malformed CST is fatal.
pub fn extractFunction(
    ctx: *Ctx,
    fn_entity: spine.EntityId,
) anyerror!bool {
    const ent = ctx.g.symbol_table.get(fn_entity) orelse return error.FunctionBodyMissing;
    if (ent.kind != .fn_) return error.FunctionBodyMissing;

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(rust.language());
    const tree = parser.parseString(ctx.src, null) orelse return error.MalformedCst;
    defer tree.destroy();

    const root = tree.rootNode();
    var wanted_impl: ?[]const u8 = null;
    if (ent.parent) |parent_id| {
        if (ctx.g.symbol_table.get(parent_id)) |parent| {
            if (parent.kind == .impl_) wanted_impl = parent.name;
        }
    }
    var item = findFunctionNode(ctx, root, ent.name, wanted_impl, null);
    if (item == null and wanted_impl != null) {
        item = findFunctionNode(ctx, root, ent.name, null, null);
    }
    const fn_node = item orelse return error.FunctionBodyMissing;

    var block: ?ts.Node = null;
    var params_node: ?ts.Node = null;
    var i: u32 = 0;
    while (fn_node.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "block")) block = child;
        if (std.mem.eql(u8, kind, "parameters")) params_node = child;
    }
    const blk_node = block orelse return error.FunctionBodyMissing;
    if (root.hasError()) return error.MalformedCst;
    if (fn_entity >= ctx.bodies_list.items.len) return error.FunctionBodyMissing;

    var ex: Ext = .{ .ctx = ctx, .fn_id = fn_entity };
    ex.self_ty = findSelfType(&ex, ent);
    defer ex.deinit();

    // Register outer parameter locals first. Nontrivial source patterns use
    // the synthetic names supplied by the CST pass and one root-body prologue.
    var param_prelude: std.ArrayListUnmanaged(exprs.NodeId) = .empty;
    defer param_prelude.deinit(ctx.alloc);
    const fn_params: []const items.Param = switch (ctx.bodies_list.items[fn_entity]) {
        .fn_ => |body| body.params,
        else => return error.FunctionBodyMissing,
    };
    if (params_node) |pn| {
        var p: u32 = 0;
        var param_index: usize = 0;
        while (pn.namedChild(p)) |pnode| : (p += 1) {
            const kind = pnode.kind();
            if (!std.mem.eql(u8, kind, "parameter") and
                !std.mem.eql(u8, kind, "self_parameter")) continue;
            if (param_index >= fn_params.len) return error.MalformedCst;
            try registerParamLocal(&ex, pnode, fn_params[param_index], &param_prelude);
            param_index += 1;
        }
        if (param_index != fn_params.len) return error.MalformedCst;
    }

    const body_expr = try lowerExpr(&ex, blk_node);
    if (param_prelude.items.len > 0) {
        switch (ctx.exprs.items[body_expr].kind) {
            .block => |*body| {
                const old_statements = body.statements;
                const merged = try ctx.alloc.alloc(exprs.NodeId, param_prelude.items.len + old_statements.len);
                @memcpy(merged[0..param_prelude.items.len], param_prelude.items);
                @memcpy(merged[param_prelude.items.len..], old_statements);
                if (old_statements.len > 0) ctx.alloc.free(old_statements);
                body.statements = merged;
            },
            else => return error.MalformedCst,
        }
    }

    // Lossless partial lower: keep the full lowered body even when
    // sub-expressions are `.unsupported`; emit renders those as loud
    // runtime `@panic` unsoundness markers (never a silent wrong value).
    var fn_body = switch (ctx.bodies_list.items[fn_entity]) {
        .fn_ => |body| body,
        else => return error.FunctionBodyMissing,
    };
    fn_body.body = body_expr;
    ctx.bodies_list.items[fn_entity] = .{ .fn_ = fn_body };
    updateStructMethodBody(ctx, ent, body_expr);
    return true;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "decode byte character at length boundary" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try decodeRustByteLiteral(allocator, "b'")) == null);

    const decoded = (try decodeRustByteLiteral(allocator, "b'a'")) orelse
        return error.ExpectedByteCharacter;
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, "a", decoded);
}

test "lower else-if branches exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
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

    const src = "fn choose() { if true { 1 } else if false { 2 } else { 3 } }";
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
    var ext: Ext = .{ .ctx = &ctx, .fn_id = 0 };
    defer ext.deinit();

    const parser = ts.Parser.create();
    defer parser.destroy();
    if (parser.setLanguage(rust.language())) |_| {} else |_| {}
    const tree = parser.parseString(src, null) orelse return error.ParseFailed;
    defer tree.destroy();

    const function_node = tree.rootNode().namedChild(0) orelse return error.MissingFunction;
    var block_node: ?ts.Node = null;
    var child_index: u32 = 0;
    while (function_node.namedChild(child_index)) |child| : (child_index += 1) {
        if (std.mem.eql(u8, child.kind(), "block")) {
            block_node = child;
            break;
        }
    }
    const raw_if_node = (block_node orelse return error.MissingFunctionBlock).namedChild(0) orelse
        return error.MissingIfExpression;
    const if_node = if (std.mem.eql(u8, raw_if_node.kind(), "expression_statement"))
        raw_if_node.namedChild(0) orelse return error.MissingIfExpression
    else
        raw_if_node;

    const outer_id = try lowerIf(&ext, if_node);
    const outer = switch (exprs_list.items[outer_id].kind) {
        .if_else => |if_else| if_else,
        else => return error.ExpectedIfExpression,
    };
    switch (exprs_list.items[outer.cond].kind) {
        .literal => |literal| switch (literal) {
            .boolean => |value| try std.testing.expect(value),
            else => return error.ExpectedBooleanCondition,
        },
        else => return error.ExpectedBooleanCondition,
    }
    const outer_then_id = outer.then_.tail orelse return error.MissingThenTail;
    switch (exprs_list.items[outer_then_id].kind) {
        .literal => |literal| switch (literal) {
            .int => |int| try std.testing.expectEqual(@as(i128, 1), int.value),
            else => return error.ExpectedIntegerThenTail,
        },
        else => return error.ExpectedIntegerThenTail,
    }

    const inner_id = switch (outer.@"else") {
        .chain => |chain| chain,
        else => return error.ExpectedElseIfChain,
    };
    const inner = switch (exprs_list.items[inner_id].kind) {
        .if_else => |if_else| if_else,
        else => return error.ExpectedNestedIfExpression,
    };
    switch (exprs_list.items[inner.cond].kind) {
        .literal => |literal| switch (literal) {
            .boolean => |value| try std.testing.expect(!value),
            else => return error.ExpectedBooleanCondition,
        },
        else => return error.ExpectedBooleanCondition,
    }
    const inner_then_id = inner.then_.tail orelse return error.MissingNestedThenTail;
    switch (exprs_list.items[inner_then_id].kind) {
        .literal => |literal| switch (literal) {
            .int => |int| try std.testing.expectEqual(@as(i128, 2), int.value),
            else => return error.ExpectedIntegerThenTail,
        },
        else => return error.ExpectedIntegerThenTail,
    }
    const final_else = switch (inner.@"else") {
        .block => |block| block,
        else => return error.ExpectedFinalElseBlock,
    };
    const final_else_id = final_else.tail orelse return error.MissingFinalElseTail;
    switch (exprs_list.items[final_else_id].kind) {
        .literal => |literal| switch (literal) {
            .int => |int| try std.testing.expectEqual(@as(i128, 3), int.value),
            else => return error.ExpectedIntegerElseTail,
        },
        else => return error.ExpectedIntegerElseTail,
    }
}

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
        .params = &.{.{ .name = "self", .ty = .{ .prim = .unit }, .span = span }},
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
    var found_vec_lit = false;
    var found_unsupported = false;
    var found_panic = false;
    var found_unreachable = false;
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
            .vec_lit => |vec_lit| {
                if (vec_lit.elements.len == 3 and vec_lit.repeat == null) found_vec_lit = true;
            },
            .panic_ => |panic_value| {
                const panic_type_id = ex.ty orelse return error.ExpectedPanicType;
                switch (types_list.items[panic_type_id]) {
                    .prim => |primitive| try std.testing.expectEqual(types.Prim.never, primitive),
                    else => return error.ExpectedPanicType,
                }
                if (std.mem.eql(u8, panic_value.message, "unreachable")) {
                    found_unreachable = true;
                } else {
                    found_panic = true;
                }
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
    try std.testing.expect(found_vec_lit); // vec![1,2,3] → non-repeated three-element Vec literal
    try std.testing.expect(found_assert_marker); // assert!/debug_assert! → assertion: marker
    try std.testing.expect(found_debug_assert_ge); // debug_assert!(x > 0) → .gt binary
    try std.testing.expect(found_panic); // panic! -> diverging panic expression
    try std.testing.expect(found_unreachable); // unreachable! -> diverging panic expression
    try std.testing.expect(found_unsupported); // unresolved names remain explicit refusal
}

test "lower literal vec macro forms to vec literals" {
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
        \\    let empty = vec![];
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
    try std.testing.expectEqual(@as(usize, 5), body.statements.len);

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
    try std.testing.expect(explicit_init == .vec_lit);
    try std.testing.expect(explicit_init != .unsupported);
    const explicit_vec = switch (explicit_init) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.ExpectedExplicitVecLit,
    };
    try std.testing.expectEqual(@as(usize, 3), explicit_vec.elements.len);
    try std.testing.expect(explicit_vec.repeat == null);

    const explicit_tuple = switch (exprs_list.items[explicit_vec.elements[1]].kind) {
        .array => |tuple| tuple,
        else => return error.ExpectedExplicitVecTuple,
    };
    try std.testing.expectEqual(@as(usize, 2), explicit_tuple.elements.len);
    try std.testing.expect(explicit_tuple.repeat == null);

    const empty_let = switch (stmts_list.items[body.statements[1]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedEmptyVecLet,
    };
    const empty_binding = switch (pats_list.items[empty_let.pattern].kind) {
        .binding => |binding| binding,
        else => return error.ExpectedEmptyVecBinding,
    };
    try std.testing.expectEqualStrings("empty", empty_binding.name);
    const empty_init_id = empty_let.init orelse return error.ExpectedEmptyVecInitializer;
    const empty_vec = switch (exprs_list.items[empty_init_id].kind) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.ExpectedEmptyVecLit,
    };
    try std.testing.expectEqual(@as(usize, 0), empty_vec.elements.len);
    try std.testing.expect(empty_vec.repeat == null);

    const repeated_let = switch (stmts_list.items[body.statements[2]].kind) {
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
    try std.testing.expect(repeated_init == .vec_lit);
    try std.testing.expect(repeated_init != .unsupported);
    const repeated_vec = switch (repeated_init) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.ExpectedRepeatedVecLit,
    };
    try std.testing.expectEqual(@as(usize, 1), repeated_vec.elements.len);
    try std.testing.expectEqual(
        @as(usize, 200_000),
        repeated_vec.repeat orelse return error.ExpectedRepeatedVecCount,
    );

    const suffixed_decimal_let = switch (stmts_list.items[body.statements[3]].kind) {
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
    try std.testing.expect(suffixed_decimal_init == .vec_lit);
    try std.testing.expect(suffixed_decimal_init != .unsupported);
    const suffixed_decimal_vec = switch (suffixed_decimal_init) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.ExpectedSuffixedDecimalVecLit,
    };
    try std.testing.expectEqual(@as(usize, 1), suffixed_decimal_vec.elements.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        suffixed_decimal_vec.repeat orelse return error.ExpectedSuffixedDecimalVecCount,
    );

    const suffixed_hex_let = switch (stmts_list.items[body.statements[4]].kind) {
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
    try std.testing.expect(suffixed_hex_init == .vec_lit);
    try std.testing.expect(suffixed_hex_init != .unsupported);
    const suffixed_hex_vec = switch (suffixed_hex_init) {
        .vec_lit => |vec_lit| vec_lit,
        else => return error.ExpectedSuffixedHexVecLit,
    };
    try std.testing.expectEqual(@as(usize, 1), suffixed_hex_vec.elements.len);
    try std.testing.expectEqual(
        @as(usize, 255),
        suffixed_hex_vec.repeat orelse return error.ExpectedSuffixedHexVecCount,
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
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{.{
            .name = "shape",
            .ty = .{ .path = .{ .segments = &.{.{ .name = "Shape", .id = null }} } },
            .span = span,
        }},
        .ret = .{ .prim = .f64 },
        .body = 0,
    } });
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
        \\    let _character = match 'a' {
        \\        'a' => 0,
        \\    };
        \\    let _number = match 1 {
        \\        1 => 0,
        \\    };
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
    var match_count: usize = 0;
    var struct_pat_count: usize = 0;
    var found_float = false;
    var found_binding_r = false;
    var found_character_pattern = false;
    var found_integer_pattern = false;
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
                match_count += 1;
                match_arm_count += me.arms.len;
                try std.testing.expect(!me.option_scrutinee);
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
            .literal => |literal| switch (literal) {
                .character => |character| {
                    try std.testing.expectEqual(@as(u32, 'a'), character.value);
                    try std.testing.expectEqualStrings("'a'", character.text);
                    found_character_pattern = true;
                },
                .int => |integer| {
                    try std.testing.expectEqual(@as(i128, 1), integer.value);
                    try std.testing.expectEqualStrings("1", integer.text);
                    try std.testing.expect(integer.base == .dec);
                    try std.testing.expect(integer.ty_suffix == null);
                    found_integer_pattern = true;
                },
                else => return error.UnexpectedLiteralPattern,
            },
            .wildcard => return error.UnexpectedWildcardPattern,
            .unsupported => return error.UnexpectedUnsupportedPattern,
            else => {},
        }
    }
    try std.testing.expect(found_struct_lit); // Point { x: 0, y: 0 }
    try std.testing.expect(found_match); // match shape { ... }
    try std.testing.expectEqual(@as(usize, 3), match_count);
    try std.testing.expectEqual(@as(usize, 4), match_arm_count);
    try std.testing.expectEqual(@as(usize, 2), struct_pat_count); // Circle + Rect
    try std.testing.expect(found_binding_r); // r bound by Circle(r)
    try std.testing.expect(found_float); // 3.14159 in the Circle arm body
    try std.testing.expect(found_character_pattern);
    try std.testing.expect(found_integer_pattern);
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

    const calc_params = try alloc.dupe(items.Param, &.{
        .{ .name = "x", .ty = .{ .prim = .u16 }, .span = span },
    });
    switch (bodies_list.items[10]) {
        .fn_ => |*body| body.params = calc_params,
        else => return error.ExpectedFunctionBody,
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

/// Ids a `Type::trait_method` fixture needs a test to name.
const OwnerTypeMethodFixture = struct {
    /// The impl method a `Vec::from_hex(..)` call must bind to.
    from_hex_id: spine.EntityId,
    /// The function whose body spells the call.
    caller_id: spine.EntityId,
};

/// Build the crate half of a `Type::trait_method` fixture and the body table
/// that goes with it.
///
/// The trait impl's self type is `Vec<u8>`, an external nominal that gets no
/// entity of its own. That is the whole shape under test: `Vec::from_hex(..)`
/// names a receiver type and a trait method, and neither half resolves by name
/// — only the impl that carries `from_hex` can.
///
/// `vec_impls` adds further trait impls for the same `Vec<u8>`, each declaring
/// `from_hex`, so the ambiguous case is built from the same fixture.
fn buildOwnerTypeMethodFixture(
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
    vec_impls: usize,
) !OwnerTypeMethodFixture {
    const root_id = try addLookupTestEntity(alloc, g, .module, "", null, null);
    const trait_id = try addLookupTestEntity(alloc, g, .trait_, "FromHex", root_id, null);
    const error_id = try addLookupTestEntity(alloc, g, .enum_, "FromHexError", root_id, null);

    const self_ty: types.Type = .{ .external_nominal = .{
        .path = try alloc.dupe([]const u8, &.{ "alloc", "vec", "Vec" }),
        .args = try alloc.dupe(types.Type, &.{.{ .prim = .u8 }}),
    } };
    const trait_path: types.Path = .{ .segments = try alloc.dupe(
        types.PathSegment,
        &.{.{ .name = "FromHex", .id = trait_id }},
    ) };
    const result_ty = try alloc.create(types.Result);
    result_ty.* = .{
        .ok = self_ty,
        .err = .{ .path = .{ .segments = try alloc.dupe(
            types.PathSegment,
            &.{.{ .name = "FromHexError", .id = error_id }},
        ) } },
        .is_error_unionable = false,
    };

    // The body table is indexed by entity id, and ids are dense in `add` order.
    try bodies_list.append(alloc, .none); // root module
    try bodies_list.append(alloc, .{ .trait_ = .{ .name = "FromHex" } });
    try bodies_list.append(alloc, .{ .enum_ = .{} });

    var from_hex_id: spine.EntityId = 0;
    for (0..vec_impls) |index| {
        const impl_name = if (index == 0)
            "FromHex for Vec<u8>"
        else
            try std.fmt.allocPrint(alloc, "FromHex for Vec<u8> #{d}", .{index});
        const impl_id = try addLookupTestEntity(alloc, g, .impl_, impl_name, root_id, null);
        try bodies_list.append(alloc, .{ .impl_ = .{
            .self_ty = self_ty,
            .trait_path = trait_path,
        } });
        const method_id = try addLookupTestEntity(alloc, g, .fn_, "from_hex", impl_id, null);
        try bodies_list.append(alloc, .{ .fn_ = .{
            .params = &.{},
            .ret = .{ .result = result_ty },
            .body = 0,
        } });
        if (index == 0) from_hex_id = method_id;
    }

    const caller_id = try addLookupTestEntity(alloc, g, .fn_, "decode_hex", root_id, null);
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });
    const root_items = try alloc.dupe(spine.EntityId, &.{caller_id});
    try addLookupTestModule(alloc, g, "", null, true, root_items);
    return .{ .from_hex_id = from_hex_id, .caller_id = caller_id };
}

test "lowerCall binds a trait method through an owner type that has no entity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    const fixture = try buildOwnerTypeMethodFixture(alloc, &g, &tables.bodies_list, 1);

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn decode_hex() {
        \\    Vec::from_hex("00").unwrap()
        \\}
        ,
        .mod_id = 0,
    };
    try std.testing.expect(try extractFunction(&ctx, fixture.caller_id));

    const body_id = tables.bodies_list.items[fixture.caller_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    // `Vec::from_hex("00").unwrap()` — the chain a real caller writes, and the
    // one whose receiver type decides whether `unwrap` resolves at all.
    const unwrap = switch (tables.exprs_list.items[
        block.tail orelse
            return error.MissingTailExpression
    ].kind) {
        .method_call => |value| value,
        else => return error.ExpectedMethodCall,
    };
    const lowered = tables.exprs_list.items[unwrap.receiver];
    switch (lowered.kind) {
        .call => |call| switch (call.call_kind) {
            .associated => |target| try std.testing.expectEqual(fixture.from_hex_id, target),
            else => return error.ExpectedAssociatedCall,
        },
        else => return error.ExpectedCall,
    }
    for (tables.exprs_list.items) |ex| {
        if (ex.kind == .unsupported) {
            try std.testing.expect(!std.mem.eql(u8, ex.kind.unsupported.reason, "unresolved call"));
        }
    }

    // The call must carry its declared `Result`, so the `unwrap` receiver is a
    // typed operand rather than an untyped hole the comparison operator can
    // never resolve.
    const b: bodies.Bodies = .{
        .exprs = tables.exprs_list.items,
        .stmts = tables.stmts_list.items,
        .pats = tables.pats_list.items,
        .types = tables.types_list.items,
        .bodies = tables.bodies_list.items,
    };
    var inferred = try infer.solveWithGraph(alloc, &b, &g);
    defer inferred.deinit(alloc);
    const receiver_type_id = inferred.getType(unwrap.receiver) orelse
        return error.UntypedUnwrapReceiver;
    const receiver_ty = tables.types_list.items[receiver_type_id];
    switch (receiver_ty) {
        .result => {},
        else => return error.ReceiverIsNotAResult,
    }
}

test "lowerCall still rejects a trait method for a type no impl covers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    const fixture = try buildOwnerTypeMethodFixture(alloc, &g, &tables.bodies_list, 1);

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn decode_hex() {
        \\    String::from_hex("00")
        \\}
        ,
        .mod_id = 0,
    };
    try std.testing.expect(try extractFunction(&ctx, fixture.caller_id));

    const body_id = tables.bodies_list.items[fixture.caller_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const lowered = tables.exprs_list.items[
        block.tail orelse
            return error.MissingTailExpression
    ];
    // No impl in this crate covers `String`, so the path still has to be
    // rejected — with the reason that says which construct failed.
    switch (lowered.kind) {
        .unsupported => |marker| try std.testing.expectEqualStrings(
            "unresolved call",
            marker.reason,
        ),
        else => return error.ExpectedUnsupportedCall,
    }
}

test "lowerCall rejects an owner type whose impls disagree on the method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    const fixture = try buildOwnerTypeMethodFixture(alloc, &g, &tables.bodies_list, 2);

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn decode_hex() {
        \\    Vec::from_hex("00")
        \\}
        ,
        .mod_id = 0,
    };
    try std.testing.expect(try extractFunction(&ctx, fixture.caller_id));

    const body_id = tables.bodies_list.items[fixture.caller_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const lowered = tables.exprs_list.items[
        block.tail orelse
            return error.MissingTailExpression
    ];
    // Two impls both claim `from_hex` for `Vec<u8>`, so nothing in the path
    // chooses between them. Binding either one would emit a call into an
    // implementation the source never named.
    switch (lowered.kind) {
        .unsupported => |marker| try std.testing.expectEqualStrings(
            "unresolved call",
            marker.reason,
        ),
        else => return error.ExpectedUnsupportedCall,
    }
}

test "appendGenericCall uses declared nominal return type for associated calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const hasher_id = try addLookupTestEntity(
        alloc,
        &g,
        .struct_,
        "Hasher",
        null,
        null,
    );
    const impl_id = try addLookupTestEntity(
        alloc,
        &g,
        .impl_,
        "Hasher",
        hasher_id,
        null,
    );
    const default_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "default",
        impl_id,
        null,
    );

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .{ .struct_ = .{
        .generic_params = &.{},
        .layout = .named,
        .fields = &.{},
    } });
    try tables.bodies_list.append(alloc, .none);
    const return_segments = [_]types.PathSegment{
        .{ .name = "Hasher", .id = hasher_id },
    };
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .path = .{ .segments = &return_segments } },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src = "",
        .mod_id = hasher_id,
    };
    var ext: Ext = .{ .ctx = &ctx, .fn_id = default_id };
    defer ext.deinit();

    const call_id = try appendGenericCall(
        &ext,
        .{ .associated = default_id },
        &.{},
        &.{},
    );
    const call_expr = tables.exprs_list.items[call_id];
    const call = switch (call_expr.kind) {
        .call => |value| value,
        else => return error.ExpectedAssociatedCall,
    };
    switch (call.call_kind) {
        .associated => |def| try std.testing.expectEqual(default_id, def),
        else => return error.ExpectedAssociatedCall,
    }

    const return_type_id = call_expr.ty orelse return error.MissingAssociatedCallType;
    try std.testing.expectEqual(@as(usize, 1), tables.types_list.items.len);
    switch (tables.types_list.items[return_type_id]) {
        .path => |path| {
            try std.testing.expectEqual(@as(usize, 1), path.segments.len);
            try std.testing.expectEqual(hasher_id, path.segments[0].id.?);
            try std.testing.expectEqualStrings("Hasher", path.segments[0].name);
        },
        else => return error.ExpectedNominalCallType,
    }
}

test "appendGenericCall leaves signature-inferred generic return untyped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const function_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "id",
        null,
        null,
    );

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    const type_parameter_segments = [_]types.PathSegment{
        .{ .name = "T", .id = null },
    };
    const type_parameter: types.Type = .{
        .path = .{ .segments = &type_parameter_segments },
    };
    const params = [_]ir.items.Param{
        .{ .name = "value", .ty = type_parameter, .span = span_of },
    };
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &params,
        .ret = type_parameter,
        .generic_params = &.{},
        .body = 0,
    } });
    try tables.types_list.append(alloc, .{ .prim = .u64 });
    try tables.exprs_list.append(alloc, .{
        .id = 0,
        .span = span_of,
        .ty = 0,
        .kind = .{ .literal = .{ .int = .{
            .text = "1",
            .value = 1,
            .base = .dec,
            .ty_suffix = null,
        } } },
    });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src = "",
        .mod_id = function_id,
    };
    var ext: Ext = .{ .ctx = &ctx, .fn_id = function_id };
    defer ext.deinit();

    const call_id = try appendGenericCall(
        &ext,
        .{ .free = function_id },
        &.{0},
        &.{},
    );
    const call_expr = tables.exprs_list.items[call_id];
    const call = switch (call_expr.kind) {
        .call => |value| value,
        else => return error.ExpectedFreeCall,
    };
    switch (call.call_kind) {
        .free => |def| try std.testing.expectEqual(function_id, def),
        else => return error.ExpectedFreeCall,
    }

    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqual(@as(exprs.NodeId, 0), call.args[0]);
    try std.testing.expectEqual(@as(usize, 0), tables.bodies_list.items[
        function_id
    ].fn_.generic_params.len);
    try std.testing.expect(call_expr.ty == null);
    try std.testing.expectEqual(@as(usize, 1), tables.types_list.items.len);
}

test "appendGenericCall uses declared u64 return type for free calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const function_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "hash",
        null,
        null,
    );

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u64 },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src = "",
        .mod_id = function_id,
    };
    var ext: Ext = .{ .ctx = &ctx, .fn_id = function_id };
    defer ext.deinit();

    const call_id = try appendGenericCall(
        &ext,
        .{ .free = function_id },
        &.{},
        &.{},
    );
    const call_expr = tables.exprs_list.items[call_id];
    const call = switch (call_expr.kind) {
        .call => |value| value,
        else => return error.ExpectedFreeCall,
    };
    switch (call.call_kind) {
        .free => |def| try std.testing.expectEqual(function_id, def),
        else => return error.ExpectedFreeCall,
    }

    const return_type_id = call_expr.ty orelse return error.MissingFreeCallType;
    try std.testing.expectEqual(@as(usize, 1), tables.types_list.items.len);
    switch (tables.types_list.items[return_type_id]) {
        .prim => |primitive| try std.testing.expectEqual(types.Prim.u64, primitive),
        else => return error.ExpectedPrimitiveCallType,
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
    const right_wyr3_id = try add_entity(alloc, &g, .fn_, "wyr3", local_mod_id);
    const right_wyr4_id = try add_entity(alloc, &g, .fn_, "wyr4", local_mod_id);
    const hasher_id = try add_entity(alloc, &g, .struct_, "Hasher", local_mod_id);
    const impl_id = try add_entity(alloc, &g, .impl_, "Hasher", hasher_id);
    const wrong_const_id = try add_entity(alloc, &g, .const_, "CONTINUATION_BIT", other_mod_id);
    const right_const_id = try add_entity(alloc, &g, .const_, "CONTINUATION_BIT", impl_id);
    const caller_id = try add_entity(alloc, &g, .fn_, "caller", impl_id);
    const local_items = try alloc.alloc(spine.EntityId, 5);
    local_items[0] = right_call_id;
    local_items[1] = hasher_id;
    local_items[2] = impl_id;
    local_items[3] = right_wyr3_id;
    local_items[4] = right_wyr4_id;
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
        \\    wymix();
        \\    wyr3();
        \\    wyr4()
        \\}
        \\}
        ,
        .mod_id = local_mod_id,
    };
    try std.testing.expect(try extractFunction(&ctx, caller_id));

    var found_constant = false;
    var found_forward_call = false;
    var found_wyr3_call = false;
    var found_wyr4_call = false;
    for (exprs_list.items) |expression| {
        switch (expression.kind) {
            .path => |path| {
                if (path.def == right_const_id) found_constant = true;
            },
            .call => |call| switch (call.call_kind) {
                .free => |def| {
                    if (def == right_call_id) found_forward_call = true;
                    if (def == right_wyr3_id) found_wyr3_call = true;
                    if (def == right_wyr4_id) found_wyr4_call = true;
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(found_constant);
    try std.testing.expect(found_forward_call);
    try std.testing.expect(found_wyr3_call);
    try std.testing.expect(found_wyr4_call);
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
        .params = &.{.{ .name = "flag", .ty = .{ .prim = .bool }, .span = span }},
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
            .int => |integer| integer,
            else => return error.ExpectedByteLiteral,
        },
        else => return error.ExpectedLiteralExpression,
    };
    try std.testing.expectEqual(@as(i128, 0), nul_literal.value);
    try std.testing.expectEqualStrings(
        "u8",
        nul_literal.ty_suffix orelse return error.ExpectedByteType,
    );

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

test "lower scalar casts and shared and mutable references" {
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
    const repeat_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "repeat_N"),
        .span = span,
        .visibility = .public,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const fn_id = try g.symbol_table.add(.{
        .id = 0,
        .kind = .fn_,
        .name = try alloc.dupe(u8, "refuse"),
        .span = span,
        .visibility = .private,
        .parent = root_id,
        .resolved = null,
        .renamed_to = null,
        .attributes = &.{},
    });
    const root_items = try alloc.alloc(spine.EntityId, 2);
    root_items[0] = repeat_id;
    root_items[1] = fn_id;
    g.modules.items[0].items = root_items;

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
        .ret = .{ .prim = .u16 },
        .body = 0,
    } });
    try bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .u16 },
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
        \\fn repeat_N() -> u16 {
        \\    7
        \\}
        \\fn refuse() -> u16 {
        \\    let value = 7u8;
        \\    let casted = value as u16;
        \\    let borrowed = &repeat_N();
        \\    let mutable_borrowed = &mut repeat_N();
        \\    let invalid = value as &u8;
        \\    casted
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
    try std.testing.expectEqual(@as(usize, 5), body.statements.len);

    const cast_let = switch (stmts_list.items[body.statements[1]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedCastLet,
    };
    const cast_init = cast_let.init orelse return error.ExpectedCastInitializer;
    const cast_expr = switch (exprs_list.items[cast_init].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedSupportedCast,
    };
    try std.testing.expectEqual(exprs.ConversionKind.as_, cast_expr.kind);
    try std.testing.expect(cast_expr.operand < exprs_list.items.len);
    try std.testing.expect(cast_expr.target < types_list.items.len);
    try std.testing.expectEqual(
        types.Type{ .prim = .u16 },
        types_list.items[cast_expr.target],
    );
    try std.testing.expectEqual(cast_expr.target, exprs_list.items[cast_init].ty.?);

    const shared_let = switch (stmts_list.items[body.statements[2]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedSharedReferenceLet,
    };
    const shared_init = shared_let.init orelse return error.ExpectedSharedReferenceInitializer;
    const shared_reference = switch (exprs_list.items[shared_init].kind) {
        .unary => |unary| unary,
        else => return error.ExpectedSharedReference,
    };
    switch (shared_reference.op) {
        .ref => |mode| try std.testing.expect(mode == .shared),
        else => return error.ExpectedSharedReference,
    }
    const shared_call = switch (exprs_list.items[shared_reference.operand].kind) {
        .call => |call| call,
        else => return error.ExpectedSharedReferenceCall,
    };
    switch (shared_call.call_kind) {
        .free => |target| try std.testing.expectEqual(
            @as(exprs.DefId, repeat_id),
            target,
        ),
        else => return error.ExpectedSharedReferenceCall,
    }

    const mutable_let = switch (stmts_list.items[body.statements[3]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedMutableReferenceLet,
    };
    const mutable_init = mutable_let.init orelse
        return error.ExpectedMutableReferenceInitializer;
    const mutable_reference = switch (exprs_list.items[mutable_init].kind) {
        .unary => |unary| unary,
        else => return error.ExpectedMutableReference,
    };
    switch (mutable_reference.op) {
        .ref => |mode| try std.testing.expect(mode == .mutable),
        else => return error.ExpectedMutableReference,
    }
    const mutable_call = switch (exprs_list.items[mutable_reference.operand].kind) {
        .call => |call| call,
        else => return error.ExpectedMutableReferenceCall,
    };
    switch (mutable_call.call_kind) {
        .free => |target| try std.testing.expectEqual(
            @as(exprs.DefId, repeat_id),
            target,
        ),
        else => return error.ExpectedMutableReferenceCall,
    }
    const invalid_let = switch (stmts_list.items[body.statements[4]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedInvalidCastLet,
    };
    const invalid_init = invalid_let.init orelse return error.ExpectedInvalidCastInitializer;
    const invalid_reason = switch (exprs_list.items[invalid_init].kind) {
        .unsupported => |unsupported_expr| unsupported_expr.reason,
        else => return error.ExpectedUnsupportedCastTarget,
    };
    try std.testing.expectEqualStrings("cast target type", invalid_reason);

    const tail_id = body.tail orelse return error.ExpectedFunctionTail;
    try std.testing.expect(exprs_list.items[tail_id].kind == .path);
}

test "lower unsigned primitive from calls as casts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "primitive_from",
        root_id,
        null,
    );
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    const source_params = try alloc.dupe(items.Param, &.{
        .{ .name = "a", .ty = .{ .prim = .u64 }, .span = span_of },
        .{
            .name = "data",
            .ty = .{ .array = &.{
                .elem = .{ .prim = .u8 },
                .len = .{ .literal = 1 },
            } },
            .span = span_of,
        },
    });
    switch (tables.bodies_list.items[fn_id]) {
        .fn_ => |*function_body| function_body.params = source_params,
        else => return error.ExpectedFunctionBody,
    }

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn primitive_from(a: u64, data: [u8; 1]) {
        \\    let wide = u128::from(a);
        \\    let indexed = u64::from(data[0]);
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const body = switch (tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), body.statements.len);

    const expected_targets = [_]types.Type{
        .{ .prim = .u128 },
        .{ .prim = .u64 },
    };
    var operand_ids: [expected_targets.len]exprs.NodeId = undefined;
    for (body.statements, expected_targets, 0..) |statement_id, expected_target, index| {
        const let_statement = switch (tables.stmts_list.items[statement_id].kind) {
            .let => |statement| statement,
            else => return error.ExpectedPrimitiveFromLet,
        };
        const init = let_statement.init orelse return error.ExpectedPrimitiveFromInitializer;
        const cast = switch (tables.exprs_list.items[init].kind) {
            .cast => |value| value,
            .unsupported => return error.PrimitiveFromLoweredAsUnsupportedCall,
            else => return error.ExpectedPrimitiveFromCast,
        };
        try std.testing.expectEqual(exprs.ConversionKind.primitive_from, cast.kind);
        try std.testing.expect(cast.operand < tables.exprs_list.items.len);
        try std.testing.expect(cast.target < tables.types_list.items.len);
        try std.testing.expectEqual(expected_target, tables.types_list.items[cast.target]);
        operand_ids[index] = cast.operand;
    }

    switch (tables.exprs_list.items[operand_ids[0]].kind) {
        .path => {},
        else => return error.ExpectedPrimitiveFromPathOperand,
    }
    const indexed_operand = switch (tables.exprs_list.items[operand_ids[1]].kind) {
        .index => |index| index,
        else => return error.ExpectedPrimitiveFromIndexOperand,
    };
    try std.testing.expect(indexed_operand.base < tables.exprs_list.items.len);
    try std.testing.expect(indexed_operand.index < tables.exprs_list.items.len);
    try std.testing.expect(tables.exprs_list.items[indexed_operand.base].kind == .path);
    try std.testing.expect(tables.exprs_list.items[indexed_operand.index].kind == .literal);

    for (tables.exprs_list.items) |expression| {
        if (expression.kind == .unsupported) {
            return error.PrimitiveFromLoweredAsUnsupportedCall;
        }
    }
}

test "extract and infer concrete cast types while rejecting references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "cast_contract",
        root_id,
        null,
    );
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    const byte_source_pointer = try alloc.create(types.RawPtr);
    byte_source_pointer.* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const compatible_source_pointer = try alloc.create(types.RawPtr);
    compatible_source_pointer.* = .{ .mut = false, .pointee = .{ .prim = .u32 } };
    const source_params = try alloc.alloc(items.Param, 2);
    source_params[0] = .{
        .name = "source",
        .ty = .{ .raw_ptr = byte_source_pointer },
        .span = span_of,
    };
    source_params[1] = .{
        .name = "compatible_source",
        .ty = .{ .raw_ptr = compatible_source_pointer },
        .span = span_of,
    };
    switch (tables.bodies_list.items[fn_id]) {
        .fn_ => |*function_body| function_body.params = source_params,
        else => return error.ExpectedFunctionBody,
    }
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn cast_contract(source: *const u8, compatible_source: *const u32) {
        \\    let wide = 1u128 as u64;
        \\    let index = 1usize as u64;
        \\    let pointer = source as *mut u8;
        \\    let compatible_pointer = compatible_source as *const i32;
        \\    let reference = 1usize as &u8;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const extracted: bodies.Bodies = .{
        .exprs = tables.exprs_list.items,
        .stmts = tables.stmts_list.items,
        .pats = tables.pats_list.items,
        .types = tables.types_list.items,
        .bodies = tables.bodies_list.items,
    };
    var inferred = try infer.solveWithGraph(alloc, &extracted, &g);
    defer inferred.deinit(alloc);

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const body = switch (tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 5), body.statements.len);

    const expected_sources = [_]types.Type{
        .{ .prim = .u128 },
        .{ .prim = .usize },
    };
    for (body.statements[0..expected_sources.len], expected_sources) |statement_id, expected_source| {
        const let_statement = switch (tables.stmts_list.items[statement_id].kind) {
            .let => |statement| statement,
            else => return error.ExpectedScalarCastLet,
        };
        const init = let_statement.init orelse return error.ExpectedScalarCastInitializer;
        const cast = switch (tables.exprs_list.items[init].kind) {
            .cast => |cast| cast,
            else => return error.ExpectedScalarCast,
        };
        try std.testing.expectEqual(expected_source, cast.source_type);
        try std.testing.expectEqual(
            types.Type{ .prim = .u64 },
            tables.types_list.items[cast.target],
        );
    }

    const pointer_let = switch (tables.stmts_list.items[body.statements[2]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedPointerCastLet,
    };
    const pointer_init = pointer_let.init orelse return error.ExpectedPointerCastInitializer;
    const pointer_cast = switch (tables.exprs_list.items[pointer_init].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedPointerCast,
    };
    switch (pointer_cast.source_type) {
        .raw_ptr => |pointer| {
            try std.testing.expect(!pointer.mut);
            try std.testing.expectEqual(types.Type{ .prim = .u8 }, pointer.pointee);
        },
        else => return error.ExpectedRawPointerSource,
    }
    switch (tables.types_list.items[pointer_cast.target]) {
        .raw_ptr => |pointer| {
            try std.testing.expect(pointer.mut);
            try std.testing.expectEqual(types.Type{ .prim = .u8 }, pointer.pointee);
        },
        else => return error.ExpectedRawPointerTarget,
    }

    const compatible_pointer_let = switch (tables.stmts_list.items[body.statements[3]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedCompatiblePointerCastLet,
    };
    const compatible_pointer_init =
        compatible_pointer_let.init orelse return error.ExpectedCompatiblePointerCastInitializer;
    const compatible_pointer_cast = switch (tables.exprs_list.items[compatible_pointer_init].kind) {
        .cast => |cast| cast,
        else => return error.ExpectedCompatiblePointerCast,
    };
    switch (compatible_pointer_cast.source_type) {
        .raw_ptr => |pointer| {
            try std.testing.expect(!pointer.mut);
            try std.testing.expectEqual(types.Type{ .prim = .u32 }, pointer.pointee);
        },
        else => return error.ExpectedCompatibleRawPointerSource,
    }
    switch (tables.types_list.items[compatible_pointer_cast.target]) {
        .raw_ptr => |pointer| {
            try std.testing.expect(!pointer.mut);
            try std.testing.expectEqual(types.Type{ .prim = .i32 }, pointer.pointee);
        },
        else => return error.ExpectedCompatibleRawPointerTarget,
    }

    const reference_let = switch (tables.stmts_list.items[body.statements[4]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedReferenceCastLet,
    };
    const reference_init = reference_let.init orelse return error.ExpectedReferenceCastInitializer;
    const reference_reason = switch (tables.exprs_list.items[reference_init].kind) {
        .unsupported => |unsupported_expr| unsupported_expr.reason,
        else => return error.ExpectedUnsupportedReferenceCast,
    };
    try std.testing.expectEqualStrings("cast target type", reference_reason);
}

test "raw pointer cast across pointee sizes succeeds during inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "unaligned_pointer_cast",
        root_id,
        null,
    );
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    const source_pointer = try alloc.create(types.RawPtr);
    source_pointer.* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const source_params = try alloc.alloc(items.Param, 1);
    source_params[0] = .{
        .name = "source",
        .ty = .{ .raw_ptr = source_pointer },
        .span = span_of,
    };
    switch (tables.bodies_list.items[fn_id]) {
        .fn_ => |*function_body| function_body.params = source_params,
        else => return error.ExpectedFunctionBody,
    }

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn unaligned_pointer_cast(source: *const u8) {
        \\    let unaligned_cast = source as *const u32;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const extracted: bodies.Bodies = .{
        .exprs = tables.exprs_list.items,
        .stmts = tables.stmts_list.items,
        .pats = tables.pats_list.items,
        .types = tables.types_list.items,
        .bodies = tables.bodies_list.items,
    };
    var inferred = try infer.solveWithGraph(alloc, &extracted, &g);
    defer inferred.deinit(alloc);
}

test "reference to raw pointer with pointee mismatch is rejected for translation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source_ref = try alloc.create(types.Ref);
    source_ref.* = .{ .mut = false, .pointee = .{ .prim = .u8 } };
    const params = try alloc.dupe(items.Param, &.{
        .{ .name = "source", .ty = .{ .reference = source_ref }, .span = span_of },
    });
    var fixture = try SourceTestFixture.init(
        alloc,
        "reject_reference_mismatch",
        \\fn reject_reference_mismatch(source: &u8) {
        \\    let invalid_ref_cast = source as *const u32;
        \\}
    ,
        params,
        .{ .prim = .unit },
    );
    try std.testing.expectError(
        error.UnsupportedExpression,
        fixture.validate(),
    );
}

test "preserve function block while refusing unsupported slice match pattern" {
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
        .name = try alloc.dupe(u8, "first"),
        .span = span,
        .visibility = .public,
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
        .params = &.{.{
            .name = "values",
            .ty = .{ .reference = &.{
                .mut = false,
                .pointee = .{ .slice = &.{ .const_ = true, .elem = .{ .prim = .u8 } } },
            } },
            .span = span,
        }},
        .ret = .{ .prim = .u8 },
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
        \\pub fn first(values: &[u8]) -> u8 {
        \\    match values {
        \\        [first, ..] => first,
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
    try std.testing.expectEqual(@as(usize, 0), body.statements.len);
    const match_id = body.tail orelse return error.ExpectedMatchTail;
    const match_kind = exprs_list.items[match_id].kind;
    try std.testing.expect(match_kind != .match);
    const match_reason = switch (match_kind) {
        .unsupported => |unsupported_expr| unsupported_expr.reason,
        else => return error.ExpectedUnsupportedMatch,
    };
    try std.testing.expect(
        std.mem.indexOf(u8, match_reason, "unsupported match pattern") != null,
    );

    var found_slice_pattern = false;
    for (pats_list.items) |pattern| {
        switch (pattern.kind) {
            .wildcard => return error.UnexpectedWildcardSlicePattern,
            .unsupported => |unsupported_pattern| {
                if (std.mem.indexOf(u8, unsupported_pattern.reason, "slice pattern") != null) {
                    found_slice_pattern = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_slice_pattern);
}

test "refuse rejected numeric literals while preserving unary and unit semantics" {
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
        .name = try alloc.dupe(u8, "literal_controls"),
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
        \\fn literal_controls() {
        \\    let rejected_integer = 340282366920938463463374607431768211455u128;
        \\    let rejected_float = 1.25f32;
        \\    let negated = -7i32;
        \\    let inverted = !false;
        \\    let unit = ();
        \\    return;
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
    try std.testing.expectEqual(@as(usize, 6), body.statements.len);

    const integer_let = switch (stmts_list.items[body.statements[0]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedRejectedIntegerLet,
    };
    const integer_init = integer_let.init orelse return error.ExpectedRejectedIntegerInitializer;
    try std.testing.expect(exprs_list.items[integer_init].kind != .literal);
    const integer_reason = switch (exprs_list.items[integer_init].kind) {
        .unsupported => |unsupported_expr| unsupported_expr.reason,
        else => return error.ExpectedUnsupportedIntegerLiteral,
    };
    try std.testing.expectEqualStrings("integer literal out of range", integer_reason);

    const float_let = switch (stmts_list.items[body.statements[1]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedRejectedFloatLet,
    };
    const float_init = float_let.init orelse return error.ExpectedRejectedFloatInitializer;
    try std.testing.expect(exprs_list.items[float_init].kind != .literal);
    const float_reason = switch (exprs_list.items[float_init].kind) {
        .unsupported => |unsupported_expr| unsupported_expr.reason,
        else => return error.ExpectedUnsupportedFloatLiteral,
    };
    try std.testing.expectEqualStrings("invalid float literal", float_reason);

    const negated_let = switch (stmts_list.items[body.statements[2]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedNegatedLet,
    };
    const negated_init = negated_let.init orelse return error.ExpectedNegatedInitializer;
    const negated = switch (exprs_list.items[negated_init].kind) {
        .unary => |unary| unary,
        else => return error.ExpectedNegateUnary,
    };
    try std.testing.expectEqual(.negate, std.meta.activeTag(negated.op));
    try std.testing.expect(negated.operand != negated_init);
    try std.testing.expect(exprs_list.items[negated.operand].kind == .literal);

    const inverted_let = switch (stmts_list.items[body.statements[3]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedInvertedLet,
    };
    const inverted_init = inverted_let.init orelse return error.ExpectedInvertedInitializer;
    const inverted = switch (exprs_list.items[inverted_init].kind) {
        .unary => |unary| unary,
        else => return error.ExpectedLogicalNotUnary,
    };
    try std.testing.expectEqual(.logical_not, std.meta.activeTag(inverted.op));
    try std.testing.expect(inverted.operand != inverted_init);
    try std.testing.expect(exprs_list.items[inverted.operand].kind == .literal);

    const unit_let = switch (stmts_list.items[body.statements[4]].kind) {
        .let => |statement| statement,
        else => return error.ExpectedUnitLet,
    };
    const unit_init = unit_let.init orelse return error.ExpectedUnitInitializer;
    switch (exprs_list.items[unit_init].kind) {
        .unit => {},
        else => return error.ExpectedUnitExpression,
    }

    const return_statement = switch (stmts_list.items[body.statements[5]].kind) {
        .expr => |expr_id| expr_id,
        else => return error.ExpectedBareReturnStatement,
    };
    const return_expr = switch (exprs_list.items[return_statement].kind) {
        .return_ => |return_expr| return_expr,
        else => return error.ExpectedBareReturnExpression,
    };
    try std.testing.expect(return_expr.value == null);
}

const LookupTestTables = struct {
    exprs_list: std.ArrayListUnmanaged(exprs.Expr) = .empty,
    stmts_list: std.ArrayListUnmanaged(exprs.Statement) = .empty,
    pats_list: std.ArrayListUnmanaged(exprs.Pattern) = .empty,
    types_list: std.ArrayListUnmanaged(types.Type) = .empty,
    bodies_list: std.ArrayListUnmanaged(bodies.BodyKind) = .empty,

    fn deinit(tables: *LookupTestTables, alloc: std.mem.Allocator) void {
        tables.exprs_list.deinit(alloc);
        tables.stmts_list.deinit(alloc);
        tables.pats_list.deinit(alloc);
        tables.types_list.deinit(alloc);
        tables.bodies_list.deinit(alloc);
        tables.* = undefined;
    }
};

fn addLookupTestEntity(
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    kind: spine.EntityKind,
    name: []const u8,
    parent: ?spine.EntityId,
    resolved: ?spine.EntityId,
) !spine.EntityId {
    return g.symbol_table.add(.{
        .id = 0,
        .kind = kind,
        .name = try alloc.dupe(u8, name),
        .span = span_of,
        .visibility = .public,
        .parent = parent,
        .resolved = resolved,
        .renamed_to = null,
        .attributes = &.{},
    });
}

fn addLookupTestModule(
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    name: []const u8,
    parent: ?spine.EntityId,
    is_crate: bool,
    test_items: []const spine.EntityId,
) !void {
    _ = try g.addModule(.{
        .id = 0,
        .kind = if (is_crate) .root else .file,
        .name = try alloc.dupe(u8, name),
        .parent = parent,
        .source_path = null,
        .is_crate = is_crate,
        .is_extern = false,
        .span = span_of,
        .items = test_items,
        .attributes = &.{},
    });
}

fn appendLookupTestBodies(
    alloc: std.mem.Allocator,
    g: *const graph.CrateGraph,
    bodies_list: *std.ArrayListUnmanaged(bodies.BodyKind),
) !void {
    for (g.symbol_table.entities.items) |entity| {
        switch (entity.kind) {
            .fn_ => try bodies_list.append(alloc, .{ .fn_ = .{
                .params = &.{},
                .ret = .{ .prim = .unit },
                .body = 0,
            } }),
            .struct_ => try bodies_list.append(alloc, .{ .struct_ = .{
                .generic_params = &.{},
                .layout = .named,
                .fields = &.{},
            } }),
            else => try bodies_list.append(alloc, .none),
        }
    }
}

test "resolved type method keeps the imported parent identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const a_type = try addLookupTestEntity(alloc, &g, .struct_, "Item", null, null);
    const a_impl = try addLookupTestEntity(alloc, &g, .impl_, "Item", a_type, null);
    const a_method = try addLookupTestEntity(alloc, &g, .fn_, "value", a_impl, null);
    const b_type = try addLookupTestEntity(alloc, &g, .struct_, "Item", null, null);
    const b_impl = try addLookupTestEntity(alloc, &g, .impl_, "Item", b_type, null);
    const b_method = try addLookupTestEntity(alloc, &g, .fn_, "value", b_impl, null);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src = "",
        .mod_id = 0,
    };
    const ext: Ext = .{ .ctx = &ctx, .fn_id = 0 };

    try std.testing.expectEqual(b_method, resolveTypeMethod(&ext, b_type, "value"));
    try std.testing.expectEqual(b_method, resolveTypeMember(&ext, b_type, "value"));
    try std.testing.expect(a_method != b_method);
}
test "body type paths accept a leading global separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "leading_type", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .none);
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn leading_type() {
        \\    let y: ::core::option::Option<u8>;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const statement = switch (tables.stmts_list.items[block.statements[0]].kind) {
        .let => |value| value,
        else => return error.ExpectedLetStatement,
    };
    const type_id = statement.ty orelse return error.ExpectedAnnotatedType;
    switch (tables.types_list.items[type_id]) {
        .option => |inner| try std.testing.expectEqual(types.Type{ .prim = .u8 }, inner.*),
        else => return error.ExpectedOptionType,
    }
}

test "resolved parent glob exposes body-visible declarations and terminates cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    try std.testing.expectEqual(@as(spine.EntityId, 0), root_id);
    const child_id = try addLookupTestEntity(alloc, &g, .module, "tests", root_id, null);
    const helper_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "repeat_N",
        root_id,
        null,
    );
    const caller_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "parent_glob_body",
        child_id,
        null,
    );
    const parent_glob_id = try addLookupTestEntity(
        alloc,
        &g,
        .use_,
        "super::*",
        child_id,
        root_id,
    );
    const child_glob_id = try addLookupTestEntity(
        alloc,
        &g,
        .use_,
        "tests::*",
        root_id,
        child_id,
    );
    try g.addUse(.{
        .id = parent_glob_id,
        .kind = .glob,
        .local_name = "",
        .is_pub_export = false,
        .target = root_id,
        .span = span_of,
    });
    try g.addUse(.{
        .id = child_glob_id,
        .kind = .glob,
        .local_name = "",
        .is_pub_export = false,
        .target = child_id,
        .span = span_of,
    });

    const root_items = try alloc.dupe(
        spine.EntityId,
        &.{ child_id, helper_id, child_glob_id },
    );
    const child_items = try alloc.dupe(
        spine.EntityId,
        &.{ parent_glob_id, caller_id },
    );
    try addLookupTestModule(alloc, &g, "", null, true, root_items);
    try addLookupTestModule(alloc, &g, "tests", root_id, false, child_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\use super::*;
        \\fn parent_glob_body() {
        \\    repeat_N()
        \\}
        ,
        .mod_id = child_id,
    };
    try std.testing.expect(try extractFunction(&ctx, caller_id));

    const body_id = tables.bodies_list.items[caller_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const call_id = block.tail orelse return error.ExpectedFunctionTail;
    const call = switch (tables.exprs_list.items[call_id].kind) {
        .call => |value| value,
        else => return error.ExpectedCall,
    };
    switch (call.call_kind) {
        .free => |target| try std.testing.expectEqual(
            @as(exprs.DefId, helper_id),
            target,
        ),
        else => return error.ExpectedFreeCall,
    }

    var ext: Ext = .{ .ctx = &ctx, .fn_id = caller_id };
    defer ext.deinit();
    try std.testing.expect(resolveModuleItem(&ext, child_id, "missing") == null);
}

test "associated type method resolves through a parent glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const child_id = try addLookupTestEntity(alloc, &g, .module, "tests", root_id, null);
    const hasher_id = try addLookupTestEntity(
        alloc,
        &g,
        .struct_,
        "Hasher",
        root_id,
        null,
    );
    const impl_id = try addLookupTestEntity(
        alloc,
        &g,
        .impl_,
        "Hasher",
        hasher_id,
        null,
    );
    const method_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "repeat_N",
        impl_id,
        null,
    );
    const caller_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "glob_associated_body",
        child_id,
        null,
    );
    const glob_id = try addLookupTestEntity(
        alloc,
        &g,
        .use_,
        "super::*",
        child_id,
        root_id,
    );
    try g.addUse(.{
        .id = glob_id,
        .kind = .glob,
        .local_name = "",
        .is_pub_export = false,
        .target = root_id,
        .span = span_of,
    });

    const root_items = try alloc.dupe(spine.EntityId, &.{ child_id, hasher_id });
    const child_items = try alloc.dupe(spine.EntityId, &.{caller_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);
    // Omit the glob from this slice to exercise the exact-parent fallback used
    // by partially constructed graphs.
    try addLookupTestModule(alloc, &g, "tests", root_id, false, child_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\use super::*;
        \\fn glob_associated_body() {
        \\    Hasher::repeat_N()
        \\}
        ,
        .mod_id = child_id,
    };
    try std.testing.expect(try extractFunction(&ctx, caller_id));

    const body_id = tables.bodies_list.items[caller_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const call_id = block.tail orelse return error.ExpectedFunctionTail;
    const call = switch (tables.exprs_list.items[call_id].kind) {
        .call => |value| value,
        else => return error.ExpectedCall,
    };
    switch (call.call_kind) {
        .associated => |target| try std.testing.expectEqual(
            @as(exprs.DefId, method_id),
            target,
        ),
        else => return error.ExpectedAssociatedCall,
    }
}

test "malformed reference expression remains a fatal CST error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(
        alloc,
        &g,
        .fn_,
        "malformed_reference",
        root_id,
        null,
    );
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn malformed_reference() {
        \\    let borrowed = &mut;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expectError(error.MalformedCst, extractFunction(&ctx, fn_id));
}

test "local collect and flat_map calls use normal method lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const source_id = try addLookupTestEntity(alloc, &g, .struct_, "Source", root_id, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "local_methods", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{ source_id, fn_id });
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var source_segments = [_]types.PathSegment{.{ .name = "Source", .id = source_id }};
    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .none);
    try tables.bodies_list.append(alloc, .{ .struct_ = .{} });
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{.{
            .name = "source",
            .ty = .{ .path = .{ .segments = &source_segments } },
            .span = span_of,
        }},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn local_methods(source: Source) {
        \\    source.collect();
        \\    source.flat_map(1);
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 2), block.statements.len);
    const collect_statement = switch (tables.stmts_list.items[block.statements[0]].kind) {
        .expr => |value| value,
        else => return error.ExpectedCollectExpressionStatement,
    };
    const collect_call = switch (tables.exprs_list.items[collect_statement].kind) {
        .method_call => |value| value,
        else => return error.ExpectedCollectMethodCall,
    };
    try std.testing.expectEqualStrings(
        "collect",
        (g.symbol_table.get(collect_call.method) orelse return error.ExpectedCollectMethod).name,
    );
    const flat_map_statement = switch (tables.stmts_list.items[block.statements[1]].kind) {
        .expr => |value| value,
        else => return error.ExpectedFlatMapExpressionStatement,
    };
    const flat_map_call = switch (tables.exprs_list.items[flat_map_statement].kind) {
        .method_call => |value| value,
        else => return error.ExpectedFlatMapMethodCall,
    };
    try std.testing.expectEqualStrings(
        "flat_map",
        (g.symbol_table.get(flat_map_call.method) orelse return error.ExpectedFlatMapMethod).name,
    );
}

test "a method turbofish is recorded on the method call node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const source_id = try addLookupTestEntity(alloc, &g, .struct_, "Source", root_id, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "turbofish_methods", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{ source_id, fn_id });
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var source_segments = [_]types.PathSegment{.{ .name = "Source", .id = source_id }};
    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .none);
    try tables.bodies_list.append(alloc, .{ .struct_ = .{} });
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{.{
            .name = "source",
            .ty = .{ .path = .{ .segments = &source_segments } },
            .span = span_of,
        }},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn turbofish_methods(source: Source) {
        \\    source.parse::<u32>();
        \\    source.collect::<u8>();
        \\    source.len();
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 3), block.statements.len);

    const calls = [_][]const u8{ "parse", "collect", "len" };
    for (calls, 0..) |expected_name, index| {
        const statement = switch (tables.stmts_list.items[block.statements[index]].kind) {
            .expr => |value| value,
            else => return error.ExpectedExpressionStatement,
        };
        const call = switch (tables.exprs_list.items[statement].kind) {
            .method_call => |value| value,
            else => return error.ExpectedMethodCall,
        };
        try std.testing.expectEqualStrings(
            expected_name,
            (g.symbol_table.get(call.method) orelse return error.ExpectedMethodEntity).name,
        );
        // The turbofish survives as IR: `::<u32>` and `::<u8>` each carry one
        // argument, and the unturbofished `.len()` carries none.
        if (index < 2) {
            try std.testing.expectEqual(@as(usize, 1), call.generic_args.len);
        } else {
            try std.testing.expectEqual(@as(usize, 0), call.generic_args.len);
        }
    }

    // The two turbofish arguments name different primitives, so the recorded
    // list is per-call-site state and not one shared node.
    const parse_statement = switch (tables.stmts_list.items[block.statements[0]].kind) {
        .expr => |value| value,
        else => return error.ExpectedExpressionStatement,
    };
    const parse_call = switch (tables.exprs_list.items[parse_statement].kind) {
        .method_call => |value| value,
        else => return error.ExpectedMethodCall,
    };
    try std.testing.expectEqual(types.Prim.u32, parse_call.generic_args[0].prim);
    const collect_statement = switch (tables.stmts_list.items[block.statements[1]].kind) {
        .expr => |value| value,
        else => return error.ExpectedExpressionStatement,
    };
    const collect_call = switch (tables.exprs_list.items[collect_statement].kind) {
        .method_call => |value| value,
        else => return error.ExpectedMethodCall,
    };
    try std.testing.expectEqual(types.Prim.u8, collect_call.generic_args[0].prim);
}

test "lower bounded flat_map collect chains into canonical iterator IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "repeat", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .none);
    var bytes_slice: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{.{ .name = "bytes", .ty = .{ .slice = &bytes_slice }, .span = span_of }},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn repeat(bytes: &[u8]) {
        \\    (0..10).flat_map(|_| bytes.iter().cloned()).collect()
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const chain_id = block.tail orelse return error.ExpectedIteratorChainTail;
    const chain = switch (tables.exprs_list.items[chain_id].kind) {
        .iterator_chain => |value| value,
        else => return error.ExpectedIteratorChain,
    };
    try std.testing.expectEqual(exprs.IteratorTerminal.collect_vec, chain.terminal);
    try std.testing.expectEqual(@as(usize, 1), chain.adapters.len);

    const range = switch (tables.exprs_list.items[chain.source].kind) {
        .range => |value| value,
        else => return error.ExpectedRangeSource,
    };
    const range_start = switch (tables.exprs_list.items[range.start].kind) {
        .literal => |value| switch (value) {
            .int => |integer| integer,
            else => return error.ExpectedRangeStartLiteral,
        },
        else => return error.ExpectedRangeStartLiteral,
    };
    const range_end_id = range.end orelse return error.ExpectedRangeEndLiteral;
    const range_end = switch (tables.exprs_list.items[range_end_id].kind) {
        .literal => |value| switch (value) {
            .int => |integer| integer,
            else => return error.ExpectedRangeEndLiteral,
        },
        else => return error.ExpectedRangeEndLiteral,
    };
    try std.testing.expectEqual(@as(i128, 0), range_start.value);
    try std.testing.expectEqual(@as(i128, 10), range_end.value);
    try std.testing.expect(!range.inclusive);

    const closure = switch (chain.adapters[0]) {
        .flat_map => |value| value,
        else => return error.ExpectedFlatMapAdapter,
    };
    try std.testing.expectEqual(@as(usize, 1), closure.params.len);
    switch (tables.pats_list.items[closure.params[0]].kind) {
        .wildcard => {},
        else => return error.ExpectedWildcardClosureParameter,
    }
    try std.testing.expectEqual(@as(usize, 1), closure.captures.len);
    try std.testing.expectEqualStrings("bytes", closure.captures[0].name);
    try std.testing.expectEqual(exprs.CaptureMode.by_ref, closure.captures[0].mode);
    switch (tables.types_list.items[closure.captures[0].ty]) {
        .slice => |slice| {
            try std.testing.expect(slice.const_);
            try std.testing.expectEqual(types.Type{ .prim = .u8 }, slice.elem);
        },
        else => return error.ExpectedSliceCaptureType,
    }
    const closure_tail = closure.body.tail orelse return error.ExpectedClosureBodyTail;
    const cloned = switch (tables.exprs_list.items[closure_tail].kind) {
        .method_call => |value| value,
        else => return error.ExpectedClonedMethodCall,
    };
    try std.testing.expectEqualStrings(
        "cloned",
        (g.symbol_table.get(cloned.method) orelse return error.ExpectedClonedMethod).name,
    );
    const iter = switch (tables.exprs_list.items[cloned.receiver].kind) {
        .method_call => |value| value,
        else => return error.ExpectedIterMethodCall,
    };
    try std.testing.expectEqualStrings(
        "iter",
        (g.symbol_table.get(iter.method) orelse return error.ExpectedIterMethod).name,
    );
    switch (tables.exprs_list.items[iter.receiver].kind) {
        .path => |path| {
            try std.testing.expectEqualStrings(
                closure.captures[0].name,
                g.symbol_table.get(path.def).?.name,
            );
        },
        else => return error.ExpectedCapturedBytesPath,
    }
}

test "refuse malformed iterator closure arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "reject", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try tables.bodies_list.append(alloc, .none);
    var bytes_slice: types.Slice = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    try tables.bodies_list.append(alloc, .{ .fn_ = .{
        .params = &.{.{ .name = "bytes", .ty = .{ .slice = &bytes_slice }, .span = span_of }},
        .ret = .{ .prim = .unit },
        .body = 0,
    } });

    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn reject(bytes: &[u8]) {
        \\    let malformed = (0..3).flat_map(|a, b| bytes.iter().cloned()).collect();
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    try std.testing.expectEqual(@as(usize, 1), block.statements.len);
    for (block.statements) |statement_id| {
        const statement = switch (tables.stmts_list.items[statement_id].kind) {
            .let => |value| value,
            else => return error.ExpectedLetStatement,
        };
        const init_id = statement.init orelse return error.ExpectedIteratorRefusal;
        try std.testing.expect(tables.exprs_list.items[init_id].kind == .unsupported);
    }
}

const SourceTestFixture = struct {
    graph_store: graph.CrateGraph,
    tables: LookupTestTables,
    function_id: spine.EntityId,

    fn init(
        alloc: std.mem.Allocator,
        function_name: []const u8,
        source: []const u8,
        params: []const items.Param,
        return_type: types.Type,
    ) !SourceTestFixture {
        std.debug.assert(function_name.len > 0);
        std.debug.assert(source.len > 0);

        var graph_store = graph.CrateGraph.init(alloc);
        errdefer graph_store.deinit();
        const root_id = try addLookupTestEntity(alloc, &graph_store, .module, "", null, null);
        const function_id = try addLookupTestEntity(
            alloc,
            &graph_store,
            .fn_,
            function_name,
            root_id,
            null,
        );
        const root_items = try alloc.dupe(spine.EntityId, &.{function_id});
        try addLookupTestModule(alloc, &graph_store, "", null, true, root_items);
        try graph_store.addCrate(.{
            .name = try alloc.dupe(u8, "source-test"),
            .edition = 2021,
            .kind = .lib,
            .root = root_id,
            .deps = &.{},
            .is_translated = true,
        });

        var tables: LookupTestTables = .{};
        errdefer tables.deinit(alloc);
        try appendLookupTestBodies(alloc, &graph_store, &tables.bodies_list);
        switch (tables.bodies_list.items[function_id]) {
            .fn_ => |*function_body| {
                function_body.params = params;
                function_body.ret = return_type;
            },
            else => return error.ExpectedFunctionBody,
        }

        var ctx: Ctx = .{
            .alloc = alloc,
            .g = &graph_store,
            .exprs = &tables.exprs_list,
            .stmts = &tables.stmts_list,
            .pats = &tables.pats_list,
            .types = &tables.types_list,
            .bodies_list = &tables.bodies_list,
            .src = source,
            .mod_id = root_id,
        };
        if (!try extractFunction(&ctx, function_id)) return error.FunctionBodyMissing;
        return .{
            .graph_store = graph_store,
            .tables = tables,
            .function_id = function_id,
        };
    }

    fn deinit(fixture: *SourceTestFixture, alloc: std.mem.Allocator) void {
        fixture.tables.deinit(alloc);
        fixture.graph_store.deinit();
        fixture.* = undefined;
    }

    fn bodyTables(fixture: *const SourceTestFixture) bodies.Bodies {
        std.debug.assert(fixture.tables.exprs_list.items.len > 0);
        std.debug.assert(fixture.function_id < fixture.tables.bodies_list.items.len);
        return .{
            .exprs = fixture.tables.exprs_list.items,
            .stmts = fixture.tables.stmts_list.items,
            .pats = fixture.tables.pats_list.items,
            .types = fixture.tables.types_list.items,
            .bodies = fixture.tables.bodies_list.items,
        };
    }

    fn validate(fixture: *const SourceTestFixture) !void {
        const extracted = fixture.bodyTables();
        const rust_ir: ir.RustIr = .{
            .crate_name = "source-test",
            .graph = fixture.graph_store,
            .types = fixture.tables.types_list.items,
            .bodies = extracted,
        };
        try ir.validateForTranslation(&rust_ir);
    }
};

test "Wyhash open-ended byte slice validates without dropping its start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const slice = try alloc.create(types.Slice);
    slice.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
    const reference = try alloc.create(types.Ref);
    reference.* = .{ .mut = false, .pointee = .{ .slice = slice } };
    const slice_reference: types.Type = .{ .reference = reference };
    const params = try alloc.dupe(items.Param, &.{
        .{ .name = "data", .ty = slice_reference, .span = span_of },
    });
    var fixture = try SourceTestFixture.init(
        alloc,
        "tail",
        "fn tail(data: &[u8]) -> &[u8] { &data[4..] }",
        params,
        slice_reference,
    );
    defer fixture.deinit(alloc);
    try fixture.tables.types_list.append(alloc, slice_reference);

    const extracted = fixture.bodyTables();
    _ = try infer.solveWithGraph(alloc, &extracted, &fixture.graph_store);

    const body_id = fixture.tables.bodies_list.items[fixture.function_id].fn_.body;
    const body = switch (fixture.tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    _ = body.tail orelse return error.ExpectedFunctionTail;

    try fixture.validate();

    var found_start = false;
    for (fixture.tables.exprs_list.items) |expression| {
        if (expression.kind != .literal) continue;
        switch (expression.kind.literal) {
            .int => |integer| {
                if (integer.value == 4) found_start = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_start);
}

test "Adler typed local constants resolve and retain multiply initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var fixture = try SourceTestFixture.init(
        alloc,
        "checksum",
        \\fn checksum() -> usize {
        \\    const MOD: usize = 65_521;
        \\    const CHUNK_SIZE: usize = 5_552 * 4;
        \\    MOD * CHUNK_SIZE
        \\}
    ,
        &.{},
        .{ .prim = .usize },
    );
    defer fixture.deinit(alloc);
    try fixture.tables.types_list.append(alloc, .{ .prim = .usize });

    const extracted = fixture.bodyTables();
    var inferred = try infer.solveWithGraph(alloc, &extracted, &fixture.graph_store);
    defer inferred.deinit(alloc);
    const body_id = fixture.tables.bodies_list.items[fixture.function_id].fn_.body;
    const body = switch (fixture.tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    const tail_id = body.tail orelse return error.ExpectedFunctionTail;
    const tail_type_id = inferred.getType(tail_id) orelse return error.ExpectedUsizeType;
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        fixture.tables.types_list.items[tail_type_id],
    );

    try fixture.validate();

    var found_mod_path = false;
    var found_chunk_path = false;
    var initializer_multiply: ?exprs.NodeId = null;
    for (fixture.tables.exprs_list.items) |expression| {
        switch (expression.kind) {
            .path => |path| {
                const entity = fixture.graph_store.symbol_table.get(path.def) orelse continue;
                if (entity.parent != fixture.function_id) continue;
                if (std.mem.eql(u8, entity.name, "MOD")) found_mod_path = true;
                if (std.mem.eql(u8, entity.name, "CHUNK_SIZE")) found_chunk_path = true;
            },
            .binary => |binary| {
                if (binary.op != .mul) continue;
                const lhs_is_chunk = switch (fixture.tables.exprs_list.items[binary.lhs].kind) {
                    .literal => |literal| switch (literal) {
                        .int => |integer| integer.value == 5_552,
                        else => false,
                    },
                    else => false,
                };
                const rhs_is_factor = switch (fixture.tables.exprs_list.items[binary.rhs].kind) {
                    .literal => |literal| switch (literal) {
                        .int => |integer| integer.value == 4,
                        else => false,
                    },
                    else => false,
                };
                if (lhs_is_chunk and rhs_is_factor) initializer_multiply = expression.id;
            },
            else => {},
        }
    }
    try std.testing.expect(found_mod_path);
    try std.testing.expect(found_chunk_path);
    const multiply_id = initializer_multiply orelse return error.ExpectedConstMultiplyInitializer;
    const multiply_type_id = inferred.getType(multiply_id) orelse return error.ExpectedUsizeType;
    try std.testing.expectEqual(
        types.Type{ .prim = .usize },
        fixture.tables.types_list.items[multiply_type_id],
    );
}

test "panic and unreachable match arms preserve diverging branch types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const params = try alloc.dupe(items.Param, &.{
        .{ .name = "tag", .ty = .{ .prim = .u8 }, .span = span_of },
    });
    var fixture = try SourceTestFixture.init(
        alloc,
        "choose",
        \\fn choose(tag: u8) -> u64 {
        \\    match tag {
        \\        0 => 7u64,
        \\        1 => panic!("invalid tag"),
        \\        _ => unreachable!(),
        \\    }
        \\}
    ,
        params,
        .{ .prim = .u64 },
    );
    defer fixture.deinit(alloc);
    try fixture.tables.types_list.append(alloc, .{ .prim = .u8 });
    try fixture.tables.types_list.append(alloc, .{ .prim = .u64 });
    try fixture.tables.types_list.append(alloc, .{ .prim = .never });

    const extracted = fixture.bodyTables();
    var inferred = try infer.solveWithGraph(alloc, &extracted, &fixture.graph_store);
    defer inferred.deinit(alloc);
    const body_id = fixture.tables.bodies_list.items[fixture.function_id].fn_.body;
    const body = switch (fixture.tables.exprs_list.items[body_id].kind) {
        .block => |block| block,
        else => return error.ExpectedFunctionBlock,
    };
    const tail_id = body.tail orelse return error.ExpectedFunctionTail;
    const match_expression = switch (fixture.tables.exprs_list.items[tail_id].kind) {
        .match => |match_expression| match_expression,
        else => return error.ExpectedMatchExpression,
    };
    try std.testing.expectEqual(@as(usize, 3), match_expression.arms.len);
    const result_type_id = inferred.getType(tail_id) orelse return error.ExpectedU64Type;
    try std.testing.expectEqual(
        types.Type{ .prim = .u64 },
        fixture.tables.types_list.items[result_type_id],
    );

    try fixture.validate();

    for (match_expression.arms[1..]) |arm| {
        const branch_type_id = inferred.getType(arm.body) orelse return error.ExpectedNeverType;
        switch (fixture.tables.types_list.items[branch_type_id]) {
            .prim => |primitive| try std.testing.expectEqual(types.Prim.never, primitive),
            else => return error.ExpectedNeverType,
        }
    }
}

/// A `use_` entity binding `local_name` to a rooted path with no graph entity,
/// the shape the extractor reads for `use alloc::vec::Vec;`.
fn addExternalUseTestAlias(
    alloc: std.mem.Allocator,
    g: *graph.CrateGraph,
    parent: spine.EntityId,
    source_text: []const u8,
    local_name: []const u8,
    path: []const []const u8,
) !spine.EntityId {
    const use_id = try addLookupTestEntity(alloc, g, .use_, source_text, parent, null);
    try g.addUse(.{
        .id = use_id,
        .kind = .{ .external = .{ .path = try alloc.dupe([]const u8, path) } },
        .local_name = try alloc.dupe(u8, local_name),
        .is_pub_export = false,
        .target = 0,
        .span = span_of,
    });
    return use_id;
}

/// The type of the first statement of a one-block fn body, for the type-path
/// tests that assert on a single annotated `let`.
fn annotatedLetType(tables: *const LookupTestTables, fn_id: spine.EntityId) !types.Type {
    const body_id = tables.bodies_list.items[fn_id].fn_.body;
    const block = switch (tables.exprs_list.items[body_id].kind) {
        .block => |value| value,
        else => return error.ExpectedFunctionBlock,
    };
    const statement = switch (tables.stmts_list.items[block.statements[0]].kind) {
        .let => |value| value,
        else => return error.ExpectedLetStatement,
    };
    const type_id = statement.ty orelse return error.ExpectedAnnotatedType;
    return tables.types_list.items[type_id];
}

test "a type naming an external use alias lowers to that external nominal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "alias_type", root_id, null);
    const use_id = try addExternalUseTestAlias(
        alloc,
        &g,
        root_id,
        "alloc::vec::Vec",
        "Vec",
        &.{ "alloc", "vec", "Vec" },
    );
    const root_items = try alloc.dupe(spine.EntityId, &.{ fn_id, use_id });
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\use alloc::vec::Vec;
        \\
        \\fn alias_type() {
        \\    let v: Vec<u8>;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const external = switch (try annotatedLetType(&tables, fn_id)) {
        .external_nominal => |value| value,
        else => return error.ExpectedExternalNominalType,
    };
    try std.testing.expectEqual(@as(usize, 3), external.path.len);
    try std.testing.expectEqualStrings("alloc", external.path[0]);
    try std.testing.expectEqualStrings("vec", external.path[1]);
    try std.testing.expectEqualStrings("Vec", external.path[2]);
    try std.testing.expectEqual(@as(usize, 1), external.args.len);
    try std.testing.expectEqual(types.Type{ .prim = .u8 }, external.args[0]);
}

test "a scoped type path head bound by an external use alias names that external" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "scoped_alias_type", root_id, null);
    const use_id = try addExternalUseTestAlias(
        alloc,
        &g,
        root_id,
        "core::iter",
        "iter",
        &.{ "core", "iter" },
    );
    const root_items = try alloc.dupe(spine.EntityId, &.{ fn_id, use_id });
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\use core::iter;
        \\
        \\fn scoped_alias_type() {
        \\    let sink: iter::FromIterator<char>;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const external = switch (try annotatedLetType(&tables, fn_id)) {
        .external_nominal => |value| value,
        else => return error.ExpectedExternalNominalType,
    };
    try std.testing.expectEqual(@as(usize, 3), external.path.len);
    try std.testing.expectEqualStrings("core", external.path[0]);
    try std.testing.expectEqualStrings("iter", external.path[1]);
    try std.testing.expectEqualStrings("FromIterator", external.path[2]);
    try std.testing.expectEqual(@as(usize, 1), external.args.len);
    try std.testing.expectEqual(types.Type{ .prim = .char }, external.args[0]);
}

test "a bare external crate root is not a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "bare_root", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn bare_root() {
        \\    let v: std;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expectError(error.UnresolvedNominalType, extractFunction(&ctx, fn_id));
}

test "a type argument placeholder lowers to the inference placeholder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var g = graph.CrateGraph.init(alloc);
    defer g.deinit();

    const root_id = try addLookupTestEntity(alloc, &g, .module, "", null, null);
    const fn_id = try addLookupTestEntity(alloc, &g, .fn_, "inferred_arg", root_id, null);
    const root_items = try alloc.dupe(spine.EntityId, &.{fn_id});
    try addLookupTestModule(alloc, &g, "", null, true, root_items);

    var tables: LookupTestTables = .{};
    defer tables.deinit(alloc);
    try appendLookupTestBodies(alloc, &g, &tables.bodies_list);
    var ctx: Ctx = .{
        .alloc = alloc,
        .g = &g,
        .exprs = &tables.exprs_list,
        .stmts = &tables.stmts_list,
        .pats = &tables.pats_list,
        .types = &tables.types_list,
        .bodies_list = &tables.bodies_list,
        .src =
        \\fn inferred_arg() {
        \\    let v: core::option::Option<_>;
        \\}
        ,
        .mod_id = root_id,
    };
    try std.testing.expect(try extractFunction(&ctx, fn_id));

    const inner = switch (try annotatedLetType(&tables, fn_id)) {
        .option => |value| value,
        else => return error.ExpectedOptionType,
    };
    const placeholder = switch (inner.*) {
        .external_nominal => |value| value,
        else => return error.ExpectedInferencePlaceholderArg,
    };
    try std.testing.expectEqual(@as(usize, 1), placeholder.path.len);
    try std.testing.expectEqualStrings("_", placeholder.path[0]);
    try std.testing.expectEqual(@as(usize, 0), placeholder.args.len);
}
